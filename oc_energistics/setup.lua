
-- TODO: Maybe integrate this into the client script and have it run if it doesn't find the config file??

local component = require("component")
local event = require("event")
local sides = require("sides")
local text = require("text")

local dstructs = require("dstructs")

local setupConfig
-- Comment out below for interactive setup.
--
setupConfig = {}
setupConfig["minecraft:cobblestone/0"] = "storage"
setupConfig["minecraft:iron_ingot/0"] = "input"
setupConfig["minecraft:gold_ingot/0"] = "output"
setupConfig["minecraft:redstone/0"] = "drone"
--

local OUTPUT_FILENAME = "routing.config"

-- Verify string has item name format "<mod name>:<item name>/<damage>". Allows
-- skipping the damage value (which then defaults to zero).
local function stringToItemName(s)
  s = string.lower(s)
  if not string.find(s, "/") then
    s = s .. "/0"
  end
  assert(string.find(s, "[%w_]+:[%w_]+/%d+"), "Item name does not have valid format.")
  return s
end

-- Search an inventory for item in specified slot. Returns nil if not inventory,
-- item name and count if found, or empty string if empty.
local function findInventoryItemName(transposer, side, slotNum)
  if not transposer.getInventorySize(side) then
    return nil
  end
  local item = transposer.getStackInSlot(side, slotNum)
  if item then
    return item.name .. "/" .. math.floor(item.damage), math.floor(item.size)
  end
  return ""
end

-- Return the side opposite of the given one.
local function getOppositeSide(side)
  if side % 2 == 0 then
    return side + 1
  else
    return side - 1
  end
end

-- Get transposer index and side number formatted as a string.
local function formatConnection(transIdx, side)
  return tostring(transIdx) .. ":" .. tostring(side) .. ","
end

-- Get transposer index and side number from a string (starting at init).
local function parseConnections(connections, init)
  local transIdx, side = string.match(connections, "(%d*):(%d*),", init)
  return tonumber(transIdx), tonumber(side)
end

-- Creates a new table for routing information. This is very similar to the
-- inventories table. The routing table contains unique inventories with
-- potentially multiple connections to them, whereas the inventories table
-- contains unique transposers (can have duplicate inventories). This new table
-- is more ideal for running graph search algorithms such as BFS.
local function buildRoutingTable(transposers, inventories)
  local routing = {}
  routing.storage = {}
  routing.input = {}
  routing.output = {}
  routing.transfer = {}
  routing.drone = {}
  
  -- Add all unvisited connections. Usually these each correspond to a unique inventory (except for transfer ones).
  local unvisited = {}
  for _, inventory in pairs(inventories) do
    for _, connection in ipairs(inventory) do
      unvisited[connection] = true
    end
  end
  
  -- Create a stack for depth-first traversal, this holds connections that need to be checked.
  local searchStack = dstructs.Deque:new()
  local startTransIdx, startSide = parseConnections(inventories.input[1])
  local inputItem = transposers[startTransIdx].getStackInSlot(startSide, 1)
  local inputItemName = inputItem.name .. "/" .. math.floor(inputItem.damage)
  
  -- Add connections to stack that are adjacent to transposer. The beginSide is added first (so it pops off last).
  local function addAdjacentConnections(transIdx, beginSide)
    searchStack:push_front(formatConnection(transIdx, beginSide))
    for side = 0, 5 do
      if transposers[transIdx].getInventorySize(side) and side ~= beginSide then
        searchStack:push_front(formatConnection(transIdx, side))
      end
    end
  end
  addAdjacentConnections(startTransIdx, startSide)
  
  -- Find all connections (from unvisited) that can see the target item.
  local function findItemConnections()
    local itemConnections = {}
    for connection, _ in pairs(unvisited) do
      local transIdx, side = parseConnections(connection)
      local item = transposers[transIdx].getStackInSlot(side, 1)
      if item and item.name .. "/" .. math.floor(item.damage) == inputItemName then
        itemConnections[#itemConnections + 1] = connection
      end
    end
    return itemConnections
  end
  local lastItemConnections = findItemConnections()
  
  -- Get the type of inventory the targetConnection belongs to, or nil if not found.
  local function findInventoryType(targetConnection)
    for invType, inventory in pairs(inventories) do
      for _, connection in ipairs(inventory) do
        if targetConnection == connection then
          return invType
        end
      end
    end
    return nil
  end
  
  -- Start DFS to send the item to each inventory in the network.
  while not searchStack:empty() do
    local connection = searchStack:front()
    local transIdx, side = parseConnections(searchStack:front())
    io.write("Checking connection: " .. searchStack:front() .. "\n")
    searchStack:pop_front()
    
    -- First, move the item into the inventory with the current connection.
    local currentSide
    for _, connection2 in ipairs(lastItemConnections) do
      local transIdx2, side2 = parseConnections(connection2)
      if transIdx2 == transIdx then
        currentSide = side2
        break
      end
    end
    assert(currentSide)
    local numTransferred = transposers[transIdx].transferItem(currentSide, side, 1, 1, 1)
    if numTransferred == 0 then
      local status, result = pcall(transposers[transIdx].transferItem, side, side, math.huge, 1, 2)
      assert(status and result > 0, "Failed to move item stack from slot 1 to 2.")
      assert(transposers[transIdx].transferItem(currentSide, side, 1, 1, 1) > 0, "Failed to transfer item between inventories.")
    end
    
    -- Figure out the type of the inventory we landed in.
    local invType = findInventoryType(connection)
    
    if unvisited[connection] then
      -- If this is a newly explored connection, check if we can branch further.
      lastItemConnections = findItemConnections()
      --print("lastItemConnections = ")
      --tdebug.printTable(lastItemConnections)
      
      local routingEntry = routing[invType]
      local routingEntryIndex = #routingEntry + 1
      
      for _, connection2 in ipairs(lastItemConnections) do
        -- Connections have now been visited, remove them from the set.
        unvisited[connection2] = nil
        
        routingEntry[routingEntryIndex] = (routingEntry[routingEntryIndex] or "") .. connection2
        
        -- If this inventory can be used for transfers, and the item is visible
        -- by other transposers, add their connections to search stack.
        if invType == "transfer" then
          local transIdx2, side2 = parseConnections(connection2)
          if transIdx2 ~= transIdx then
            io.write("  Found a transfer point, branching to " .. connection2 .. "\n")
            addAdjacentConnections(transIdx2, side2)
            --print("added adjacent connections for " .. connection2)
          end
        end
      end
    else
      -- We have been to this connection before (so the item is moving back).
      -- The lastItemConnections table is expected to be set for the next
      -- iteration though, so use the routing table to figure it out.
      io.write("  Closing branch.\n")
      local connectionsPacked
      for _, connections in ipairs(routing[invType]) do
        if string.find(connections, connection, 1, true) then
          connectionsPacked = connections
          break
        end
      end
      --print("connectionsPacked:", connectionsPacked)
      
      -- Unpack connectionsPacked and store them in lastItemConnections.
      lastItemConnections = {}
      for connection2 in string.gmatch(connectionsPacked, "%d*:%d*,") do
        lastItemConnections[#lastItemConnections + 1] = connection2
      end
    end
  end
  
  -- Confirm no more unvisited connections.
  assert(next(unvisited) == nil, "Failed to traverse entire storage system, check to make sure all transposers have a routable connection to each other.")
  
  return routing
end

-- Main function, does setup stuff.
local function main()
  io.write("Running setup for the storage network, remember not to change the network during\n")
  io.write("this process or afterwards! Accidentally breaking a transposer and replacing it\n")
  io.write("can also cause problems (the transposer UUID will change). If this happens or if\n")
  io.write("the storage is in dire need of an upgrade, run the setup again or make changes\n")
  io.write("to the configuration file manually.\n")
  
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
  
  if not setupConfig then
    setupConfig = {}
    io.write("\nPlease select the four item types to use for inventory identification. Use the\n")
    io.write("format \"<mod name>:<item name>/<damage>\" for each (for example, this would be\n")
    io.write("minecraft:stone/0 for stone and minecraft:wool/13 for green wool).\n\n")
    
    -- Confirm item chosen has valid form and is unique, then add it to setupConfig.
    local function validateItemAdd(s, itemType)
      s = stringToItemName(s)
      assert(not setupConfig[s], "Item type must be unique.")
      setupConfig[s] = itemType
    end
    io.write("Storage (bulk storage for items): ")
    validateItemAdd(io.read(), "storage")
    io.write("Input (dump items into the network): ")
    validateItemAdd(io.read(), "input")
    io.write("Output (request items from the network): ")
    validateItemAdd(io.read(), "output")
    io.write("Drone (access point for drones): ")
    validateItemAdd(io.read(), "drone")
  else
    io.write("\nUsing these item types for inventory identification:\n")
    for k, v in pairs(setupConfig) do
      io.write(k .. " -> " .. v .. "\n")
    end
  end
  
  io.write("\nNext, add at least one of those items to the FIRST slot of each inventory in the\n")
  io.write("network corresponding to its type. The number of items in the slot will effect\n")
  io.write("the priority of the inventory, with more items meaning higher priority. The\n")
  io.write("transfer inventories for routing items should have an empty first slot.\n")
  io.write("Ready to continue? [Y/n] ")
  input = io.read()
  if string.lower(input) ~= "y" and string.lower(input) ~= "yes" then
    io.write("Setup canceled.\n")
    return
  end
  
  io.write("\nIdentifying inventories...\n")
  
  -- Assign numeric IDs to each transposer.
  local transposers = {}
  local transposerAddresses = {}
  for address, name in pairs(component.list("transposer", true)) do
    transposers[#transposers + 1] = component.proxy(address)
    transposerAddresses[#transposerAddresses + 1] = address
  end
  
  -- Identify inventories by checking if the item in the first slot matches one
  -- from the setupConfig list. If it does, we add that "connection" to the
  -- table corresponding to its type. Note that a connection is defined as a
  -- transposer/side number combo (the pattern "<transposer index>:<side number>,")
  -- so the same inventory can show up more than once in this list if multiple
  -- transposers can reach it.
  local inventories = {}
  inventories.storage = {}
  inventories.input = {}
  inventories.output = {}
  inventories.transfer = {}
  inventories.drone = {}
  
  -- Also keep track of priority (item count in first slot) for later. We match
  -- each connection to the corresponding priority for storage and drone
  -- inventories.
  local inventoryPriority = {}
  
  for i, transposer in ipairs(transposers) do
    for side = 0, 5 do
      local itemName, itemCount = findInventoryItemName(transposer, side, 1)
      if itemName then
        local invType = setupConfig[itemName]
        if itemName == "" then
          invType = "transfer"
          inventories.transfer[#inventories.transfer + 1] = formatConnection(i, side)
        elseif not invType then
          assert(false, "Found unrecognized item \"" .. itemName .. "\" in inventory.")
        elseif invType == "storage" then
          inventories.storage[#inventories.storage + 1] = formatConnection(i, side)
        elseif invType == "input" then
          assert(#inventories.input == 0, "Found a second input inventory (there must be only one connected to a single transposer in network).")
          inventories.input[#inventories.input + 1] = formatConnection(i, side)
        elseif invType == "output" then
          assert(#inventories.output == 0, "Found a second output inventory (there must be only one connected to a single transposer in network).")
          inventories.output[#inventories.output + 1] = formatConnection(i, side)
        elseif invType == "drone" then
          inventories.drone[#inventories.drone + 1] = formatConnection(i, side)
        end
        
        io.write("Found a " .. text.padLeft(tostring(math.floor(transposer.getInventorySize(side))), 5) .. " slot " .. text.padLeft(invType, 8) .. " inventory ")
        if invType == "storage" or invType == "drone" then
          io.write("with priority " .. text.padLeft(tostring(itemCount), 2) .. " ")
          inventoryPriority[formatConnection(i, side)] = itemCount
        end
        io.write("(" .. transposer.getInventoryName(side) .. ").\n")
      end
    end
  end
  
  assert(#inventories.storage > 0, "No storage inventories found.")
  assert(#inventories.input > 0, "No input inventory found.")
  assert(#inventories.output > 0, "No output inventory found.")
  
  io.write("\nNow remove those first slot items EXCEPT for the one in the input inventory.\n")
  io.write("You can skip this step in most cases, but there will be problems if the items\n")
  io.write("fail to be moved to the second slot (single-slot inventories better be empty).\n")
  io.write("Ready to continue? [Y/n] ")
  input = io.read()
  if string.lower(input) ~= "y" and string.lower(input) ~= "yes" then
    io.write("Setup canceled.\n")
    return
  end
  
  io.write("\nBuilding routing table, this may take a while...\n")
  
  local routing = buildRoutingTable(transposers, inventories)
  
  --tdebug.printTable(routing)
  
  -- Use insertion sort to reorder a category in the routing table to match the priorities in inventoryPriority.
  local function sortPriority(routingType)
    local i = 2
    while i <= #routingType do
      local connections = routingType[i]
      local priority = inventoryPriority[string.match(connections, "%d*:%d*,")]
      local j = i - 1
      while j > 0 and inventoryPriority[string.match(routingType[j], "%d*:%d*,")] < priority do
        routingType[j + 1] = routingType[j]
        j = j - 1
      end
      routingType[j + 1] = connections
      i = i + 1
    end
  end
  
  sortPriority(routing.storage)
  sortPriority(routing.drone)
  
  local outputFile = io.open(OUTPUT_FILENAME, "w")
  if outputFile then
    outputFile:write("# This file was generated by \"setup.lua\".\n")
    outputFile:write("# File contains the routing information for the storage network. This includes\n")
    outputFile:write("# priorities of storage inventories. To change the priorites, look for the\n")
    outputFile:write("# section labeled \"storage:\" and rearrange the lines to put higher-priority\n")
    outputFile:write("# inventories at the top of the section (in the OpenOS editor, use Ctrl+K to cut\n")
    outputFile:write("# and Ctrl+U to paste).\n\n")
    outputFile:write("# Each entry for an inventory has a name (just to help identify it, it can be\n")
    outputFile:write("# changed to whatever), and a list of connections. Each connection represents a\n")
    outputFile:write("# transposer index from the \"transposers:\" section, and a side number (shown\n")
    outputFile:write("# below for reference). The side refers to the side the transposer touches the\n")
    outputFile:write("# inventory, not the side of the inventory itself. A transposer can be\n")
    outputFile:write("# identified in the world by using the Analyzer on it and matching the UUID to\n")
    outputFile:write("# the one in the transposers section.\n\n")
    outputFile:write("# Side numbering: 0 = -y, 1 = +y, 2 = -z, 3 = +z, 4 = -x, 5 = +x\n\n")
    
    outputFile:write("transposers:\n")
    for i, address in ipairs(transposerAddresses) do
      outputFile:write(tostring(i) .. " = " .. address .. "\n")
    end
    
    -- Add line to file with the slot count, and connections the inventory has.
    local function writeConnectionsLine(connections)
      local transIdx, side = parseConnections(connections)
      local invName = transposers[transIdx].getInventoryName(side)
      
      outputFile:write("\"" .. invName .. "\"; connections = " .. connections .. "\n")
    end
    
    outputFile:write("\nstorage:\n")
    for _, connections in ipairs(routing.storage) do
      writeConnectionsLine(connections)
    end
    
    outputFile:write("\ninput:\n")
    for _, connections in ipairs(routing.input) do
      writeConnectionsLine(connections)
    end
    
    outputFile:write("\noutput:\n")
    for _, connections in ipairs(routing.output) do
      writeConnectionsLine(connections)
    end
    
    outputFile:write("\ntransfer:\n")
    for _, connections in ipairs(routing.transfer) do
      writeConnectionsLine(connections)
    end
    
    outputFile:write("\ndrone:\n")
    for _, connections in ipairs(routing.drone) do
      writeConnectionsLine(connections)
    end
    
    outputFile:close()
  end
  
  io.write("\nSetup completed, saved configuration file to \"" .. OUTPUT_FILENAME .. "\".\n")
end

main()
