local settings = {
  spatialIoPort = "tile%.appliedenergistics2%.BlockSpatialIOPort",
  enderChest = "tile%.enderchest",
  generator = "gt%.blockmachines",
  spatialCellItem = "appliedenergistics2:item%.ItemSpatialStorageCell.*",
  emptyFuelItem = "IC2:itemCellEmpty/0",
  scanDelaySeconds = 4.0,
  warpWaitAttempts = 6,
  fuelSlot = "d1",
  emptyFuelSlot = "d2",
}
local thisDestinationSlotId = "d5"
local targetDestinationSlotId = "d3"

local redstone = component.proxy(component.list("redstone")())    -- FIXME: what happens if you do this for component that is not available, do we need assert?
local transposer = component.proxy(component.list("transposer")())

local sides = {
  down = 0,
  up = 1,
  back = 2,
  front = 3,
  right = 4,
  left = 5,
}

##local include = require("include")
##local embedded = include("embedded")

----------------  warp_common  ----------------------

##for line in embedded.extractModuleSource("/usr/lib/warp_common.lua", "warp_common", true, {"scanRelativeSides", "getWorldSide", "getWorldSideAndSlot", "playWarningSound"}) do
##spwrite(line)
##end
------------------  itemutil  --------------------------

##for line in embedded.extractModuleSource("/usr/lib/itemutil.lua", "itemutil", true, {"getItemFullName", "invIterator"}) do
##spwrite(line)
##end
--------------------------------------------------------


local spatialIoPortSide


local function refuelGenerator(inventoryNames, side, slot, item)
  if not inventoryNames[side] then
    inventoryNames[side] = transposer.getInventoryName(side)
  end

  local fuelSide, fuelSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, settings.fuelSlot)
  if string.match(inventoryNames[side], settings.generator) and (transposer.getSlotStackSize(fuelSide, fuelSlot) or 0) > 0 then
    local emptyFuelSide, emptyFuelSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, settings.emptyFuelSlot)
    local itemsMoved = transposer.transferItem(side, emptyFuelSide, item.size, slot, emptyFuelSlot)
    if itemsMoved == item.size then
      transposer.transferItem(fuelSide, side, 1, fuelSlot, 1)
    end
  end
end


local function receiveWarp(side, slot, item)
  -- Verify the side and slot of the remote cell is known.
  local remoteSide, remoteSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, item.label)
  if not remoteSide or not remoteSlot then
    error("unable to determine slot id for storage cell in my slot with label \"" .. item.label .. "\" (label is invalid)")
  end

  -- Move the cell into spatial IO port and trigger it.
  if transposer.transferItem(side, spatialIoPortSide, 1, slot, 1) ~= 1 then
    return false
  end

  warp_common_playWarningSound()
  redstone.setOutput(sides.back, 15)
  os.sleep(0.1)
  redstone.setOutput(sides.back, 0)

  -- Move cell in remote slot back into my slot.
  local itemInRemoteSlot = transposer.getStackInSlot(remoteSide, remoteSlot)
  if not itemInRemoteSlot or itemInRemoteSlot.label ~= thisDestinationSlotId then

    -- FIXME: bug in next line, operator order is wrong, need to fix here and in main code! ##########################################################################################################################
    error("expected storage cell \"" .. thisDestinationSlotId .. "\" in remote slot (found " .. itemInRemoteSlot and ("\"" .. itemInRemoteSlot.label .. "\"") or "no item" .. ")")
  end
  if transposer.transferItem(remoteSide, side, 1, remoteSlot, slot) ~= 1 then
    error("failed to move storage cell \"" .. itemInRemoteSlot.label .. "\" into my slot")
  end

  -- Move cell in spatial IO port into remote slot.
  if transposer.transferItem(spatialIoPortSide, remoteSide, 1, 2, remoteSlot) ~= 1 then
    error("failed to move storage cell \"" .. itemInRemoteSlot.label .. "\" in spatial IO port into remote slot")
  end

  return true
end


local function startWarp(itemInMySlot, useDefaultDestination)
  -- FIXME: check dest? (source should be good at this point)

  local mySide, mySlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, thisDestinationSlotId)

  local remoteSide, remoteSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, targetDestinationSlotId)

  if useDefaultDestination then
    -- Move my cell into spatial IO port and trigger it.
    if transposer.transferItem(mySide, spatialIoPortSide, 1, mySlot, 1) ~= 1 then
      -- FIXME: fail noise, someone is arriving at this teleporter
      return
    end
  elseif not itemInMySlot or itemInMySlot.label == thisDestinationSlotId then
    -- FIXME: fail noise, no storage cell or user put remote cell in spatialIoPort
    return
  else
    remoteSide, remoteSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, itemInMySlot.label)
  end

  -- FIXME: success noise (single short beep?)
  os.sleep(1.0)
  redstone.setOutput(sides.back, 15)
  os.sleep(0.1)
  redstone.setOutput(sides.back, 0)

  if useDefaultDestination then
    -- Move remote cell into my slot.
    local remoteCellTransferred = false
    for _ = 1, 3 do
      local itemInRemoteSlot = transposer.getStackInSlot(remoteSide, remoteSlot)
      if itemInRemoteSlot and itemInRemoteSlot.label == targetDestinationSlotId then
        if transposer.transferItem(remoteSide, mySide, 1, remoteSlot, mySlot) == 1 then
          remoteCellTransferred = true
          break
        end
      end
      os.sleep(1.0)
    end
    if not remoteCellTransferred then
      assert(transposer.transferItem(spatialIoPortSide, spatialIoPortSide, 1, 2, 1) == 1)

      warp_common_playWarningSound()
      redstone.setOutput(sides.back, 15)
      os.sleep(0.1)
      redstone.setOutput(sides.back, 0)

      assert(transposer.transferItem(spatialIoPortSide, mySide, 1, 2, mySlot) == 1)
      return
    end
  end

  -- Move my cell in spatial IO port into remote slot.
  local warpSuccess = false
  if transposer.transferItem(spatialIoPortSide, remoteSide, 1, 2, remoteSlot) == 1 then
    -- Wait for my cell to arrive back in my slot, if it takes too long then we need to rescue the player stuck in the storage cell.
    for _ = 1, settings.warpWaitAttempts do
      os.sleep(settings.scanDelaySeconds / 2.0)
      local itemInMySlot = transposer.getStackInSlot(mySide, mySlot)
      if itemInMySlot and itemInMySlot.label == thisDestinationSlotId then
        warpSuccess = true
        break
      end
    end
    if not warpSuccess then
      assert(transposer.transferItem(remoteSide, spatialIoPortSide, 1, remoteSlot, 1) == 1)
    end
  else
    assert(transposer.transferItem(spatialIoPortSide, spatialIoPortSide, 1, 2, 1) == 1)
  end

  if not warpSuccess then
    warp_common_playWarningSound()
    redstone.setOutput(sides.back, 15)
    os.sleep(0.1)
    redstone.setOutput(sides.back, 0)

    assert(transposer.transferItem(mySide, remoteSide, 1, mySlot, remoteSlot) == 1)
    assert(transposer.transferItem(spatialIoPortSide, mySide, 1, 2, mySlot) == 1)
  end
end



for i = 0, 5 do
  if string.match(transposer.getInventoryName(i) or "", settings.spatialIoPort) then
    spatialIoPortSide = i
  end
end
if not spatialIoPortSide then
  error("transposer cannot see spatial IO port")
end
if spatialIoPortSide == sides.down or spatialIoPortSide == sides.up then
  error("transposer must access spatial IO port on the side, not up or down (for direction finding)")
end

while true do
  local ev = {computer.pullSignal(settings.scanTimeSeconds)}

  -- Scan each side for items.
  local inventoryNames = {}
  local mySide, mySlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, thisDestinationSlotId)
  local itemInMySlot
  for relativeSide in string.gmatch(warp_common_scanRelativeSides, "(.)") do
    local worldSide = warp_common_getWorldSide(spatialIoPortSide, relativeSide)
    for slot, item in itemutil_invIterator(transposer.getAllStacks(worldSide)) do
      if settings.fuelSlot and string.match(itemutil_getItemFullName(item), settings.emptyFuelItem) then
        refuelGenerator(inventoryNames, worldSide, slot, item)
      elseif worldSide == mySide and slot == mySlot then
        itemInMySlot = item
      end
    end
  end

  -- Check if spatial IO port is empty. If it's not, the user is likely to be manually dialing the destination.
  local spatialIoPortEmpty = true
  for _, _ in itemutil_invIterator(transposer.getAllStacks(spatialIoPortSide)) do
    spatialIoPortEmpty = false
  end

  if itemInMySlot and string.match(itemutil_getItemFullName(itemInMySlot), settings.spatialCellItem) and itemInMySlot.label ~= thisDestinationSlotId and spatialIoPortEmpty then
    receiveWarp(mySide, mySlot, itemInMySlot)
  elseif ev[1] == "redstone_changed" and ev[3] == sides.front and ev[5] > 0 then
    startWarp(itemInMySlot, spatialIoPortEmpty)
  end
end
