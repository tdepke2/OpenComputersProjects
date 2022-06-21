--[[
Test basic communication between two systems over RPC.

Run this program on each system and use the listed keys to send messages. See
standard output or log file for debugging packet transfer.
--]]

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local modem = component.modem
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include.reload("mnet")
local mrpc_server = include("mrpc").newServer(789)
mrpc_server.addDeclarations(dofile("net_testing/ocvnc_mrpc.lua"))

local HOST1 = "1315"
local HOST2 = "2f2c"

local sentData = {}
local receivedData = {}

mrpc_server.functions.stor_discover = function(...)
  dlog.out("stor_discover", "running func called with: ", {...})
  receivedData[#receivedData + 1] = "stor_discover called"
end

mrpc_server.functions.stor_extract = function(...)
  dlog.out("stor_extract", "running func called with: ", {...})
  receivedData[#receivedData + 1] = "stor_extract called"
  return "results from my stor_extract call"
end

local function listenerThreadFunc()
  while true do
    local processed
    local host, port, message = mnet.receive(0.1)
    if host then
      dlog.out("receive", host, " ", port, " ", message)
    end
    processed = processed or mrpc_server.handleMessage("my_obj", host, port, message)
    if host and not processed then
      receivedData[#receivedData + 1] = message
    end
  end
end

local function main()
  dlog.setFileOut("/tmp/messages", "w")
  --mnet.debugEnableLossy(true)
  --mnet.debugSetSmallMTU(true)
  
  dlog.out("init", "Hello, I am ", mnet.hostname, ". Press \'s\' to send a message to ", HOST1, " or \'d\' to send a message to ", HOST2)
  
  local listenerThread = thread.create(listenerThreadFunc)
  
  while true do
    local event = {event.pull(0.1)}
    if event[1] == "interrupted" then
      local function numKeys(t)
        local n = 0
        for k, _ in pairs(t) do
          n = n + 1
        end
        return n
      end
      
      dlog.out("done", "sent " .. numKeys(sentData) .. ":")
      for k, v in pairs(sentData) do
        dlog.out("    ", "[", v, "]")
      end
      dlog.out("done", "received " .. numKeys(receivedData) .. ":")
      for k, v in pairs(receivedData) do
        dlog.out("    ", "[", v, "]")
      end
      
      
      dlog.out("done", "table sizes: routingTable=", numKeys(mnet.routingTable), ", foundPackets=", numKeys(mnet.foundPackets), ", sentPackets=", numKeys(mnet.sentPackets), ", receivedPackets=", numKeys(mnet.receivedPackets), ", lastSent=", numKeys(mnet.lastSent), ", lastReceived=", numKeys(mnet.lastReceived))
      break
    elseif event[1] == "key_down" then
      if not keyboard.isControl(event[3]) then
        if event[3] == string.byte("s") then
          --sendPacket(HOST1, 456, "abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz", true)
          
          dlog.out("mrpc_server call", {mrpc_server.async.stor_discover(HOST1, true, "big nuts", {"xd", "123"})})
          
          dlog.out("mrpc_server call", {mrpc_server.sync.stor_extract(HOST1, "ok", 10001)})
        elseif event[3] == string.byte("d") then
          sendPacket(HOST2, 456, "sample text", true)
        end
      elseif event[4] == keyboard.keys.enter then
        dlog.out("d", "")
      end
    end
    
    if listenerThread:status() == "dead" then
      break
    end
  end
  
  listenerThread:kill()
end
main()
mnet.debugEnableLossy(false)
mnet.debugSetSmallMTU(false)
dlog.osBlockNewGlobals(false)
