--[[
Cross dimensional player teleportation using AE2.

One enderchest slot per destination, need to support multiple ender chests.
Can update config by placing a named item like `de:d3="mars;suit,oxyge` and `cfg:n,thermal"` into any consecutive slots.
  Item names are too short, in above case the name is broken up into multiple items for the config entry.
  Use `se:` to change a setting, or `de:` to change a destination. The `de:` format looks like `de:slotId="name;requirements"` which is different from the config format. Assign the value nil to clear a destination.
Still need to copy the config file onto a new teleporter instance before hand.
Make sure to test config before leaving (teleport to the current teleporter should say you are already here)!
Spatial chamber size should have equal x and z dimensions, otherwise it will be directional.
Note that ender chests can be obtained through quest rewards, you do not need to reach the end of platline to get them.
Options to escape the storage dimension: death, /dimensiontp, or a trustworthy friend.

Some slots are special:
  * Fuel slot (optional)
  * Empty fuel slot (optional)

Warp process:
  1. Put fuel item into destination slot.
  2. Once it's gone, after a short delay redstone pulse the IO port.
    a. If it didn't go away, move it into fuel return slot and error.
  3. Put cell into destination slot.
    a. If my cell doesn't come back to my slot, put it into IO port and pulse, error.
    b. If my cell does come back to my slot, put it into IO port.

Warpd process:
  1. If fuel item in my slot, move it into return slot.
  2. If cell in my slot, 


Cells are stored in the ender chests, each slot corresponds to a destination and cells are named with that slot.
Taking a cell "locks" that destination allowing the sender to put their cell in the destination slot.
We cannot take cells out of the spatial IO port input slot if there is a problem (the user can do this instead).

Warp process:
  1. At warp, if my cell in my slot and dest cell in dest slot then put my cell in IO port, create lock file with computer uptime, then pulse after a moment.
    a. Do not wait if conditions not fulfilled, someone could be in transit to this destination.
    b. If this location same as dest, inform user and exit.
    c. If my cell not in my slot, someone is in transit to this destination. If dest cell not in dest slot, destination is busy.
    d. If any cell in IO port, we also have a problem.
  2. Put dest cell at dest slot into my slot (warpd sees lock file and knows this isn't a warp request).
    a. Wait for the cell if not there, if it takes too long spit the player back out (alert anyone nearby of the arrival).
  3. Put my cell into destination slot (try once, if failure go to step a). Expect my cell to come back in my slot.
    a. If my cell stays in dest slot too long, put my cell into IO port and pulse (alert anyone nearby of the arrival), put dest cell back (assert), put my cell back (assert).
  4. Delete lock file.

Warpd process:
  1. Init: assert no cell in IO port. Check sides once for generator and ender chests, if any destination not available then warn.
  2. If fuel slots defined, generator available, and has empty fuel, put all empty fuel in return slot (try once) and put one fuel in first slot (try once).
  3. If we see a config entry, update the config and save it if it's a new value and it's a valid form.
    a. If it's new, check sides again. If it corresponds to a destination we don't have available then warn.   FIXME: forgot about this, should we actually do this though?
    b. If it's not a valid form then warn.
  4. If remote cell in my slot and no lock file (or lock file is stale) and IO port empty, put remote cell in IO port, alert anyone nearby of the arrival, then pulse after a moment.
    a. If lock file was stale, remove it and warn.
  5. Put my cell back in my slot (retry a few times if failure, then log error), put remote cell in remote slot (retry a few times if failure, then log error).

]]

-- OS libraries.
local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local redstone = component.redstone
local shell = require("shell")
local sides = require("sides")
local transposer = component.transposer

-- User libraries.
local include = require("include")
include.mode("debug")
local dlog = include("dlog")
--dlog.mode("debug")

local config = include("config")
local itemutil = include("itemutil")
local warp_common = include("warp_common")


-- WarpClient class definition.
---@class WarpClient
local WarpClient = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(WarpClient, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in WarpClient class.", 2)
  end
})


-- Construct a new WarpClient instance with the provided configuration.
-- 
---@param cfg table
---@nodiscard
function WarpClient:new(cfg)
  self.__index = self
  self = setmetatable({}, self)

  self.cfg = cfg
  ---@type Sides
  self.spatialIoPortSide = sides.down

  return self
end


-- Run some preliminary checks, then start the warp.
-- 
---@param destination string
---@param opts table
---@return number
function WarpClient:prepareWarp(destination, opts)
  local hostname = os.getenv("HOSTNAME") or ""
  if hostname == destination then
    io.write("Already at this destination.\n")
    return 0
  end

  -- Note that `warpd` is much more strict about verifying config and hardware setup, so we just stick with basic checks here.

  -- Find spatial IO port.
  local spatialIoPortSide
  for i = 0, 5 do
    if string.match(transposer.getInventoryName(i) or "", self.cfg.settings.spatialIoPort) then
      spatialIoPortSide = i
    end
  end
  if not spatialIoPortSide then
    io.stderr:write("warp: transposer cannot see spatial IO port.\n")
    return 2
  end
  self.spatialIoPortSide = spatialIoPortSide --[[@as Sides]]

  -- Verify source and destination.
  local thisDestinationSlotId, remoteSlotId, remoteRequirements
  for _, v in ipairs(self.cfg.destinations) do
    local id, name, requirements = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
    if name == hostname then
      thisDestinationSlotId = id
    elseif name == destination then
      remoteSlotId = id
      remoteRequirements = requirements
    end
  end
  if not thisDestinationSlotId then
    io.stderr:write("warp: hostname \"", hostname, "\" for this destination was not found in the list of destinations.\n")
    return 2
  elseif not remoteSlotId then
    io.stderr:write("warp: destination \"", destination, "\" was not found in the list of destinations.\n")
    return 2
  end

  -- Ensure spatial IO port empty.
  for slot, _ in itemutil.invIterator(transposer.getAllStacks(self.spatialIoPortSide)) do
    io.stderr:write("warp: spatial IO port has item in slot ", slot, ", please put it back in its place in the ender chests.\n")
    return 2
  end

  if #remoteRequirements > 0 and not (opts["y"] or opts["yes"]) then
    io.write("This destination requires: ", remoteRequirements, "\n")
    io.write("Do you wish to proceed? (Y/n): ")
    local input = io.read()
    if type(input) ~= "string" or string.lower(input) == "n" or string.lower(input) == "no" then
      io.write("Exiting...\n")
      return 0
    end
  end

  -- Verify storage cells.
  local remoteSide, remoteSlot = warp_common.getSideAndSlot(remoteSlotId)
  local itemInRemoteSlot = transposer.getStackInSlot(warp_common.getWorldSide(self.spatialIoPortSide, remoteSide), remoteSlot)
  if not itemInRemoteSlot or itemInRemoteSlot.label ~= remoteSlotId then
    io.stderr:write("warp: destination is busy serving another request (storage cell ", remoteSlotId, " is not in its slot).\n")
    return 2
  end

  local mySide, mySlot = warp_common.getSideAndSlot(thisDestinationSlotId)
  local itemInMySlot = transposer.getStackInSlot(warp_common.getWorldSide(self.spatialIoPortSide, mySide), mySlot)
  if not itemInMySlot or itemInMySlot.label ~= thisDestinationSlotId then
    io.stderr:write("warp: source is busy, someone may be arriving at this teleporter (storage cell ", thisDestinationSlotId, " is not in its slot).\n")
    return 2
  end

  return self:startWarp(destination, thisDestinationSlotId, remoteSlotId)
end


-- Begin the warp process. If any problems occur then make a best effort to
-- recover the player from the storage cell and move the cells back into their
-- slots.
-- 
---@param destination string
---@param thisDestinationSlotId string
---@param remoteSlotId string
---@return number
function WarpClient:startWarp(destination, thisDestinationSlotId, remoteSlotId)
  local mySide, mySlot = warp_common.getSideAndSlot(thisDestinationSlotId)
  local myWorldSide = warp_common.getWorldSide(self.spatialIoPortSide, mySide)

  local remoteSide, remoteSlot = warp_common.getSideAndSlot(remoteSlotId)
  local remoteWorldSide = warp_common.getWorldSide(self.spatialIoPortSide, remoteSide)

  -- Move my cell into spatial IO port and trigger it.
  if transposer.transferItem(myWorldSide, self.spatialIoPortSide, 1, mySlot, 1) ~= 1 then
    io.stderr:write("warp: source is busy, someone may be arriving at this teleporter (failed to move my storage cell into spatial IO port).\n")
    return 2
  end
  local lockFile = io.open(warp_common.lockFilename, "w")
  if not lockFile then
    io.stderr:write("warp: unable to open lock file ", warp_common.lockFilename, " for writing.\n")
    return 2
  end
  lockFile:write(computer.uptime())
  lockFile:close()

  io.write("Warping to \"", destination, "\"...\n")
  os.sleep(1.0)
  redstone.setOutput(sides.back, 15)
  os.sleep(0.1)
  redstone.setOutput(sides.back, 0)

  -- Move remote cell into my slot.
  local remoteCellTransferred = false
  for _ = 1, 3 do    -- FIXME: make this a setting ############################
    local itemInRemoteSlot = transposer.getStackInSlot(remoteWorldSide, remoteSlot)
    if itemInRemoteSlot and itemInRemoteSlot.label == remoteSlotId then
      if transposer.transferItem(remoteWorldSide, myWorldSide, 1, remoteSlot, mySlot) == 1 then
        remoteCellTransferred = true
        break
      end
    end
    os.sleep(1.0)
  end
  if not remoteCellTransferred then
    io.stderr:write("warp: unable to move destination storage cell into my slot, aborting warp.\n")
    xassert(transposer.transferItem(self.spatialIoPortSide, self.spatialIoPortSide, 1, 2, 1) == 1)

    warp_common.playWarningSound()
    redstone.setOutput(sides.back, 15)
    os.sleep(0.1)
    redstone.setOutput(sides.back, 0)

    xassert(transposer.transferItem(self.spatialIoPortSide, myWorldSide, 1, 2, mySlot) == 1)
    return 2
  end

  -- Move my cell in spatial IO port into remote slot.
  local warpSuccess = false
  if transposer.transferItem(self.spatialIoPortSide, remoteWorldSide, 1, 2, remoteSlot) == 1 then
    for _ = 1, 5 do    -- FIXME: another setting ########################################
      os.sleep(2.5)    -- FIXME: this is a setting too, make it half the loop time in warpd?
      local itemInMySlot = transposer.getStackInSlot(myWorldSide, mySlot)
      if itemInMySlot and itemInMySlot.label == thisDestinationSlotId then
        warpSuccess = true
        break
      end
    end
    if not warpSuccess then
      io.stderr:write("warp: destination is not responding to request, aborting warp.\n")
      xassert(transposer.transferItem(remoteWorldSide, self.spatialIoPortSide, 1, remoteSlot, 1) == 1)
    end
  else
    io.stderr:write("warp: unable to move my storage cell into destination slot, aborting warp.\n")
    xassert(transposer.transferItem(self.spatialIoPortSide, self.spatialIoPortSide, 1, 2, 1) == 1)
  end

  if not warpSuccess then
    warp_common.playWarningSound()
    redstone.setOutput(sides.back, 15)
    os.sleep(0.1)
    redstone.setOutput(sides.back, 0)

    xassert(transposer.transferItem(myWorldSide, remoteWorldSide, 1, mySlot, remoteSlot) == 1)
    xassert(transposer.transferItem(self.spatialIoPortSide, myWorldSide, 1, 2, mySlot) == 1)
    return 2
  end

  return 0
end


local USAGE_STRING = [[
Usage: warp [OPTION]... DESTINATION

Options:
  -l, --list        list available destinations
  -y, --yes         skip confirmation prompts
  -h, --help        display help message and exit

To configure, run: edit ]] .. warp_common.configFilename .. "\n" .. [[
After changing config, run: rc warpd restart
For more information, run: man warp
]]

local function main(...)
  -- Get command-line arguments.
  local args, opts = shell.parse(...)

  if opts["h"] or opts["help"] then
    io.write(USAGE_STRING)
    return 0
  end

  local cfgPath = warp_common.configFilename
  if not filesystem.exists(cfgPath) then
    io.stderr:write("warp: config ", cfgPath, " not found, please enable and start `warpd` to create it.\n")
    return 2
  end
  local cfgTypes, cfgFormat = warp_common.makeConfigTemplate()
  local cfg = config.loadFile(cfgPath, cfgFormat, false)
  config.verify(cfg, cfgFormat, cfgTypes)

  local warpClient = WarpClient:new(cfg)

  if opts["l"] or opts["list"] then
    io.write("There are ", #cfg.destinations, " destinations available:\n")
    for _, v in ipairs(cfg.destinations) do
      local id, name, requirements = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
      if #requirements > 0 then
        io.write("\t", name, "\t(slot ", id, ", requires ", requirements, ")\n")
      else
        io.write("\t", name, "\t(slot ", id, ")\n")
      end
    end
    return 0
  end

  if #args ~= 1 then
    io.write(USAGE_STRING)
    return 0
  end

  local result = warpClient:prepareWarp(args[1], opts)
  if filesystem.exists(warp_common.lockFilename) then
    filesystem.remove(warp_common.lockFilename)
  end

  return result
end

local status, ret = dlog.handleError(xpcall(main, debug.traceback, ...))
os.exit(status and ret or 1)
