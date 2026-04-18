--------------------------------------------------------------------------------
-- Teleportation network client, microcontroller version.
-- 
-- @see file://warp_mini/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


-- Copy of the default settings from warp_common.lua, see that file for
-- descriptions.
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

-- Slot id in the ender chest (and the name of the storage cell) associated with
-- the current teleporter.
local thisDestinationSlotId = "d5"

-- Slot id of the destination to warp to when the button is pressed.
local targetDestinationSlotId = "d3"



local redstone = component.proxy(component.list("redstone")())
local transposer = component.proxy(component.list("transposer")())

local sides = {
  down = 0,
  up = 1,
  back = 2,
  front = 3,
  right = 4,
  left = 5,
}
local os = {
  sleep = computer.pullSignal,
}


-- warp_common.lua

-- Only the down, up, back, and left sides (relative) are scanned for ender chests and generators, right side is the spatial IO port.
local warp_common_scanRelativeSides = "dubl"

-- Convert a side (relative to the spatial IO port) to the real side in the
-- world. The transposer will need this result.
-- 
---@param spatialIoPortSide Sides
---@param relativeSideChar string
---@return Sides|nil
local function warp_common_getWorldSide(spatialIoPortSide, relativeSideChar)
  local relativeSide = string.find("dubfrl", relativeSideChar, 1, true) --[[@as Sides]]
  if not relativeSide then
    return nil
  end
  relativeSide = relativeSide - 1

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

-- Unpack a slot id (character representing a side, and slot number).
-- 
---@param spatialIoPortSide Sides
---@param slotId string
---@return Sides|nil
---@return integer|nil
local function warp_common_getWorldSideAndSlot(spatialIoPortSide, slotId)
  return warp_common_getWorldSide(spatialIoPortSide, string.sub(slotId, 1, 1)), tonumber(string.sub(slotId, 2)) --[[@as integer]]
end

-- Make a noise to alert any nearby players to get out of the way.
local function warp_common_playWarningSound()
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


-- itemutil.lua

-- Get the unique identifier of an item (internal name and metadata). This is
-- used for table indexing of items and such. Note that items with different NBT
-- can still resolve to the same identifier.
-- 
-- The resulting name has the pattern:
-- `<mod name>:<item id name>/<metadata number>[n]`.
-- For example, `minecraft:iron_pickaxe/0n` is an enchanted iron pickaxe with
-- full durability.
-- 
---@param item Item
---@return ItemFullName itemName
---@nodiscard
local function itemutil_getItemFullName(item)
  return item.name .. "/" .. math.floor(item.damage) .. (item.hasTag and "n" or "")
end

-- Iterator wrapper for the result returned from `icontroller.getAllStacks()`
-- and `transposer.getAllStacks()`. Returns the current slot number and item
-- with each call, skipping over empty slots.
-- 
---@param itemIter fun():Item|nil
---@return fun(itemIter: function, slot: integer):integer, Item
---@return fun():Item|nil
---@return integer
---@nodiscard
local function itemutil_invIterator(itemIter)
  local function iter(itemIter, slot)
    slot = slot + 1
    local item = itemIter()
    while item do
      if next(item) ~= nil then
        return slot, item
      end
      slot = slot + 1
      item = itemIter()
    end
  end

  if itemIter == nil then
    itemIter = function() end
  end
  return iter, itemIter, 0
end



---@type Sides
local spatialIoPortSide


-- Attempt to move empty fuel out of the generator and put new fuel in.
-- 
---@param inventoryNames table
---@param side Sides
---@param slot integer
---@param item Item
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


-- Attempt to complete a warp request using the storage cell at the given side
-- and slot.
-- 
---@param side Sides
---@param slot integer
---@param item Item
local function receiveWarp(side, slot, item)
  -- Verify the side and slot of the remote cell is known.
  local remoteSide, remoteSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, item.label)
  if not remoteSide or not remoteSlot then
    error("unable to determine slot id for storage cell in my slot with label \"" .. item.label .. "\" (label is invalid)")
  end

  -- Move the cell into spatial IO port and trigger it.
  if transposer.transferItem(side, spatialIoPortSide, 1, slot, 1) ~= 1 then
    return
  end

  warp_common_playWarningSound()
  redstone.setOutput(sides.right, 15)
  os.sleep(0.1)
  redstone.setOutput(sides.right, 0)

  -- Move cell in remote slot back into my slot.
  local itemInRemoteSlot = transposer.getStackInSlot(remoteSide, remoteSlot)
  if not itemInRemoteSlot or itemInRemoteSlot.label ~= thisDestinationSlotId then
    error("expected storage cell \"" .. thisDestinationSlotId .. "\" in remote slot (found " .. (itemInRemoteSlot and ("\"" .. itemInRemoteSlot.label .. "\"") or "no item") .. ")")
  end
  if transposer.transferItem(remoteSide, side, 1, remoteSlot, slot) ~= 1 then
    error("failed to move storage cell \"" .. itemInRemoteSlot.label .. "\" into my slot")
  end

  -- Move cell in spatial IO port into remote slot.
  if transposer.transferItem(spatialIoPortSide, remoteSide, 1, 2, remoteSlot) ~= 1 then
    error("failed to move storage cell \"" .. itemInRemoteSlot.label .. "\" in spatial IO port into remote slot")
  end
end


-- Begin the warp process. If any problems occur then make a best effort to
-- recover the player from the storage cell and move the cells back into their
-- slots.
-- 
---@param itemInMySlot Item
---@param itemInSpatialIoPort Item
local function startWarp(itemInMySlot, itemInSpatialIoPort)
  local mySide, mySlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, thisDestinationSlotId)

  local remoteSide, remoteSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, targetDestinationSlotId)

  if itemInSpatialIoPort then
    -- User is manually dialing, the item in my slot has the destination.
    remoteSide, remoteSlot = warp_common_getWorldSideAndSlot(spatialIoPortSide, (itemInMySlot or {}).label or "")
    if itemInSpatialIoPort.label ~= thisDestinationSlotId or not remoteSide or not remoteSlot then
      -- Fail, no storage cell or user put wrong one in spatialIoPort.
      computer.beep(200, 0.4)
      return
    end
  else
    -- Move my cell into spatial IO port and trigger it.
    local itemInRemoteSlot = transposer.getStackInSlot(remoteSide, remoteSlot)
    if (itemInMySlot or {}).label ~= thisDestinationSlotId or (itemInRemoteSlot or {}).label ~= targetDestinationSlotId or transposer.transferItem(mySide, spatialIoPortSide, 1, mySlot, 1) ~= 1 then
      -- Fail, someone is arriving at this teleporter or destination is busy.
      computer.beep(200, 0.4)
      return
    end
  end

  computer.beep(500, 0.1)
  computer.beep(700, 0.1)
  os.sleep(1.0)
  redstone.setOutput(sides.right, 15)
  os.sleep(0.1)
  redstone.setOutput(sides.right, 0)

  if not itemInSpatialIoPort then
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
      redstone.setOutput(sides.right, 15)
      os.sleep(0.1)
      redstone.setOutput(sides.right, 0)

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
      itemInMySlot = transposer.getStackInSlot(mySide, mySlot)
      if itemInMySlot and itemInMySlot.label == thisDestinationSlotId then
        warpSuccess = true
        break
      end
    end
    if not warpSuccess then
      -- Move my cell back into spatial IO port. We must continue aborting the warp even if this fails.
      transposer.transferItem(remoteSide, spatialIoPortSide, 1, remoteSlot, 1)
    end
  else
    assert(transposer.transferItem(spatialIoPortSide, spatialIoPortSide, 1, 2, 1) == 1)
  end

  if not warpSuccess then
    warp_common_playWarningSound()
    redstone.setOutput(sides.right, 15)
    os.sleep(0.1)
    redstone.setOutput(sides.right, 0)

    assert(transposer.transferItem(mySide, remoteSide, 1, mySlot, remoteSlot) == 1)
    assert(transposer.transferItem(spatialIoPortSide, mySide, 1, 2, mySlot) == 1)
  end
end


-- Find spatial IO port.
for i = 0, 5 do
  if string.match(transposer.getInventoryName(i) or "", settings.spatialIoPort) then
    spatialIoPortSide = i --[[@as Sides]]
  end
end
if not spatialIoPortSide then
  error("transposer cannot see spatial IO port")
end
if spatialIoPortSide == sides.down or spatialIoPortSide == sides.up then
  error("transposer must access spatial IO port on the side, not up or down (for direction finding)")
end

-- Main loop.
while true do
  local ev = {computer.pullSignal(settings.scanDelaySeconds)}

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

  -- Check if spatial IO port is empty. If it's not, the user is manually dialing the destination.
  local itemInSpatialIoPort
  for _, item in itemutil_invIterator(transposer.getAllStacks(spatialIoPortSide)) do
    itemInSpatialIoPort = item
  end

  if itemInMySlot and string.match(itemutil_getItemFullName(itemInMySlot), settings.spatialCellItem) and itemInMySlot.label ~= thisDestinationSlotId and not itemInSpatialIoPort then
    receiveWarp(mySide, mySlot, itemInMySlot)
  elseif ev[1] == "redstone_changed" and ev[3] ~= sides.right and ev[5] > 0 then
    startWarp(itemInMySlot, itemInSpatialIoPort)
  end
end
