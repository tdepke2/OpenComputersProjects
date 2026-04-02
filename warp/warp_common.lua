
local sides = require("sides")

local warp_common = {}


-- Only four sides are scanned for ender chests and generators, right side (relative) is the spatial IO port.
warp_common.scanSides = {
  d = sides.down,
  u = sides.up,
  b = sides.back,
  l = sides.left
}


-- Create tables to describe the configuration format. This is used in
-- conjunction with the config module to save/load/verify the configuration.
-- 
---@return table cfgTypes
---@return table cfgFormat
---@nodiscard
function warp_common.makeConfigTemplate()
  local cfgTypes = {
    SlotId = {
      verify = function(v)
        if type(v) ~= "string" or not string.match(v, "^[dubl][1-9]%d*$") then
          error("provided SlotId must be a side (d, u, b, l) and slot number greater than zero.")
        end
      end
    },
    Destination = {
      verify = function(v)
        if type(v) ~= "string" then
          error("provided Destination must be a string.")
        end
        local id, name, _ = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
        if not id then
          error("provided Destination has invalid format.")
        elseif not string.match(id, "^[dubl][1-9]%d*$") then
          error("provided Destination id must be a side (d, u, b, l) and slot number greater than zero.")
        elseif not string.match(name, "^[%w_-]+$") then
          error("provided Destination name must only contain alphanumeric characters and dashes/underscores.")
        end
      end
    },
  }

  local cfgFormat = {
    settings = {
      _order_ = 1,
      spatialIoPort = {_order_ = 1, "string", "tile%.appliedenergistics2%.BlockSpatialIOPort", [[

FIXME: comments needed about tilename/itemname and that lua patterns are allowed.]],
      },
      enderChest = {_order_ = 2, "string", "tile%.enderchest"},
      generator = {_order_ = 3, "string", "gt%.blockmachines"},
      spatialCellItem = {_order_ = 4, "string", "appliedenergistics2:item%.ItemSpatialStorageCell.*"},
      emptyFuelItem = {_order_ = 5, "string", "IC2:itemCellEmpty/0"},    -- When empty fuel is removed, more fuel is added. There must be some empty or full fuel in the generator for this to work.
      fuelSlot = {_order_ = 6, "SlotId|nil", "d1"},
      emptyFuelSlot = {_order_ = 7, "SlotId|nil", "d2"},
    },
    destinations = {
      _order_ = 2,
      _comment_ = "\nDestinations I guess.",
      _ipairs_ = {"Destination",
        "d3;home;",
      },
    },
  }

  return cfgTypes, cfgFormat
end


-- Unpack a slot id (character representing a side, and slot number).
-- 
---@param slotId string
---@return Sides
---@return integer
function warp_common.getSideAndSlot(slotId)
  return warp_common.scanSides[string.sub(slotId, 1, 1)], tonumber(string.sub(slotId, 2)) --[[@as integer]]
end


-- Convert a side (relative to the spatial IO port) to the real side in the
-- world. The transposer will need this result.
-- 
---@param spatialIoPortSide Sides
---@param relativeSide Sides
---@return Sides
function warp_common.getWorldSide(spatialIoPortSide, relativeSide)
  if relativeSide < 2 then
    -- Either up or down.
    return relativeSide
  else
    -- Adjust the sides to put them in clockwise order (back = 2, right = 4, front = 6, left = 8).
    local adjustedSpatialIoSide = spatialIoPortSide % 2 == 0 and spatialIoPortSide or spatialIoPortSide + 3
    local adjustedRelativeSide = relativeSide % 2 == 0 and relativeSide or relativeSide + 3
    local adjustedWorldSide = (adjustedSpatialIoSide + 2 + adjustedRelativeSide) % 8 + 2

    -- Undo the adjustment on the world side.
    return adjustedWorldSide <= 4 and adjustedWorldSide or adjustedWorldSide - 3
  end
end

return warp_common
