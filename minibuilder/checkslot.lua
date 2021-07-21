local component = require("component")
local inv = component.inventory_controller
local tmod = require("tmod")

local item = inv.getStackInInternalSlot(1)
tmod.printTable(item)