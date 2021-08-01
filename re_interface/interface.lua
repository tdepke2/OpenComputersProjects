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
local wnet = require("wnet")

local function main()
  modem.open(COMMS_PORT)
  
  --wnet.debug = true
  wnet.maxDataLength = 512
  
  --"b421d616-21a6-4b13-b843-5c121476abcb"
  wnet.send(modem, nil, COMMS_PORT, "hello")
  --sendMessage(modem, nil, COMMS_PORT, "1234567890abcdefgh")
  local data = ""
  for i = 1, 5000 do
    data = data .. i
  end
  wnet.send(modem, nil, COMMS_PORT, data)
  os.sleep(3)
  wnet.send(modem, nil, COMMS_PORT, "1244567890abcdefgh")
  os.sleep(3)
  wnet.send(modem, nil, COMMS_PORT, "beans")--"hello again, I've returned")
  
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
