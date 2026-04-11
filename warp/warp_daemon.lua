--------------------------------------------------------------------------------
-- Teleportation network daemon. Run by `warpd` to handle teleport requests.
-- 
-- @see file://warp/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


--[[
Warpd process (see `warp.lua` for the sending side):
  1. Init: assert no cell in IO port. Check sides once for generator and ender chests, if any destination not available then warn.
  2. If fuel slots defined, generator available, and has empty fuel, put all empty fuel in return slot (try once) and put one fuel in first slot (try once).
  3. If we see a config entry, update the config and save it if it's a new value and it's a valid form.
    a. If it's not a valid form then warn.
  4. If remote cell in my slot and no lock file (or lock file is stale) and IO port empty, put remote cell in IO port, alert anyone nearby of the arrival, then pulse after a moment.
    a. If lock file was stale, remove it and warn.
  5. Put my cell back in my slot (try once, if failure then log error), put remote cell in remote slot (try once, if failure then log error).
--]]


-- OS libraries.
local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local redstone = component.redstone
local sides = require("sides")
local transposer = component.transposer

-- User libraries.
local include = require("include")
include.mode("optimize1")
local dlog = include("dlog")
--dlog.mode("debug")

local config = include("config")
local itemutil = include("itemutil")
local warp_common = include("warp_common")


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
  ---@type Sides
  self.spatialIoPortSide = sides.down

  self.running = true

  return self
end


-- Entry point, called by `warpd` after initialization.
function WarpDaemon:start()
  dlog("d", "WarpDaemon:start() called")
  dlog.handleError(xpcall(WarpDaemon.main, debug.traceback, self))
end


-- If existingCfg is provided, it is used instead of loading the config from a
-- file. Returns true if successful, or false and an error message.
-- 
---@param existingCfg table|nil
---@return boolean
---@return string|nil
function WarpDaemon:verifyAndSaveConfig(existingCfg)
  local cfgPath = warp_common.configFilename
  local cfgTypes, cfgFormat = warp_common.makeConfigTemplate()
  local cfg
  if not existingCfg then
    local loadedDefaults
    cfg, loadedDefaults = config.loadFile(cfgPath, cfgFormat, true)
    if loadedDefaults then
      dlog("warpd", "configuration not found, saving defaults to ", cfgPath)
      config.saveFile(cfgPath, cfg, cfgFormat, cfgTypes)
    end
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
  if existingCfg then
    config.saveFile(cfgPath, cfg, cfgFormat, cfgTypes)
  end
  self.cfg = cfg
  self.thisDestinationSlotId = thisDestinationSlotId

  return true
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
    if not enderChestSides[warp_common.getWorldSide(spatialIoPortSide, string.sub(id, 1, 1))] then
      unreachableDestinations = unreachableDestinations .. name .. ", "
    end
  end
  unreachableDestinations = string.sub(unreachableDestinations, 1, -3)
  if #unreachableDestinations > 0 then
    dlog("warn", "\27[33m", "some destinations are unreachable due to missing ender chests: [", unreachableDestinations, "].\27[0m")
  end

  -- Check spatial storage cells.
  local foundStorageCell = false
  for relativeSide in string.gmatch(warp_common.scanRelativeSides, "(.)") do
    local worldSide = warp_common.getWorldSide(self.spatialIoPortSide, relativeSide)
    for _, item in itemutil.invIterator(transposer.getAllStacks(worldSide)) do
      if string.match(itemutil.getItemFullName(item), settings.spatialCellItem) then
        foundStorageCell = true
        break
      end
    end
  end
  if not foundStorageCell then
    dlog("warn", "\27[33m", "no storage cells found in ender chests (looking for ", settings.spatialCellItem, ").\27[0m")
  end

  while self.running do
    self:mainLoop()
    os.sleep(settings.scanDelaySeconds)
  end
end


-- Attempt to move empty fuel out of the generator and put new fuel in.
-- 
---@param inventoryNames table
---@param side Sides
---@param slot integer
---@param item Item
function WarpDaemon:refuelGenerator(inventoryNames, side, slot, item)
  local settings = self.cfg.settings
  if not inventoryNames[side] then
    inventoryNames[side] = transposer.getInventoryName(side)
  end

  local fuelSide, fuelSlot = warp_common.getWorldSideAndSlot(self.spatialIoPortSide, settings.fuelSlot)
  if string.match(inventoryNames[side], settings.generator) and (transposer.getSlotStackSize(fuelSide, fuelSlot) or 0) > 0 then
    dlog("d", "its a generator and we have fuel available.")
    local emptyFuelSide, emptyFuelSlot = warp_common.getWorldSideAndSlot(self.spatialIoPortSide, settings.emptyFuelSlot)
    local itemsMoved = transposer.transferItem(side, emptyFuelSide, item.size, slot, emptyFuelSlot)
    if itemsMoved == item.size then
      dlog("d", "all items moved, put one fuel into first slot.")
      transposer.transferItem(fuelSide, side, 1, fuelSlot, 1)
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


-- Attempt to complete a warp request using the storage cell at the given side
-- and slot. Any error that occurs is outside the normal operating conditions,
-- so just log the error and return instead of trying to reset everything to a
-- good state.
-- 
---@param side Sides
---@param slot integer
---@param item table
function WarpDaemon:receiveWarp(side, slot, item)
  -- Ensure that `warp` program is not in the middle of sending.
  local lockFile = io.open(warp_common.lockFilename, "r")
  if lockFile then
    local lastTime = lockFile:read("n")
    lockFile:close()
    if computer.uptime() - lastTime > self.cfg.settings.scanDelaySeconds * self.cfg.settings.warpWaitAttempts then
      dlog("warn", "\27[33m", "lock file ", warp_common.lockFilename, " is stale, removing it. Did a previous warp attempt fail?\27[0m")
      filesystem.remove(warp_common.lockFilename)
    else
      return
    end
  end

  dlog("d", "remote cell in my slot, receive the warp")

  -- Verify spatial IO port is empty.
  for s, _ in itemutil.invIterator(transposer.getAllStacks(self.spatialIoPortSide)) do
    dlog("error", "\27[31m", "warp arrival failed, spatial IO port has item in slot ", s, ", please put it back in its place in the ender chests.\27[0m")
    return
  end

  -- Verify the side and slot of the remote cell is known.
  local remoteSide, remoteSlot = warp_common.getWorldSideAndSlot(self.spatialIoPortSide, item.label)
  if not remoteSide or not remoteSlot then
    dlog("error", "\27[31m", "warp arrival failed, unable to determine slot id for storage cell in my slot with label \"", item.label, "\" (label is invalid).\27[0m")
    return
  end

  -- Move the cell into spatial IO port and trigger it.
  if transposer.transferItem(side, self.spatialIoPortSide, 1, slot, 1) ~= 1 then
    dlog("warn", "\27[33m", "warp arrival aborted, unable to move storage cell \"", item.label, "\" into spatial IO port.\27[0m")
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
  warp_common.playWarningSound()
  redstone.setOutput(sides.back, 15)
  os.sleep(0.1)
  redstone.setOutput(sides.back, 0)

  -- Move cell in remote slot back into my slot.
  local itemInRemoteSlot = transposer.getStackInSlot(remoteSide, remoteSlot)
  if not itemInRemoteSlot or itemInRemoteSlot.label ~= self.thisDestinationSlotId then
    dlog("error", "\27[31m", "expected storage cell \"", self.thisDestinationSlotId, "\" in remote slot (found ", itemInRemoteSlot and ("\"" .. itemInRemoteSlot.label .. "\"") or "no item", ").\27[0m")
    return
  end
  if transposer.transferItem(remoteSide, side, 1, remoteSlot, slot) ~= 1 then
    dlog("error", "\27[31m", "failed to move storage cell \"", itemInRemoteSlot.label, "\" into my slot.\27[0m")
    return
  end

  -- Move cell in spatial IO port into remote slot.
  if transposer.transferItem(self.spatialIoPortSide, remoteSide, 1, 2, remoteSlot) ~= 1 then
    dlog("error", "\27[31m", "failed to move storage cell \"", itemInRemoteSlot.label, "\" in spatial IO port into remote slot.\27[0m")
    return
  end
end


-- Check items in surrounding inventories and determine if there is work to do.
function WarpDaemon:mainLoop()
  local settings = self.cfg.settings

  -- Scan each of the inventories for items and check for fuel, config updates, warp requests, etc.
  local inventoryNames = {}
  local configPrefix, configEntry
  local mySide, mySlot = warp_common.getWorldSideAndSlot(self.spatialIoPortSide, self.thisDestinationSlotId)
  local itemInMySlot

  for relativeSide in string.gmatch(warp_common.scanRelativeSides, "(.)") do
    local worldSide = warp_common.getWorldSide(self.spatialIoPortSide, relativeSide)
    for slot, item in itemutil.invIterator(transposer.getAllStacks(worldSide)) do

      if settings.fuelSlot and string.match(itemutil.getItemFullName(item), settings.emptyFuelItem) then
        dlog("d", "empty fuel at ", sides[worldSide], " slot ", slot)
        self:refuelGenerator(inventoryNames, worldSide, slot, item)
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

      if worldSide == mySide and slot == mySlot then
        itemInMySlot = item
      end
    end
    configPrefix, configEntry = nil, nil
  end

  -- Check for incoming warp.
  if itemInMySlot and string.match(itemutil.getItemFullName(itemInMySlot), settings.spatialCellItem) and itemInMySlot.label ~= self.thisDestinationSlotId then
    self:receiveWarp(mySide, mySlot, itemInMySlot)
  end
end


-- Called by `warpd` when the daemon is requested to stop.
function WarpDaemon:stop()
  io.write("Stopping warpd...\n")
  self.running = false
end

return WarpDaemon
