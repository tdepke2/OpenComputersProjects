--[[
requirements:
  * one or more rpc servers can run on a machine (each one claims a single vport)
  * synchronous and asynchronous calls (chosen when client does call)
  * able to get a return value (even from broadcast?)
  * function definitions

the general purpose event handler at bottom of this page is good: https://ocdoc.cil.li/api:event

instance = mrpc.registerPort(...)

client:
<return vals> mrpc.sync.<function name>(host, ...)
    <hostseq> mrpc.async.<function name>(host, ...)

server:
mrpc.functions.<function name> = function
mrpc.handleMessage(obj, host, port, message)
<function name> called with (obj, host, ...)

both:
mrpc.declareFunction(name[, {args}[, {returns}] ])
mrpc.addDeclarations({decl})

decl = {}
decl[1] = {name, {args}, {returns}}
...






--]]

local serialization = require("serialization")

-- Check for optional dependency dlog.
local dlog, xassert
do
  local status, ret = pcall(require, "dlog")
  if status then
    dlog = ret
    xassert = dlog.xassert
  else
    -- Fallback option for xassert if dlog not found.
    xassert = function(v, ...)
      assert(v, string.rep("%s", select("#", ...)):format(...))
    end
  end
end

local mrpc = {}
local mrpcInterface = {}
local cachedPort

mrpc.ports = {}

local portMetatable = {
  __index = function(t, k)
    cachedPort = t.port
    return mrpcInterface[k]
  end
}

function mrpc.registerPort(port)
  mrpc.ports[port] = mrpc.ports[port] or setmetatable({port = port}, portMetatable)
  return mrpc.ports[port]
end










local cachedCallName

-- Function callbacks registered by the server and executed when a matching
-- remote call is received.
mrpcInterface.functions = {}

-- Sets the action to take when no callback is registered for a given remote
-- call. Normally this should do nothing, but it is possible to override the
-- metatable to log the event here or even throw an error.
setmetatable(mrpcInterface.functions, {
  __index = function(t, k)
    if dlog then
      dlog.out("mrpc", "No function registered for call to \"", k, "\".")
    end
    return nil
  end
})

-- Declarations for remote calls and expected data types. Each call name has a
-- table of strings for these expected types, or a value of "true" if there are
-- none for that header.
mrpcInterface.callTypes = {}



mrpcInterface.callTypes["name\0" .. port] = {} or true
-- optional return:
mrpcInterface.callTypes["name\0" .. port .. "r"] = {}




setmetatable(mrpcInterface.callTypes, {
  __index = function(t, k)
    xassert(false, "attempt to index mrpcInterface.callTypes for \"", k, "\" failed (call name not declared).")
  end
})

-- Serializes the given arguments into a table and returns a string containing
-- the header and this table.
local function syncSend(host, ...)
  local arg = table.pack(...)
  local namePortPair = cachedCallName .. "\0" .. cachedPort
  
  if type(mrpcInterface.callTypes[namePortPair]) == "table" then
    if #mrpcInterface.callTypes[namePortPair] ~= arg.n then
      xassert(false, "number of arguments passed for call to \"", cachedCallName, "\" is incorrect (", #mrpcInterface.callTypes[namePortPair], " expected, got ", arg.n, ").")
    end
    for i, validTypes in ipairs(mrpcInterface.callTypes[namePortPair]) do
      if not string.find(validTypes, type(arg[i]), 1, true) and validTypes ~= "any" then
        xassert(false, "bad argument for call to \"", cachedCallName, "\" at index #", i, " (", validTypes, " expected, got ", type(arg[i]), ").")
      end
    end
  end
  
  mnet.send(host, cachedPort, "s," .. cachedCallName .. (arg.n == 0 and "{n=0}" or serialization.serialize(arg)), host ~= "*", true)
end

local function asyncSend(host, ...)
  local arg = table.pack(...)
  local namePortPair = cachedCallName .. "\0" .. cachedPort
  
  if type(mrpcInterface.callTypes[namePortPair]) == "table" then
    if #mrpcInterface.callTypes[namePortPair] ~= arg.n then
      xassert(false, "number of arguments passed for call to \"", cachedCallName, "\" is incorrect (", #mrpcInterface.callTypes[namePortPair], " expected, got ", arg.n, ").")
    end
    for i, validTypes in ipairs(mrpcInterface.callTypes[namePortPair]) do
      if not string.find(validTypes, type(arg[i]), 1, true) and validTypes ~= "any" then
        xassert(false, "bad argument for call to \"", cachedCallName, "\" at index #", i, " (", validTypes, " expected, got ", type(arg[i]), ").")
      end
    end
  end
  
  mnet.send(host, cachedPort, "a," .. cachedCallName .. (arg.n == 0 and "{n=0}" or serialization.serialize(arg)), host ~= "*")
end

-- Deserializes the given string message (contains the header and table data)
-- and returns the original data. An error is thrown if data in the message does
-- not match the specified types defined for the header.
local function doUnpack(message)
  if not string.find(message, "^.," .. cachedCallName .. "{n=0}") then
  
  
    print("watch out im calling unserialize()")
  
  
  
  
    local arg = serialization.unserialize(string.sub(message, #cachedCallName + 3))
    xassert(arg, "failed to deserialize the provided message.")
    return table.unpack(arg, 1, arg.n)
  end
end

mrpcInterface.sync = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return syncSend
  end
})

mrpcInterface.async = setmetatable({}, {
  __index = function(t, k)
    cachedCallName = k
    return asyncSend
  end
})

mrpcInterface.unpack = setmetatable({}, {
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
function mrpcInterface.declareFunction(port, callName, arguments, results)
  if dlog then
    dlog.checkArgs(port, "number", callName, "string", arguments, "table,nil", results, "table,nil")
  end
  
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
  
  mrpcInterface.callTypes[callName .. "\0" .. port] = (next(argTypes) == nil and true or argTypes)
  mrpcInterface.callTypes[callName .. "\0" .. port .. "r"] = (next(resultTypes) ~= nil and resultTypes or nil)
end

function mrpcInterface.addDeclarations(port, tbl)
  for callName, v in pairs(tbl) do
    mrpcInterface.declareFunction(port, callName, v[1], v[2])
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
function mrpcInterface.handleMessage(obj, host, port, message)
  if port ~= cachedPort then
    return
  end
  local namePortPair = string.match(message, ".,([^{]*)") .. "\0" .. cachedPort
  if mrpcInterface.functions[namePortPair] then
    if string.byte(message) == string.byte("s") then
      
      
      
    else
      mrpcInterface.functions[namePortPair](obj, host, mrpcInterface.unpack[namePortPair](message))
    end
  end
end

--[[
-- packer.extractHeader([address: string, port: number, message: string]):
--     string|nil, number|nil, string|nil, string|nil
-- 
-- Convenience function to find the header attached to a packet. Returns the
-- address, port, header, and message (message is unmodified and still contains
-- the header). If message is not a string, returns nil.
function mrpcInterface.extractHeader(address, port, message)
  if type(message) ~= "string" then
    return
  end
  local header = string.match(message, "[^{]*")
  return address, port, header, message
end
--]]

return mrpc
