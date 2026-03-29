

-- OS libraries.
local component = require("component")
local sides = require("sides")
local transposer = component.transposer

-- User libraries.
local include = require("include")
include.mode("debug")
local dlog = include("dlog")
dlog.mode("debug")

local config = include("config")
local itemutil = include("itemutil")

-- WarpDaemon class definition.
local WarpDaemon = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(WarpDaemon, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in WarpDaemon class.", 2)
  end
})


-- Create tables to describe the configuration format. This is used in
-- conjunction with the config module to save/load/verify the configuration.
-- 
---@return table cfgTypes
---@return table cfgFormat
---@nodiscard
function WarpDaemon.makeConfigTemplate()
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


function WarpDaemon.verifyAndSaveConfig(existingCfg)
  local cfgPath = "/etc/warp.cfg"
  local cfgTypes, cfgFormat = WarpDaemon.makeConfigTemplate()
  local cfg, loadedDefaults
  if not existingCfg then
    cfg, loadedDefaults = config.loadFile(cfgPath, cfgFormat, true)
  else
    cfg = existingCfg
  end

  local status, result = pcall(config.verify, cfg, cfgFormat, cfgTypes)
  if not status then
    return false, cfgPath .. ": " .. result
  end

  -- Validate the destinations.
  local ids, names = {}, {}
  if cfg.settings.fuelSlot then
    ids[cfg.settings.fuelSlot] = true
  end
  if cfg.settings.emptyFuelSlot then
    ids[cfg.settings.emptyFuelSlot] = true
  end
  for _, v in ipairs(cfg.destinations) do
    local id, name, _ = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
    if ids[id] then
      return false, cfgPath .. ": destination id \"" .. id .. "\" appears more than once."
    elseif names[name] then
      return false, cfgPath .. ": destination name \"" .. name .. "\" appears more than once."
    end
    ids[id] = true
    names[name] = true
  end

  if loadedDefaults then
    dlog("warpd", "Configuration not found, saving defaults to ", cfgPath, "\n")
    config.saveFile(cfgPath, cfg, cfgFormat, cfgTypes)
  elseif existingCfg then
    config.saveFile(cfgPath, cfg, cfgFormat, cfgTypes)
  end

  return true, cfg
end


function WarpDaemon:new(...)
  self.__index = self
  self = setmetatable({}, self)

  self.cfg = {}
  self.spatialIoPortSide = -1

  -- Only four sides are scanned for ender chests and generators, right side (relative) is the spatial IO port.
  self.scanSides = {d = sides.down, u = sides.up, b = sides.back, l = sides.left}

  self.running = true

  return self
end


function WarpDaemon:start()
  io.write("WarpDaemon:start() called\n")
  dlog.handleError(xpcall(WarpDaemon.main, debug.traceback, self))

  --[[self.myCounter = self.myCounter + 1
  dlog("warpd", "WarpDaemon:start(), myCounter = ", self.myCounter)

  for i = 0, 5 do
    dlog("warpd", sides[i], " -> ", transposer.getInventoryName(i))
  end

  io.write("it worked?\n")]]



  --while self.running do
    --os.sleep(1)
  --end
end


function WarpDaemon:main()
  -- Load config file, or use default config if not found.
  local status, result = WarpDaemon.verifyAndSaveConfig()
  if not status then
    dlog("error", "\27[31m", result, "\27[0m")
    return
  end
  self.cfg = result

  dlog("warpd", "config: ", self.cfg)

  -- Find blocks next to the transposer.
  local inventoryNames = {}
  local namesFormatted = ""
  for i = 0, 5 do
    inventoryNames[i] = transposer.getInventoryName(i)
    if inventoryNames[i] then
      namesFormatted = namesFormatted .. inventoryNames[i] .. ", "
    end
  end
  namesFormatted = string.sub(namesFormatted, 1, -3)

  dlog("warpd", inventoryNames)

  local settings = self.cfg.settings
  local spatialIoPortSide
  for k, v in pairs(inventoryNames) do
    if string.match(v, settings.spatialIoPort) then
      spatialIoPortSide = k
    end
  end

  if not spatialIoPortSide then
    dlog("error", "\27[31m", "transposer cannot see spatial IO port (looking for ", settings.spatialIoPort, ", got [", namesFormatted, "]).\27[0m")
    return
  elseif spatialIoPortSide == sides.down or spatialIoPortSide == sides.up then
    dlog("error", "\27[31m", "transposer must access spatial IO port on the side, not up or down (for direction finding).\27[0m")
    return
  end
  for slot, _ in itemutil.invIterator(transposer.getAllStacks(spatialIoPortSide)) do
    dlog("error", "\27[31m", "spatial IO port has item in slot ", slot, ", please put it back in its place in the ender chests.\27[0m")
    return
  end
  self.spatialIoPortSide = spatialIoPortSide

  if settings.fuelSlot then
    if not settings.emptyFuelSlot then
      dlog("error", "\27[31m", "settings.fuelSlot is set to \"", settings.fuelSlot, "\" but settings.emptyFuelSlot is not defined.\27[0m")
      return
    end
    local generatorSide
    for k, v in pairs(inventoryNames) do
      if string.match(v, settings.generator) then
        generatorSide = k
      end
    end
    if not generatorSide then
      dlog("error", "\27[31m", "settings.fuelSlot is set to \"", settings.fuelSlot, "\" and transposer cannot see generator (looking for ", settings.generator, ", got [", namesFormatted, "]).\27[0m")
      return
    end
  end

  local enderChestSides = {}
  for k, v in pairs(inventoryNames) do
    if string.match(v, settings.enderChest) then
      enderChestSides[k] = true
    end
  end
  if next(enderChestSides) == nil then
    dlog("error", "\27[31m", "transposer cannot find any ender chests (looking for ", settings.enderChest, ", got [", namesFormatted, "]).\27[0m")
    return
  end
  local unreachableDestinations = ""
  for _, v in ipairs(self.cfg.destinations) do
    local id, name, _ = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
    if not enderChestSides[self.scanSides[string.sub(id, 1, 1)]] then
      unreachableDestinations = unreachableDestinations .. name .. ", "
    end
  end
  unreachableDestinations = string.sub(unreachableDestinations, 1, -3)
  if #unreachableDestinations > 0 then
    dlog("warn", "\27[33m", "some destinations are unreachable due to missing ender chests: [", unreachableDestinations, "].\27[0m")
  end

  --while self.running do
    self:doStuff()
    --os.sleep(20)
  --end
end


function WarpDaemon:getWorldSide(relativeSide)
  if relativeSide < 2 then
    -- Either up or down.
    return relativeSide
  else
    -- Adjust the sides to put them in clockwise order (back = 2, right = 4, front = 6, left = 8).
    local adjustedSpatialIoSide = self.spatialIoPortSide % 2 == 0 and self.spatialIoPortSide or self.spatialIoPortSide + 3
    local adjustedRelativeSide = relativeSide % 2 == 0 and relativeSide or relativeSide + 3
    local adjustedWorldSide = (adjustedSpatialIoSide + 2 + adjustedRelativeSide) % 8 + 2

    -- Undo the adjustment on the world side.
    return adjustedWorldSide <= 4 and adjustedWorldSide or adjustedWorldSide - 3
  end
end


function WarpDaemon:getSideAndSlot(slotId)
  return self.scanSides[string.sub(slotId, 1, 1)], tonumber(string.sub(slotId, 2))
end


function WarpDaemon:refuelGenerator(eachSideStacks, inventoryNames, relativeSide, slot, item)
  local settings = self.cfg.settings
  local worldSide = self:getWorldSide(relativeSide)
  if not inventoryNames[relativeSide] then
    inventoryNames[relativeSide] = transposer.getInventoryName(worldSide)
  end

  local fuelSide, fuelSlot = self:getSideAndSlot(settings.fuelSlot)
  if string.match(inventoryNames[relativeSide], settings.generator) and eachSideStacks[fuelSide][fuelSlot] then
    dlog("d", "Its a generator and we have fuel available.")
    local emptyFuelSide, emptyFuelSlot = self:getSideAndSlot(settings.emptyFuelSlot)
    local itemsMoved = transposer.transferItem(worldSide, emptyFuelSide, item.size, slot, emptyFuelSlot)
    if itemsMoved == item.size then
      dlog("d", "All items moved, put fuel in.")
      transposer.transferItem(fuelSide, worldSide, 1, fuelSlot, 1)
    end
  end
end


function WarpDaemon:updateConfig(configPrefix, configEntry)
  dlog("d", "Update config ", configPrefix, " with entry [", configEntry, "]")
  local subConfig
  if configPrefix == "se:" then
    subConfig = self.cfg.settings
  elseif configPrefix == "de:" then
    subConfig = self.cfg.destinations
  end

  local key, value = string.match(configEntry, "^([^=]+)=(.+)$")
  if not key then
    dlog("warn", "\27[33m", "Config update [", configPrefix, configEntry, "] is not a key/value form.\27[0m")
    return
  end

  local fn, ret, status
  fn, ret = load("return " .. value, "chunk", "t", {math = {huge = math.huge}})
  if fn then
    status, ret = pcall(fn)
  end
  if not status then
    dlog("warn", "\27[33m", "Config update [", configPrefix, configEntry, "] has an invalid value: ", ret, "\27[0m")
    return
  end
  value = ret

  dlog("d", "update ", key, " -> ", value)
  local oldValue = subConfig[key]
  subConfig[key] = value

  --FIXME: we really only need to do this if the value changed, verify and save config next
end


function WarpDaemon:doStuff()
  local settings = self.cfg.settings

  -- Scan each of the inventories for items and cache them. The transposer calls take one tick to run, so doing a pre-pass like this is more performant.
  local eachSideStacks = {}
  for _, relativeSide in pairs(self.scanSides) do
    local worldSide = self:getWorldSide(relativeSide)
    local stacks = transposer.getAllStacks(worldSide)
    local stacksCopy = {}
    if stacks then
      for slot, item in itemutil.invIterator(stacks) do
        stacksCopy[slot] = {
          fullName = itemutil.getItemFullName(item),
          label = item.label,
          size = item.size,
        }
      end
    end
    eachSideStacks[relativeSide] = stacksCopy
  end

  -- Make a second pass through the items to check for fuel, config updates, warp requests, etc.
  local inventoryNames = {}
  local configPrefix, configEntry
  for relativeSide, stacks in pairs(eachSideStacks) do
    for slot, item in pairs(stacks) do
      if settings.fuelSlot and string.match(item.fullName, settings.emptyFuelItem) then
        dlog("d", "Empty fuel at ", sides[relativeSide], " slot ", slot)
        self:refuelGenerator(eachSideStacks, inventoryNames, relativeSide, slot, item)
      elseif string.match(item.label, "^[sd]e:") then
        if string.sub(item.label, 1, 3) ~= configPrefix then
          configEntry = nil
        end
        configPrefix = string.sub(item.label, 1, 3)
        configEntry = (configEntry or "") .. string.match(item.label, "^" .. configPrefix .. "(.*)")

        -- The config entry is finished if we have an even number of quotes, otherwise it may continue at the next item.
        if select(2, string.gsub(configEntry, "\"", "")) % 2 == 0 then
          self:updateConfig(configPrefix, configEntry)
          configPrefix, configEntry = nil, nil
        end
      end
    end
    configPrefix, configEntry = nil, nil
  end
end


function WarpDaemon:stop()
  io.write("WarpDaemon:stop() called\n")
  self.running = false
end

return WarpDaemon
