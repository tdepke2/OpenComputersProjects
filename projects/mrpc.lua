--[[
Remote procedure call library for mnet.

requirements:
  * one or more rpc servers can run on a machine (each one claims a single vport)
  * synchronous and asynchronous calls (chosen when client does call)
  * able to get a return value (except from broadcast)
  * function definitions

the general purpose event handler at bottom of this page is good: https://ocdoc.cil.li/api:event

rpc_server = mrpc.newServer(port)

client:
<return vals> rpc_server.sync.<call name>(host, ...)
    <hostseq> rpc_server.async.<call name>(host, ...)

server:
rpc_server.functions.<call name> = function
rpc_server.handleMessage(obj, host, port, message)
<call name> called with (obj, host, ...)

both:
rpc_server.declareFunction(name[, {args}[, {returns}] ])
rpc_server.addDeclarations({decl})

decl = {}
decl[1] = {name, {args}, {returns}}
...




Note: do not try to save a reference to the functions called with rpc_server:sync.<call name>(), and same for rpc_server:async and rpc_server:unpack.


--]]

local computer = require("computer")
local serialization = require("serialization")

local include = require("include")
local dlog = include("dlog")
local mnet = include("mnet")

local mrpc = {}
local MrpcClass = {}

local cachedObj, cachedCallName

MrpcClass.__index = function(t, k)
  cachedObj = t
  return MrpcClass[k]
end

function mrpc.newServer(port)
  local self = setmetatable({}, MrpcClass)
  
  dlog.checkArgs(port, "number")
  self.port = port
  
  -- Function callbacks registered by the server and executed when a matching
  -- remote call is received.
  self.functions = {}
  
  -- Sets the action to take when no callback is registered for a given remote
  -- call. Normally this should do nothing, but it is possible to override the
  -- metatable to log the event here or even throw an error.
  setmetatable(self.functions, {
    __index = function(t, k)
      dlog.out("mrpc", "No function registered for call to \"", k, "\".")
    end
  })
  
  -- Declarations for remote calls and expected data types. Each call name has a
  -- table of strings for these expected types, or a value of "true" if there are
  -- none for that header.
  self.callTypes = {}
  
  setmetatable(self.callTypes, {
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

-- Serializes the given arguments into a table and returns a string containing
-- the header and this table.
local function syncSend(host, ...)
  xassert(host ~= "*", "broadcast address not allowed for synchronous call.")
  local self, callName, arg = cachedObj, cachedCallName, table.pack(...)
  verifyCallTypes(callName, self.callTypes[callName .. ",a"], arg, "argument", 1)
  
  while self.syncSendMutex do
    os.sleep(0.05)
  end
  self.syncSendMutex = true
  
  self.returnedCallName = nil
  self.returnedMessage = nil
  
  local sendResult = mnet.send(host, self.port, "s," .. callName .. (arg.n == 0 and "{n=0}" or serialization.serialize(arg)), true, true)
  if not sendResult then
    self.syncSendMutex = false
    xassert(false, "remote call to \"", callName, "\" for host \"", host, "\" timed out.")
  end
  
  local timeEnd = computer.uptime() + mnet.dropTime
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

local function asyncSend(host, ...)
  local self, callName, arg = cachedObj, cachedCallName, table.pack(...)
  verifyCallTypes(callName, self.callTypes[callName .. ",a"], arg, "argument", 1)
  
  return mnet.send(host, self.port, "a," .. callName .. (arg.n == 0 and "{n=0}" or serialization.serialize(arg)), host ~= "*")
end

-- Deserializes the given string message (contains the header and table data)
-- and returns the original data. An error is thrown if data in the message does
-- not match the specified types defined for the header.
local function doUnpack(message)
  local self, callName = cachedObj, cachedCallName
  if not string.find(message, "^.," .. callName .. "{n=0}") then
    
    
    dlog.out("mrpc", "watch out im calling unserialize()")
    
    
    
    
    local arg = serialization.unserialize(string.sub(message, #callName + 3))
    xassert(arg, "failed to deserialize the provided message.")
    return table.unpack(arg, 1, arg.n)
  end
  
  
  dlog.out("mrpc", "skipped call to unserialize()")
end

MrpcClass.sync = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return syncSend
  end
})

MrpcClass.async = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return asyncSend
  end
})

MrpcClass.unpack = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return doUnpack
  end
})

-- packer.defineHeader(header: string[, name1: string, types1: string, ...])
-- 
-- Define a packet header and the list of accepted values. For each value, give
-- a name (purely for making it clearer what the value represents in the code)
-- and a comma-separated list of types. The string "any" can also be used for
-- the types to allow any value.
function MrpcClass.declareFunction(callName, arguments, results)
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

function MrpcClass.addDeclarations(tbl)
  for callName, v in pairs(tbl) do
    MrpcClass.declareFunction(callName, v[1], v[2])
  end
end

-- packer.handlePacket(obj: table|nil[, address: string, port: number,
--   message: string])
-- 
-- Looks up the packet handler in packer.callbacks for the given packet, and
-- executes the action. If no callback is registered, behavior depends on the
-- metatable of packer.callbacks (nothing happens by default). The obj argument
-- should be used if the callbacks are set to class member functions. Otherwise,
-- nil can be passed for obj and the first argument in a callback can be
-- ignored. The address, port, and message arguments are the same as returned
-- from wnet.receive (message contains the full packet with header and data
-- segments).
function MrpcClass.handleMessage(obj, host, port, message)
  local self = cachedObj
  if port ~= self.port then
    return false
  end
  local messageType = string.byte(message)
  local callName = string.match(message, ".,([^{]*)")
  
  if messageType == string.byte("r") then
    if self.syncSendMutex then
      self.returnedCallName = callName
      self.returnedMessage = message
    end
  elseif self.functions[callName] then
    if messageType == string.byte("s") then
      local results = table.pack(self.functions[callName](obj, host, self.unpack[callName](message)))
      verifyCallTypes(callName, self.callTypes[callName .. ",r"], results, "result", 0)
      
      mnet.send(host, self.port, "r," .. callName .. (results.n == 0 and "{n=0}" or serialization.serialize(results)), true)
    else
      self.functions[callName](obj, host, self.unpack[callName](message))
    end
  end
  return true
end

return mrpc
