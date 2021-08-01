local component = require("component")
local sides = require("sides")

local t1 = component.proxy(component.get("5f0a", "transposer"))
local t2 = component.proxy(component.get("9d62", "transposer"))

for i = 1, 20 do
  t1.transferItem(sides.north, sides.south, 64, 1, 1)
  t2.transferItem(sides.north, sides.south, 64, 1, 1)
  t2.transferItem(sides.south, sides.north, 64, 1, 1)
  t1.transferItem(sides.south, sides.north, 64, 1, 1)
  --print(i)
end