--------------------------------------------------------------------------------
-- Mesh networking protocol with minimalistic API.
-- 
-- Compiled by simple_preprocess. This version runs on embedded systems.
-- 
-- @see file://libmnet/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local component = require("component")


-- Most private variables have been bound to a local value to optimize file compression and performance. See comments in below section for descriptions.
local mnet, mnetRoutingTable, mnetFoundPackets, mnetSentPackets, mnetReceivedPackets, mnetLastSent, mnetLastReceived, mnetReceiveReadyHostSeq, mnetMaxSequence, modems = {}, {}, {}, {}, {}, {}, {}, nil, math.floor(2 ^ 32), {}

--- `mnet.hostname = <env HOSTNAME or first 8 characters of computer address>`
-- 
-- Unique address for the machine running this instance of mnet. Do not set this
-- to the string `*` (asterisk is the broadcast address).
mnet.hostname = computer.address():sub(1, 8)

--- `mnet.port = 2048`
-- 
-- Common hardware port used by all hosts in this network.
mnet.port = 2048

--- `mnet.route = true`
-- 
-- Enables forwarding of packets to other hosts (packets with a different
-- destination than `mnet.hostname`). Can be disabled for network nodes that
-- function as endpoints.
mnet.route = true

--- `mnet.routeTime = 30`
-- 
-- Time in seconds for entries in the routing cache to persist (set this longer
-- for static networks and shorter for dynamically changing ones).
mnet.routeTime = 30

--- `mnet.retransmitTime = 3`
-- 
-- Time in seconds for reliable messages to be retransmitted while no "ack" is
-- received.
mnet.retransmitTime = 3

--- `mnet.dropTime = 12`
-- 
-- Time in seconds until packets in the cache are dropped or reliable messages
-- time out.
mnet.dropTime = 12


-- Used to determine routes for packets. Stores receiverAddress, senderAddress, and uptime (or nil if static) for each host.
--mnet.routingTable = mnetRoutingTable

-- Cache of packets that we have seen. Stores uptime for each packet id.
--mnet.foundPackets = mnetFoundPackets

-- Reliable sent packets that are waiting for acknowledgment (or recently acknowledged). Stores uptime, id, flags, port, and message (or nil if acknowledged) where the key is a host-sequence pair.
--mnet.sentPackets = mnetSentPackets

-- Packets of a message that have been received (or recently received). Stores uptime, flags, port, message (or nil if found previously), and fragment number (or nil) where the key is a host-sequence pair.
--mnet.receivedPackets = mnetReceivedPackets

-- Most recent sequence number used for sent packets. Stores sequence number for each host (host has leading character).
--mnet.lastSent = mnetLastSent

-- Most recent in-order sequence number found from reliable received packets. Stores sequence number for each host (host has leading character).
--mnet.lastReceived = mnetLastReceived

-- Set to a host-sequence pair when data in mnetReceivedPackets is ready to return.
--mnet.receiveReadyHostSeq = mnetReceiveReadyHostSeq

-- Largest value allowed for sequence before wrapping back to 1. This can theoretically be up to 2^53 (integer precision of 64-bit floating-point mantissa in Lua 5.2).
--mnet.maxSequence = mnetMaxSequence




-- Collect all currently attached network interfaces into a table.
for address in component.list("modem", true) do
  modems[address] = component.proxy(address)
  modems[address].open(mnet.port)
end

-- The message string we send in a packet can be up to the maximum transmission unit (default 8192) minus the maximum amount of overhead bytes to make sure the packet can send.
-- Maximum overhead =    sum(total values,  id, sequence, flags, dest hostname, src hostname, port, fragment, a little extra)
mnet.mtuAdjusted = 8042






-- Communicates with available modems to send the packet to the destination
-- host. If a corresponding entry for the destination is found in
-- mnetRoutingTable, we send the packet directly to that modem address (and hope
-- that the address will still lead back to the destination). Otherwise, we just
-- broadcast the packet to everyone.
local function routePacket(id, sequence, flags, dest, src, port, fragment)
  if mnetRoutingTable[dest] and modems[mnetRoutingTable[dest][1]] then
    modems[mnetRoutingTable[dest][1]].send(mnetRoutingTable[dest][2], mnet.port, id, sequence, flags, dest, src, port, fragment)
  else
    for _, modem in pairs(modems) do
      modem.broadcast(mnet.port, id, sequence, flags, dest, src, port, fragment)
    end
  end
end


-- Forms a new packet with generated id to send over the network. The host is
-- expected to have a leading character representing reliability of the message.
-- If sequence is nil, the next value in the sequence is used (or a random value
-- if none). If requireAck is true, the packet data is cached in
-- mnetSentPackets for retransmission if a loss is detected. The flags can be a
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
  -- [1, mnetMaxSequence] and wraps back around if the range would be exceeded.
  -- A sequence of 0 is not allowed and has special meaning in an ack.
  if not sequence then
    sequence = mnetLastSent[host]
    if not sequence then
      sequence = math.floor(math.random(1, mnetMaxSequence))
      flags = "s1" .. flags
    end
    sequence = sequence % mnetMaxSequence + 1
    mnetLastSent[host] = sequence
  end
  
  mnetFoundPackets[id] = t
  if requireAck then
    mnetSentPackets[host .. "," .. sequence] = {t, id, flags, port, fragment}
  end
  
  routePacket(id, sequence, flags, host:sub(2), mnet.hostname, port, fragment)
  return id
end


--- `mnet.send(host: string, port: number, message: string, reliable: boolean[,
--   waitForAck: boolean]): string|nil`
-- 
-- Sends a message with a virtual port number to another host in the network.
-- The message can be any length and contain binary data. The host `*` can be
-- used to broadcast the message to all other hosts (reliable must be set to
-- false in this case). The host `localhost` or `mnet.hostname` allow the
-- machine to send a message to itself (loopback interface).
-- 
-- When reliable is true, this function returns a string concatenating the host
-- and last used sequence number separated by a comma (the host also begins with
-- an `r` or `u` character indicating reliability, like `rHOST,SEQUENCE`). The
-- sent message is expected to be acknowledged in this case (think TCP). When
-- reliable is false, nil is returned and no "ack" is expected (think UDP). If
-- reliable and waitForAck are true, this function will block until the "ack" is
-- received or the message times out (nil is returned if it timed out).
function mnet.send(host, port, message, reliable, waitForAck)
  assert(not reliable or host ~= "*")
  
  
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
      sendFragment(nil, flags .. (i ~= fragmentCount and "f0" or "f" .. fragmentCount), host, port, message:sub((i - 1) * mnet.mtuAdjusted + 1, i * mnet.mtuAdjusted), reliable)
    end
  end
  
  if reliable then
    local lastHostSeq = host .. "," .. mnetLastSent[host]
    
    -- Busy-wait until the last packet receives an ack or it times out.
    if waitForAck then
      while mnetSentPackets[lastHostSeq] do
        if not mnetSentPackets[lastHostSeq][5] then
          return lastHostSeq
        end
        os.sleep(0.05)
      end
    else
      return lastHostSeq
    end
  end
end


-- Breaks a comma-separated host and sequence string into their values. The host
-- will still have the extra prefix character. To remove this, just add a period
-- at the start of the match pattern.
local function splitHostSequencePair(hostSeq)
  local host, sequence = hostSeq:match("(.*),([^,]+)$")
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
    return host:sub(2), currentPacket[3], message
  end
  
  -- Search for the sentinel fragment.
  while currentPacket and currentPacket[5] == 0 do
    sequence = sequence % mnetMaxSequence + 1
    currentPacket = mnetReceivedPackets[host .. "," .. sequence]
  end
  
  if currentPacket then
    -- Iterate mnetReceivedPackets in reverse to collect the fragments. Quit early if any are missing.
    local fragments = {}
    for i = currentPacket[5], 1, -1 do
      local packet = mnetReceivedPackets[host .. "," .. sequence]
      if not (packet and packet[4]) then
        return
      end
      fragments[i] = packet[4]
      sequence = (sequence - 2) % mnetMaxSequence + 1
    end
    -- Found all fragments, clear the corresponding mnetReceivedPackets entries.
    for i = 1, currentPacket[5] do
      sequence = sequence % mnetMaxSequence + 1
      mnetReceivedPackets[host .. "," .. sequence][4] = nil
    end
    return host:sub(2), currentPacket[3], table.concat(fragments)
  end
end


--- `mnet.receive(timeout: number[, connectionLostCallback: function]): nil |
--   (string, number, string)`<br>
-- *On embedded systems, pass an event (in a table) instead of timeout:*<br>
-- `mnet.receive(ev: table[, connectionLostCallback: function]): nil |
--   (string, number, string)`
-- 
-- Pulls events up to the timeout duration and returns the sender host, virtual
-- port, and message if any data destined for this host was received. The
-- connectionLostCallback is used to catch reliable messages that failed to send
-- from this host. If provided, the function is called with a string
-- host-sequence pair, a virtual port number, and string fragment. The
-- host-sequence pair corresponds to the return values from `mnet.send()`. Note
-- that the host in this pair has an `r` character prefix, and the sequence
-- number will only match a previous return value from `mnet.send()` if it
-- corresponds to the last fragment of the original message.
function mnet.receive(ev, connectionLostCallback)
  
  -- Check if we have buffered packets that are ready to return immediately.
  if mnetReceiveReadyHostSeq then
    local hostSeq, host, sequence = mnetReceiveReadyHostSeq, splitHostSequencePair(mnetReceiveReadyHostSeq)
    if mnetReceivedPackets[hostSeq] then
      mnetReceiveReadyHostSeq = host .. "," .. sequence % mnetMaxSequence + 1
      -- Skip if the packet has no message data (it was already processed).
      if not mnetReceivedPackets[hostSeq][4] then
        return
      end
      return nextMessage(hostSeq, mnetReceivedPackets[hostSeq])
    else
      mnetReceiveReadyHostSeq = nil
    end
  end
  
  local eventType, receiverAddress, senderAddress, senderPort, _, id, sequence, flags, dest, src, port, message = table.unpack(ev, 1, 12)
  local t = computer.uptime()
  
  -- Check for packets that timed out, and any that were lost that need to be sent again.
  for hostSeq, packet in pairs(mnetSentPackets) do
    if t > packet[1] + mnet.dropTime then
      if packet[5] then
        if connectionLostCallback then
          connectionLostCallback(hostSeq, packet[4], packet[5])
        end
      end
      mnetSentPackets[hostSeq] = nil
    elseif packet[5] and t > mnetFoundPackets[packet[2]] + mnet.retransmitTime then
      -- Packet requires retransmission. The same data is sent again but with a new packet id.
      local sentHost, sentSequence = splitHostSequencePair(hostSeq)
      packet[2] = sendFragment(sentSequence, packet[3], sentHost, packet[4], packet[5])
    end
  end
  
  -- Remove previously found packet id numbers and routing cache entries that are old.
  for k, v in pairs(mnetFoundPackets) do
    if t > v + mnet.dropTime then
      mnetFoundPackets[k] = nil
    end
  end
  for k, v in pairs(mnetRoutingTable) do
    if t > v[3] + mnet.routeTime then
      mnetRoutingTable[k] = nil
    end
  end
  
  -- Return early if not a valid packet.
  if eventType ~= "modem_message" or (senderPort ~= mnet.port and senderPort ~= 0) or mnetFoundPackets[id] then
    return
  end
  sequence = math.floor(sequence)
  port = math.floor(port)
  
  for k, v in pairs(mnetReceivedPackets) do
    if t > v[1] + mnet.dropTime then
      mnetReceivedPackets[k] = nil
    end
  end
  
  mnetFoundPackets[id] = t
  mnetRoutingTable[src] = mnetRoutingTable[src] or {receiverAddress, senderAddress, t}
  
  if dest ~= mnet.hostname and mnet.route then
    -- Packet is intended for a different recipient, forward it.
    routePacket(id, sequence, flags, dest, src, port, message)
  end
  
  if dest == mnet.hostname or dest == "*" then
    -- Prepend reliability character just like we do in mnet.send().
    local reliable = flags:find("[ra]1")
    src = (reliable and "r" or "u") .. src
    
    -- Packet arrived at destination, consume it. First check if it is an ack to a previously sent packet.
    local hostSeq = src .. "," .. sequence
    if flags == "a1" then
      if mnetSentPackets[hostSeq] then
        -- Set the message to nil to mark completion (and all previous sequential messages).
        while mnetSentPackets[hostSeq] and mnetSentPackets[hostSeq][5] do
          mnetSentPackets[hostSeq][5] = nil
          sequence = (sequence - 2) % mnetMaxSequence + 1
          hostSeq = src .. "," .. sequence
        end
      else
        -- An ack was received for a sequence number that was not sent, we may need to synchronize the receiver. Set hostSeq to the first instance we find for this host (first pending sent packet).
        local beforeFirstSequence = mnetLastSent[src] or 0
        repeat
          beforeFirstSequence = (beforeFirstSequence - 2) % mnetMaxSequence + 1
          hostSeq = src .. "," .. beforeFirstSequence
        until not (mnetSentPackets[hostSeq] and mnetSentPackets[hostSeq][5])
        hostSeq = src .. "," .. beforeFirstSequence % mnetMaxSequence + 1
        
        -- If the ack does not correspond to before the first pending sent packet and we found the first pending one, force it to have the syn flag set.
        local firstSentPacket = mnetSentPackets[hostSeq]
        if beforeFirstSequence ~= sequence and firstSentPacket and not firstSentPacket[3]:find("s1") then
          firstSentPacket[3] = firstSentPacket[3] .. "s1"
        end
      end
      return
    end
    
    -- Some tricky cases that can happen, and how they are handled:
    --   * Two syn packets with same sequence arrive (second gets dropped because we already saw that sequence).
    --   * Two ack packets for same sequence arrive (second gets ignored because we still have the sent packet cached and it's marked acknowledged).
    --   * Random ack arrives (determine if a new connection is needed based on the first pending sent packet).
    --   * Unexpected sequence arrives (cache it for later and ack the last in-order sequence we got).
    --   * Syn packet arrives after we saw other sequences in order (syn sequence takes priority and we renew the connection, we still bump it forward if there are buffered packets).
    
    -- Only process packet with this sequence number if it has not been processed before.
    local currentPacket
    if not mnetReceivedPackets[hostSeq] or mnetReceivedPackets[hostSeq][4] then
      currentPacket = {t, flags, port, message, tonumber(flags:match("f(%d+)"))}
      mnetReceivedPackets[hostSeq] = currentPacket
      
      if not reliable then
        -- Packet is unreliable, we don't care about ordering.
      elseif flags:find("s1") or mnetLastReceived[src] and mnetLastReceived[src] % mnetMaxSequence + 1 == sequence then
        -- Packet has syn flag set (marks a new connection) or the sequence corresponds to the next one we expect.
        mnetLastReceived[src] = sequence
        -- Push the last received sequence value ahead while there are in-order buffered packets.
        while mnetReceivedPackets[src .. "," .. mnetLastReceived[src] % mnetMaxSequence + 1] do
          mnetLastReceived[src] = mnetLastReceived[src] % mnetMaxSequence + 1
          mnetReceiveReadyHostSeq = mnetReceiveReadyHostSeq or src .. "," .. mnetLastReceived[src]
        end
      else
        -- Sequence does not correspond to the expected one, delay processing the packet until later.
        currentPacket = nil
      end
    else
    end
    
    -- If packet is reliable then ack the last in-order one we received.
    if reliable then
      sendFragment(mnetLastReceived[src] or 0, "a1", src, port)
    end
    
    return nextMessage(hostSeq, currentPacket)
  end
end

return mnet
