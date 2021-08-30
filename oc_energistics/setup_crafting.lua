local component = require("component")
local computer = require("computer")
local modem = component.modem
local tdebug = require("tdebug")
local term = require("term")
local wnet = require("wnet")

local COMMS_PORT = 0xE298

local setupConfig
-- Comment out below for interactive setup.
--
setupConfig = {}
setupConfig.searchItem = "minecraft:redstone/0"
--

local OUTPUT_FILENAME = "robots.config"

-- Verify string has item name format "<mod name>:<item name>/<damage>[n]".
-- Allows skipping the damage value (which then defaults to zero).
local function stringToItemName(s)
  s = string.lower(s)
  if not string.find(s, "/") then
    s = s .. "/0"
  end
  assert(string.match(s, "[%w_]+:[%w_]+/%d+n?") == s, "Item name does not have valid format.")
  return s
end

local function main()
  modem.open(COMMS_PORT)
  wnet.debug = true
  
  io.write("Running crafting setup.\n")
  
  local input
  local outputFile = io.open(OUTPUT_FILENAME, "r")
  if outputFile then
    outputFile:close()
    io.write("\nConfig file \"" .. OUTPUT_FILENAME .. "\" already exists, are you sure you want to overwrite it? [Y/n] ")
    input = io.read()
    if string.lower(input) ~= "y" and string.lower(input) ~= "yes" then
      io.write("Setup canceled.\n")
      return
    end
  end
  
  -- Contact the storage server.
  local storageServerAddress
  local attemptNumber = 1
  local lastAttemptTime = 0
  while not storageServerAddress do
    if computer.uptime() >= lastAttemptTime + 2 then
      lastAttemptTime = computer.uptime()
      term.clearLine()
      io.write("Trying to contact storage server on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
      wnet.send(modem, nil, COMMS_PORT, "stor:discover,")
      attemptNumber = attemptNumber + 1
    end
    local address, port, data = wnet.receive(0.1)
    if port == COMMS_PORT then
      local dataHeader = string.match(data, "[^,]*")
      data = string.sub(data, #dataHeader + 2)
      if dataHeader == "any:item_list" then
        storageServerAddress = address
      end
    end
  end
  io.write("\nSuccess.\n")
  
  if not setupConfig then
    setupConfig = {}
    io.write("\nPlease select the item type to use for robot connection scanning. Use the format\n")
    io.write("\"<mod name>:<item name>/<damage>\" for each (for example, this would be\n")
    io.write("minecraft:stone/0 for stone and minecraft:wool/13 for green wool). At least one\n")
    io.write("of this item must exist in the storage network.\n\n")
    
    io.write("Item: ")
    setupConfig.searchItem = stringToItemName(io.read())
  else
    io.write("\nUsing this item type for robot connection scanning:\n")
    io.write(setupConfig.searchItem .. "\n")
  end
  
  -- Reset any running robots.
  wnet.send(modem, nil, COMMS_PORT, "robot:halt,")
  os.sleep(1)
  
  -- Send robot code to active robots.
  local robotUpFile = io.open("robot_up.lua")
  io.write("Uploading \"robot_up.lua\"...\n")
  wnet.debug = false
  wnet.send(modem, nil, COMMS_PORT, "robot:upload," .. robotUpFile:read("a"))
  wnet.debug = true
  robotUpFile:close()
  
  -- Wait for robots to receive the software update and keep track of their addresses.
  local robotAddresses = {}
  local numRobotAddresses = 0
  local lastResponseTime = computer.uptime()
  while lastResponseTime + 2 > computer.uptime() do
    local address, port, data = wnet.receive(1)
    if port == COMMS_PORT then
      local dataHeader = string.match(data, "[^,]*")
      
      if dataHeader == "any:robot_start" then
        numRobotAddresses = numRobotAddresses + (robotAddresses[address] and 0 or 1)
        robotAddresses[address] = true
      end
    end
  end
  io.write("Found " .. numRobotAddresses .. " active robots.\n")
  os.sleep(1)
  
  
  
  --wnet.send(modem, nil, COMMS_PORT, "robot:scan_adjacent,minecraft:redstone/0,1")
end

main()
