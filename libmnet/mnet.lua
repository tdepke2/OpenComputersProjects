--------------------------------------------------------------------------------
-- Mesh networking protocol with minimalistic API.
-- 
-- @see file://libmnet/README.md
-- @author tdepke2
--------------------------------------------------------------------------------



-- FIXME things left to do: #############################################################
-- * test fixes to simultaneous connection start
-- * add support for linked cards
-- * finish routing behavior
-- * functions to open/close mnet.port?
-- * BUG: broadcasts need to be consumed and forwarded
-- * potential bug: can modem.broadcast() trigger a thread sleep? (pretty sure no). could cause problems with return value from mnet.send() if two threads try to send a message
-- * potential bug: what happens if two servers are reliably communicating and connection goes down for a long time, then comes back? (neither server reboots)
-- * loopback interface?
-- * what happens if a NIC is plugged or unplugged? do we need a function to register/unregister a NIC?




local component = require("component")
##if OPEN_OS then
local computer = require("computer")
local event = require("event")
##end

##if USE_DLOG then
local include = require("include")
local dlog = include("dlog")
##end

-- Most private variables have been bound to a local value to optimize file compression and performance. See comments in below section for descriptions.
local mnet, mnetRoutingTable, mnetFoundPackets, mnetSentPackets, mnetReceivedPackets, mnetLastSent, mnetLastReceived, mnetReceiveReadyHostSeq, mnetMaxSequence = {}, {}, {}, {}, {}, {}, {}, nil, math.floor(2 ^ 52)

-- Unique address for the machine running this instance of mnet. Do not set this to the string "*" (asterisk is the broadcast address).
mnet.hostname = computer.address():sub(1, 4)
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


-- Used to determine routes for packets. Stores uptime, receiverAddress, and senderAddress for each host.
--mnet.routingTable = mnetRoutingTable
-- Cache of packets that we have seen. Stores uptime for each packet id.
--mnet.foundPackets = mnetFoundPackets
-- Pending reliable sent packets waiting for acknowledgment, and recently sent packets. Stores uptime, id, flags, port, and message (or nil if acknowledged) where the key is a host-sequence pair.
--mnet.sentPackets = mnetSentPackets
-- Pending packets of a message that have been received, and recently received packets. Stores uptime, flags, port, message (or nil if found previously), and fragment number (or nil) where the key is a host-sequence pair.
--mnet.receivedPackets = mnetReceivedPackets
-- Most recent sequence number used for sent packets. Stores sequence number for each host.
--mnet.lastSent = mnetLastSent
-- First sequence number and most recent in-order sequence number found from reliable received packets. Stores sequence numbers for each host.
--mnet.lastReceived = mnetLastReceived
-- Set to a host-sequence pair when data in mnetReceivedPackets is ready to return.
--mnet.receiveReadyHostSeq = mnetReceiveReadyHostSeq
-- Largest value allowed for sequence before wrapping back to 1.
--mnet.maxSequence = mnetMaxSequence


-- Collect all network interfaces into a table.
-- Other devices (like the linked card) can be included here as long as they implement open(), close(), send(), and broadcast().
local modems = {}
for address in component.list("modem", true) do
  modems[address] = component.proxy(address)
  modems[address].open(mnet.port)
  mnet.mtuAdjusted = modems[address].maxPacketSize()
end
for address in component.list("tunnel", true) do
  local tunnel = component.proxy(address)
  modems[address] = setmetatable({
    open = function() end,
    close = function() end,
    send = function(a, p, ...) return tunnel.send(...) end,
    broadcast = function(p, ...) return tunnel.send(...) end
  }, {
    __index = tunnel
  })
  mnet.mtuAdjusted = tunnel.maxPacketSize()
end

-- The message string we send in a packet can be up to the maximum transmission unit (default 8192) minus the maximum amount of overhead bytes to make sure the packet can send.
-- Maximum overhead =    sum(total values,  id, sequence, flags, dest hostname, src hostname, port, fragment, a little extra)
##local maxPacketOverhead = (       7 * 2  + 8       + 8    + 8           + 36          + 36   + 8       + 0            + 0)    -- FIXME change extra to 32 #################################################################
##spwrite("mnet.mtuAdjusted = mnet.mtuAdjusted - ", maxPacketOverhead)


##if EXPERIMENTAL_DEBUG then
-- Debugging functions. The following should only be used for testing purposes.

-- Artificial cap on the maximum transmission unit when debugSetSmallMTU() is enabled.
local SMALL_MTU_SIZE = 10
-- Probability to intentionally drop a packet [0, 1].
local PACKET_DROP_CHANCE = 0.1
-- Probability to intentionally reorder a packet [0, 1].
local PACKET_SWAP_CHANCE = 0.1
-- Highest number of packets to come after the swapped one before we finally send it.
local PACKET_SWAP_MAX_OFFSET = 3


-- mnet.debugEnableLossy(lossy: boolean)
-- 
-- Sets lossy mode for packet transmission. This hooks into each network
-- interface in the modems table and overrides modem.send() and
-- modem.broadcast() to have a percent chance to drop (delete) or swap the
-- ordering of a packet during transmit. This mimics real behavior of wireless
-- packet transfer when the receiver is close to the maximum range of the
-- wireless transmitter. Packets can also arrive in a different order than the
-- order they are sent in large networks where routing paths are frequently
-- changing. This is purely for debugging the performance and correctness of
-- mnet.
function mnet.debugEnableLossy(lossy)
  local function buildTransmitWrapper(modem, func)
    local dropSeq, swapSeq = {}, {}
    
    return function(...)
      -- Attempt to drop the packet.
      local doDrop = (math.random() < PACKET_DROP_CHANCE)
      if dropSeq[1] then
        doDrop = (dropSeq[1] == 1)
        table.remove(dropSeq, 1)
      end
      if doDrop then
        dlog.out("modem", "\27[31mDropped.\27[0m")
        return true
      end
      
      -- Attempt to swap order with the next N packets.
      local swapAmount = (math.random() < PACKET_SWAP_CHANCE and math.floor(math.random(1, PACKET_SWAP_MAX_OFFSET)) or 0)
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
        func(...)
      end
      -- Send any swapped packets that are ready.
      local i = 1
      while modem.debugBufferedPackets[i] do
        local v = modem.debugBufferedPackets[i]
        v[2] = v[2] - 1
        if computer.uptime() > v[1] or v[2] < 0 then
          if computer.uptime() < v[1] then
            func(table.unpack(v[3], 1, v[3].n))
          end
          table.remove(modem.debugBufferedPackets, i)
          i = i - 1
        end
        i = i + 1
      end
      return true
    end
  end
  
  for _, modem in pairs(modems) do
    if lossy and not modem.debugLossyActive then
      modem.sendReal = modem.send
      modem.send = buildTransmitWrapper(modem, modem.sendReal)
      modem.broadcastReal = modem.broadcast
      modem.broadcast = buildTransmitWrapper(modem, modem.broadcastReal)
      modem.debugLossyActive = true
    elseif not lossy and modem.debugLossyActive then
      modem.send = modem.sendReal
      modem.broadcast = modem.broadcastReal
      modem.debugLossyActive = false
    end
  end
end

-- mnet.debugSetSmallMTU(b: boolean)
-- 
-- Sets small MTU mode for testing how mnet behaves when a message is fragmented
-- into many small pieces.
local mtuAdjustedReal
function mnet.debugSetSmallMTU(b)
  if b and not mtuAdjustedReal then
    mtuAdjustedReal = mnet.mtuAdjusted
    mnet.mtuAdjusted = SMALL_MTU_SIZE
  elseif not b and mtuAdjustedReal then
    mnet.mtuAdjusted = mtuAdjustedReal
    mtuAdjustedReal = nil
  end
end

##end



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
  
  ##if USE_DLOG then
  dlog.out("mnet", "\27[32mSending packet ", mnet.hostname, " -> ", host:sub(2), ":", port, " id=", id, ", seq=", sequence, ", flags=", flags, ", m=", fragment, "\27[0m")
  ##end
  for _, modem in pairs(modems) do
    modem.broadcast(mnet.port, id, sequence, flags, host:sub(2), mnet.hostname, port, fragment)
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
  ##if USE_DLOG then
  dlog.checkArgs(host, "string", port, "number", message, "string", reliable, "boolean", waitForAck, "boolean,nil")
  xassert(not reliable or host ~= "*", "broadcast address not allowed for reliable packet transmission.")
  ##else
  assert(not reliable or host ~= "*")
  ##end
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
    if waitForAck then
      -- Busy-wait until the last packet receives an ack or it times out.
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


-- Breaks a comma-separated host and sequence string into their values.
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
      ##if USE_DLOG then
      dlog.out("mnet", "Collecting fragment ", host .. "," .. sequence)
      ##end
      if not (packet and packet[4]) then
        return
      end
      fragments[i] = packet[4]
      sequence = (sequence - 2) % mnetMaxSequence + 1
    end
    -- Found all fragments, clear the corresponding mnetReceivedPackets entries.
    for i = 1, currentPacket[5] do
      sequence = sequence % mnetMaxSequence + 1
      ##if USE_DLOG then
      dlog.out("mnet", "Removing ", host .. "," .. sequence, " from cache.")
      ##end
      mnetReceivedPackets[host .. "," .. sequence][4] = nil
    end
    return host:sub(2), currentPacket[3], table.concat(fragments)
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
##if OPEN_OS then
function mnet.receive(timeout, connectionLostCallback)
##else
function mnet.receive(ev, connectionLostCallback)
##end
##if USE_DLOG then
  dlog.checkArgs(timeout, "number", connectionLostCallback, "function,nil")
##end
  
  -- Check if we have buffered packets that are ready to return immediately.
  if mnetReceiveReadyHostSeq then
    local hostSeq, host, sequence = mnetReceiveReadyHostSeq, splitHostSequencePair(mnetReceiveReadyHostSeq)
    ##if USE_DLOG then
    dlog.out("mnet", "Buffered data ready, hostSeq=", hostSeq, ", type(packet)=", type(mnetReceivedPackets[hostSeq]))
    ##end
    if mnetReceivedPackets[hostSeq] then
      mnetReceiveReadyHostSeq = host .. "," .. sequence % mnetMaxSequence + 1
      -- Skip if the packet has no message data (it was already processed).
      if not mnetReceivedPackets[hostSeq][4] then
        return
      end
      ##if USE_DLOG then
      dlog.out("mnet", "Returning buffered packet ", hostSeq, ", dat=", mnetReceivedPackets[hostSeq])
      ##end
      return nextMessage(hostSeq, mnetReceivedPackets[hostSeq])
    else
      mnetReceiveReadyHostSeq = nil
    end
  end
  
  ##spwrite("local eventType, receiverAddress, senderAddress, senderPort, _, id, sequence, flags, dest, src, port, message = ", OPEN_OS and "event.pull(timeout, \"modem_message\")" or "table.unpack(ev, 1, 12)")
  local t = computer.uptime()
  
  -- Check for packets that timed out, and any that were lost that need to be sent again.
  for hostSeq, packet in pairs(mnetSentPackets) do
    if t > packet[1] + mnet.dropTime then
      if packet[5] then
        ##if USE_DLOG then
        dlog.out("mnet", "\27[33mPacket ", hostSeq, " timed out, dat=", packet, "\27[0m")
        ##end
        if connectionLostCallback then
          connectionLostCallback(hostSeq, packet[4], packet[5])
        end
      end
      mnetSentPackets[hostSeq] = nil
    elseif packet[5] and t > mnetFoundPackets[packet[2]] + mnet.retransmitTime then
      -- Packet requires retransmission. The same data is sent again but with a new packet id.
      ##if USE_DLOG then
      dlog.out("mnet", "Retransmitting packet with previous id ", packet[2])
      ##end
      local sentHost, sentSequence = splitHostSequencePair(hostSeq)
      packet[2] = sendFragment(sentSequence, packet[3], sentHost, packet[4], packet[5])
    end
  end
  
  for k, v in pairs(mnetFoundPackets) do
    if t > v + mnet.dropTime then
      ##if USE_DLOG then
      --dlog.out("mnet", "\27[33mDropping foundPacket ", k, "\27[0m")
      ##end
      mnetFoundPackets[k] = nil
    end
  end
  
  -- Return early if not a valid packet.
  if eventType ~= "modem_message" or senderPort ~= mnet.port or mnetFoundPackets[id] then
    return
  end
  sequence = math.floor(sequence)
  port = math.floor(port)
  
  --[[
  for k, v in pairs(mnetRoutingTable) do
    if t > v[1] + mnet.routeTime then
      mnetRoutingTable[k] = nil
    end
  end--]]
  for k, v in pairs(mnetReceivedPackets) do
    if t > v[1] + mnet.dropTime then
      ##if USE_DLOG then
      if v[4] then
        dlog.out("mnet", "\27[33mDropping receivedPacket ", k, "\27[0m")
      end
      ##end
      mnetReceivedPackets[k] = nil
    end
  end
  
  ##if USE_DLOG then
  dlog.out("mnet", "\27[36mGot packet ", src, " -> ", dest, ":", port, " id=", id, ", seq=", sequence, ", flags=", flags, ", m=", message, "\27[0m")
  ##end
  mnetFoundPackets[id] = t
  
  if dest ~= mnet.hostname and dest ~= "*" then
    -- Packet is intended for a different recipient, forward it.
    ##if USE_DLOG then
    dlog.out("mnet", "\27[32mRouting packet ", id, "\27[0m")
    ##end
    for _, modem in pairs(modems) do
      modem.broadcast(mnet.port, id, sequence, flags, dest, src, port, message)
    end
  else
    -- Prepend reliability character just like we do in mnet.send().
    local reliable = flags:find("[ra]1")
    src = (reliable and "r" or "u") .. src
    
    -- Packet arrived at destination, consume it. First check if it is an ack to a previously sent packet.
    local hostSeq = src .. "," .. sequence
    if flags == "a1" then
      if mnetSentPackets[hostSeq] then
        -- Set the message to nil to mark completion (and all previous sequential messages).
        while mnetSentPackets[hostSeq] and mnetSentPackets[hostSeq][5] do
          ##if USE_DLOG then
          dlog.out("mnet", "Marking ", hostSeq, " as acknowledged.")
          ##end
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
        ##if USE_DLOG then
        dlog.out("mnet", "Found unexpected ack, beforeFirstSequence is ", beforeFirstSequence, ", first hostSeq is ", hostSeq)
        ##end
        local firstSentPacket = mnetSentPackets[hostSeq]
        if beforeFirstSequence ~= sequence and firstSentPacket and not firstSentPacket[3]:find("s1") then
          ##if USE_DLOG then
          dlog.out("mnet", "Setting syn flag for hostSeq.")
          ##end
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
    if not mnetReceivedPackets[hostSeq] or mnetReceivedPackets[hostSeq][4] then
      currentPacket = {t, flags, port, message, tonumber(flags:match("f(%d+)"))}
      mnetReceivedPackets[hostSeq] = currentPacket
      
      if not reliable then
        -- Packet is unreliable, we don't care about ordering.
        ##if USE_DLOG then
        dlog.out("mnet", "Ignored ordering, passing packet through.")
        ##end
      elseif flags:find("s1") or mnetLastReceived[src] and mnetLastReceived[src] % mnetMaxSequence + 1 == sequence then
        -- Packet has syn flag set (marks a new connection) or the sequence corresponds to the next one we expect.
        ##if USE_DLOG then
        if flags:find("s1") then
          dlog.out("mnet", "Begin new connection to ", src:sub(2))
        else
          dlog.out("mnet", "Packet arrived in expected order.")
        end
        ##end
        mnetLastReceived[src] = sequence
        -- Push the last received sequence value ahead while there are in-order buffered packets.
        while mnetReceivedPackets[src .. "," .. mnetLastReceived[src] % mnetMaxSequence + 1] do
          mnetLastReceived[src] = mnetLastReceived[src] % mnetMaxSequence + 1
          ##if USE_DLOG then
          dlog.out("mnet", "Buffered packet ready, bumped last sequence to ", mnetLastReceived[src])
          ##end
          mnetReceiveReadyHostSeq = mnetReceiveReadyHostSeq or src .. "," .. mnetLastReceived[src]
        end
      else
        -- Sequence does not correspond to the expected one, delay processing the packet until later.
        ##if USE_DLOG then
        dlog.out("mnet", "Packet arrived in unexpected order (last sequence was ", mnetLastReceived[src], ")")
        ##end
        currentPacket = nil
      end
    else
      ##if USE_DLOG then
      dlog.out("mnet", "Already processed this sequence, ignoring.")
      ##end
    end
    
    -- If packet is reliable then ack the last in-order one we received.
    if reliable then
      sendFragment(mnetLastReceived[src] or 0, "a1", src, port)
    end
    
    return nextMessage(hostSeq, currentPacket)
  end
end

return mnet
