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
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  local storageCtrlAddress, storageItems
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    modem.open(COMMS_PORT)
    wnet.debug = true
    
    local attemptNumber = 1
    while not storageCtrlAddress do
      term.clearLine()
      io.write("Trying to contact storage controller on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
      
      wnet.send(modem, nil, COMMS_PORT, "stor_discover,")
      local address, port, data = wnet.receive(2)
      if address and port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        if dataType == "stor_item_list" then
          storageItems = serialization.unserialize(data)
          storageCtrlAddress = address
        end
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
  
  local exitSuccess = false
  
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
        input[2] = input[2] or ""
        input[3] = input[3] or ""
        wnet.send(modem, storageCtrlAddress, COMMS_PORT, "stor_extract," .. input[2] .. "," .. input[3])
      elseif input[1] == "a" then    -- Add.
        --print("result = ", insertStorage(transposers, routing, storageItems, "input", 1))
        wnet.send(modem, storageCtrlAddress, COMMS_PORT, "stor_insert,")
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
  
  interruptThread:kill()
  commandThread:kill()
  
  if not exitSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
  end
end

main()
