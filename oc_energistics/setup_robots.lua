--[[
Setup script for discovering robots and their connections to the drone
inventories.

This script generates a configuration file that is required for the crafting
server application to run. It should be run once to discover the robots in the
system and find out which drone inventories they can reach (or run again when
new robots are added or moved around).

The setup works by sending an item to each drone inventory in the system
sequentially. Each time, the robots scan inventories adjacent to them (all 6
sides) and report if they can see the target item.
--]]

local component = require("component")
local computer = require("computer")
local modem = component.modem
local serialization = require("serialization")
local term = require("term")

local dlog = require("dlog")
local packer = require("packer")
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

-- Apply a diff to droneItems to keep the item list synced up. The
-- droneItemsDiff is obtained as a response from the storage server.
local function applyDroneItemsDiff(droneItems, droneItemsDiff)
  for invIndex, diff in pairs(droneItemsDiff) do
    droneItems[invIndex] = diff
  end
end

-- Handle the any:drone_item_diff packet type.
local function handleDroneItemDiff(droneItems, data)
  local operation = string.match(data, "[^,]*")
  local result = string.match(data, "[^,]*", #operation + 2)
  local droneItemsDiff = serialization.unserialize(string.sub(data, #operation + #result + 3))
  applyDroneItemsDiff(droneItems, droneItemsDiff)
  
  return operation, result, droneItemsDiff
end

local function main()
  modem.open(COMMS_PORT)
  
  io.write("Running robots setup.\n")
  
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
  local storageServerAddress, storageItems
  local attemptNumber = 1
  local lastAttemptTime = 0
  while not storageServerAddress do
    if computer.uptime() >= lastAttemptTime + 2 then
      lastAttemptTime = computer.uptime()
      term.clearLine()
      io.write("Trying to contact storage server on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
      wnet.send(modem, nil, COMMS_PORT, packer.pack.stor_discover())
      attemptNumber = attemptNumber + 1
    end
    local address, port, data = wnet.receive(0.1)
    if port == COMMS_PORT then
      local dataHeader = string.match(data, "[^,]*")
      data = string.sub(data, #dataHeader + 2)
      if dataHeader == "any:item_list" then
        storageItems = serialization.unserialize(data)
        storageServerAddress = address
      end
    end
  end
  io.write("\nSuccess.\n")
  
  if not setupConfig then
    setupConfig = {}
    io.write("\nPlease select the item type to use for robot connection scanning. Use the format\n")
    io.write("\"<mod name>:<item name>/<damage>\" for each (for example, this would be\n")
    io.write("minecraft:stone/0 for stone and minecraft:wool/13 for green wool). Exactly one of\n")
    io.write("this item must exist in the storage network.\n\n")
    
    io.write("Item: ")
    setupConfig.searchItem = stringToItemName(io.read())
  else
    io.write("\nUsing this item type for robot connection scanning:\n")
    io.write(setupConfig.searchItem .. "\n")
  end
  
  if not storageItems[setupConfig.searchItem] or storageItems[setupConfig.searchItem].total ~= 1 then
    io.stderr:write("\nError: Found " .. (storageItems[setupConfig.searchItem] and storageItems[setupConfig.searchItem].total or 0) .. " of ")
    io.stderr:write("\"" .. setupConfig.searchItem .. "\" in the storage network, but there must be exactly 1 to run setup.\n")
    io.stderr:write("Add/remove the items to correct the total or choose a different item type.\n")
    os.exit(1)
  end
  
  -- Reset any running robots.
  wnet.send(modem, nil, COMMS_PORT, "robot:halt,")
  os.sleep(1)
  
  -- Send robot code to active robots.
  local robotUpFile = io.open("robot_up.lua")
  io.write("\nUploading \"robot_up.lua\"...\n")
  local dlogWnetState = dlog.subsystems.wnet
  dlog.setSubsystem("wnet", false)
  wnet.send(modem, nil, COMMS_PORT, "robot:upload," .. robotUpFile:read("a"))
  dlog.setSubsystem("wnet", dlogWnetState)
  robotUpFile:close()
  
  -- Wait for robots to receive the software update and keep track of their addresses.
  local robotAddresses = {}
  local numRobotAddresses = 0
  while true do
    local address, port, _, data = wnet.waitReceive(nil, COMMS_PORT, "any:robot_start,", 2)
    if address then
      numRobotAddresses = numRobotAddresses + (robotAddresses[address] and 0 or 1)
      robotAddresses[address] = true
    else
      break
    end
  end
  
  io.write("Found " .. numRobotAddresses .. " active robots.\n")
  os.sleep(1)
  
  -- Get the droneItems table to get a count of the number of drone inventories.
  local droneItems
  wnet.send(modem, storageServerAddress, COMMS_PORT, packer.pack.stor_get_drone_item_list())
  local address, port, _, data = wnet.waitReceive(nil, COMMS_PORT, "any:drone_item_list,", 5)
  assert(address, "Lost connection with storage server (request timed out).")
  droneItems = serialization.unserialize(data)
  
  -- Create a table to track the connections of robots for each drone inventory, and make a copy of robotAddresses to check off the list.
  local robotConnections = {}
  for i = 1, #droneItems do
    robotConnections[i] = {}
  end
  local remainingRobotAddresses = {}
  for k, v in pairs(robotAddresses) do
    remainingRobotAddresses[k] = v
  end
  
  -- Request item to transfer to each drone inventory, and have the robots scan for it each time.
  local extractList = {}
  extractList[1] = {setupConfig.searchItem, 1}
  extractList.supplyIndices = {}
  for i = 1, #droneItems do
    io.write("Checking robot access for drone inventory " .. i .. ".\n")
    
    wnet.send(modem, storageServerAddress, COMMS_PORT, packer.pack.stor_drone_extract(i, nil, extractList))
    local address, port, _, data = wnet.waitReceive(nil, COMMS_PORT, "any:drone_item_diff,", 5)
    assert(address, "Lost connection with storage server (request timed out).")
    local _, result = handleDroneItemDiff(droneItems, data)
    assert(result ~= "missing", "Item \"" .. setupConfig.searchItem .. "\" was not found in storage.")
    assert(result == "ok", "Extract to drone inventory failed.")
    assert(droneItems[i][1].fullName == setupConfig.searchItem and not droneItems[i][2], "Unexpected contents in inventory.")
    
    -- Item moved, the current inventory becomes the supply one (and dirty flag is false as we don't change the contents externally).
    extractList.supplyIndices[i - 1] = nil
    extractList.supplyIndices[i] = false
    
    -- Request robots to scan for the item in adjacent inventories, and wait for response from all.
    wnet.send(modem, nil, COMMS_PORT, "robot:scan_adjacent," .. setupConfig.searchItem .. ",1")
    for j = 1, numRobotAddresses do
      local address, port, _, data = wnet.waitReceive(nil, COMMS_PORT, "any:scan_adjacent_result,", 5)
      assert(address, "Communication with robot failed, got responses from " .. j - 1 .. " of " .. numRobotAddresses .. " bots.")
      robotConnections[i][address] = tonumber(data)
      if tonumber(data) then
        remainingRobotAddresses[address] = nil
      end
    end
  end
  
  -- Add residual item back into storage system.
  wnet.send(modem, storageServerAddress, COMMS_PORT, packer.pack.stor_drone_insert(#droneItems, nil))
  local address, port, _, data = wnet.waitReceive(nil, COMMS_PORT, "any:drone_item_diff,", 5)
  assert(address, "Lost connection with storage server (request timed out).")
  local _, result = handleDroneItemDiff(droneItems, data)
  assert(result == "ok", "Insert from drone inventory to storage failed.")
  
  if next(remainingRobotAddresses) then
    local numRemaining = 0
    for address, _ in pairs(remainingRobotAddresses) do
      numRemaining = numRemaining + 1
    end
    io.stderr:write("\nWarning: Detected " .. numRemaining .. " robot(s) that do not have access to drone inventories.\n")
  end
  
  dlog.out("main", "Done, robotConnections:", robotConnections)
  
  local outputFile = io.open(OUTPUT_FILENAME, "w")
  if outputFile then
    outputFile:write("# This file was generated by \"setup_robots.lua\".\n")
    outputFile:write("# File contains the robotConnections table.\n\n")
    outputFile:write(serialization.serialize(robotConnections) .. "\n")
    
    outputFile:close()
  end
  
  io.write("\nSetup completed, saved configuration file to \"" .. OUTPUT_FILENAME .. "\".\n")
end

main()
