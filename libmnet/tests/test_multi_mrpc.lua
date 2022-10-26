--[[
Test interaction of multiple RPC servers running on the same machine, and
confirm two servers that share the same port still function. If servers are not
explicitly destroyed then garbage collection must clean them up properly.
--]]

local event = require("event")
local serialization = require("serialization")
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.mode("debug")
local mnet = include("mnet")
local mrpc = include("mrpc")

-- Create server on port 530.
local mrpc_server = mrpc.newServer(530)
local mrpc_server2 = mrpc.newServer(530, true)

-- Declare function say_hello.
mrpc_server.declareFunction("say_hello", {
  "senderMessage", "string",
  "extraData", "any",
}, {
  "msg", "string",
  "idk", "nil",
})
mrpc_server2.declareFunction("say_hello2", {
  "senderMessage", "string",
  "extraData", "any",
})

-- Register function to run when we receive a say_hello request.
mrpc_server.functions.say_hello = function(obj, host, senderMessage, extraData)
  print("Server1 got: Hello from " .. host .. ": " .. senderMessage)
  print(serialization.serialize(extraData))
  return "got hello", nil
end
mrpc_server2.functions.say_hello2 = function(obj, host, senderMessage, extraData)
  print("Server2 got: Hello from " .. host .. ": " .. senderMessage)
  print(serialization.serialize(extraData))
end

-- Request other active servers to run say_hello.
mrpc_server.async.say_hello("*", "anyone out there?", {"extra", "data"})
mrpc_server2.async.say_hello2("*", "um, helloooo?", 12345)
mrpc_server.async.say_hello("localhost", "anyone local?", {"extra", "data"})
print("Sent request to run say_hello on other servers.")

local caughtInterrupt = false

-- Respond to requests from other servers.
local listenerThread = thread.create(function()
  while not caughtInterrupt do
    local host, port, message = mnet.receive(0.1)
    local status = dlog.handleError(xpcall(mrpc_server.handleMessage, debug.traceback, nil, host, port, message))
    if not status then
      break
    end
  end
  print("Server is shutting down...")
  mrpc_server.destroy()
  mrpc_server2.destroy()
end)

local interruptThread = thread.create(function()
  event.pull("interrupted")
  caughtInterrupt = true
end)

local results = table.pack(mrpc_server.sync.say_hello("localhost", "local sync call", {"cool"}))
print("sync call done")
dlog.out("main", "results:", results)
