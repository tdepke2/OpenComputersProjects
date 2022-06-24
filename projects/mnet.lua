--[[
Mesh networking protocol with minimalistic API.

The mnet protocol stack covers layers 3 and 4 of the OSI model and is designed
for general purpose mesh networking using reliable or unreliable communication
(much like TCP and UDP). The interface is kept as simple as possible for
performance and to allow embedded devices with a small EEPROM to run it. Much of
the inspiration for mnet came from minitel:
https://github.com/ShadowKatStudios/OC-Minitel

Key features:
  * Supports unicast, routed, reliable, in-order, arbitrary-length messages.
  * Supports unicast/broadcast, routed, unreliable, arbitrary-length messages.
  * Automatic configuration of routes.
  * No background service to handle packets keeps things simple and fast.
  * Minified version runs on embedded hardware like drones and microcontrollers.

Limitations:
  * Hostnames are used as addresses, they must be unique (no DNS or DHCP).
  * No congestion control, the network can get overloaded in extreme cases.
  * No loopback interface (machine cannot send messages to itself).

Each message consists of a string sent to a target host (or broadcasted to all
hosts in the network) and a virtual port. The virtual port is used to specify
which process on the host the message is intended for. All messages are sent
over the modem using a common port number (mnet.port). This hardware port number
can be changed to separate networks with overlapping range. When sending a
message, there is a choice between reliable transfer and unreliable transfer.
With the reliable option, the sender expects the message to be acknowledged to
confirm successful transmission. The sender will retransmit the message until an
"ack" is received, or the message may time out (see mnet configuration options).
When unreliable is used, the message will only be sent once and the receiver
will not send an "ack" back to the sender. This can reduce latency, but the
message may not be received or it might arrive in a different order than the
order it was sent. One thing to note is that there is no interface to establish
a connection for reliable messaging. Connections are managed internally by mnet
and are allowed to persist forever (no "keepalive" like we have in TCP).

For both reliable and unreliable transmission, if the message size is larger
than the maximum transmission unit the modem supports (default is 8192) then it
will be fragmented. A fragmented message gets split into multiple packets and
sent one at a time, then they are recombined into the full message on the
receiving end. This means there is no worry about sending a message with too
much data.

Routing in mnet is very simple and in practice roughly mimics shortest path
first algorithm. When a packet needs to be sent to a receiver, the address of
the modem to forward it to may be unknown (and we may need to broadcast the
packet to everyone). However, the address it came from is known so we will
remember which way to send the next one destined for that sender. When combined
with reliable messaging, a single message and "ack" pair will populate the
routing cache with the current best route between the two hosts (assuming all
routing hosts are processing packets at the same rate).

Example usage:
-- Send a message.
mnet.send("my_target_host", 123, "hello remote host on port 123!", true)

-- Receive messages (preferably done within a thread to run in the background).
-- This should be run even if received messages will be ignored.
local listenerThread = thread.create(function()
  while true do
    local host, port, message = mnet.receive(0.1)
    if message then
      -- Do something with the message, such as parsing the string data to check
      -- for a specific command or pass it to RPC.
    end
  end
end)
--]]



-- FIXME things left to do: #############################################################
-- * test fixes to simultaneous connection start
-- * add support for linked cards
-- * finish routing behavior
-- * functions to open/close mnet.port?
-- * BUG: broadcasts need to be consumed and forwarded
-- * potential bug: can modem.broadcast() trigger a thread sleep? could cause problems with return value from mnet.send() if two threads try to send a message
-- * potential bug: what happens if two servers are reliably communicating and connection goes down for a long time, then comes back? (neither server reboots)




local component = require("component")
local computer = require("computer")
local event = require("event")

local include = require("include")
local dlog = include("dlog")

local mnet = {}

-- Unique address for the machine running this instance of mnet. Do not set this to the string "*" (asterisk is the broadcast address).
mnet.hostname = string.sub(computer.address(), 1, 4)
-- Common hardware port used by all hosts in this network.
mnet.port = 123

-- FIXME NYI ##################################################################################################
mnet.route = true
-- Time in seconds for entries in the routing cache to persist (set this longer for static networks and shorter for dynamically changing ones).
mnet.routeTime = 30
-- Time in seconds for reliable messages to be retransmitted while no "ack" is received.
mnet.retransmitTime = 3
-- Time in seconds until packets in the cache are dropped or reliable messages time out.
mnet.dropTime = 12

-- The message string can be up to the max packet size, minus a bit to make sure the packet can send.
mnet.mtuAdjusted = 1000  --1024  --computer.getDeviceInfo()[component.modem.address].capacity - 32


-- Used to determine routes for packets. Stores uptime, receiverAddress, and senderAddress for each host.
mnet.routingTable = {}
-- Cache of packets that we have seen. Stores uptime for each packet id.
mnet.foundPackets = {}
-- Pending reliable sent packets waiting for acknowledgment, and recently sent packets. Stores uptime, id, flags, port, and message (or nil if acknowledged) where the key is a host-sequence pair.
mnet.sentPackets = {}
-- Pending packets of a message that have been received, and recently received packets. Stores uptime, flags, port, message (or nil if found previously), and fragment number (or nil) where the key is a host-sequence pair.
mnet.receivedPackets = {}
-- Most recent sequence number used for sent packets. Stores sequence number for each host.
mnet.lastSent = {}
-- First sequence number and most recent in-order sequence number found from reliable received packets. Stores sequence numbers for each host.
mnet.lastReceived = {}
-- Set to a host-sequence pair when data in mnet.receivedPackets is ready to return.
mnet.receiveReadyHostSeq = nil
-- Largest value allowed for sequence before wrapping back to 1.
local maxSequence = 100


local modems = {}
for address in component.list("modem", true) do
  modems[address] = component.proxy(address)
  modems[address].open(mnet.port)
end


-- FIXME evil broadcast used for testing unreliable comms ###################################################
local dropSeq, swapSeq
if mnet.hostname == "2f2c" then
  dropSeq = {}
  swapSeq = {}
else
  dropSeq = {}
  swapSeq = {}
end
function mnet.debugEnableLossy(lossy)
  for address in component.list("modem", true) do
    local modem = component.proxy(address)
    if lossy and not modem.debugLossyActive then
      modem.broadcastReal = modem.broadcast
      modem.broadcast = function(...)
        -- Attempt to drop the packet.
        local doDrop = (math.random() < 0.1)
        if dropSeq[1] then
          doDrop = (dropSeq[1] == 1)
          table.remove(dropSeq, 1)
        end
        if doDrop then
          dlog.out("modem", "\27[31mDropped.\27[0m")
          return
        end
        
        -- Attempt to swap order with the next N packets.
        local swapAmount = (math.random() < 0.1 and math.floor(math.random(1, 3)) or 0)
        if swapSeq[1] then
          swapAmount = swapSeq[1]
          table.remove(swapSeq, 1)
        end
        if not modem.debugBufferedPackets then
          modem.debugBufferedPackets = {}
        end
        if swapAmount > 0 then
          dlog.out("modem", "\27[31mSwapping packet order with next ", swapAmount, " packets\27[0m")
          modem.debugBufferedPackets[#modem.debugBufferedPackets + 1] = {computer.uptime() + 20, swapAmount, table.pack(...)}
        else
          modem.broadcastReal(...)
        end
        -- Send any swapped packets that are ready.
        local i = 1
        while modem.debugBufferedPackets[i] do
          local v = modem.debugBufferedPackets[i]
          v[2] = v[2] - 1
          if computer.uptime() > v[1] or v[2] < 0 then
            if computer.uptime() < v[1] then
              modem.broadcastReal(table.unpack(v[3], 1, v[3].n))
            end
            table.remove(modem.debugBufferedPackets, i)
            i = i - 1
          end
          i = i + 1
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
    mnet.mtuAdjusted = 10
  else
    mnet.mtuAdjusted = 1024
  end
end





-- Forms a new packet with generated id to send over the network. The host is
-- expected to have a leading character representing reliability of the message.
-- If sequence is nil, the next value in the sequence is used (or a random value
-- if none). If requireAck is true, the packet data is cached in
-- mnet.sentPackets for retransmission if a loss is detected. The flags can be a
-- string of letter-number pairs with the following options:
--   Flag "s1" means the sender is attempting to synchronize and the sequence
--     number represents the beginning sequence.
--   Flag "r1" means the sender requires acknowledgment of the packet.
--   Flag "a1" means the sequence corresponds to an acknowledged packet.
--   Flag "f<n>" means the message was fragmented and indicates the total number
--     of fragments (if it's the last one) or that there are more fragments
--     (when n is zero).
local function sendFragment(sequence, flags, host, port, fragment, requireAck)
  local id = math.random()
  local t = computer.uptime()
  
  -- The sequence starts at an initial random value and increments by 1 for each
  -- consecutive fragment we send. It is bounded within the range
  -- [1, maxSequence] and wraps back around if the range would be exceeded. A
  -- sequence of 0 is not allowed and has special meaning in an ack.
  if not sequence then
    sequence = mnet.lastSent[host]
    if not sequence then
      sequence = math.floor(math.random(1, maxSequence))
      flags = "s1" .. flags
    end
    sequence = sequence % maxSequence + 1
    mnet.lastSent[host] = sequence
  end
  
  mnet.foundPackets[id] = t
  if requireAck then
    mnet.sentPackets[host .. "," .. sequence] = {t, id, flags, port, fragment}
  end
  
  dlog.out("mnet", "\27[32mSending packet ", mnet.hostname, " -> ", string.sub(host, 2), ":", port, " id=", id, ", seq=", sequence, ", flags=", flags, ", m=", fragment, "\27[0m")
  for _, modem in pairs(modems) do
    modem.broadcast(mnet.port, id, sequence, flags, string.sub(host, 2), mnet.hostname, port, fragment)
  end
  return id
end


-- mnet.send(host: string, port: number, message: string, reliable: boolean[,
--   waitForAck: boolean]): string|nil
-- 
-- Sends a message with a virtual port number to another host in the network.
-- The string "*" can be used to broadcast the message to all other hosts
-- (reliable must be set to false in this case). When reliable is true, this
-- function returns a string concatenating the host and last used sequence
-- number separated by a comma (the host also begins with an 'r' character). The
-- sent message is expected to be acknowledged in this case (think TCP). When
-- reliable is false, nil is returned and no "ack" is expected (think UDP). If
-- reliable and waitForAck are true, this function will block until the "ack" is
-- received or the message times out (nil is returned if it timed out).
function mnet.send(host, port, message, reliable, waitForAck)
  dlog.checkArgs(host, "string", port, "number", message, "string", reliable, "boolean", waitForAck, "boolean,nil")
  xassert(not reliable or host ~= "*", "broadcast address not allowed for reliable packet transmission.")
  -- We prepend an extra character to the host to guarantee unique host-sequence pairs for reliable and unreliable packets.
  host = (reliable and "r" or "u") .. host
  
  local flags = reliable and "r1" or ""
  if #message <= mnet.mtuAdjusted then
    -- Message fits into one packet, send it without fragmenting.
    sendFragment(nil, flags, host, port, message, reliable)
  else
    -- Substring message into multiple pieces and send each.
    local fragmentCount = math.ceil(#message / mnet.mtuAdjusted)
    for i = 1, fragmentCount do
      sendFragment(nil, flags .. (i ~= fragmentCount and "f0" or "f" .. fragmentCount), host, port, string.sub(message, (i - 1) * mnet.mtuAdjusted + 1, i * mnet.mtuAdjusted), reliable)
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


-- Filters the message in the current packet to prevent returning a fragment of
-- a larger message. The currentPacket must be a packet that is in-order or nil.
-- Non-fragment messages simply pass through. If a sentinel fragment is found,
-- all of the fragments are concatenated (if possible) and returned.
local function nextMessage(hostSeq, currentPacket)
  local host, sequence = splitHostSequencePair(hostSeq)
  if currentPacket and not currentPacket[5] then
    local message = currentPacket[4]
    currentPacket[4] = nil
    return string.sub(host, 2), currentPacket[3], message
  end
  
  -- Search for the sentinel fragment.
  while currentPacket and currentPacket[5] == 0 do
    sequence = sequence % maxSequence + 1
    currentPacket = mnet.receivedPackets[host .. "," .. sequence]
  end
  
  if currentPacket then
    -- Iterate mnet.receivedPackets in reverse to collect the fragments. Quit early if any are missing.
    local fragments = {}
    for i = currentPacket[5], 1, -1 do
      local packet = mnet.receivedPackets[host .. "," .. sequence]
      dlog.out("mnet", "Collecting fragment ", host .. "," .. sequence)
      if not (packet and packet[4]) then
        return
      end
      fragments[i] = packet[4]
      sequence = (sequence - 2) % maxSequence + 1
    end
    -- Found all fragments, clear the corresponding mnet.receivedPackets entries.
    for i = 1, currentPacket[5] do
      sequence = sequence % maxSequence + 1
      dlog.out("mnet", "Removing ", host .. "," .. sequence, " from cache.")
      mnet.receivedPackets[host .. "," .. sequence][4] = nil
    end
    return string.sub(host, 2), currentPacket[3], table.concat(fragments)
  end
end


-- mnet.receive(timeout: number[, connectionLostCallback: function]): nil |
--   (string, number, string)
-- 
-- Pulls events up to the timeout duration and returns the sender host, virtual
-- port, and message if any data destined for this host was received. The
-- connectionLostCallback is used to catch reliable messages that failed to send
-- from this host. If provided, the function is called with a string
-- host-sequence pair, a virtual port number, and string fragment. The
-- host-sequence pair corresponds to the return values from mnet.send(), except
-- that fragments besides the last one in a message will not match up.
function mnet.receive(timeout, connectionLostCallback)
  dlog.checkArgs(timeout, "number", connectionLostCallback, "function,nil")
  
  -- Check if we have buffered packets that are ready to return immediately.
  if mnet.receiveReadyHostSeq then
    local hostSeq, host, sequence = mnet.receiveReadyHostSeq, splitHostSequencePair(mnet.receiveReadyHostSeq)
    dlog.out("mnet", "Buffered data ready, hostSeq=", hostSeq, ", type(packet)=", type(mnet.receivedPackets[hostSeq]))
    if mnet.receivedPackets[hostSeq] then
      mnet.receiveReadyHostSeq = host .. "," .. sequence % maxSequence + 1
      -- Skip if the packet has no message data (it was already processed).
      if not mnet.receivedPackets[hostSeq][4] then
        return
      end
      dlog.out("mnet", "Returning buffered packet ", hostSeq, ", dat=", mnet.receivedPackets[hostSeq])
      return nextMessage(hostSeq, mnet.receivedPackets[hostSeq])
    else
      mnet.receiveReadyHostSeq = nil
    end
  end
  
  local eventType, receiverAddress, senderAddress, senderPort, _, id, sequence, flags, dest, src, port, message = event.pull(timeout, "modem_message")
  local t = computer.uptime()
  
  -- Check for packets that timed out, and any that were lost that need to be sent again.
  for hostSeq, packet in pairs(mnet.sentPackets) do
    if t > packet[1] + mnet.dropTime then
      if packet[5] then
        dlog.out("mnet", "\27[33mPacket ", hostSeq, " timed out, dat=", packet, "\27[0m")
        if connectionLostCallback then
          connectionLostCallback(hostSeq, packet[4], packet[5])
        end
      end
      mnet.sentPackets[hostSeq] = nil
    elseif packet[5] and t > mnet.foundPackets[packet[2]] + mnet.retransmitTime then
      -- Packet requires retransmission. The same data is sent again but with a new packet id.
      dlog.out("mnet", "Retransmitting packet with previous id ", packet[2])
      local sentHost, sentSequence = splitHostSequencePair(hostSeq)
      packet[2] = sendFragment(sentSequence, packet[3], sentHost, packet[4], packet[5])
    end
  end
  
  for k, v in pairs(mnet.foundPackets) do
    if t > v + mnet.dropTime then
      --dlog.out("mnet", "\27[33mDropping foundPacket ", k, "\27[0m")
      mnet.foundPackets[k] = nil
    end
  end
  
  -- Return early if not a valid packet.
  if not eventType or senderPort ~= mnet.port or mnet.foundPackets[id] then
    return
  end
  sequence = math.floor(sequence)
  port = math.floor(port)
  
  --[[
  for k, v in pairs(mnet.routingTable) do
    if t > v[1] + mnet.routeTime then
      mnet.routingTable[k] = nil
    end
  end--]]
  for k, v in pairs(mnet.receivedPackets) do
    if t > v[1] + mnet.dropTime then
      if v[4] then
        dlog.out("mnet", "\27[33mDropping receivedPacket ", k, "\27[0m")
      end
      mnet.receivedPackets[k] = nil
    end
  end
  
  dlog.out("mnet", "\27[36mGot packet ", src, " -> ", dest, ":", port, " id=", id, ", seq=", sequence, ", flags=", flags, ", m=", message, "\27[0m")
  mnet.foundPackets[id] = t
  
  if dest ~= mnet.hostname and dest ~= "*" then
    -- Packet is intended for a different recipient, forward it.
    dlog.out("mnet", "\27[32mRouting packet ", id, "\27[0m")
    for _, modem in pairs(modems) do
      modem.broadcast(mnet.port, id, sequence, flags, dest, src, port, message)
    end
  else
    -- Prepend reliability character just like we do in mnet.send().
    local reliable = string.find(flags, "[ra]1")
    src = (reliable and "r" or "u") .. src
    
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
        hostSeq = src .. "," .. beforeFirstSequence % maxSequence + 1
        
        -- If the ack does not correspond to before the first pending sent packet and we found the first pending one, force it to have the syn flag set.
        dlog.out("mnet", "Found unexpected ack, beforeFirstSequence is ", beforeFirstSequence, ", first hostSeq is ", hostSeq)
        local firstSentPacket = mnet.sentPackets[hostSeq]
        if beforeFirstSequence ~= sequence and firstSentPacket and not string.find(firstSentPacket[3], "s1") then
          dlog.out("mnet", "Setting syn flag for hostSeq.")
          firstSentPacket[3] = firstSentPacket[3] .. "s1"
        end
      end
      return
    end
    
    
    --[[
    FIXME consider these cases: ###############################################################
      * two syn packets with same sequence arrive
      * two ack packets for same sequence arrive
      * random ack arrives (may need to ignore or start new connection)
      * unexpected sequence arrives
      * syn packet arrives after we saw other sequences in order
    --]]
    
    local currentPacket
    
    -- Only process packet with this sequence number if it has not been processed before.
    if not mnet.receivedPackets[hostSeq] or mnet.receivedPackets[hostSeq][4] then
      currentPacket = {t, flags, port, message, tonumber(string.match(flags, "f(%d+)"))}
      mnet.receivedPackets[hostSeq] = currentPacket
      
      if not reliable then
        -- Packet is unreliable, we don't care about ordering.
        dlog.out("mnet", "Ignored ordering, passing packet through.")
      elseif string.find(flags, "s1") or mnet.lastReceived[src] and mnet.lastReceived[src] % maxSequence + 1 == sequence then
        -- Packet has syn flag set (marks a new connection) or the sequence corresponds to the next one we expect.
        if string.find(flags, "s1") then
          dlog.out("mnet", "Begin new connection to ", string.sub(src, 2))
        else
          dlog.out("mnet", "Packet arrived in expected order.")
        end
        mnet.lastReceived[src] = sequence
        -- Push the last received sequence value ahead while there are in-order buffered packets.
        while mnet.receivedPackets[src .. "," .. mnet.lastReceived[src] % maxSequence + 1] do
          mnet.lastReceived[src] = mnet.lastReceived[src] % maxSequence + 1
          dlog.out("mnet", "Buffered packet ready, bumped last sequence to ", mnet.lastReceived[src])
          mnet.receiveReadyHostSeq = mnet.receiveReadyHostSeq or src .. "," .. mnet.lastReceived[src]
        end
      else
        -- Sequence does not correspond to the expected one, delay processing the packet until later.
        dlog.out("mnet", "Packet arrived in unexpected order (last sequence was ", mnet.lastReceived[src], ")")
        currentPacket = nil
      end
    else
      dlog.out("mnet", "Already processed this sequence, ignoring.")
    end
    
    -- If packet is reliable then ack the last in-order one we received.
    if reliable then
      sendFragment(mnet.lastReceived[src] or 0, "a1", src, port)
    end
    
    return nextMessage(hostSeq, currentPacket)
  end
end

return mnet
