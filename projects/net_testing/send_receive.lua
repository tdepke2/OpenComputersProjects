--[[
Test basic communication between two systems.

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

--local PORT = 123
local HOST1 = "1315"
local HOST2 = "2f2c"

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
      receivedData[#receivedData + 1] = message
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
  mnet.debugSetSmallMTU(true)
  
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
          --dlog.out("send", modem.broadcast(PORT, "ping"))
          
          sendPacket("*", 456, "abcdefghijklmnopqrstuvwxyz", false)
          sendPacket(HOST1, 456, "abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz", true)
          sendPacket(HOST1, 456, "abcdefghijklmnopqrstuvwxyz", false)
          --sendPacket(HOST1, 456, "first second third fourth fifth sixth " .. math.floor(math.random(1, 100)), false)
          --sendPacket(HOST1, 456, "beef_" .. math.floor(math.random(1, 100)), false)
          
          --modem.setStrength(1)
          
          sendPacket(HOST1, 456, "a_" .. math.floor(math.random(1, 100)), true)
          sendPacket(HOST1, 456, "b_" .. math.floor(math.random(1, 100)), true)
          sendPacket(HOST1, 456, "c_" .. math.floor(math.random(1, 100)), true)
          
          --modem.setStrength(200)
          
          --sendPacket(HOST1, 456, "d_" .. math.floor(math.random(1, 100)), true)
          --sendPacket(HOST1, 456, "e_" .. math.floor(math.random(1, 100)), true)
          
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
--dlog.out("done", "mnet: ", mnet)
dlog.osBlockNewGlobals(false)
