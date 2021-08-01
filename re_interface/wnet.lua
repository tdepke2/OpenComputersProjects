--[[
Network wrapper with very simple interface.

Supports debugging of packet transfer, data messages that do not fit in a single
packet, and guarantees data integrity on receiving end. Much like UDP in
networking, it does not support reliable transfer (packets may be lost, and this
can cause pending packets to be dropped). There are no ACKs sent back to the
sender to notify that the message was received. The simplicity of this protocol
allows it to fit onto a 4kB EEPROM for programming drones and such (see the
compressed version at bottom).
--]]

local component = require("component")
local computer = require("computer")
local event = require("event")

local wnet = {}

-- Debugging control. If true then packet data is printed to standard output.
wnet.debug = false

-- Maximum lifetime of a buffered packet (in seconds). Note that packets are only dropped when a new one is received.
wnet.maxPacketLife = 5

-- The string can be up to the max packet size, minus a bit to make sure the packet can send.
wnet.maxDataLength = computer.getDeviceInfo()[component.modem.address].capacity - 64

wnet.packetNumber = 1
wnet.packetBuffer = {}

-- send(modem: table, address: string|nil, port: number, data: string)
-- 
-- Send a message over the network containing the data packet (must be a
-- string). If the address is nil, message is sent as a broadcast. The data
-- packet is broken up into smaller pieces if it is too big for the max packet
-- size.
function wnet.send(modem, address, port, data)
  checkArg(1, modem, "table", 3, port, "number", 4, data, "string")
  --print("Send message to " .. string.sub(tostring(address), 1, 4) .. " port " .. port .. ": " .. data)
  
  if #data <= wnet.maxDataLength then
    -- Data is small enough, send it in one packet.
    if address then
      modem.send(address, port, wnet.packetNumber .. "/1", data)
    else
      modem.broadcast(port, wnet.packetNumber .. "/1", data)
    end
    if wnet.debug then
      print("Packet to " .. (address == nil and "BROAD" or string.sub(address, 1, 5)) .. ":" .. port .. " -> " .. wnet.packetNumber .. "/1 " .. data)
    end
    wnet.packetNumber = wnet.packetNumber + 1
  else
    -- Substring data into multiple pieces and send each. The first one includes a "/<packet count>" after the packet number.
    local packetCount = math.ceil(#data / wnet.maxDataLength)
    for i = 1, packetCount do
      if address then
        modem.send(address, port, wnet.packetNumber .. (i == 1 and "/" .. packetCount or ""), string.sub(data, (i - 1) * wnet.maxDataLength + 1, i * wnet.maxDataLength))
      else
        modem.broadcast(port, wnet.packetNumber .. (i == 1 and "/" .. packetCount or ""), string.sub(data, (i - 1) * wnet.maxDataLength + 1, i * wnet.maxDataLength))
      end
      if wnet.debug then
        print("Packet to " .. (address == nil and "BROAD" or string.sub(address, 1, 5)) .. ":" .. port .. " -> " .. wnet.packetNumber .. (i == 1 and "/" .. packetCount or "") .. " " .. string.sub(data, (i - 1) * wnet.maxDataLength + 1, i * wnet.maxDataLength))
      end
      wnet.packetNumber = wnet.packetNumber + 1
    end
  end
end

-- receive([timeout: number]): string, number, string
-- 
-- Get a message sent over the network (waits until one arrives). If the timeout
-- is specified, this function only waits for that many seconds before
-- returning. If a message was split into multiple packets, combines them before
-- returning the result. Returns nil if timeout reached, or address, port, and
-- data if received.
function wnet.receive(timeout)
  local eventType, _, senderAddress, senderPort, _, sequence, data = event.pull(timeout, "modem_message")
  if not eventType then
    return nil
  end
  senderPort = math.floor(senderPort)
  if wnet.debug then
    print("Packet from " .. string.sub(senderAddress, 1, 5) .. ":" .. senderPort .. " <- " .. sequence .. " " .. data)
  end
  
  if string.match(sequence, "/(%d+)") == "1" then
    -- Got a packet without any pending ones. Do a quick clean of dead packets and return this one.
    --print("found packet with no pending")
    for k, v in pairs(wnet.packetBuffer) do
      if computer.uptime() > v[1] + wnet.maxPacketLife then
        if wnet.debug then
          print("Dropping packet: " .. k)
        end
        wnet.packetBuffer[k] = nil
      end
    end
    return senderAddress, senderPort, data
  end
  while true do
    wnet.packetBuffer[senderAddress .. ":" .. senderPort .. "," .. sequence] = {computer.uptime(), data}
    
    -- Iterate through packet buffer to check if we have enough to return some data.
    for k, v in pairs(wnet.packetBuffer) do
      local kAddress, kPort, kPacketNum = string.match(k, "([%w-]+):(%d+),(%d+)")
      kPacketNum = tonumber(kPacketNum)
      local kPacketCount = tonumber(string.match(k, "/(%d+)"))
      --print("in loop: ", k, kAddress, kPort, kPacketNum, kPacketCount)
      
      if computer.uptime() > v[1] + wnet.maxPacketLife then
        if wnet.debug then
          print("Dropping packet: " .. k)
        end
        wnet.packetBuffer[k] = nil
      elseif kPacketCount and (kPacketCount == 1 or wnet.packetBuffer[kAddress .. ":" .. kPort .. "," .. (kPacketNum + kPacketCount - 1)]) then
        -- Found a start packet and the corresponding end packet was received, try to form the full data.
        --print("found begin and end packets, checking...")
        data = ""
        for i = 1, kPacketCount do
          if not wnet.packetBuffer[kAddress .. ":" .. kPort .. "," .. (kPacketNum + i - 1) .. (i == 1 and "/" .. kPacketCount or "")] then
            data = nil
            break
          end
        end
        
        -- Confirm we really have all the packets before forming the data and deleting them from the buffer (a packet could have been lost or is still in transit).
        if data then
          for i = 1, kPacketCount do
            local k2 = kAddress .. ":" .. kPort .. "," .. (kPacketNum + i - 1) .. (i == 1 and "/" .. kPacketCount or "")
            data = data .. wnet.packetBuffer[k2][2]
            wnet.packetBuffer[k2] = nil
          end
          return kAddress, tonumber(kPort), data
        end
        --print("nope, need more")
      end
    end
    
    -- Don't have enough packets yet, wait for more.
    eventType, _, senderAddress, senderPort, _, sequence, data = event.pull(timeout, "modem_message")
    if not eventType then
      return nil
    end
    senderPort = math.floor(senderPort)
    if wnet.debug then
      print("Packet from " .. string.sub(senderAddress, 1, 5) .. ":" .. senderPort .. " <- " .. sequence .. " " .. data)
    end
  end
end

return wnet

--[[
-- Compressed version of wnet to fit on EEPROM.


--]]
