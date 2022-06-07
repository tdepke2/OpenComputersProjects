--[[
Mesh network.


--]]

local component = require("component")
local computer = require("computer")
local event = require("event")

local include = require("include")
local dlog = include("dlog")

local mnet = {}

mnet.hostname = string.sub(computer.address(), 1, 4)
mnet.port = 123

-- The message string can be up to the max packet size, minus a bit to make sure the packet can send.
mnet.maxLength = 10  --1024  --computer.getDeviceInfo()[component.modem.address].capacity - 32

-- Used to determine routes for packets. Stores uptime, receiverAddress, and senderAddress for each host.
mnet.routingTable = {}
-- Cache of packets that we have seen. Stores uptime for each packet id.
mnet.foundPackets = {}
-- Pending sent packets waiting for acknowledgment, and recently sent packets. Stores uptime, id, flags, port, and message (or nil if acknowledged) where the key is a host-sequence pair.
mnet.sentPackets = {}
-- Pending packets of a message that have been received. Stores uptime, flags, port, and message where the key is a host-sequence pair.
mnet.receivedPackets = {}
-- Most recent sequence number used for sent packets. Stores sequence number for each host.
mnet.lastSent = {}

mnet.lastSentUnreliable = {}
-- First sequence number and most recent in-order sequence number found from received packets. Stores sequence number for each host.
mnet.lastReceived = {}
-- Set to a host string when data in mnet.receivedPackets is ready to return.
mnet.receiveReadyHost = nil
-- Same as mnet.receiveReadyHost for the sequence.
mnet.receiveReadySeq = nil


local routingExpiration = 30
local retransmitTime = 3
local dropTime = 12

local maxSequence = 1000


local modems = {}
for address in component.list("modem", true) do
  modems[address] = component.proxy(address)
  modems[address].open(mnet.port)
end



-- FIXME evil broadcast used for testing unreliable comms ###################################################
function mnet.debugEnableLossy(lossy)
  for _, modem in pairs(modems) do
    if lossy and not modem.debugLossyActive then
      modem.broadcastReal = modem.broadcast
      modem.broadcast = function(...)
        -- Attempt to drop the packet.
        if math.random() < 0.2 then
          dlog.out("modem", "\27[31mDropped.\27[0m")
          return
        end
        -- Attempt to swap order with the next packet.
        local bufferedPacket = modem.debugBufferedPacket
        modem.debugBufferedPacket = nil
        if math.random() < 0.2 and not bufferedPacket then
          dlog.out("modem", "\27[31mSwapping packet order with next.\27[0m")
          modem.debugBufferedPacket = {computer.uptime() + 20, table.pack(...)}
        else
          modem.broadcastReal(...)
        end
        if bufferedPacket and computer.uptime() < bufferedPacket[1] then
          modem.broadcastReal(table.unpack(bufferedPacket[2], 1, bufferedPacket[2].n))
        end
      end
      modem.debugLossyActive = true
    elseif not lossy and modem.debugLossyActive then
      modem.broadcast = modem.broadcastReal
      modem.debugLossyActive = false
    end
  end
end

function mnet.debugSetSmallMTU(b)
  if b then
    mnet.maxLength = 10
  else
    mnet.maxLength = 1024
  end
end





-- Forms a new packet with generated id to send over the network. If sequence is
-- nil, the next value in the sequence is used (or a random value if none). If
-- requireAck is true, the packet data is cached in mnet.sentPackets for
-- retransmission if a loss is detected. The flags can be a string of
-- letter-number pairs with the following options:
--   Flag "s1" means the sender is attempting to synchronize and the sequence
--     number represents the beginning sequence.
--   Flag "r1" means the sender requires acknowledgment of the packet.
--   Flag "a1" means the sequence corresponds to an acknowledged packet.
--   Flag "t<n>" means the message has been split into a total of n fragments.
--   Flag "f<n>" means the fragment number of the message (descending order).
local function sendFragment(sequence, flags, host, port, fragment, requireAck)
  local id = math.random()
  local t = computer.uptime()
  
  -- The sequence starts at an initial random value and increments by 1 for each
  -- consecutive fragment we send. It is bounded within the range
  -- [1, maxSequence] and wraps back around if the range would be exceeded. A
  -- sequence of 0 is not allowed and has special meaning in an ack.
  if not sequence then
    local lastSent = requireAck and mnet.lastSent or mnet.lastSentUnreliable
    sequence = lastSent[host]
    if not sequence then
      sequence = math.floor(math.random(1, maxSequence))
      flags = "s1" .. flags
    end
    sequence = sequence % maxSequence + 1
    lastSent[host] = sequence
  end
  
  mnet.foundPackets[id] = t
  if requireAck then
    mnet.sentPackets[host .. "," .. sequence] = {t, id, flags, port, fragment}
  end
  
  dlog.out("mnet", "\27[32mSending packet ", mnet.hostname, " -> ", host, ":", port, " id=", id, ", seq=", sequence, ", flags=", flags, ", m=", fragment, "\27[0m")
  for _, modem in pairs(modems) do
    modem.broadcast(mnet.port, id, sequence, flags, host, mnet.hostname, port, fragment)
  end
  return id
end

-- mnet.send(host: string, port: number, message: string, reliable: boolean[, waitForAck: boolean]): string
-- 
-- 
function mnet.send(host, port, message, reliable, waitForAck)
  dlog.checkArgs(host, "string", port, "number", message, "string", reliable, "boolean", waitForAck, "boolean,nil")
  assert(not reliable or host ~= "*", "Broadcast address not allowed for reliable packet transmission.")
  
  local flags = reliable and "r1" or ""
  if #message <= mnet.maxLength then
    -- Message fits into one packet, send it without fragmenting.
    sendFragment(nil, flags, host, port, message, reliable)
  else
    -- Substring message into multiple pieces and send each.
    local fragmentCount = math.ceil(#message / mnet.maxLength)
    for i = 1, fragmentCount do
      sendFragment(nil, flags .. (i ~= fragmentCount and "f0" or "f" .. fragmentCount), host, port, string.sub(message, (i - 1) * mnet.maxLength + 1, i * mnet.maxLength), reliable)
    end
  end
  
  if reliable then
    local lastHostSeq = host .. "," .. mnet.lastSent[host]
    if waitForAck then
      -- Busy-wait until the last packet receives an ack or it times out.
      while mnet.sentPackets[lastHostSeq] do
        if not mnet.sentPackets[lastHostSeq][5] then
          return lastHostSeq
        end
        os.sleep(0.05)
      end
    else
      return lastHostSeq
    end
  end
end

-- Breaks a comma-separated host and sequence string into their values.
local function splitHostSequencePair(hostSeq)
  local host, sequence = string.match(hostSeq, "(.*),([^,]+)$")
  return host, tonumber(sequence)
end

-- mnet.receive(timeout: number): nil | (string, number, string) | (string, number, number)
-- 
-- 
function mnet.receive(timeout, connectionLostCallback)
  dlog.checkArgs(timeout, "number", connectionLostCallback, "function,nil")
  
  -- Check if we have buffered packets that are ready to return immediately.
  if mnet.receiveReadyHost then
    local hostSeq = mnet.receiveReadyHost .. "," .. mnet.receiveReadySeq
    local packet = mnet.receivedPackets[hostSeq]
    dlog.out("mnet", "Buffered data ready to return, hostSeq=", hostSeq, ", type(packet)=", type(packet))
    if packet then
      mnet.receivedPackets[hostSeq] = nil
      mnet.receiveReadySeq = mnet.receiveReadySeq % maxSequence + 1
      dlog.out("mnet", "Returning buffered packet ", hostSeq, ", dat=", packet)
      return mnet.receiveReadyHost, packet[3], packet[4]
    else
      mnet.receiveReadyHost = nil
      mnet.receiveReadySeq = nil
    end
  end
  
  local eventType, receiverAddress, senderAddress, senderPort, _, id, sequence, flags, dest, src, port, message = event.pull(timeout, "modem_message")
  local t = computer.uptime()
  
  -- Check for packets that timed out, and any that were lost that need to be sent again.
  for hostSeq, packet in pairs(mnet.sentPackets) do
    if t > packet[1] + dropTime then
      if packet[5] then
        dlog.out("mnet", "\27[33mPacket ", hostSeq, " timed out, dat=", packet, "\27[0m")
        if connectionLostCallback then
          connectionLostCallback(hostSeq, packet[4], packet[5])
        end
      end
      mnet.sentPackets[hostSeq] = nil
    elseif packet[5] and t > mnet.foundPackets[packet[2]] + retransmitTime then
      -- Packet requires retransmission. The same data is sent again but with a new packet id.
      dlog.out("mnet", "Retransmitting packet with previous id ", packet[2])
      local sentHost, sentSequence = splitHostSequencePair(hostSeq)
      packet[2] = sendFragment(sentSequence, packet[3], sentHost, packet[4], packet[5])
    end
  end
  
  for k, v in pairs(mnet.foundPackets) do
    if t > v + dropTime then
      --dlog.out("mnet", "\27[33mDropping foundPacket ", k, "\27[0m")
      mnet.foundPackets[k] = nil
    end
  end
  
  -- Return early if not a valid packet.
  if not eventType or senderPort ~= mnet.port or mnet.foundPackets[id] then
    return nil
  end
  sequence = math.floor(sequence)
  port = math.floor(port)
  
  --[[
  for k, v in pairs(mnet.routingTable) do
    if t > v[1] + routingExpiration then
      mnet.routingTable[k] = nil
    end
  end--]]
  for k, v in pairs(mnet.receivedPackets) do
    if t > v[1] + dropTime then  --(type(v) == "number" and v or v[1]) + dropTime then
      dlog.out("mnet", "\27[33mDropping receivedPacket ", k, "\27[0m")
      mnet.receivedPackets[k] = nil
    end
  end
  
  dlog.out("mnet", "\27[36mGot packet ", src, " -> ", dest, ":", port, " id=", id, ", seq=", sequence, ", flags=", flags, ", m=", message, "\27[0m")
  mnet.foundPackets[id] = t
  
  if dest == mnet.hostname or dest == "*" then
    -- Packet arrived at destination, consume it. First check if it is an ack to a previously sent packet.
    local hostSeq = src .. "," .. sequence
    if flags == "a1" then
      if mnet.sentPackets[hostSeq] then
        -- Set the message to nil to mark completion (and all previous sequential messages).
        while mnet.sentPackets[hostSeq] and mnet.sentPackets[hostSeq][5] do
          dlog.out("mnet", "Marking ", hostSeq, " as acknowledged.")
          mnet.sentPackets[hostSeq][5] = nil
          sequence = (sequence - 2) % maxSequence + 1
          hostSeq = src .. "," .. sequence
        end
      else
        -- An ack was received for a sequence number that was not sent, we may need to synchronize the receiver. Set hostSeq to the first instance we find for this host (first pending sent packet).
        local beforeFirstSequence = mnet.lastSent[src] or 0
        repeat
          beforeFirstSequence = (beforeFirstSequence - 2) % maxSequence + 1
          hostSeq = src .. "," .. beforeFirstSequence
        until not (mnet.sentPackets[hostSeq] and mnet.sentPackets[hostSeq][5])
        hostSeq = src .. "," .. (beforeFirstSequence % maxSequence + 1)
        
        -- If the ack does not correspond to before the first pending sent packet and we found the first pending one, force it to have the syn flag set.
        dlog.out("mnet", "Found unexpected ack, beforeFirstSequence is ", beforeFirstSequence, ", first hostSeq is ", hostSeq)
        local firstSentPacket = mnet.sentPackets[hostSeq]
        if beforeFirstSequence ~= sequence and firstSentPacket and not string.find(firstSentPacket[3], "s1") then
          dlog.out("mnet", "Setting syn flag for hostSeq.")
          firstSentPacket[3] = firstSentPacket[3] .. "s1"
        end
      end
      return nil
    end
    
    
    --[[
    FIXME consider these cases: ###############################################################
      * two syn packets with same sequence arrive
      * two ack packets for same sequence arrive
      * random ack arrives (may need to ignore or start new connection)
      * unexpected sequence arrives
      * syn packet arrives after we saw other sequences in order
    --]]
    
    local fragmentCount = tonumber(string.match(flags, "f(%d+)"))
    
    -- Filters the message in the current packet to prevent returning a fragment
    -- of a jumbo frame. Non-fragment messages simply pass through. If a
    -- sentinel fragment is found, all of the fragments are concatenated (if
    -- possible) and returned.
    local function nextMessage()
      if not fragmentCount then
        return message
      end
      
      -- Add fragment to buffer, then search for the sentinel fragment.
      local endPacket = {t, flags, port, message, fragmentCount}
      mnet.receivedPackets[hostSeq] = endPacket
      while endPacket and endPacket[5] == 0 do
        sequence = sequence % maxSequence + 1
        endPacket = mnet.receivedPackets[src .. "," .. sequence]
      end
      
      if endPacket then
        -- Iterate mnet.receivedPackets in reverse to collect the fragments. Quit early if any are missing.
        local fragments = {}
        for i = endPacket[5], 1, -1 do
          local packet = mnet.receivedPackets[src .. "," .. sequence]
          dlog.out("mnet", "Collecting fragment ", src .. "," .. sequence)
          if not packet then
            return
          end
          fragments[i] = packet[4]
          sequence = (sequence - 2) % maxSequence + 1
        end
        -- Found all fragments, clear the corresponding mnet.receivedPackets entries.
        for i = 1, endPacket[5] do
          sequence = sequence % maxSequence + 1
          dlog.out("mnet", "Removing ", src .. "," .. sequence, " from cache.")
          mnet.receivedPackets[src .. "," .. sequence] = nil
        end
        return table.concat(fragments)
      end
    end
    
    local firstLastSequence = mnet.lastReceived[src]
    local result
    if not string.find(flags, "r1") then
      -- Packet is unreliable.
      dlog.out("mnet", "Ignored ordering, passing packet through.")
      result = nextMessage()
    elseif string.find(flags, "s1") then
      -- Packet has syn flag set. If we have not seen it already then this marks a new connection and any buffered packets are invalid.
      if sequence ~= (firstLastSequence and firstLastSequence[1]) then
        dlog.out("mnet", "Begin new connection to ", src)
        mnet.receivedPackets = {}
        firstLastSequence = {sequence, sequence}
        mnet.lastReceived[src] = firstLastSequence
        result = nextMessage()
      end
    elseif firstLastSequence and firstLastSequence[2] % maxSequence + 1 == sequence then
      -- No syn flag set and the sequence corresponds to the next one we expect. Push the last received sequence value ahead while there are in-order buffered packets.
      dlog.out("mnet", "Packet arrived in expected order.")
      firstLastSequence[2] = sequence
      while mnet.receivedPackets[src .. "," .. (firstLastSequence[2] % maxSequence + 1)] do
        firstLastSequence[2] = firstLastSequence[2] % maxSequence + 1
        dlog.out("mnet", "Buffered packet ready, bumped last sequence to ", firstLastSequence[2])
        mnet.receiveReadyHost = src
        mnet.receiveReadySeq = mnet.receiveReadySeq or firstLastSequence[2]
      end
      result = nextMessage()
    elseif not fragmentCount then
      -- Sequence does not correspond to the expected one and not a jumbo frame, cache the packet for later.
      dlog.out("mnet", "Packet arrived in unexpected order (last sequence was ", firstLastSequence and firstLastSequence[2], ")")
      mnet.receivedPackets[hostSeq] = {t, flags, port, message}
    end
    
    if string.find(flags, "r1") then
      sendFragment(firstLastSequence and firstLastSequence[2] or 0, "a1", src, port)
    end
    
    if result then
      return src, port, result
    end
  else
    -- Packet is intended for a different recipient, forward it.
    dlog.out("mnet", "\27[32mRouting packet ", id, "\27[0m")
    for _, modem in pairs(modems) do
      modem.broadcast(mnet.port, id, sequence, flags, dest, src, port, message)
    end
  end
end

return mnet

--[[
requirements:
  * hostnames are unique.
  * support for unicast, routed, reliable, in-order, arbitrary-length messages (jumbo frames).
  * support for unicast/broadcast, routed, unreliable, arbitrary-length messages.
  * we do not support congestion control or ARP.
  * jumbo frames (for reliable messages) are not buffered.
  * there is no loopback interface (machine cannot send messages to itself).

packet fields:
id (rand number), last/current sequence (number), flags (string), dest, src, port, message
or maybe:
id (rand number), sequence (number), flags (string), dest, src, port, message

flags:
  * r1 indicates "requires ack"
  * a1 indicates an ack
  * s1 indicates "synchronize" to begin a new connection
  * f<n> indicates fragment number if a message was split into fragments (sent in descending order)

syn flag is set by sender if:
  1. we have not yet talked to receiver (no entry in lastSent)
  2. the receiver says it expects seq 0 (receiver has no entry in lastReceived) and no syn flags set in sentPackets
  3. the receiver says it expects a seq that is not in sentPackets and no syn flags set in sentPackets

case 1, no loss:
a - b
a sends message1 to b (id 1 seq 35 flags "r1s1")
  foundPackets[id 1] = uptime
  sentPackets[b seq 35] = {uptime, flags, port, message}
  lastSent[b] = seq 35
a sends message2 to b (id 6 seq 36 flags "r1")
  foundPackets[id 6] = ...
  sentPackets[b seq 36] = ...
  lastSent[b] = seq 36
a sends message3 to b (id 3 seq 37 flags "r1")
  foundPackets[id 3] = ...
  sentPackets[b seq 37] = ...
  lastSent[b] = seq 37
b gets id 1, sees no entry in lastReceived but syn flag is set
  foundPackets[id 1] = uptime
  receivedPackets[a seq 35] = uptime
  lastReceived[a] = seq 35
  b returns message1 and sends ack to a (id 15 seq 35 flags "a1")
b gets id 6, updates entry for lastReceived
  foundPackets[id 6] = uptime
  receivedPackets[a seq 36] = uptime
  lastReceived[a] = seq 36
  b returns message2 and sends ack to a (id 5 seq 36 flags "a1")
...
a gets id 15, crosses seq 35 off of the sentPackets list and all previous ones in sequence
a gets id 5, crosses seq 36 off of the sentPackets list and all previous ones in sequence
...

case 2, send 2 fragments:
a - b
a sends message1-f1 to b (id 1 seq 35 flags "r1s1f2")
  foundPackets[id 1] = uptime
  sentPackets[b seq 35] = {uptime, flags, port, message}
  lastSent[b] = seq 35
a sends message1-f2 to b (id 6 seq 36 flags "r1f1")
  foundPackets[id 6] = ...
  sentPackets[b seq 36] = ...
  lastSent[b] = seq 36
b gets id 1, sees no entry in lastReceived but syn flag is set
  foundPackets[id 1] = uptime
  receivedPackets[a seq 35] = {uptime, flags, message1}
  lastReceived[a] = seq 35
  b returns nil and sends ack to a (id 15 seq 35 flags "a1")
b gets id 6, updates entry for lastReceived
  foundPackets[id 6] = uptime
  receivedPackets[a seq 36] = {uptime, flags, message1}
  lastReceived[a] = seq 36
  b returns message1 and sends ack to a (id 5 seq 36 flags "a1")
...
a gets id 15, crosses seq 35 off of the sentPackets list
a gets id 5, crosses seq 36 off of the sentPackets list
...

case 3, loss of syn packet:
a - b
a sends message1 to b (id 1 seq 35 flags "r1s1")
  sentPackets[b seq 35] = {uptime, flags, port, message}
  lastSent[b] = seq 35
a sends message2 to b (id 6 seq 36 flags "r1")
  sentPackets[b seq 36] = ...
  lastSent[b] = seq 36
a sends message3 to b (id 3 seq 37 flags "r1")
  sentPackets[b seq 37] = ...
  lastSent[b] = seq 37
id 1 is lost!
b gets id 6, sees no entry in lastReceived
  receivedPackets[a seq 36] = {uptime, flags, message2}
  b returns nil and sends ack to a (id 15 seq 0 flags "a1")
b gets id 3, sees no entry in lastReceived
  receivedPackets[a seq 37] = {uptime, flags, message3}
  b returns nil and sends ack to a (id 5 seq 0 flags "a1")
...
a gets id 15, sees an ack for seq 0 but also has a syn flag set in sentPackets
a gets id 5, sees an ack for seq 0 but also has a syn flag set in sentPackets
...
id 1 was lost
a sends message1 to b (id 56 seq 35 flags "r1s1")
b gets id 56, sees no entry in lastReceived but syn flag is set
  receivedPackets[a seq 35] = uptime
  b returns message1 and sends ack to a (id 15 seq 35 flags "a1")
  receivedPackets[a seq 36] = uptime
  b returns message2 and sends ack to a (id 15 seq 36 flags "a1")
  receivedPackets[a seq 37] = uptime
  b returns message3 and sends ack to a (id 15 seq 37 flags "a1")


case 4, loss of middle packet:

case 5, a reboots:

case 6, b reboots:


a - b - c
a sends message1 to c (seq 36)
a sends message2 to c (seq 37)
a sends message3 to c (seq 38)
1 is lost
a sends 1, 2, and 3 again

a - b - c
a sends (1, 2, 3) to c
1 reaches c but 1-ack is lost
a sends 1, 2, and 3 again

--]]
