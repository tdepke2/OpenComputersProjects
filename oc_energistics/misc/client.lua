--[[

Storage system:
  * Build 

TODO:
  * Use redstone I/O block and comparator on chest to set up auto-input to RE system.

--]]

local component = require("component")
local event = require("event")
local modem = component.modem
local sides = require("sides")
local term = require("term")
local text = require("text")
local thread = require("thread")

local tdebug = require("tdebug")

local COMMS_PORT = 0x1F48

modem.open(COMMS_PORT)

-- Scan through the inventory at specified side, and return total count of the
-- items found. Updates the storageItems table with details about the item (max
-- stack size, id, label, etc) including the total amount and where the items
-- are (separated into full slots and partial slots for fast lookup).
local function scanInventory(transposer, invID, side, storageItems)
  if transposer.getInventorySize(side) == nil then
    return nil
  end
  local numItemsFound = 0
  for i = 1, transposer.getInventorySize(side) do
    local item = transposer.getStackInSlot(side, i)
    if item then
      -- Concat the item name and it's damage (metadata) to get the table index.
      local fullName = item.name .. "/" .. math.floor(item.damage)
      if not storageItems[fullName] then
        storageItems[fullName] = {}
        storageItems[fullName].maxDamage = item.maxDamage    -- Maximum damage this item can have.
        storageItems[fullName].maxSize = item.maxSize    -- Maximum stack size.
        storageItems[fullName].id = item.id    -- Minecraft id of the item.
        storageItems[fullName].label = item.label    -- Translated item name.
        storageItems[fullName].total = 0
        storageItems[fullName].partialSlots = ""    -- CSV of "invID : slotNum".
        storageItems[fullName].fullSlots = ""    -- CSV of "invID : slotNum c size".
      end
      storageItems[fullName].total = storageItems[fullName].total + item.size
      if item.size < item.maxSize then
        storageItems[fullName].partialSlots = storageItems[fullName].partialSlots .. tostring(invID) .. ":" .. tostring(i) .. "c" .. tostring(item.size) .. ","
      else
        storageItems[fullName].fullSlots = storageItems[fullName].fullSlots .. tostring(invID) .. ":" .. tostring(i) .. ","
      end
      numItemsFound = numItemsFound + item.size
    end
  end
  return numItemsFound
end

-- Searches the string for the last "invID : slotNum c size" pattern. Returns
-- the index right before it was found and the values as numbers.
local function findLastSlot(slots)
  if slots == "" then
    return nil
  end
  
  -- Find longest text without a comma, that ends with comma, anchored to the right.
  local slot = string.match(slots, "[^,]*,$")
  -- Get three captures corresponding to the slot data.
  local invId, slotNum, size = string.match(slot, "(%d*):(%d*)c(%d*),")
  if not invId then
    invId, slotNum = string.match(slot, "(%d*):(%d*),")
  end
  
  return #slots - #slot, tonumber(invId), tonumber(slotNum), tonumber(size)
end

local function insertItems(mainTransposer, side, transposers, storageItems)
  
end

local function extractItems(mainTransposer, side, transposers, item, amount)
  -- Attempt to pull from partial slots first.
  while amount > 0 do
    local idx, invId, slotNum, size = findLastSlot(item.partialSlots)
    if not idx then
      break
    end
    
    -- Find the amount from this slot to transfer, and update item totals.
    local transferAmount = math.min(size, amount)
    size = size - transferAmount
    amount = amount - transferAmount
    item.total = item.total - transferAmount
    if size > 0 then
      item.partialSlots = string.sub(item.partialSlots, 1, idx) .. tostring(invID) .. ":" .. tostring(slotNum) .. "c" .. tostring(size) .. ","
    else
      item.partialSlots = string.sub(item.partialSlots, 1, idx)
    end
    
    print("Transfer " .. tostring(invID) .. ":" .. tostring(slotNum) .. "c" .. tostring(transferAmount) .. " to mainTransposer")
  end
  
  while amount > 0 do
    local idx, invId, slotNum = findLastSlot(item.fullSlots)
    if not idx then
      break
    end
    local size = 
    
    local transferAmount = math.min(size, amount)
    size = size - transferAmount
    amount = amount - transferAmount
    item.total = item.total - transferAmount
  end
  
  print(findLastSlot(item.fullSlots))
end

local mainTransposerAddress = component.get("e4da", "transposer")
local mainTransposer = component.proxy(mainTransposerAddress)

-- Assign numeric IDs to each transposer.
local transposers = {}
for address, name in pairs(component.list("transposer", true)) do
  if address ~= mainTransposerAddress then
    transposers[#transposers + 1] = component.proxy(address)
  end
end

local storageItems = {}
print("scanning inventories...")
for i, t in ipairs(transposers) do
  print("scanned " .. scanInventory(t, i, sides.top, storageItems) .. " items from inventory " .. i)
end

tdebug.printTable(storageItems)

while true do
  io.write("> ")
  local input = io.read()
  input = text.tokenize(input)
  if input[1] == "r" then
    if storageItems[input[2]] then
      extractItems(mainTransposer, sides.south, transposers, storageItems[input[2]], tonumber(input[3]))
    else
      print("We don\'t have any of those :(")
    end
  elseif input[1] == "exit" then
    break
  else
    print("Enter \"r <item> <count>\" to request, \"a\" to add, or \"exit\" to quit.")
  end
end

os.exit()







local droneAddress
local eventListener = thread.create(function()
  while true do
    local ev, _, sender, port, _, message, arg1 = event.pull()
    if ev == "modem_message" then
      if message == "FIND_DRONE_ACK" then
        droneAddress = sender
      end
      print("Got a message from " .. sender .. " on port " .. port .. ":")
      if arg1 then
        print(message .. ", " .. arg1)
      else
        print(message)
      end
    else
      --print("Unknown event " .. ev)
    end
  end
end)

modem.broadcast(COMMS_PORT, "FIND_DRONE")

while true do
  io.write("> ")
  local input = io.read()
  input = text.tokenize(input)
  if input[1] == "up" then
    local file = io.open("drone_up.lua")
    local sourceCode = file:read(10000000)
    print("Uploading \"drone_up.lua\"...")
    modem.send(droneAddress, COMMS_PORT, "UPLOAD", sourceCode)
  elseif input[1] == "exit" then
    eventListener:kill()
    break
  else
    print("Enter \"up\" to upload, or \"exit\" to quit.")
  end
end
