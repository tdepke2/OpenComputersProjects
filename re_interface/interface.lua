--[[

--]]

local COMMS_PORT = 0xE298

local component = require("component")
local computer = require("computer")
local event = require("event")
local modem = component.modem
local serialization = require("serialization")
local tdebug = require("tdebug")
local term = require("term")
local text = require("text")
local thread = require("thread")

local packetNumber = 1
local packetBuffer = {}
local maxDataLength = computer.getDeviceInfo()[component.modem.address].capacity - 64    -- The string can be up to the max packet size, minus a bit to make sure the packet can send.
local maxPacketLife = 5

-- sendMessage(modem: table, address: string|nil, port: number, data: string)
-- 
-- Send a message over the network containing the data packet (must be a
-- string). If the address is nil, message is sent as a broadcast. The data
-- packet is broken up into smaller pieces if it is too big for the max packet
-- size.
local function sendMessage(modem, address, port, data)
  checkArg(1, modem, "table", 3, port, "number", 4, data, "string")
  print("Send message to " .. string.sub(tostring(address), 1, 4) .. " port " .. port .. ": " .. data)
  
  if #data <= maxDataLength then
    -- Data is small enough, send it in one packet.
    if address then
      modem.send(address, port, packetNumber .. "/1", data)
    else
      modem.broadcast(port, packetNumber .. "/1", data)
    end
    print("  Packet to " .. string.sub(tostring(address), 1, 4) .. " port " .. port .. ": " .. packetNumber .. "/1 " .. data)
    packetNumber = packetNumber + 1
  else
    -- Substring data into multiple pieces and send each. The first one includes a "/<packet count>" after the packet number.
    local packetCount = math.ceil(#data / maxDataLength)
    for i = 1, packetCount do
      if address then
        modem.send(address, port, packetNumber .. (i == 1 and "/" .. packetCount or ""), string.sub(data, (i - 1) * maxDataLength + 1, i * maxDataLength))
      else
        modem.broadcast(port, packetNumber .. (i == 1 and "/" .. packetCount or ""), string.sub(data, (i - 1) * maxDataLength + 1, i * maxDataLength))
      end
      print("  Packet to " .. string.sub(tostring(address), 1, 4) .. " port " .. port .. ": " .. packetNumber .. (i == 1 and "/" .. packetCount or "") .. " " .. string.sub(data, (i - 1) * maxDataLength + 1, i * maxDataLength))
      packetNumber = packetNumber + 1
    end
  end
end

-- getMessage(modem: table[, timeout: number]): string, number, string
-- 
-- Get a message sent over the network. The timeout is the max number of seconds
-- to block while waiting for packet. If a message was split into multiple
-- packets, combines them before returning the result. Returns nil if timeout
-- reached, or address, port, and data if received.
local function getMessage(modem, timeout)
  checkArg(1, modem, "table")
  local eventType, _, senderAddress, senderPort, _, sequence, data = event.pull(timeout, "modem_message")
  if not eventType then
    return nil
  end
  senderPort = math.floor(senderPort)
  print("Packet from " .. string.sub(senderAddress, 1, 4) .. " port " .. senderPort .. ": " .. sequence .. " " .. data)
  
  if string.match(sequence, "/(%d+)") == "1" then
    -- Got a packet without any pending ones. Do a quick clean of dead packets and return this one.
    print("found packet with no pending")
    for k, v in pairs(packetBuffer) do
      if computer.uptime() > v[1] + maxPacketLife then
        print("dropping packet: " .. k)
        packetBuffer[k] = nil
      end
    end
    return senderAddress, senderPort, data
  end
  while true do
    packetBuffer[senderAddress .. ":" .. senderPort .. "," .. sequence] = {computer.uptime(), data}
    
    -- Iterate through packet buffer to check if we have enough to return some data.
    for k, v in pairs(packetBuffer) do
      local kAddress, kPort, kPacketNum = string.match(k, "([%w-]+):(%d+),(%d+)")
      kPacketNum = tonumber(kPacketNum)
      local kPacketCount = tonumber(string.match(k, "/(%d+)"))
      print("in loop: ", k, kAddress, kPort, kPacketNum, kPacketCount)
      
      if computer.uptime() > v[1] + maxPacketLife then
        print("dropping packet: " .. k)
        packetBuffer[k] = nil
      elseif kPacketCount and (kPacketCount == 1 or packetBuffer[kAddress .. ":" .. kPort .. "," .. (kPacketNum + kPacketCount - 1)]) then
        -- Found a start packet and the corresponding end packet was received, try to form the full data.
        print("found begin and end packets, checking...")
        data = ""
        for i = 1, kPacketCount do
          if not packetBuffer[kAddress .. ":" .. kPort .. "," .. (kPacketNum + i - 1) .. (i == 1 and "/" .. kPacketCount or "")] then
            data = nil
            break
          end
        end
        
        -- Confirm we really have all the packets before forming the data and deleting them from the buffer (a packet could have been lost or is still in transit).
        if data then
          for i = 1, kPacketCount do
            local k2 = kAddress .. ":" .. kPort .. "," .. (kPacketNum + i - 1) .. (i == 1 and "/" .. kPacketCount or "")
            data = data .. packetBuffer[k2][2]
            packetBuffer[k2] = nil
          end
          return kAddress, tonumber(kPort), data
        end
        print("nope, need more")
      end
    end
    
    -- Don't have enough packets yet, wait for more.
    eventType, _, senderAddress, senderPort, _, sequence, data = event.pull(timeout, "modem_message")
    if not eventType then
      return nil
    end
    senderPort = math.floor(senderPort)
    print("Packet from " .. string.sub(senderAddress, 1, 4) .. " port " .. senderPort .. ": " .. sequence .. " " .. data)
  end
end

local function main()
  modem.open(COMMS_PORT)
  
  --"b421d616-21a6-4b13-b843-5c121476abcb"
  sendMessage(modem, nil, COMMS_PORT, "hello")
  --sendMessage(modem, nil, COMMS_PORT, "1234567890abcdefgh")
  local data = ""
  for i = 1, 5000 do
    data = data .. i
  end
  sendMessage(modem, nil, COMMS_PORT, data)
  os.sleep(3)
  sendMessage(modem, nil, COMMS_PORT, "1244567890abcdefgh")
  os.sleep(3)
  sendMessage(modem, nil, COMMS_PORT, "beans")--"hello again, I've returned")
  
  os.exit()
  
  for i = 1, 100 do
    local _, _, senderAddress, port, _, packetType, data = event.pull("modem_message", nil, nil, COMMS_PORT)
    assert(packetType == "my_numbers" and i == data)
    print(i)
  end
  
  print("done!")
  os.exit()
  
  
  
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  local storageCtrlAddress, storageItems
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    modem.open(COMMS_PORT)
    
    local attemptNumber = 1
    while not storageCtrlAddress do
      term.clearLine()
      io.write("Trying to contact storage controller on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
      
      modem.broadcast(COMMS_PORT, "stor_discover")
      local _, _, senderAddress, port, _, packetType, data1 = event.pull(2, "modem_message", nil, nil, COMMS_PORT)
      
      if packetType == "stor_item_list" then
        storageItems = serialization.unserialize(data1)
        storageCtrlAddress = senderAddress
      end
      
      attemptNumber = attemptNumber + 1
    end
    io.write("\nSuccess.\n")
    
    print(" - items - ")
    tdebug.printTable(storageItems)
  end)
  
  thread.waitForAny({interruptThread, setupThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  end
  
  -- Continuously get user input and send commands to storage controller.
  local commandThread = thread.create(function()
    while true do
      io.write("> ")
      local input = io.read()
      if type(input) ~= "string" then
        input = "exit"
      end
      input = text.tokenize(input)
      if input[1] == "l" then    -- List.
        io.write("Storage contents:\n")
        for itemName, itemDetails in pairs(storageItems) do
          if itemName ~= "firstEmptyIndex" and itemName ~= "firstEmptySlot" then
            io.write("  " .. itemDetails.total .. "  " .. itemName .. "\n")
          end
        end
      elseif input[1] == "r" then    -- Request.
        --print("result = ", extractStorage(transposers, routing, storageItems, "output", 1, nil, input[2], tonumber(input[3])))
        sendPacket(storageCtrlAddress, COMMS_PORT, "stor_extract", "beef")
      elseif input[1] == "a" then    -- Add.
        --print("result = ", insertStorage(transposers, routing, storageItems, "input", 1))
        sendPacket(storageCtrlAddress, COMMS_PORT, "stor_insert")
      elseif input[1] == "d" then
        print(" - items - ")
        tdebug.printTable(storageItems)
      elseif input[1] == "exit" then
        break
      else
        print("Enter \"l\" to list, \"r <item> <count>\" to request, \"a\" to add, or \"exit\" to quit.")
      end
    end
  end)
  
  thread.waitForAny({interruptThread, commandThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  end
end

main()
