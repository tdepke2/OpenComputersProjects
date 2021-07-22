
-- TODO: Maybe integrate this into the client script and have it run if it doesn't find the data file??

local component = require("component")
local event = require("event")
local sides = require("sides")
local text = require("text")

local tdebug = require("tdebug")

local OUTPUT_FILENAME = "routing_data"

-- Deque class (like a deck of cards). Works like a queue or a stack.
Deque = {}
function Deque:new(obj)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  self.backIndex = 1
  self.length = 0
  return obj
end

function Deque:empty()
  return self.length == 0
end

function Deque:size()
  return self.length
end

function Deque:front()
  return self[self.backIndex + self.length - 1]
end

function Deque:back()
  return self[self.backIndex]
end

function Deque:push_front(val)
  self[self.backIndex + self.length] = val
  self.length = self.length + 1
end

function Deque:push_back(val)
  self.backIndex = self.backIndex - 1
  self[self.backIndex] = val
  self.length = self.length + 1
end

function Deque:pop_front()
  self[self.backIndex + self.length - 1] = nil
  self.length = self.length - 1
end

function Deque:pop_back()
  self[self.backIndex] = nil
  self.backIndex = self.backIndex + 1
  self.length = self.length - 1
end

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
-- item name if found, or empty string if empty.
local function findInventoryItemName(transposer, side, slotNum)
  if not transposer.getInventorySize(side) then
    return nil
  end
  local item = transposer.getStackInSlot(side, slotNum)
  if item then
    return item.name .. "/" .. math.floor(item.damage)
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

local function buildRoutingTable(transposers, inventories)
  local routing = {}
  routing.storage = {}
  routing.input = {}
  routing.output = {}
  routing.transfer = {}
  routing.drone = {}
  
  -- Add all unvisited connections. Usually these each correspond to a unique inventory (except for transfer ones).
  local unvisited = {}
  for _, connection in ipairs(inventories.storage) do
    unvisited[connection] = true
  end
  unvisited[inventories.input] = true    -- FIXME not sure about this one ############################################
  unvisited[inventories.output] = true
  for _, connection in ipairs(inventories.transfer) do
    unvisited[connection] = true
  end
  for _, connection in ipairs(inventories.drone) do
    unvisited[connection] = true
  end
  
  -- Create a stack for depth-first traversal, and add the inventories adjacent to the first transposer.
  local searchStack = Deque:new()
  local startTransIdx, startSide = parseConnections(inventories.input)
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
  
  -- Get the type of inventory the connection belongs to, or nil if not found.
  local function findInventoryType(connection)
    for _, c in ipairs(inventories.storage) do
      if connection == c then
        return "storage"
      end
    end
    if connection == inventories.input then
      return "input"
    end
    if connection == inventories.output then
      return "output"
    end
    for _, c in ipairs(inventories.transfer) do
      if connection == c then
        return "transfer"
      end
    end
    for _, c in ipairs(inventories.drone) do
      if connection == c then
        return "drone"
      end
    end
    return nil
  end
  
  while not searchStack:empty() do
    local connection = searchStack:front()
    local transIdx, side = parseConnections(searchStack:front())
    print("searchStack front:", searchStack:front())
    searchStack:pop_front()
    
    local currentSide
    for _, connection2 in ipairs(lastItemConnections) do
      local transIdx2, side2 = parseConnections(connection2)
      if transIdx2 == transIdx then
        currentSide = side2
        break
      end
    end
    assert(currentSide)
    local numTransferred = transposers[transIdx].transferItem(currentSide, side, 1, 1, 1)    -- FIXME assert that item was moved instead of shifting stuff around? ######################################
    if numTransferred == 0 then
      assert(transposers[transIdx].transferItem(side, side, 1, 1, 2) > 0)
      assert(transposers[transIdx].transferItem(currentSide, side, 1, 1, 1) > 0)
    end
    
    local invType = findInventoryType(connection)
    
    if unvisited[connection] then
      lastItemConnections = findItemConnections()
      --print("lastItemConnections = ")
      --tdebug.printTable(lastItemConnections)
      
      local routingEntry = routing[invType]
      local routingEntryIndex = #routingEntry + 1
      
      for _, connection2 in ipairs(lastItemConnections) do
        -- Connections have now been visited, remove them from the set.
        unvisited[connection2] = nil
        
        routingEntry[routingEntryIndex] = (routingEntry[routingEntryIndex] or "") .. connection2
        
        local transIdx2, side2 = parseConnections(connection2)
        if transIdx2 ~= transIdx then
          addAdjacentConnections(transIdx2, side2)
          print("added adjacent connections for " .. connection2)
        end
      end
    else
      print("going back I guess")
      local connectionsPacked
      for _, connections in ipairs(routing[invType]) do
        if string.find(connections, connection, 1, true) then
          connectionsPacked = connections
          break
        end
      end
      print("connectionsPacked:", connectionsPacked)
      
      -- Unpack connectionsPacked and store them in lastItemConnections.
      lastItemConnections = {}
      for connection2 in string.gmatch(connectionsPacked, "%d*:%d*,") do
        lastItemConnections[#lastItemConnections + 1] = connection2
      end
    end
  end
  
  print("unvisited:")
  tdebug.printTable(unvisited)
  
  return routing
end

-- Main function, does setup stuff.
local function main()
  local input
  local outputFile = io.open(OUTPUT_FILENAME, "r")
  if outputFile then
    outputFile:close()
    io.write("Data file \"" .. OUTPUT_FILENAME .. "\" already exists, are you sure you want to overwrite it? [Y/n] ")
    input = io.read()
    if string.lower(input) ~= "y" and string.lower(input) ~= "yes" then
      io.write("Setup canceled.\n")
      return
    end
  end
  
  local setupConfig
  --
  setupConfig = {}
  setupConfig["minecraft:wool/13"] = "input"
  setupConfig["minecraft:wool/14"] = "output"
  setupConfig["minecraft:redstone/0"] = "transfer"
  setupConfig["minecraft:stone/0"] = "drone"
  --
  if not setupConfig then
    setupConfig = {}
    io.write("Please select the four item types to use for inventory identification. Use the\n")
    io.write("format \"<mod name>:<item name>/<damage>\" for each (for example, this would be\n")
    io.write("minecraft:stone/0 for stone and minecraft:wool/13 for green wool).\n\n")
    
    -- Confirm item chosen has valid form and is unique, then add it to setupConfig.
    local function validateItemAdd(s, itemType)
      s = stringToItemName(s)
      assert(not setupConfig[s], "Item type must be unique.")
      setupConfig[s] = itemType
    end
    io.write("Input (dump items into the network): ")
    validateItemAdd(io.read(), "input")
    io.write("Output (request items from the network): ")
    validateItemAdd(io.read(), "output")
    io.write("Transfer (buffer between transposers): ")
    validateItemAdd(io.read(), "transfer")
    io.write("Drone (access point for drones): ")
    validateItemAdd(io.read(), "drone")
  else
    io.write("Using these item types for inventory identification:\n")
    for k, v in pairs(setupConfig) do
      io.write(k .. " -> " .. v .. "\n")
    end
  end
  
  io.write("\nNext, add one of those items to the FIRST slot of each inventory in the network\n")
  io.write("corresponding to its type. The inventories for bulk storage should have an empty\n")
  io.write("first slot.\n")
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
  
  -- Inventories are identified with the pattern "<transposer index>,<side number>".
  local inventories = {}
  inventories.storage = {}
  inventories.input = nil
  inventories.output = nil
  inventories.transfer = {}
  inventories.drone = {}
  
  for i, transposer in ipairs(transposers) do
    for side = 0, 5 do
      local itemName = findInventoryItemName(transposer, side, 1)
      if itemName then
        local invType = setupConfig[itemName]
        if itemName == "" then
          invType = "storage"
          inventories.storage[#inventories.storage + 1] = formatConnection(i, side)
        elseif not invType then
          assert(false, "Found unrecognized item \"" .. itemName .. "\" in inventory.")
        elseif invType == "input" then
          assert(not inventories.input, "Found a second input inventory (there must be only one connected to a single transposer in network).")
          inventories.input = formatConnection(i, side)
        elseif invType == "output" then
          assert(not inventories.output, "Found a second output inventory (there must be only one connected to a single transposer in network).")
          inventories.output = formatConnection(i, side)
        elseif invType == "transfer" then
          inventories.transfer[#inventories.transfer + 1] = formatConnection(i, side)
        elseif invType == "drone" then
          inventories.drone[#inventories.drone + 1] = formatConnection(i, side)
        end
        
        io.write("Found a " .. transposer.getInventorySize(side) .. " slot " .. invType .. " inventory.\n")
      end
    end
  end
  
  assert(#inventories.storage > 0, "No storage inventories found.")
  assert(inventories.input, "No input inventory found.")
  assert(inventories.output, "No output inventory found.")
  
  io.write("\nBuilding routing table, this may take a while...\n")
  
  local routing = buildRoutingTable(transposers, inventories)
  
  tdebug.printTable(routing)
  
  local outputFile = io.open(OUTPUT_FILENAME, "w")
  if outputFile then
    outputFile:write("# TODO: Explain a bit about format here.\n\n")
    
    outputFile:write("transposers:\n")
    for i, address in ipairs(transposerAddresses) do
      outputFile:write(tostring(i) .. " = " .. address .. "\n")
    end
    
    -- Add line to file with the slot count, and connections the inventory has.
    local function writeConnectionsLine(connections)
      local transIdx, side = parseConnections(connections)
      local invSize = transposers[transIdx].getInventorySize(side)
      
      outputFile:write("slots = " .. tostring(invSize) .. "; connections = " .. connections .. "\n")
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
  
  --[[
  The routing file:
  
  # My comment.
  
  transposers:
  1 = <uuid>
  2 = <uuid>
  3 = <uuid>
  ...
  
  storage:
  slots = 27; connections = 1:1,4:5,
  slots = 1; connections = 1:2,
  ...
  
  input:
  slots = 27; connections = 1:1,
  
  output:
  slots = 27; connections = 2:1,
  
  ...
  
  
  The routing table might look like:
  
  storage {
    1: "<transposer ID>:<side>,"  -- Highest priority (insert here)
    2: "<transposer ID>:<side>,"
    3: "<transposer ID>:<side>,"  -- Lowest priority (extract here)
  }
  transfer {
    1: "<transposer ID>:<side>,<transposer ID>:<side>,"
    2: "<transposer ID>:<side>,<transposer ID>:<side>,<transposer ID>:<side>,"
  }
  input: "<transposer ID>:<side>,<transposer ID>:<side>,"
  --]]
end

main()
