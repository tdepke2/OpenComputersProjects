local component = require("component")
local transposer = component.transposer
local sides = require("sides")
local tdebug = require("tdebug")

local function transfer1()
  print("transfer1")
  for i = 1, transposer.getInventorySize(sides.west) do
    transposer.transferItem(sides.top, sides.west, 1, 1, i)
  end
  print("done")
end

local function transfer2()
  local slots = {}
  for i = 1, 53 do
    slots[i] = 1
  end
  slots[54] = 0

  print("transfer2")
  for i = 1, transposer.getInventorySize(sides.west) do
    if slots[i] == 0 then
      transposer.transferItem(sides.top, sides.west, 1, 1, i)
    end
  end
  print("done")
end

local function query1()
  local total = 0
  print("query1")
  for i = 1, transposer.getInventorySize(sides.top) do
    local count = transposer.getSlotStackSize(sides.top, i)
    total = total + count
  end
  print("done, " .. total)
end

-- Seems like this works really well, definitely use it() to traverse inventory.
-- The "it.count()" function returns inventory size, but it's slow.
-- Can also do it[n] to get item table for the n'th slot, but returns a table with minecraft:air for empty slots (unlike it() which returns empty table).
local function query2()
  local total = 0
  print("query2")
  local it = transposer.getAllStacks(sides.top)
  local item = it()
  while item do
    total = total + (item.size or 0)
    item = it()
  end
  print("done, " .. total)
end

local time1 = os.clock()
query2()
local time2 = os.clock()
print("took " .. time2 - time1)