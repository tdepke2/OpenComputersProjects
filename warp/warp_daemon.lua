

-- OS libraries.
local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local redstone = component.redstone
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
---@class WarpDaemon
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


-- If existingCfg is provided, it is used instead of loading the config from a
-- file. Returns true if successful, or false and an error message.
-- 
---@param existingCfg table|nil
---@return boolean
---@return string|nil
function WarpDaemon:verifyAndSaveConfig(existingCfg)
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

  local hostname = os.getenv("HOSTNAME")
  local thisDestinationSlotId
  if not hostname or #hostname == 0 then
    return false, cfgPath .. ": hostname is not set, please set it using `hostname <name>` with the name of this destination."
  end

  -- Validate the destinations.
  local ids, names = {}, {}
  if cfg.settings.fuelSlot then
    ids[cfg.settings.fuelSlot] = "settings.fuelSlot"
  end
  if cfg.settings.emptyFuelSlot then
    ids[cfg.settings.emptyFuelSlot] = "settings.emptyFuelSlot"
  end
  for _, v in ipairs(cfg.destinations) do
    local id, name, _ = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
    if name == hostname then
      thisDestinationSlotId = id
    end
    if ids[id] then
      return false, cfgPath .. ": slot id for \"" .. v .. "\" is already used for \"" .. ids[id] .. "\"."
    elseif names[name] then
      return false, cfgPath .. ": destination name for \"" .. v .. "\" is already used for \"" .. names[name] .. "\"."
    end
    ids[id] = v
    names[name] = v
  end
  if not thisDestinationSlotId then
    return false, cfgPath .. ": hostname \"" .. hostname .. "\" for this destination was not found in the list of destinations."
  end

  -- Only save and update member variables at the end once verification passed.
  if loadedDefaults then
    dlog("warpd", "configuration not found, saving defaults to ", cfgPath, "\n")
    config.saveFile(cfgPath, cfg, cfgFormat, cfgTypes)
  elseif existingCfg then
    config.saveFile(cfgPath, cfg, cfgFormat, cfgTypes)
  end
  self.cfg = cfg
  self.thisDestinationSlotId = thisDestinationSlotId

  return true
end


-- Create a new daemon instance.
-- 
---@param ... any
---@return WarpDaemon
---@nodiscard
function WarpDaemon:new(...)
  self.__index = self
  self = setmetatable({}, self)

  self.cfg = {}
  self.thisDestinationSlotId = ""
  self.spatialIoPortSide = -1

  -- Only four sides are scanned for ender chests and generators, right side (relative) is the spatial IO port.
  self.scanSides = {d = sides.down, u = sides.up, b = sides.back, l = sides.left}

  self.running = true

  return self
end


-- Entry point, called by `warpd` after initialization.
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


-- Reads configuration, checks setup for errors, then runs the main loop.
function WarpDaemon:main()
  -- Load config file, or use default config if not found.
  local status, result = self:verifyAndSaveConfig()
  if not status then
    dlog("error", "\27[31m", result, "\27[0m")
    return
  end

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

  -- Check the spatial IO port.
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

  -- Check fuel related things.
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

  -- Check placement of ender chests.
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

  -- Check spatial storage cells.
  local eachSideStacks, iterateStacks = self:scanInventories()
  local foundStorageCell = false
  for _, stacks in pairs(eachSideStacks) do
    for _, item in iterateStacks(stacks) do
      if string.match(item.fullName, settings.spatialCellItem) then
        foundStorageCell = true
        break
      end
    end
  end
  if not foundStorageCell then
    dlog("warn", "\27[33m", "no storage cells found in ender chests (looking for ", settings.spatialCellItem, ").\27[0m")
  end

  --while self.running do
    self:mainLoop()
    --os.sleep(20)
  --end
end


-- Convert a side (relative to the spatial IO port) to the real side in the
-- world. The transposer will need this result.
-- 
---@param relativeSide Sides
---@return Sides
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


-- Unpack a slot id (character representing a side, and slot number).
-- 
---@param slotId string
---@return Sides
---@return integer
function WarpDaemon:getSideAndSlot(slotId)
  return self.scanSides[string.sub(slotId, 1, 1)], tonumber(string.sub(slotId, 2)) --[[@as integer]]
end


-- Attempt to move empty fuel out of the generator and put new fuel in.
-- 
---@param eachSideStacks table
---@param inventoryNames table
---@param relativeSide Sides
---@param slot integer
---@param item Item
function WarpDaemon:refuelGenerator(eachSideStacks, inventoryNames, relativeSide, slot, item)
  local settings = self.cfg.settings
  local worldSide = self:getWorldSide(relativeSide)
  if not inventoryNames[relativeSide] then
    inventoryNames[relativeSide] = transposer.getInventoryName(worldSide)
  end

  local fuelSide, fuelSlot = self:getSideAndSlot(settings.fuelSlot)
  if string.match(inventoryNames[relativeSide], settings.generator) and eachSideStacks[fuelSide][fuelSlot] then
    dlog("d", "its a generator and we have fuel available.")
    local emptyFuelSide, emptyFuelSlot = self:getSideAndSlot(settings.emptyFuelSlot)
    local itemsMoved = transposer.transferItem(worldSide, emptyFuelSide, item.size, slot, emptyFuelSlot)
    if itemsMoved == item.size then
      dlog("d", "all items moved, put fuel in.")
      transposer.transferItem(fuelSide, worldSide, 1, fuelSlot, 1)
    end
  end
end


-- Attempt to modify the configuration with a new entry, and save the config if
-- successful. The configPrefix indicates if the entry corresponds to settings
-- or destinations.
-- 
---@param configPrefix string
---@param configEntry string
function WarpDaemon:updateConfig(configPrefix, configEntry)
  dlog("d", "update config ", configPrefix, " with entry [", configEntry, "]")
  local key, value = string.match(configEntry, "^([^=]+)=(.+)$")
  if not key then
    dlog("warn", "\27[33m", "config update [", configPrefix, configEntry, "] is not a key/value form.\27[0m")
    return
  end

  local fn, ret, status
  fn, ret = load("return " .. value, "chunk", "t", {math = {huge = math.huge}})
  if fn then
    status, ret = pcall(fn)
  end
  if not status then
    dlog("warn", "\27[33m", "config update [", configPrefix, configEntry, "] has an invalid value: ", ret, "\27[0m")
    return
  end
  value = ret

  local subConfig
  if configPrefix == "se:" then
    subConfig = self.cfg.settings
  elseif configPrefix == "de:" then
    -- For a destination, we will change the "slotId=value" form into "index=slotId;value" so it works with the config format.
    subConfig = self.cfg.destinations
    if type(value) == "string" then
      value = key .. ";" .. value
    end

    local existingKey = false
    for i, v in ipairs(subConfig) do
      if key == string.match(v, "^([^;]+);") then
        key = i
        existingKey = true
      end
    end
    if not existingKey then
      key = #subConfig + 1
    end
  end

  if subConfig[key] == value then
    return
  end

  dlog("d", "update ", key, " -> ", value)
  local oldValue = subConfig[key]
  subConfig[key] = value
  local status2, result = self:verifyAndSaveConfig(self.cfg)
  if not status2 then
    dlog("warn", "\27[33m", "config update [", configPrefix, configEntry, "] failed: ", result, "\27[0m")
    subConfig[key] = oldValue
    return
  end
end


function WarpDaemon:warpReceive(relativeSide, slot, item)
  -- Ensure that `warp` program is not in the middle of sending.
  local lockFilename = "/tmp/warp.lock"
  local lockFile = io.open(lockFilename, "r")
  if lockFile then
    local lastTime = lockFile:read("n")
    lockFile:close()
    if computer.uptime() - lastTime > 30.0 then    -- FIXME: what value to set this to? ##################################################################
      dlog("warn", "\27[33m", "lock file ", lockFilename, " is stale, removing it. Did a previous warp attempt fail?\27[0m")
      filesystem.remove(lockFilename)
    else
      return
    end
  end

  -- Verify spatial IO port is empty.
  local spatialIoPortEmpty = true
  for _, _ in itemutil.invIterator(transposer.getAllStacks(self.spatialIoPortSide)) do
    spatialIoPortEmpty = false
  end
  if not spatialIoPortEmpty then
    return
  end

  -- Verify the side and slot of the remote cell is known.
  local remoteSide, remoteSlot = self:getSideAndSlot(item.label)
  if not remoteSide or not remoteSlot then
    dlog("warn", "\27[33m", "unable to determine slot id for storage cell in spatial IO port with label \"", item.label, "\" (label is invalid).\27[0m")
    return
  end

  -- Move the cell into spatial IO port and trigger it.
  local worldSide = self:getWorldSide(relativeSide)
  if transposer.transferItem(worldSide, self.spatialIoPortSide, 1, slot, 1) ~= 1 then
    dlog("warn", "\27[33m", "warp arrival failed, unable to move storage cell into spatial IO port.\27[0m")
    return
  end

  local arrivalName
  for _, v in ipairs(self.cfg.destinations) do
    local id, name, _ = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
    if id == item.label then
      arrivalName = name
    end
  end
  io.write("Incoming warp from \"", arrivalName or "unknown", "\", please stand clear!\n")

  --computer.beep(400, 0.4)
  --computer.beep(607, 0.4)
  --computer.beep(925, 0.4)

  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  os.sleep(0.4)
  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  computer.beep(600, 0.2)
  computer.beep(400, 0.2)
  os.sleep(0.4)

  redstone.setOutput(sides.back, 15)
  os.sleep(0.1)
  redstone.setOutput(sides.back, 0)

  -- Move cell in remote slot back into my slot.
  local remoteWorldSide = self:getWorldSide(remoteSide)
  local itemInRemoteSlot = transposer.getStackInSlot(remoteWorldSide, remoteSlot)
  if itemInRemoteSlot and itemInRemoteSlot.label == self.thisDestinationSlotId then
    local putMyCellBack = false
    for _ = 1, 3 do
      if transposer.transferItem(remoteWorldSide, worldSide, 1, remoteSlot, slot) == 1 then
        putMyCellBack = true
        break
      end
      os.sleep(0.2)
    end
    if not putMyCellBack then
      dlog("error", "\27[31m", "failed to move storage cell \"", itemInRemoteSlot.label, "\" into my slot.\27[0m")
      return
    end
  else
    dlog("error", "\27[31m", "expected storage cell \"", self.thisDestinationSlotId, "\" in remote slot (found ", itemInRemoteSlot and ("\"" .. itemInRemoteSlot.label .. "\"") or "no item", ").\27[0m")
    return
  end

  -- Move cell in spatial IO port into remote slot.
  local putRemoteCellBack = false
  for _ = 1, 3 do
    if transposer.transferItem(self.spatialIoPortSide, remoteWorldSide, 1, 2, remoteSlot) == 1 then
      putRemoteCellBack = true
      break
    end
    os.sleep(0.2)
  end
  if not putRemoteCellBack then
    dlog("error", "\27[31m", "failed to move storage cell \"", itemInRemoteSlot.label, "\" in spatial IO port into remote slot.\27[0m")
    return
  end
end


function WarpDaemon:scanInventories()
  local eachSideStacks = {}
  for _, relativeSide in pairs(self.scanSides) do
    local worldSide = self:getWorldSide(relativeSide)
    local stacks = transposer.getAllStacks(worldSide)
    local stacksCopy = {}
    local lastSlot = 0
    if stacks then
      for slot, item in itemutil.invIterator(stacks) do
        lastSlot = slot
        stacksCopy[slot] = {
          fullName = itemutil.getItemFullName(item),
          label = item.label,
          size = item.size,
        }
      end
    end
    stacksCopy.n = lastSlot
    eachSideStacks[relativeSide] = stacksCopy
  end

  -- The stacks tables are not sequences, but we need a way to iterate the items in slot order.
  local function iterateStacks(stacks)
    local function iter(stacks, slot)
      local n = stacks.n
      slot = slot + 1
      while slot <= n do
        local item = stacks[slot]
        if item then
          return slot, item
        end
        slot = slot + 1
      end
    end
    return iter, stacks, 0
  end

  return eachSideStacks, iterateStacks
end


-- Check items in surrounding inventories and determine if there is work to do.
function WarpDaemon:mainLoop()
  local settings = self.cfg.settings

  -- Scan each of the inventories for items and cache them.
  -- The transposer calls take one tick to run, so doing a pre-pass like this is more performant.
  local eachSideStacks, iterateStacks = self:scanInventories()

  -- Make a second pass through the items to check for fuel, config updates, warp requests, etc.
  local inventoryNames = {}
  local configPrefix, configEntry
  for relativeSide, stacks in pairs(eachSideStacks) do
    for slot, item in iterateStacks(stacks) do
      if settings.fuelSlot and string.match(item.fullName, settings.emptyFuelItem) then
        dlog("d", "empty fuel at ", sides[relativeSide], " slot ", slot)
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

  -- Check for incoming warp.
  local mySide, mySlot = self:getSideAndSlot(self.thisDestinationSlotId)
  local itemInMySlot = eachSideStacks[mySide][mySlot]
  if itemInMySlot and string.match(itemInMySlot.fullName, settings.spatialCellItem) and itemInMySlot.label ~= self.thisDestinationSlotId then
    dlog("d", "remote cell in my slot, receive the warp")
    self:warpReceive(mySide, mySlot, itemInMySlot)
  end
end


-- Called by `warpd` when the daemon is requested to stop.
function WarpDaemon:stop()
  io.write("WarpDaemon:stop() called\n")
  self.running = false
end

return WarpDaemon
