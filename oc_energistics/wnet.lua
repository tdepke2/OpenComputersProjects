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

local dlog = require("dlog")

local wnet = {}

-- Maximum lifetime of a buffered packet (in seconds). Note that packets are only dropped when a new one is received.
wnet.maxPacketLife = 5

-- The string can be up to the max packet size, minus a bit to make sure the packet can send.
wnet.maxDataLength = computer.getDeviceInfo()[component.modem.address].capacity - 32

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
  
  if #data <= wnet.maxDataLength then
    -- Data is small enough, send it in one packet.
    if address then
      modem.send(address, port, wnet.packetNumber .. "/1", data)
    else
      modem.broadcast(port, wnet.packetNumber .. "/1", data)
    end
    dlog.out("wnet", "Packet to " .. (address == nil and "BROAD" or string.sub(address, 1, 5)) .. ":" .. port .. " -> " .. wnet.packetNumber .. "/1", data)
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
      dlog.out("wnet", "Packet to " .. (address == nil and "BROAD" or string.sub(address, 1, 5)) .. ":" .. port .. " -> " .. wnet.packetNumber .. (i == 1 and "/" .. packetCount or ""), string.sub(data, (i - 1) * wnet.maxDataLength + 1, i * wnet.maxDataLength))
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
  if not (eventType and type(sequence) == "string" and type(data) == "string" and string.find(sequence, "^%d+")) then
    return nil
  end
  senderPort = math.floor(senderPort)
  dlog.out("wnet", "Packet from " .. string.sub(senderAddress, 1, 5) .. ":" .. senderPort .. " <- " .. sequence, data)
  
  if string.match(sequence, "/(%d+)") == "1" then
    -- Got a packet without any pending ones. Do a quick clean of dead packets and return this one.
    dlog.out("wnet:d", "Packet is single (no pending).")
    for k, v in pairs(wnet.packetBuffer) do
      if computer.uptime() > v[1] + wnet.maxPacketLife then
        dlog.out("wnet:d", "Dropping packet: " .. k)
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
      dlog.out("wnet:d", "In loop: ", k, kAddress, kPort, kPacketNum, kPacketCount)
      
      if computer.uptime() > v[1] + wnet.maxPacketLife then
        dlog.out("wnet:d", "Dropping packet: " .. k)
        wnet.packetBuffer[k] = nil
      elseif kPacketCount and (kPacketCount == 1 or wnet.packetBuffer[kAddress .. ":" .. kPort .. "," .. (kPacketNum + kPacketCount - 1)]) then
        -- Found a start packet and the corresponding end packet was received, try to form the full data.
        dlog.out("wnet:d", "Found begin and end packets, checking...")
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
        dlog.out("wnet:d", "Nope, need more.")
      end
    end
    
    -- Don't have enough packets yet, wait for more.
    eventType, _, senderAddress, senderPort, _, sequence, data = event.pull(timeout, "modem_message")
    if not (eventType and type(sequence) == "string" and type(data) == "string" and string.find(sequence, "^%d+")) then
      return nil
    end
    senderPort = math.floor(senderPort)
    dlog.out("wnet", "Packet from " .. string.sub(senderAddress, 1, 5) .. ":" .. senderPort .. " <- " .. sequence, data)
  end
end

return wnet


-- Compressed version of wnet to fit on EEPROM. This only takes up about 1,500
-- bytes. Note that the wnet.receive() function now takes an event table instead
-- of a timeout, this is to prevent the receive() from tossing out non-modem
-- events from computer.pullSignal(). To catch network packets do the following
-- in the drone code within a loop:
-- 
-- local ev = {computer.pullSignal()}
-- local address, port, data = wnet.receive(ev)
-- if port == <my port> then
--   Do stuff with data...
-- end
-- 
-- Compressed wnet starts here:
--[[

local modem = component.proxy(component.list("modem")())

-- See wnet.lua for uncompressed version.
wnet={}
wnet.life=5
wnet.len=computer.getDeviceInfo()[modem.address].capacity-32
wnet.n=1
wnet.b={}
function wnet.send(m,a,p,d)
  local c=math.ceil(#d/wnet.len)
  for i=1,c do
    if a then
      m.send(a,p,wnet.n..(i==1 and"/"..c or""),string.sub(d,(i-1)*wnet.len+1,i*wnet.len))
    else
      m.broadcast(p,wnet.n..(i==1 and"/"..c or""),string.sub(d,(i-1)*wnet.len+1,i*wnet.len))
    end
    wnet.n=wnet.n+1
  end
end
function wnet.receive(ev)
  local e,a,p,s,d=ev[1],ev[3],ev[4],ev[6],ev[7]
  if not(e and e=="modem_message"and type(s)=="string"and type(d)=="string"and string.find(s,"^%d+"))then return nil end
  p=math.floor(p)
  wnet.b[a..":"..p..","..s]={computer.uptime(),d}
  for k,v in pairs(wnet.b) do
    local ka,kp,kn = string.match(k,"([%w-]+):(%d+),(%d+)")
    kn=tonumber(kn)
    local kc=tonumber(string.match(k,"/(%d+)"))
    if computer.uptime()>v[1]+wnet.life then
      wnet.b[k]=nil
    elseif kc and(kc==1 or wnet.b[ka..":"..kp..","..(kn+kc-1)])then
      d=""
      for i=1,kc do
        if not wnet.b[ka..":"..kp..","..(kn+i-1)..(i==1 and"/"..kc or"")]then d=nil break end
      end
      if d then
        for i=1,kc do
          local k2=ka..":"..kp..","..(kn+i-1)..(i==1 and"/"..kc or"")
          d=d..wnet.b[k2][2]
          wnet.b[k2]=nil
        end
        return ka,tonumber(kp),d
      end
    end
  end
end

--]]
