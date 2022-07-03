--[[
Remote procedure calls for mnet.

The mrpc module can be used to create RPC servers that manage incoming and
outgoing requests to run functions on a remote system. Multiple server instances
can run on one machine, as long as each one is using a unique port number (same
as the virtual port in mnet). There is also support for synchronous and
asynchronous calls. Synchronous calls will block the current process while
waiting for the remote call to finish execution and return results (more like
traditional RPC). Asynchronous calls do not block, and therefore have some
performance benefits. The downside of using async is that the results of the
remote function are not returned. However, this can be resolved by having the
receiving side run an async call with the results back to the original sender.

When setting up the RPC server, function declarations must be given before a
remote call can be issued. It is required to specify the "call names" that can
be used, and optional to specify the expected arguments and return values. This
requirement is put in place to encourage the user to define a common interface
of the remote calls that an RPC server accepts. It's best to put this interface
in a separate Lua script and use MrpcServer.addDeclarations() to pull it in.

Note: it is not advised to save a reference to the functions returned by
addressing a call name (such as from MrpcServer.sync.<call name>). The function
context is only valid during indexing from the MrpcServer instance because of
the way that metatables are used to cache state.

Another note: be careful when binding functions that take a long time to
process. Running them in the same thread as mnet.receive() can block handling of
other network messages. One option to prevent this is to run the slow functions
in a separate thread and pass results from mnet.receive() over a queue.

Most of this code was adapted from the old packer.lua module. The packer module
was an early RPC prototype and was independent from the underlying network
protocol (wnet at the time). This was great for modularity, but packer also had
functions registered in a global table and an ugly call syntax.

Example usage:
-- Create server on port 1024.
local mrpc_server = mrpc.newServer(1024)

-- Declare function say_hello.
mrpc_server.declareFunction("say_hello", {
  "senderMessage", "string",
  "extraData", "any",
})

-- Register function to run when we receive a say_hello request.
mrpc_server.functions.say_hello = function(obj, host, senderMessage, extraData)
  print("Hello from " .. host .. ": " .. senderMessage)
  print(tostring(extraData))
end

-- Request other active servers to run say_hello.
mrpc_server.async.say_hello("*", "anyone out there?", {"extra", "data"})
print("Sent request to run say_hello on other servers.")

-- Respond to requests from other servers.
local listenerThread = thread.create(function()
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(nil, host, port, message)
  end
end)
--]]


local computer = require("computer")
local serialization = require("serialization")

local include = require("include")
local dlog = include("dlog")
local mnet = include("mnet")

-- Maximum seconds for a synchronous call to block execution after the request has been acknowledged. Increase this value if there are long-running functions on the receiving side.
local SYNC_RESULTS_TIMEOUT = mnet.dropTime + 1.0

local mrpc = {}
local MrpcServer = {}

-- These values are set from metatable __index events to keep track of state in chained function calls.
local cachedObj, cachedCallName

MrpcServer.__index = function(t, k)
  cachedObj = t
  return MrpcServer[k]
end


-- mrpc.newServer(port: number): table
-- 
-- Creates a new instance of an RPC server with a given port number. This server
-- is used for both requesting functions to run on a remote machine (and
-- optionally get return values back), and handling function call requests from
-- other machines. Once a server has been created on the sender and receiver
-- (with same port number), a remote call defined on both sides, and a function
-- bound on the receiving end, the sender can start sending requests to the
-- receiver.
-- Note that the object this function returns is an instance of MrpcServer, and
-- unlike most class designs the methods are invoked with a dot instead of colon
-- operator (this enables the syntax with the sync and async methods).
function mrpc.newServer(port)
  local self = setmetatable({}, MrpcServer)
  
  dlog.checkArgs(port, "number")
  self.port = port
  
  -- Function callbacks registered by the server and executed when a matching
  -- remote call is received. If no matching callback is found, a message is
  -- logged. It is also an option to override this metatable to do nothing or
  -- even throw an error.
  self.functions = setmetatable({}, {
    __index = function(t, k)
      dlog.out("mrpc", "No function registered for call to \"", k, "\".")
    end
  })
  
  -- Declarations for remote calls and expected data types. Each call name has a
  -- sequence of strings for expected arguments, or a value of "true" if there
  -- are none for that call (where the key is callName .. ",a"). If there are
  -- expected return values, another sequence of strings is provided (with the
  -- key callName .. ",r").
  self.callTypes = setmetatable({}, {
    __index = function(t, k)
      xassert(false, "attempt to index self.callTypes for \"", string.sub(k, 1, -3), "\" failed (call name not declared).")
    end
  })
  
  self.syncSendMutex = false
  self.returnedCallName = nil
  self.returnedMessage = nil
  
  return self
end


-- Confirms that the given values in the packed table packedVals match the
-- specified types in typesList.
local function verifyCallTypes(callName, typesList, packedVals, valName, valOffset)
  if type(typesList) == "table" then
    if #typesList < packedVals.n then
      xassert(false, "number of ", valName, "s for call to \"", callName, "\" is incorrect (", #typesList + valOffset, " expected, got ", packedVals.n + valOffset, ").")
    end
    for i, validTypes in ipairs(typesList) do
      if not string.find(validTypes, type(packedVals[i]), 1, true) and validTypes ~= "any" then
        xassert(false, "bad ", valName, " for call to \"", callName, "\" at index #", i + valOffset, " (", validTypes, " expected, got ", type(packedVals[i]), ").")
      end
    end
  end
end


-- Helper function for MrpcServer.sync.
local function syncSend(host, ...)
  xassert(host ~= "*", "broadcast address not allowed for synchronous call.")
  local self, callName, arg = cachedObj, cachedCallName, table.pack(...)
  verifyCallTypes(callName, self.callTypes[callName .. ",a"], arg, "argument", 1)
  
  -- Attempt to grab the mutex, or wait for other threads to finish their syncSend() calls.
  while self.syncSendMutex do
    os.sleep(0.05)
  end
  self.syncSendMutex = true
  
  -- Results from the remote call will go here, and are set by MrpcServer.handleMessage().
  self.returnedCallName = nil
  self.returnedMessage = nil
  
  -- Serialize arguments into a message and send to host. Wait for it to be received.
  local sendResult = mnet.send(host, self.port, "s," .. callName .. (arg.n == 0 and "{n=0}" or serialization.serialize(arg)), true, true)
  if not sendResult then
    self.syncSendMutex = false
    xassert(false, "remote call to \"", callName, "\" for host \"", host, "\" timed out.")
  end
  
  -- Continue waiting until results have arrived from receiving end.
  local timeEnd = computer.uptime() + SYNC_RESULTS_TIMEOUT
  while computer.uptime() < timeEnd and self.returnedCallName ~= callName do
    os.sleep(0.05)
  end
  
  local returnedCallName, returnedMessage = self.returnedCallName, self.returnedMessage
  self.returnedCallName, self.returnedMessage = nil, nil
  self.syncSendMutex = false
  
  if returnedCallName == callName then
    return self.unpack[returnedCallName](returnedMessage)
  else
    xassert(false, "results from call to \"", callName, "\" for host \"", host, "\" timed out.")
  end
end


-- Helper function for MrpcServer.async.
local function asyncSend(host, ...)
  local self, callName, arg = cachedObj, cachedCallName, table.pack(...)
  verifyCallTypes(callName, self.callTypes[callName .. ",a"], arg, "argument", 1)
  
  -- Serialize arguments into a message and send to host(s). No waiting for message to be received.
  return mnet.send(host, self.port, "a," .. callName .. (arg.n == 0 and "{n=0}" or serialization.serialize(arg)), host ~= "*")
end


-- Helper function for MrpcServer.unpack.
local function doUnpack(message)
  local self, callName = cachedObj, cachedCallName
  
  -- Only run expensive call to serialization.unserialize() if non-empty table in message.
  if not string.find(message, "^.," .. callName .. "{n=0}") then
    local arg = serialization.unserialize(string.sub(message, #callName + 3))
    xassert(arg, "failed to deserialize the provided message.")
    return table.unpack(arg, 1, arg.n)
  end
end


-- MrpcServer.sync.<call name>(host: string, ...): ...
-- 
-- Requests the given host to run a function call with the given arguments. The
-- host must not be the broadcast address. As this is the synchronous version,
-- the function will block the current process until return values are received
-- from the remote host or the request times out. Any other synchronous calls
-- made to this MrpcServer instance in other threads will wait their turn to
-- run. Returns the results from the remote function call, or throws an error if
-- request timed out (or other error occurred).
MrpcServer.sync = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return syncSend
  end
})


-- MrpcServer.async.<call name>(host: string, ...): string
-- 
-- Similar to MrpcServer.sync, requests the given host(s) to run a function call
-- with the given arguments. The host can be the broadcast address. This
-- asynchronous version will not block the current process but also does not
-- return the results of the remote call. This internally uses the reliable
-- message protocol in mnet, so async calls are guaranteed to arrive in the same
-- order they were sent (even alternating sync and async calls guarantees
-- in-order delivery). Returns the host-sequence pair of the sent message (can
-- be used to check for connection failure, see mnet for details).
MrpcServer.async = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return asyncSend
  end
})


-- MrpcServer.unpack.<call name>(message: string): ...
-- 
-- Helper function that deserializes the given RPC formatted message to extract
-- the arguments. The message format is "<type>,<call name>{<packed table>}"
-- where type is either 's', 'a', or 'r' (for sync, async, and results), call
-- name is the name bound to the function call, and packed table is a serialized
-- table of the arguments with key 'n' storing the total.
MrpcServer.unpack = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return doUnpack
  end
})


-- MrpcServer.declareFunction(callName: string, arguments: table|nil,
--   results: table|nil)
-- 
-- Specifies a function declaration and optionally the expected data types for
-- arguments and return values. A function needs to be declared the same way on
-- two machines before one can call the function on the other. The callName
-- specifies the name bound to the function. If the arguments and results are
-- provided, they should each be a sequence with the format {name1: string,
-- types1: string, ...} where name1 is the first parameter name (purely for
-- making it clear what the value represents) and types1 is a comma-separated
-- list of accepted types (or the string "any").
function MrpcServer.declareFunction(callName, arguments, results)
  dlog.checkArgs(callName, "string", arguments, "table,nil", results, "table,nil")
  local self = cachedObj
  
  local argTypes = {}
  if arguments then
    for i = 1, #arguments / 2 do
      argTypes[i] = arguments[i * 2]
      xassert(type(argTypes[i]) == "string", "arguments definition at index #", i * 2, " must be a string.")
    end
  end
  local resultTypes = {}
  if results then
    for i = 1, #results / 2 do
      resultTypes[i] = results[i * 2]
      xassert(type(resultTypes[i]) == "string", "results definition at index #", i * 2, " must be a string.")
    end
  end
  
  self.callTypes[callName .. ",a"] = (arguments and argTypes or true)
  self.callTypes[callName .. ",r"] = (results and resultTypes)
end


-- MrpcServer.addDeclarations(declarationMap: table)
-- 
-- Iterates a table and calls MrpcServer.declareFunction() for each entry. Each
-- key in declarationMap should be the call name of the function to declare and
-- the value should be another table containing the same arguments and results
-- tables that would be passed to MrpcServer.declareFunction(). The intended way
-- to use this is create a Lua script that returns the declarationMap table,
-- then use dofile() to pass it into this function.
function MrpcServer.addDeclarations(declarationMap)
  for callName, v in pairs(declarationMap) do
    MrpcServer.declareFunction(callName, v[1], v[2])
  end
end


-- MrpcServer.handleMessage(obj: any[, host: string, port: number,
--   message: string]): boolean
-- 
-- When called with the results of mnet.receive(), checks if the port and
-- message match an incoming request to run a function (or results from a sent
-- request). If the message is requesting to run a function and the
-- corresponding function has been assigned to MrpcServer.functions.<call name>,
-- it is called with obj, host, and all of the sent arguments. The obj argument
-- should be used if the bound function is a class member. Otherwise, nil can be
-- passed for obj and the first argument in the function can be ignored. Returns
-- true if the message was handled by this server, or false if not.
function MrpcServer.handleMessage(obj, host, port, message)
  local self = cachedObj
  if port ~= self.port then
    return false
  end
  local messageType = string.byte(message)
  local callName = string.match(message, ".,([^{]*)")
  
  if messageType == string.byte("r") then
    -- Message is results from a previous syncSend() call, cache it for later.
    if self.syncSendMutex then
      self.returnedCallName = callName
      self.returnedMessage = message
    end
  elseif self.functions[callName] then
    if messageType == string.byte("s") then
      -- Message is from a synchronous call, need to send the results back.
      local results = table.pack(self.functions[callName](obj, host, self.unpack[callName](message)))
      if rawget(self.callTypes, callName .. ",r") then
        verifyCallTypes(callName, self.callTypes[callName .. ",r"], results, "result", 0)
      end
      
      mnet.send(host, self.port, "r," .. callName .. (results.n == 0 and "{n=0}" or serialization.serialize(results)), true)
    else
      -- Message is from an asynchronous call, just call the function.
      self.functions[callName](obj, host, self.unpack[callName](message))
    end
  end
  return true
end

return mrpc
