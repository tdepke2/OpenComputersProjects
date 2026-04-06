
local computer = require("computer")
local sides = require("sides")

local warp_common = {}


-- Only four sides are scanned for ender chests and generators, right side (relative) is the spatial IO port.
warp_common.scanSides = {
  d = sides.down,
  u = sides.up,
  b = sides.back,
  l = sides.left
}

-- Path to the configuration file.
warp_common.configFilename = "/etc/warp.cfg"

-- Path to the lock file created by warp program when initiating the teleport.
warp_common.lockFilename = "/tmp/warp.lock"


-- Create tables to describe the configuration format. This is used in
-- conjunction with the config module to save/load/verify the configuration.
-- 
---@return table cfgTypes
---@return table cfgFormat
---@nodiscard
function warp_common.makeConfigTemplate()
  local cfgTypes = {
    Integer = {
      verify = function(v)
        if type(v) ~= "number" or math.floor(v) ~= v then
          error("provided value must be an integer type.")
        end
      end
    },
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
      _comment_ = [[
General settings. Note that in the following entries about block/item names,
there is a difference between a block name versus an item name (a block name
tends to be different than its name in item form). Also, block/item names are
interpreted as Lua patterns (similar to regex).]],
      spatialIoPort = {_order_ = 1, "string", "tile%.appliedenergistics2%.BlockSpatialIOPort"},
      enderChest = {_order_ = 2, "string", "tile%.enderchest", ""},
      generator = {_order_ = 3, "string", "gt%.blockmachines", ""},
      spatialCellItem = {_order_ = 4, "string", "appliedenergistics2:item%.ItemSpatialStorageCell.*", ""},
      emptyFuelItem = {_order_ = 5, "string", "IC2:itemCellEmpty/0", [[

Empty fuel in the generator will trigger new fuel to be added. The
generator must start with some empty or full fuel for refueling to work.]]},
      scanDelaySeconds = {_order_ = 6, "number", 4.0, [[

Time between scan attempts for fuel, config updates, and incoming warps.]]},
      warpWaitAttempts = {_order_ = 7, "Integer", 6, [[

Number of times warp program will wait for an outgoing warp to succeed
before aborting the warp and rescuing a player stuck in the storage cell.]]},
      fuelSlot = {_order_ = 8, "SlotId|nil", "d1", [[

The slot ids where fuel will be found and empty fuel can be returned. If
you are powering the teleporter using a different method, then these can be
set to nil.]]},
      emptyFuelSlot = {_order_ = 9, "SlotId|nil", "d2"},
    },
    destinations = {
      _order_ = 2,
      _comment_ = [[

Array of destinations. Each has the form "<slot id>;<name>;<requirements>".
The slot id is a single character (d, u, b, l) corresponding to down, up,
back, and left of the transposer, and an integer slot number (slot 1 is the
first slot in an inventory). The name must consist of only alphanumeric
characters and dashes/underscores, requirements can be any text or be left
empty.]],
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


-- Make a noise to alert any nearby players to get out of the way.
function warp_common.playWarningSound()
  --computer.beep(400, 0.4)
  --computer.beep(607, 0.4)
  --computer.beep(925, 0.4)

  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  os.sleep(0.3)
  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  os.sleep(0.3)
end

return warp_common
