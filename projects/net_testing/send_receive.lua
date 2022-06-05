local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local modem = component.modem
local thread = require("thread")

local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include("mnet")

local PORT = 123

local totalReceivedAck = 0
local sentData = {}
local receivedData = {}

local function listenerThreadFunc()
  while true do
    --[[
    local eventType, receiverAddress, senderAddress, senderPort, distance, message = event.pull(0.1, "modem_message")
    if eventType then
      dlog.out("receive", receiverAddress, " ", senderAddress, " ", senderPort, " ", distance, " ", message)
      receivedData[#receivedData + 1] = message
    end
    --]]
    
    local host, port, message = mnet.receive(0.1)
    if host then
      dlog.out("receive", host, " ", port, " ", message)
      --if type(message) == "string" then
        receivedData[#receivedData + 1] = message
      --else
        --totalReceivedAck = totalReceivedAck + 1
      --end
    end
  end
end

local function sendPacket(host, port, message, reliable)
  dlog.out("send", mnet.send(host, port, message, reliable))
  sentData[#sentData + 1] = message
end

local function main()
  dlog.setFileOut("/tmp/messages", "w")
  --modem.open(PORT)
  --modem.setStrength(12)
  mnet.debugEnableLossy(true)
  
  dlog.out("init", "Hello, I am ", mnet.hostname)
  
  local listenerThread = thread.create(listenerThreadFunc)
  
  while true do
    local event = {event.pull(0.1)}
    if event[1] == "interrupted" then
      dlog.out("done", "sent:")
      for k, v in pairs(sentData) do
        dlog.out("    ", "[", v, "]")
      end
      dlog.out("done", "received:")
      for k, v in pairs(receivedData) do
        dlog.out("    ", "[", v, "]")
      end
      
      local function numKeys(t)
        local n = 0
        for k, _ in pairs(t) do
          n = n + 1
        end
        return n
      end
      dlog.out("done", "table sizes: routingTable=", numKeys(mnet.routingTable), ", foundPackets=", numKeys(mnet.foundPackets), ", sentPackets=", numKeys(mnet.sentPackets), ", receivedPackets=", numKeys(mnet.receivedPackets), ", lastSent=", numKeys(mnet.lastSent), ", lastReceived=", numKeys(mnet.lastReceived))
      break
    elseif event[1] == "key_down" then
      if not keyboard.isControl(event[3]) then
        if event[3] == string.byte("s") then
          --dlog.out("send", modem.broadcast(PORT, "ping"))
          
          sendPacket("*", 456, "abcdefghijklmnopqrstuvwxyz", false)
          --sendPacket("1315", 456, "my")
          --sendPacket("1315", 456, "nutt")
          
          
          
          should probably test mixed UDP and TCP messages (ordering may break stuff) ###################
          
          
          
          
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
--dlog.out("done", "mnet: ", mnet)
dlog.osBlockNewGlobals(false)
