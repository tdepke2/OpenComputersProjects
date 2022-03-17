local component = require("component")
local computer = require("computer")
local crobot = component.robot
local icontroller = component.inventory_controller
local sides = require("sides")

local robnav = require("robnav")

-- Maximum number of attempts for the Quarry:force* functions. If one of these
-- functions goes over the limit, the operation throws to indicate that the
-- robot is stuck. Having a limit is important so that the robot does not
-- continue to whittle down the equipped tool's health while whacking a mob with
-- a massive health pool.
local MAX_FORCE_OP_ATTEMPTS = 50


local ReturnReasons = {
  energyLow = 1,
  toolLow = 2,
  inventoryFull = 3,
  quarryDone = 4
}

-- Get the unique identifier of an item (internal name and metadata). This is
-- used for table indexing of items and such. Note that items with different NBT
-- can still resolve to the same identifier.
local function getItemFullName(item)
  return item.name .. "/" .. math.floor(item.damage) .. (item.hasTag and "n" or "")
end

-- FIXME these are the real iterators that should be used in storage.lua and related! still need to check if skipping empty is valid in the use cases there, and also the item/slot are swapped around. ####################################################################################################

-- Iterator wrapper for the itemIter returned from icontroller.getAllStacks().
-- Returns the current slot number and item with each call, skipping over empty
-- slots.
local function invIterator(itemIter)
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
  
  return iter, itemIter, 0
end

-- Iterator wrapper similar to invIterator(), but does not skip empty slots.
-- Returns the current slot number and item with each call.
local function invIteratorNoSkip(itemIter)
  local function iter(itemIter, slot)
    slot = slot + 1
    local item = itemIter()
    if item then
      return slot, item
    end
  end
  
  return iter, itemIter, 0
end

-- Iterator for scanning a device's internal inventory. For efficiency reasons,
-- the inventory size is passed in as this function blocks for a tick
-- (getStackInInternalSlot() is blocking too). Returns the current slot and item
-- with each call, skipping over empty slots.
local function internalInvIterator(invSize)
  local function iter(invSize, slot)
    local item
    while slot < invSize do
      slot = slot + 1
      item = icontroller.getStackInInternalSlot(slot)
      if item then
        return slot, item
      end
    end
  end
  
  return iter, invSize, 0
end


-- Quarry class definition.
local Quarry = {}

-- Hook up errors to throw on access to nil class members.
setmetatable(Quarry, {
  __index = function(t, k)
    dlog.errorWithTraceback("Attempt to read undefined member " .. tostring(k) .. " in Quarry class.")
  end
})

function Quarry:new(length, width, height)
  self.__index = self
  self = setmetatable({}, self)
  
  length = length or 1
  width = width or 1
  height = height or 1
  
  robnav.setCoords(0, 0, 0, sides.front)
  
  self.toolDurabilityReturn = 0.5
  self.toolDurabilityMin = 0.3
  self.energyLevelMin = 100
  self.emptySlotsMin = 1
  
  self.withinMainCoroutine = false
  self.selectedSlotType = 0
  self.inventoryInput = sides.back
  self.inventoryOutput = sides.right
  self.buildBlocks = {
    "minecraft:stone/0",
    "minecraft:cobblestone/0"
  }
  self.buildBlocksStockLevel = 2
  self.stairBlocks = {
    "minecraft:stone_stairs/0"
  }
  self.stairBlocksStockLevel = 1
  self.miningItems = {
    ".*pickaxe.*"
  }
  
  self.xDir = 1
  self.zDir = 1
  
  self.xMax = length - 1
  self.yMin = -height
  self.zMax = width - 1
  
  return self
end

function Quarry:selectBuildBlock()
  self.selectedSlotType = 1
  return false, "Ran out of building blocks"
end

function Quarry:selectStairBlock()
  self.selectedSlotType = 2
  return false, "Ran out of stair blocks"
end

-- Wrapper for robnav.move(), throws an exception on failure. Tries to clear
-- obstacles in the way (entities or blocks) until the movement succeeds or a
-- limit is reached.
function Quarry:forceMove(direction)
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelMin then
    coroutine.yield(ReturnReasons.energyLow)
  end
  local result, err = robnav.move(direction)
  if not result then
    for i = 1, MAX_FORCE_OP_ATTEMPTS do
      if err == "entity" or err == "solid" or err == "replaceable" or err == "passable" then
        self:forceSwing(direction)
      elseif self.withinMainCoroutine and computer.energy() <= self.energyLevelMin then
        coroutine.yield(ReturnReasons.energyLow)
      end
      result, err = robnav.move(direction)
      if result then
        return
      end
    end
    if err == "impossible move" then
      -- Impossible move can happen if the robot has reached a flight limitation, or tries to move into an unloaded chunk.
      assert(false, "Attempt to move failed with \"" .. err .. "\", a flight upgrade or chunkloader may be required.")
    else
      -- Other errors might be "not enough energy", etc.
      assert(false, "Attempt to move failed with \"" .. tostring(err) .. "\".")
    end
  end
end

-- Wrapper for robnav.turn(), throws an exception on failure.
function Quarry:forceTurn(clockwise)
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelMin then
    coroutine.yield(ReturnReasons.energyLow)
  end
  local result, err = robnav.turn(clockwise)
  assert(result, "Attempt to turn failed with \"" .. tostring(err) .. "\".")
end

-- Wrapper for crobot.swing(), throws an exception on failure. Protects the held
-- tool by swapping it out with currently selected inventory item if the
-- durability is too low. Returns boolean result and string message.
function Quarry:forceSwing(direction, side, sneaky)
  local result, msg
  if (crobot.durability() or 1.0) <= self.toolDurabilityMin then
    assert(icontroller.equip())
    result, msg = crobot.swing(direction, side, sneaky)
    assert(icontroller.equip())
  else
    result, msg = crobot.swing(direction, side, sneaky)
  end
  assert(result or (msg ~= "block" and msg ~= "replaceable" and msg ~= "passable"), "Attempt to swing tool failed, unable to break block.")
  if self.withinMainCoroutine then
    if computer.energy() <= self.energyLevelMin then
      coroutine.yield(ReturnReasons.energyLow)
    elseif (crobot.durability() or 1.0) <= self.toolDurabilityReturn then
      coroutine.yield(ReturnReasons.toolLow)
    elseif (self.emptySlotsMin > 0 and crobot.count(crobot.inventorySize() - self.emptySlotsMin + 1) > 0) or crobot.space(crobot.inventorySize() - self.emptySlotsMin) == 0 then
      coroutine.yield(ReturnReasons.inventoryFull)
    end
  end
  return result, msg
end

-- Wrapper for crobot.swing(), throws an exception on failure. Protects tool
-- like Quarry:forceSwing() does, and continues to try and mine the target block
-- while an entity is blocking the way.
function Quarry:forceMine(direction, side, sneaky)
  local _, msg = self:forceSwing(direction, side, sneaky)
  if msg == "entity" then
    for i = 1, MAX_FORCE_OP_ATTEMPTS do
      -- Sleep as there is an entity in the way and we need to wait for iframes to deplete.
      os.sleep(0.5)
      _, msg = self:forceSwing(direction, side, sneaky)
      if msg ~= "entity" then
        return
      end
    end
    assert(false, "Attempt to swing tool failed with message \"" .. tostring(msg) .. "\".")
  end
end

-- Wrapper for crobot.place(), throws an exception on failure. Tries to clear
-- obstacles in the way (entities or blocks) until the placement succeeds or a
-- limit is reached.
function Quarry:forcePlace(direction, side, sneaky)
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelMin then
    coroutine.yield(ReturnReasons.energyLow)
  end
  local result, err = crobot.place(direction, side, sneaky)
  if not result then
    for i = 1, MAX_FORCE_OP_ATTEMPTS do
      if err ~= "nothing selected" then
        self:forceSwing(direction)
        -- Sleep in case there is an entity in the way and we need to wait for iframes to deplete.
        os.sleep(0.5)
      elseif self.withinMainCoroutine and computer.energy() <= self.energyLevelMin then
        coroutine.yield(ReturnReasons.energyLow)
      end
      result, err = crobot.place(direction, side, sneaky)
      if result then
        return
      end
    end
    assert(false, "Attempt to place block failed with \"" .. tostring(err) .. "\".")
  end
end

function Quarry:layerMine()
  assert(false, "Quarry:layerMine() not implemented.")
end

function Quarry:layerTurn()
  assert(false, "Quarry:layerTurn() not implemented.")
end

function Quarry:layerDown()
  assert(false, "Quarry:layerDown() not implemented.")
end

function Quarry:quarryStart()
  
end

function Quarry:quarryMain()
  while true do
    self:layerMine()
    if (robnav.z == self.zMax and self.zDir == 1) or (robnav.z == 0 and self.zDir == -1) then
      if (robnav.x == self.xMax and self.xDir == 1) or (robnav.x == 0 and self.xDir == -1) then
        if robnav.y == self.yMin then
          return
        end
        self:layerDown()
        self.xDir = -self.xDir
      else
        local turnDir = self.zDir * self.xDir < 0
        self:layerTurn(turnDir)
      end
      self.zDir = -self.zDir
    else
      self:forceMove(sides.front)
    end
  end
end

function Quarry:quarryEnd()
  
end

function Quarry:run()
  local co = coroutine.create(function()
    self:quarryStart()
    --self:quarryMain()
    --self:quarryEnd()
    return ReturnReasons.quarryDone
  end)
  
  while true do
    self.withinMainCoroutine = true
    local status, ret = coroutine.resume(co)
    self.withinMainCoroutine = false
    assert(status, ret)
    
    -- Return to home position.
    local xLast, yLast, zLast, rLast = robnav.getCoords()
    local selectedSlotType = self.selectedSlotType
    if robnav.y < 0 then
      self:forceMove(sides.top)
    end
    if robnav.y < 0 then
      self:forceMove(sides.top)
    end
    robnav.turnTo(sides.back)
    while robnav.z > 0 do
      self:forceMove(sides.front)
    end
    robnav.turnTo(sides.right)
    while robnav.x > 0 do
      self:forceMove(sides.front)
    end
    while robnav.y < 0 do
      self:forceMove(sides.top)
    end
    
    --assert(false, print("ret = " , ReturnReasons.quarryDone))
    
    -- Transfer the target item stack to the first available slots in the range
    -- and add to stockedItems.
    local function addItemStock(stockedItems, firstSlot, lastSlot, itemName, srcSlot)
      print("addItemStock", itemName, srcSlot)
      while firstSlot <= lastSlot do
        if not stockedItems[firstSlot] or (crobot.space(firstSlot) > 0 and stockedItems[firstSlot] == itemName) then
          print("move item from", srcSlot, "to", firstSlot)
          crobot.select(srcSlot)
          crobot.transferTo(firstSlot)
          stockedItems[firstSlot] = itemName
          if firstSlot == srcSlot or not crobot.compareTo(firstSlot) then
            return
          end
        end
        firstSlot = firstSlot + 1
      end
    end
    
    local stockedItems = {}
    local internalInventorySize = crobot.inventorySize()
    
    -- Restock build/stair blocks by moving items to first slots in robot. Mark slots as blacklisted so we don't dump the items to output containers later.
    for slot, item in internalInvIterator(internalInventorySize) do
      local itemName = getItemFullName(item)
      local stockIndex = 0
      
      if self.buildBlocksStockLevel > 0 then
        for _, buildBlock in pairs(self.buildBlocks) do
          if string.match(itemName, buildBlock) then
            addItemStock(stockedItems, stockIndex + 1, stockIndex + self.buildBlocksStockLevel, itemName, slot)
            itemName = ""
            break
          end
        end
        stockIndex = stockIndex + self.buildBlocksStockLevel
      end
      
      if self.stairBlocksStockLevel > 0 then
        for _, stairBlock in pairs(self.stairBlocks) do
          if string.match(itemName, stairBlock) then
            addItemStock(stockedItems, stockIndex + 1, stockIndex + self.stairBlocksStockLevel, itemName, slot)
            itemName = ""
            break
          end
        end
        stockIndex = stockIndex + self.stairBlocksStockLevel
      end
    end
    
    -- Push remaining slots to output.
    robnav.turnTo(self.inventoryOutput)
    local outputSide = self.inventoryOutput < 2 and self.inventoryOutput or sides.front
    for slot = 1, internalInventorySize do
      if not stockedItems[slot] and crobot.count(slot) > 0 then
        print("drop item in slot", slot)
        crobot.select(slot)
        while not crobot.drop(outputSide) and crobot.count() > 0 do
          os.sleep(1.0)
          print("sleep...")
        end
      end
    end
    
    -- Push tool to output if too low.
    crobot.select(internalInventorySize)
    icontroller.equip()
    
    -- Grab more build/stair blocks as needed (from input).
    
    
    -- Grab new tool if needed.
    
    --if tool can be damaged:
    --durability = (maxDamage - damage) / maxDamage
    
    -- Sit at 0,0,0 to recharge.
    
    robnav.turnTo(sides.front)
    crobot.select(1)
    assert(false, "made it to end")
    
    -- Go back to working area.
    if selectedSlotType == 1  then
      assert(self:selectBuildBlock())
    elseif selectedSlotType == 2  then
      assert(self:selectStairBlock())
    end
    while robnav.y > yLast + 2 do
      self:forceMove(sides.bottom)
    end
    robnav.turnTo(sides.left)
    while robnav.x < xLast do
      self:forceMove(sides.front)
    end
    robnav.turnTo(sides.front)
    while robnav.z < zLast do
      self:forceMove(sides.front)
    end
    if robnav.y > yLast then
      self:forceMove(sides.bottom)
    end
    if robnav.y > yLast then
      self:forceMove(sides.bottom)
    end
    robnav.turnTo(rLast)
    assert(robnav.x == xLast and robnav.y == yLast and robnav.z == zLast and robnav.r == rLast)
  end
end

-- Basic quarry mines out the rectangular area and nothing more.
local BasicQuarry = Quarry:new()
function BasicQuarry:layerMine()
  if (robnav.z ~= self.zMax or self.zDir ~= 1) and (robnav.z ~= 0 or self.zDir ~= -1) then
    self:forceMine(sides.front)
  end
end
function BasicQuarry:layerTurn(turnDir)
  self:forceTurn(turnDir)
  self:forceMine(sides.front)
  self:forceMove(sides.front)
  self:forceTurn(turnDir)
end
function BasicQuarry:layerDown()
  self:forceMine(sides.bottom)
  self:forceMove(sides.bottom)
  self:forceTurn(true)
  self:forceTurn(true)
end
function BasicQuarry:quarryStart()
  self:forceMine(sides.bottom)
  self:forceMove(sides.bottom)
end

-- Fast quarry mines three layers at a time, may not clear all liquids.
local FastQuarry = Quarry:new()
function FastQuarry:layerMine()
  self:forceMine(sides.top)
  if (robnav.z ~= self.zMax or self.zDir ~= 1) and (robnav.z ~= 0 or self.zDir ~= -1) then
    self:forceMine(sides.front)
  end
  self:forceMine(sides.bottom)
end
function FastQuarry:layerTurn(turnDir)
  self:forceTurn(turnDir)
  self:forceMine(sides.front)
  self:forceMove(sides.front)
  self:forceTurn(turnDir)
end
function FastQuarry:layerDown()
  self:forceMove(sides.bottom)
  self:forceMine(sides.bottom)
  self:forceMove(sides.bottom)
  self:forceMine(sides.bottom)
  self:forceMove(sides.bottom)
  self:forceTurn(true)
  self:forceTurn(true)
end
function FastQuarry:quarryStart()
  self:forceMine(sides.bottom)
  self:forceMove(sides.bottom)
  if robnav.y <= self.yMin + 1 then
    FastQuarry.layerMine = BasicQuarry.layerMine
    FastQuarry.layerTurn = BasicQuarry.layerTurn
    FastQuarry.layerDown = BasicQuarry.layerDown
    FastQuarry.quarryMain = Quarry.quarryMain
  else
    self:forceMine(sides.bottom)
    self:forceMove(sides.bottom)
  end
end
function FastQuarry:quarryMain()
  local useBasicQuarryMain = false
  while true do
    self:layerMine()
    if (robnav.z == self.zMax and self.zDir == 1) or (robnav.z == 0 and self.zDir == -1) then
      if (robnav.x == self.xMax and self.xDir == 1) or (robnav.x == 0 and self.xDir == -1) then
        if robnav.y == self.yMin + (useBasicQuarryMain and 0 or 1) then
          return
        elseif not useBasicQuarryMain and robnav.y <= self.yMin + 3 then
          FastQuarry.layerMine = BasicQuarry.layerMine
          FastQuarry.layerTurn = BasicQuarry.layerTurn
          FastQuarry.layerDown = BasicQuarry.layerDown
          self:forceMove(sides.bottom)
          useBasicQuarryMain = true
        end
        self:layerDown()
        self.xDir = -self.xDir
      else
        local turnDir = self.zDir * self.xDir < 0
        self:layerTurn(turnDir)
      end
      self.zDir = -self.zDir
    else
      self:forceMove(sides.front)
    end
    --self.xLayer, self.yLayer, self.zLayer = robnav.getCoords()
  end
end

-- Fill floor quarry ensures a solid floor below each working layer, needed for
-- when a flight upgrade is not in use.
local FillFloorQuarry = Quarry:new()
function FillFloorQuarry:layerMine()
  
end
function FillFloorQuarry:layerTurn(turnDir)
  
end
function FillFloorQuarry:layerDown()
  
end

-- Fill wall quarry creates a solid wall at the borders of the rectangular area (keeps liquids out). Requires angel upgrade.
local FillWallQuarry = Quarry:new()
function FillWallQuarry:layerMine()
  
end
function FillWallQuarry:layerTurn(turnDir)
  
end
function FillWallQuarry:layerDown()
  
end


-- Get command-line arguments.
local args = {...}

local function main()
  io.write("Starting quarry!\n")
  local quarry = BasicQuarry:new(3, 2, 3)
  --local quarry = FastQuarry:new(3, 2, 3)
  
  quarry:run()
end

main()
