
-- TODO: Maybe integrate this into the client script and have it run if it doesn't find the data file??

local component = require("component")
local event = require("event")
local sides = require("sides")
local text = require("text")

local tdebug = require("tdebug")

local OUTPUT_FILENAME = "routing_data"

-- Deque class. Works like a queue or a stack.
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

local function parseConnections(connections, init)
  local transposerID, side = string.match(connections, "(%d*):(%d*),", init)
  return tonumber(transposerID), tonumber(side)
end

local function buildRoutingTable(transposers, inventories)
  local routing = {}
  routing.storage = {}
  routing.input = inventories.input
  routing.output = inventories.output
  routing.transfer = {}
  routing.drone = {}
  
  -- Add all unvisited connections. Usually these each correspond to a unique inventory (except for transfer ones).
  local unvisited = {}
  for _, connection in ipairs(inventories.storage) do
    unvisited[connection] = true
  end
  unvisited[inventories.output] = true
  for _, connection in ipairs(inventories.transfer) do
    unvisited[connection] = true
  end
  for _, connection in ipairs(inventories.drone) do
    unvisited[connection] = true
  end
  
  local searchStack = {}
  
  
  return routing
end

-- Main function, does setup stuff.
local function main()
  d = Deque:new()
  print("d:empty() = " .. tostring(d:empty()))
  print("d:size() = " .. tostring(d:size()))
  print("d:front() = " .. tostring(d:front()))
  print("d:back() = " .. tostring(d:back()))
  print("d:push_front('first')")
  d:push_front("first")
  print("d:push_back('second')")
  d:push_back("second")
  print("d:empty() = " .. tostring(d:empty()))
  print("d:size() = " .. tostring(d:size()))
  print("d:front() = " .. tostring(d:front()))
  print("d:back() = " .. tostring(d:back()))
  print("d:pop_front()")
  d:pop_front()
  print("d:pop_back()")
  d:pop_back()
  print("d:empty() = " .. tostring(d:empty()))
  print("d:size() = " .. tostring(d:size()))
  print("d:front() = " .. tostring(d:front()))
  print("d:back() = " .. tostring(d:back()))
  print()
  
  print("Queue test:")
  q = Deque:new()
  q:push_back("hello")
  q:push_back("this")
  q:push_back("is")
  q:push_back("my")
  q:push_back("queue")
  while not q:empty() do
    print(q:front())
    q:pop_front()
  end
  print()
  
  print("Stack test:")
  s = Deque:new()
  s:push_front("greetings")
  s:push_front("this")
  s:push_front("is not")
  s:push_front("a queue")
  s:push_front("but a")
  s:push_front("stack")
  while not s:empty() do
    print(s:front())
    s:pop_front()
  end
  
  os.exit()
  
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
        local function formatInventoryData()
          return tostring(i) .. ":" .. tostring(getOppositeSide(side)) .. ","
        end
        
        local invType = setupConfig[itemName]
        if itemName == "" then
          invType = "storage"
          inventories.storage[#inventories.storage + 1] = formatInventoryData()
        elseif not invType then
          assert(false, "Found unrecognized item \"" .. itemName .. "\" in inventory.")
        elseif invType == "input" then
          assert(not inventories.input, "Found a second input inventory (there must be only one connected to a single transposer in network).")
          inventories.input = formatInventoryData()
        elseif invType == "output" then
          assert(not inventories.output, "Found a second output inventory (there must be only one connected to a single transposer in network).")
          inventories.output = formatInventoryData()
        elseif invType == "transfer" then
          inventories.transfer[#inventories.transfer + 1] = formatInventoryData()
        elseif invType == "drone" then
          inventories.drone[#inventories.drone + 1] = formatInventoryData()
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
      local transposerID, side = parseConnections(connections, 1)
      local invSize = transposers[transposerID].getInventorySize(getOppositeSide(side))
      
      outputFile:write("slots = " .. tostring(invSize) .. "; connections = " .. connections .. "\n")
    end
    
    outputFile:write("\nstorage:\n")
    for _, connections in ipairs(routing.storage) do
      writeConnectionsLine(connections)
    end
    
    outputFile:write("\ninput:\n")
    writeConnectionsLine(routing.input)
    
    outputFile:write("\noutput:\n")
    writeConnectionsLine(routing.output)
    
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
