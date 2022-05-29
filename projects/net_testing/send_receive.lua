local component = require("component")
local event = require("event")
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
      if type(message) == "string" then
        receivedData[#receivedData + 1] = message
      else
        totalReceivedAck = totalReceivedAck + 1
      end
    end
  end
end

local function sendPacket(host, port, message)
  dlog.out("send", mnet.send(host, port, message))
  sentData[#sentData + 1] = message
end

local function main()
  modem.open(PORT)
  modem.setStrength(12)
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
      dlog.out("done", "received acks: ", totalReceivedAck)
      break
    elseif event[1] == "key_down" then
      if event[3] == string.byte("s") then
        --dlog.out("send", modem.broadcast(PORT, "ping"))
        
        sendPacket("131", 456, "succ")
        sendPacket("131", 456, "my")
        sendPacket("131", 456, "nutt")
        
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
