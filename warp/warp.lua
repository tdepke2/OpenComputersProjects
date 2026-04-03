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
dlog.mode("debug")

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


function WarpClient:new()
  self.__index = self
  self = setmetatable({}, self)

  -- Note that `warpd` is much more strict about verifying config and hardware setup, so we just stick with basic checks here.

  local cfgPath = "/etc/warp.cfg"
  local cfgTypes, cfgFormat = warp_common.makeConfigTemplate()
  local cfg = config.loadFile(cfgPath, cfgFormat, false)

  if not cfg then
    io.write("error: config ", cfgPath, " not found, please enable and start `warpd` to create it.\n")
    os.exit(1)
  end
  config.verify(cfg, cfgFormat, cfgTypes)
  self.cfg = cfg

  ---@type Sides
  self.spatialIoPortSide = sides.down

  return self
end


function WarpClient:prepareWarp(destination)
  local hostname = os.getenv("HOSTNAME") or ""
  if hostname == destination then
    io.write("Already at this destination.\n")
    return    -- FIXME: exit success? ########################################
  end

  -- Find spatial IO port.
  local spatialIoPortSide
  for i = 0, 5 do
    if string.match(transposer.getInventoryName(i) or "", self.cfg.settings.spatialIoPort) then
      spatialIoPortSide = i
    end
  end
  if not spatialIoPortSide then
    io.write("error: transposer cannot see spatial IO port.\n")
    return
  end
  self.spatialIoPortSide = spatialIoPortSide --[[@as Sides]]

  -- Verify source and destination.
  local thisDestinationSlotId, remoteSlotId, thisDestinationRequirements
  for _, v in ipairs(self.cfg.destinations) do
    local id, name, requirements = string.match(v, "^([^;]+);([^;]+);([^;]*)$")
    if name == hostname then
      thisDestinationSlotId = id
      thisDestinationRequirements = requirements
    elseif name == destination then
      remoteSlotId = id
    end
  end
  if not thisDestinationSlotId then
    io.write("error: hostname \"", hostname, "\" for this destination was not found in the list of destinations.\n")
    return
  elseif not remoteSlotId then
    io.write("error: destination \"", destination, "\" was not found in the list of destinations.\n")
    return
  end

  -- Ensure spatial IO port empty.
  for slot, _ in itemutil.invIterator(transposer.getAllStacks(self.spatialIoPortSide)) do
    io.write("error: spatial IO port has item in slot ", slot, ", please put it back in its place in the ender chests.\n")
    return
  end

  --FIXME: need to allow a --force option, the requirements text is also backwards (should be for destination, not source)
  if #thisDestinationRequirements > 0 then
    io.write("This destination requires: ", thisDestinationRequirements, "\n")
    io.write("Do you wish to proceed? (Y/n): ")
    local input = io.read()
    if type(input) ~= "string" or string.lower(input) == "n" or string.lower(input) == "no" then
      io.write("Exiting...\n")
      return
    end
  end

  -- Verify storage cells.
  local remoteSide, remoteSlot = warp_common.getSideAndSlot(remoteSlotId)
  local itemInRemoteSlot = transposer.getStackInSlot(warp_common.getWorldSide(self.spatialIoPortSide, remoteSide), remoteSlot)
  if not itemInRemoteSlot or itemInRemoteSlot.label ~= remoteSlotId then
    io.write("error: destination is busy serving another request (storage cell ", remoteSlotId, " is not in its slot).\n")
    return
  end

  local mySide, mySlot = warp_common.getSideAndSlot(thisDestinationSlotId)
  local itemInMySlot = transposer.getStackInSlot(warp_common.getWorldSide(self.spatialIoPortSide, mySide), mySlot)
  if not itemInMySlot or itemInMySlot.label ~= thisDestinationSlotId then
    io.write("error: source is busy, someone may be arriving at this teleporter (storage cell ", thisDestinationSlotId, " is not in its slot).\n")
    return
  end

  self:startWarp(destination, thisDestinationSlotId, remoteSlotId)
end


function WarpClient:startWarp(destination, thisDestinationSlotId, remoteSlotId)
  local mySide, mySlot = warp_common.getSideAndSlot(thisDestinationSlotId)
  local myWorldSide = warp_common.getWorldSide(self.spatialIoPortSide, mySide)

  local remoteSide, remoteSlot = warp_common.getSideAndSlot(remoteSlotId)
  local remoteWorldSide = warp_common.getWorldSide(self.spatialIoPortSide, remoteSide)

  -- Move my cell into spatial IO port and trigger it.
  if transposer.transferItem(myWorldSide, self.spatialIoPortSide, 1, mySlot, 1) ~= 1 then
    io.write("error: source is busy, someone may be arriving at this teleporter (failed to move my storage cell into spatial IO port).\n")
    return
  end
  local lockFilename = "/tmp/warp.lock"
  local lockFile = io.open(lockFilename, "w")
  if not lockFile then
    io.write("error: unable to open lock file ", lockFilename, " for writing.\n")
    return
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
    io.write("error: unable to move destination storage cell into my slot, aborting warp.\n")
    xassert(transposer.transferItem(self.spatialIoPortSide, self.spatialIoPortSide, 1, 2, 1) == 1)

    warp_common.playWarningSound()
    redstone.setOutput(sides.back, 15)
    os.sleep(0.1)
    redstone.setOutput(sides.back, 0)

    xassert(transposer.transferItem(self.spatialIoPortSide, myWorldSide, 1, 2, mySlot) == 1)
    return
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
      io.write("error: destination is not responding to request, aborting warp.\n")
      xassert(transposer.transferItem(remoteWorldSide, self.spatialIoPortSide, 1, remoteSlot, 1) == 1)
    end
  else
    io.write("error: unable to move my storage cell into destination slot, aborting warp.\n")
    xassert(transposer.transferItem(self.spatialIoPortSide, self.spatialIoPortSide, 1, 2, 1) == 1)
  end

  if not warpSuccess then
    warp_common.playWarningSound()
    redstone.setOutput(sides.back, 15)
    os.sleep(0.1)
    redstone.setOutput(sides.back, 0)

    xassert(transposer.transferItem(myWorldSide, remoteWorldSide, 1, mySlot, remoteSlot) == 1)
    xassert(transposer.transferItem(self.spatialIoPortSide, myWorldSide, 1, 2, mySlot) == 1)
    return
  end

  filesystem.remove(lockFilename)    -- FIXME: we should remove the lock file even if earlier (non-fatal) error occurred.
end


local function main(...)
  -- Get command-line arguments.
  local args, opts = shell.parse(...)

  local warpClient = WarpClient:new()
  warpClient:prepareWarp(args[1])
end

main(...)
