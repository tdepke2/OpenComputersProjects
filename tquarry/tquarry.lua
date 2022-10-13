--[[
todo:
  * convert the coroutine checks to a function? maybe nah
  * move iterators and item rearrange logic into separate module.
  * forceSwing()/forceMine() should swap pick with a fresh one.
  * toolDurabilityReturn could be set dynamically, based on the maxHealth and a fixed number of ticks we allow on the tool.
  * need to build staircase and walls if enabled.
  * load data from config file (and generate one if not found).
  * support for generators?
  * cache state to file (for current level) and prompt to pick up at that point so some state is remembered during sudden program halt?
  * dynamically compute energyLevelMin?

to test:
  * item restocking needs more testing
  * are tools always protected? if allowed, can tools be used completely (what about tinkers tools)?

issues:
  * May be able to prevent equipment swapping in restock function by using equipmentDurability().

potential problems:
  * Items that the robot is instructed to keep in inventory (blocks for building, tools, etc) that have unique NBT tags. Items with NBT are not handled well in general, because OC provides only limited support for these.
  * Tools that have durability values but don't record this in the damage metadata (for example, the tool may store durability in NBT tags).
  * Tools must all be strong enough to mine blocks in the way.
  * Tinker's tools?
]]--

local component = require("component")
local computer = require("computer")
local crobot = component.robot
local icontroller = component.inventory_controller
local sides = require("sides")

local dlog = require("dlog")
dlog.mode("debug")
dlog.osBlockNewGlobals(true)
local robnav = require("robnav")

-- Maximum number of attempts for the Quarry:force* functions. If one of these
-- functions goes over the limit, the operation throws to indicate that the
-- robot is stuck. Having a limit is important so that the robot does not
-- continue to whittle down the equipped tool's health while whacking a mob with
-- a massive health pool.
local MAX_FORCE_OP_ATTEMPTS = 50

-- Creates a new enumeration from a given table (matches keys to values and vice
-- versa). The given table is intended to use numeric keys and string values,
-- but doesn't have to be a sequence.
-- Based on: https://unendli.ch/posts/2016-07-22-enumerations-in-lua.html
local function enum(t)
  local result = {}
  for i, v in pairs(t) do
    result[i] = v
    result[v] = i
  end
  return result
end
-- FIXME shouldn't enum protect against invalid keys? #######################################################################

local ReturnReasons = enum {
  "energyLow",
  "toolLow",
  "blocksLow",
  "inventoryFull",
  "quarryDone"
}

local StockTypes = enum {
  "buildBlock",
  "stairBlock",
  "mining"
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
      if crobot.count(slot) > 0 then
        item = icontroller.getStackInInternalSlot(slot)
        if item then
          return slot, item
        end
      end
    end
  end
  
  return iter, invSize, 0
end

-- Wrapper for crobot.durability() to handle case of no tool and tools without
-- regular damage values. Returns -1.0 for no tool, and math.huge otherwise.
-- Note that this function is non-direct (blocks main thread), like other
-- inventory inspection operations.
local function equipmentDurability()
  local durability, err = crobot.durability()
  if durability then
    return durability
  elseif err == "no tool equipped" then
    return -1.0
  else
    return math.huge
  end
end


-- Quarry class definition.
local Quarry = {}

-- Hook up errors to throw on access to nil class members.
setmetatable(Quarry, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in Quarry class.", 2)
  end
})

function Quarry:new(length, width, height)
  self.__index = self
  self = setmetatable({}, self)
  
  length = length or 1
  width = width or 1
  height = height or 1
  
  robnav.setCoords(0, 0, 0, sides.front)
  
  -- The tool health (number of uses remaining) threshold for triggering the robot to return to restock point, and minimum allowed health.
  -- The return threshold is only considered if the robot is out of spare tools. Tools generally wear down to the minimum level (or if -1, the tool is used completely).
  self.toolHealthReturn = 5
  self.toolHealthMin = 0
  -- Bias added to self.toolHealthReturn/Min when robot is selecting new tools during resupply.
  self.toolHealthBias = 5
  -- Similar to tool health, but calculated as a float value in range [0, 1] per tool.
  self.toolDurabilityReturn = false
  self.toolDurabilityMin = false
  self.lastToolDurability = -1.0
  -- Minimum threshold on energy level before robot needs to resupply.
  self.energyLevelMin = 1000
  -- Minimum number of empty slots before robot needs to resupply.
  self.emptySlotsMin = 1
  
  self.withinMainCoroutine = false
  self.inventoryInput = sides.right
  self.inventoryOutput = sides.right
  --[[self.stockLevels = {
    {2, "minecraft:stone/0", "minecraft:cobblestone/0"},
    {1, "minecraft:stone_stairs/0"}
  }--]]
  -- Defines how slots in the robot inventory will be partitioned for items that the robot can use. These are tightly packed starting at the first slot in inventory.
  self.stockLevels = {
    {3, ".*stone/.*"},
    {3, ".*stairs/.*"},
    {2, ".*pickaxe.*"}
  }
  -- The minimum number of slots that must contain items for each stock type before the robot can finish resupply.
  -- Note that zeros are only allowed for temporary stock types that the robot does not use for construction (like fuel and tools).
  self.stockLevelsMinimum = {
    1,
    1,
    0
  }
  self.currentStockSlots = false
  self.selectedStockType = 0
  
  self.xDir = 1
  self.zDir = 1
  
  self.xMax = length - 1
  self.yMin = -height
  self.zMax = width - 1
  
  return self
end

-- Selects the next available slot (starting from the highest index) for one of
-- the StockTypes items. The special value zero just selects the first slot in
-- inventory. Returns true if slot was available and selected, and false
-- otherwise.
function Quarry:selectStockType(stockType)
  if stockType == 0 then
    crobot.select(1)
    self.selectedStockType = 0
    return true
  end
  if self.withinMainCoroutine and not self.currentStockSlots[stockType][1] then
    coroutine.yield(ReturnReasons.blocksLow)
  end
  local stockSlots = self.currentStockSlots[stockType]
  for i = #stockSlots, 1, -1 do
    if stockSlots[i] then
      crobot.select(stockSlots[i])
      self.selectedStockType = stockType
      return true
    end
    stockSlots[i] = nil
  end
  self.selectedStockType = 0
  return false
end

-- Marks a slot previously selected with Quarry:selectStockType() as empty. This
-- removes the slot from stock items tracking, and a new slot can be selected
-- with Quarry:selectStockType().
function Quarry:stockSlotDepleted()
  local stockSlots = self.currentStockSlots[self.selectedStockType]
  -- When a slot is selected, the last index in stockSlots is guaranteed to point to the active slot.
  xassert(self.selectedStockType > 0 and stockSlots[#stockSlots] == crobot.select())
  stockSlots[#stockSlots] = nil
  stockSlots.n = stockSlots.n - 1
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
      xassert(false, "Attempt to move failed with \"", err, "\", a flight upgrade or chunkloader may be required.")
    else
      -- Other errors might be "not enough energy", etc.
      xassert(false, "Attempt to move failed with \"", err, "\".")
    end
  end
end

-- Wrapper for robnav.turn(), throws an exception on failure.
function Quarry:forceTurn(clockwise)
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelMin then
    coroutine.yield(ReturnReasons.energyLow)
  end
  local result, err = robnav.turn(clockwise)
  xassert(result, "Attempt to turn failed with \"", err, "\".")
end

-- Helper function for updating the durability thresholds for a given itemstack.
local function computeDurabilityThresholds(self, toolItem)
  if toolItem.maxDamage > 0 then
    self.toolDurabilityReturn = self.toolHealthReturn / toolItem.maxDamage
    self.toolDurabilityMin = self.toolHealthMin / toolItem.maxDamage
    self.lastToolDurability = (toolItem.maxDamage - toolItem.damage) / toolItem.maxDamage
  else
    self.toolDurabilityReturn = 0.0
    self.toolDurabilityMin = 0.0
    self.lastToolDurability = math.huge
  end
end

-- Wrapper for crobot.swing(), throws an exception on failure. Protects the held
-- tool by swapping it out with currently selected inventory item if the
-- durability is too low. Returns boolean result and string message.
function Quarry:forceSwing(direction, side, sneaky)
  local result, msg
  if self.lastToolDurability <= self.toolDurabilityMin and self.lastToolDurability ~= -1.0 then
    xassert(icontroller.equip())
    result, msg = crobot.swing(direction, side, sneaky)
    xassert(icontroller.equip())
  else
    result, msg = crobot.swing(direction, side, sneaky)
  end
  xassert(result or (msg ~= "block" and msg ~= "replaceable" and msg ~= "passable"), "Attempt to swing tool failed, unable to break block.")
  local previousDurability = self.lastToolDurability
  self.lastToolDurability = equipmentDurability()
  
  -- Check if the current tool is almost/all used up and needs to be replaced.
  if self.lastToolDurability <= (self.currentStockSlots[StockTypes.mining][1] and self.toolDurabilityMin or self.toolDurabilityReturn) then
    if self.currentStockSlots[StockTypes.mining][1] then
      -- Select the next available mining tool, and swap it into the equipment slot.
      -- The old tool (now in current slot) gets removed from stock items.
      local lastSelectedStockType = self.selectedStockType
      self:selectStockType(StockTypes.mining)
      local toolItem = icontroller.getStackInInternalSlot()
      icontroller.equip()
      self:stockSlotDepleted()
      computeDurabilityThresholds(self, toolItem)
      self:selectStockType(lastSelectedStockType)
    elseif self.withinMainCoroutine then
      coroutine.yield(ReturnReasons.toolLow)
    end
  end
  
  if self.withinMainCoroutine then
    if computer.energy() <= self.energyLevelMin then
      coroutine.yield(ReturnReasons.energyLow)
    elseif (self.emptySlotsMin > 0 and crobot.count(crobot.inventorySize() - self.emptySlotsMin + 1) > 0) or crobot.space(crobot.inventorySize() - self.emptySlotsMin) == 0 then    -- FIXME: inventorySize() is a blocking function! ###################################
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
    xassert(false, "Attempt to swing tool failed with message \"", msg, "\".")
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
      if err == "nothing selected" then
        local stockSlots = self.currentStockSlots[self.selectedStockType]
        xassert(stockSlots[#stockSlots], "Attempt to place block with nothing selected.")
        self:stockSlotDepleted()
        self:selectStockType(self.selectedStockType)
      else
        self:forceSwing(direction)
        -- Sleep in case there is an entity in the way and we need to wait for iframes to deplete.
        os.sleep(0.5)
      end
      result, err = crobot.place(direction, side, sneaky)
      if result then
        return
      end
    end
    xassert(false, "Attempt to place block failed with \"", err, "\".")
  end
end

function Quarry:layerMine()
  xassert(false, "Quarry:layerMine() not implemented.")
end

function Quarry:layerTurn()
  xassert(false, "Quarry:layerTurn() not implemented.")
end

function Quarry:layerDown()
  xassert(false, "Quarry:layerDown() not implemented.")
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

-- Sorts the items in the robot inventory to match the format defined in
-- self.stockLevels as close as possible. This behaves roughly like a
-- stable-sort (based on selection sort to minimize swap operations). Returns a
-- table of stockedItems that tracks items in slots defined by the stock levels
-- (so they don't get dumped into storage in the following operations).
function Quarry:itemRearrange()
  local internalInventorySize = crobot.inventorySize()
  local internalInvItems = {}
  
  -- First pass scans internal inventory and categorizes each item by stock type.
  for slot, item in internalInvIterator(internalInventorySize) do
    local itemName = getItemFullName(item)
    local stockIndex = -1
    for i, stockEntry in ipairs(self.stockLevels) do
      if stockEntry[1] > 0 then
        for j = 2, #stockEntry do
          if string.match(itemName, stockEntry[j]) then
            stockIndex = i
            break
          end
        end
        if stockIndex > 0 then
          break
        end
      end
    end
    -- If found a mining tool and the durability is less than acceptable, mark the stockIndex as invalid.
    if stockIndex == StockTypes.mining then
      if item.maxDamage > 0 and item.maxDamage - item.damage <= self.toolHealthMin + self.toolHealthBias then
        stockIndex = -1
      end
    end
    internalInvItems[slot] = {
      itemName = itemName,
      stockIndex = stockIndex
    }
  end
  
  dlog.out("itemRearrange", "internalInvItems:", internalInvItems)
  
  -- Second pass iterates only the slots used for stocking items and does the sorting.
  local stockedItems = {}
  local slot = 1
  for stockIndex, stockEntry in ipairs(self.stockLevels) do
    for i = 1, stockEntry[1] do
      local lastItemName
      if internalInvItems[slot] and internalInvItems[slot].stockIndex == stockIndex then
        lastItemName = internalInvItems[slot].itemName
        stockedItems[slot] = lastItemName
      end
      while true do
        -- Find the first item in internal inventory that should be transferred into the current slot.
        local foundSlot
        for j = 1, internalInventorySize do
          if internalInvItems[j] and internalInvItems[j].stockIndex == stockIndex and not stockedItems[j] and (lastItemName == nil or internalInvItems[j].itemName == lastItemName) then
            foundSlot = j
            break
          end
        end
        -- If the item could not be found or there is not enough space, we're done.
        if not foundSlot or (lastItemName and crobot.space(slot) == 0) then
          break
        end
        
        -- Transfer the item stack, and update internalInvItems.
        lastItemName = internalInvItems[foundSlot].itemName
        crobot.select(foundSlot)
        -- We should always be able to transfer the items, except if they are both tools of the same type then the operation fails.
        -- It's possible to handle this by moving the duplicate tool elsewhere, but ignoring the problem until later should be fine.
        if crobot.transferTo(slot) then
          stockedItems[slot] = lastItemName
          internalInvItems[slot], internalInvItems[foundSlot] = internalInvItems[foundSlot], internalInvItems[slot]
        end
        if crobot.count(foundSlot) == 0 then
          internalInvItems[foundSlot] = nil
        end
      end
      slot = slot + 1
    end
  end
  
  dlog.out("itemRearrange", "internalInvItems:", internalInvItems)
  dlog.out("itemRearrange", "stockedItems:", stockedItems)
  
  --[[
  stockedItems = {
    [slot] = <item full name>
    ...
  }
  --]]
  
  return stockedItems
end

-- Dumps each item in robot inventory to the specified side. The currently
-- equipped item is dumped too if durability is low.
function Quarry:itemDeposit(stockedItems, outputSide)
  local internalInventorySize = crobot.inventorySize()
  robnav.turnTo(outputSide)
  outputSide = outputSide < 2 and outputSide or sides.front
  
  -- Push remaining slots to output.
  for slot = 1, internalInventorySize do
    if not stockedItems[slot] and crobot.count(slot) > 0 then
      dlog.out("itemDeposit", "drop item in slot ", slot)
      crobot.select(slot)
      crobot.drop(outputSide)
      while crobot.count() > 0 do
        os.sleep(2.0)
        dlog.out("itemDeposit", "sleep...")
        crobot.drop(outputSide)
      end
    end
  end
  
  -- Push tool to output if too low.
  -- We pull the tool out of equipped slot to check if there's actually something there and it has measurable durability.
  crobot.select(internalInventorySize)
  icontroller.equip()
  local toolItem = icontroller.getStackInInternalSlot()
  if toolItem and toolItem.maxDamage > 0 and toolItem.maxDamage - toolItem.damage <= self.toolHealthReturn + self.toolHealthBias then
    crobot.drop(outputSide)
    while crobot.count() > 0 do
      os.sleep(2.0)
      dlog.out("itemDeposit", "sleep...")
      crobot.drop(outputSide)
    end
  end
  icontroller.equip()
end

-- Retrieve items from the specified side and fill slots that match the format
-- defined in self.stockLevels. If there is no equipped item then a new one is
-- picked up that meets the minimum durability requirement.
function Quarry:itemRestock(stockedItems, inputSide)
  local internalInventorySize = crobot.inventorySize()
  robnav.turnTo(inputSide)
  inputSide = inputSide < 2 and inputSide or sides.front
  
  -- Categorize items in the input inventory based on their full name (and track which slots they are stored in).
  -- Note that we could skip storing items that don't have a valid stockIndex, but then we need to search for the category each time one of those items appears.
  local inputItems = {}
  for slot, item in invIterator(icontroller.getAllStacks(inputSide)) do
    local itemName = getItemFullName(item)
    local inputItemSlots = inputItems[itemName]
    if not inputItemSlots then
      -- The first time an item type is found, search for its index in the stock levels.
      local stockIndex = -1
      for i, stockEntry in ipairs(self.stockLevels) do
        if stockEntry[1] > 0 then
          for j = 2, #stockEntry do
            if string.match(itemName, stockEntry[j]) then
              stockIndex = i
              break
            end
          end
          if stockIndex > 0 then
            break
          end
        end
      end
      -- If found a mining tool and the durability is less than acceptable, mark the stockIndex as invalid.
      -- This shouldn't cause problems if the inventory has two of the same tools with different durability levels, because the two tools will get mapped to different names (metadata is damage value).
      if stockIndex == StockTypes.mining then
        if item.maxDamage > 0 and item.maxDamage - item.damage <= self.toolHealthMin + self.toolHealthBias then
          stockIndex = -1
        end
      end
      inputItems[itemName] = {
        stockIndex = stockIndex,
        [slot] = math.floor(item.size)
      }
    else
      inputItemSlots[slot] = math.floor(item.size)
    end
  end
  
  --[[
  inputItems = {
    [item full name] = {
      stockIndex = <index in self.stockLevels>
      [slot] = <item count in slot>
      ...
    }
    ...
  }
  --]]
  
  dlog.out("itemRestock", "inputItems before:", inputItems)
  
  for slot = 1, internalInventorySize do
    -- Determine the entry in self.stockLevels that corresponds to the current slot.
    local slotStockIndex = -1
    local slotOffset = 0
    for i, stockEntry in ipairs(self.stockLevels) do
      slotOffset = slotOffset + stockEntry[1]
      if slotOffset >= slot then
        slotStockIndex = i
        break
      end
    end
    if slotStockIndex == -1 then
      break
    end
    
    dlog.out("itemRestock", "checking slot ", slot, " with stock index ", slotStockIndex)
    
    if crobot.space(slot) > 0 then
      -- Find the slots for the type of item we need to extract from the inventory. Use the same item in the current slot, or the first one that matches the option at slotStockIndex.
      local currentItemName
      local inputItemSlots
      if crobot.count(slot) > 0 then
        -- There is an item in the slot, so it should already be in stockedItems (and we can skip expensive call to check the item stack).
        currentItemName = stockedItems[slot]
        inputItemSlots = inputItems[currentItemName]
      else
        for itemName, itemSlots in pairs(inputItems) do
          if itemSlots.stockIndex == slotStockIndex then
            currentItemName = itemName
            inputItemSlots = itemSlots
            break
          end
        end
      end
      
      -- Continuously suck items from first available slot until full or none left.
      if inputItemSlots then
        dlog.out("itemRestock", "inputItemSlots:", inputItemSlots)
        stockedItems[slot] = currentItemName
        crobot.select(slot)
        local externSlot = next(inputItemSlots)
        if type(externSlot) == "string" then
          externSlot = next(inputItemSlots, externSlot)
        end
        while crobot.space(slot) > 0 do
          local numTransferred = icontroller.suckFromSlot(inputSide, externSlot, crobot.space(slot))
          xassert(numTransferred)
          inputItemSlots[externSlot] = inputItemSlots[externSlot] - numTransferred
          if inputItemSlots[externSlot] <= 0 then
            -- Slot is empty, delete it and find the next one (if we can).
            inputItemSlots[externSlot] = nil
            externSlot = next(inputItemSlots)
            if type(externSlot) == "string" then
              externSlot = next(inputItemSlots, externSlot)
            end
            if externSlot == nil then
              inputItems[currentItemName] = nil
              break
            end
          end
        end
      end
    end
  end
  dlog.out("itemRestock", "inputItems after:", inputItems)
  dlog.out("itemRestock", "stockedItems finalized:", stockedItems)
  
  -- Grab new tool if nothing is equipped.
  crobot.select(internalInventorySize)
  icontroller.equip()
  local toolItem = icontroller.getStackInInternalSlot()
  if not toolItem then
    local bestToolSlot = -1
    local bestToolHealth = -1
    while true do
      -- Check all items in input inventory for the highest durability tool that matches a mining item type.
      for slot, item in invIterator(icontroller.getAllStacks(inputSide)) do
        local itemName = getItemFullName(item)
        local health
        local stockEntry = self.stockLevels[StockTypes.mining]
        for i = 2, #stockEntry do
          if string.match(itemName, stockEntry[i]) then
            health = item.maxDamage > 0 and item.maxDamage - item.damage or math.huge
            break
          end
        end
        if health and health > self.toolHealthReturn + self.toolHealthBias and health > bestToolHealth then
          bestToolSlot = slot
          bestToolHealth = health
          toolItem = item
        end
      end
      if bestToolSlot ~= -1 then
        break
      end
      os.sleep(2.0)
      dlog.out("itemRestock", "waiting for mining tool...")
    end
    
    xassert(icontroller.suckFromSlot(inputSide, bestToolSlot))
  end
  icontroller.equip()
  
  -- Find the damage values for the corresponding health levels.
  computeDurabilityThresholds(self, toolItem)
end

-- Performs a rearrangement of items, deposits excess, and pulls in new ones to
-- match the set stock levels. The equipped tool is replaced with a fresh one if
-- necessary.
function Quarry:fullResupply()
  local stockedItems = self:itemRearrange()
  self:itemDeposit(stockedItems, self.inventoryOutput)
  
  while true do
    self:itemRestock(stockedItems, self.inventoryInput)
    
    --[[
    currentStockSlots = {
      [1] = {
        [1] = <first slot>
        [2] = <second slot, or false if empty>
        [3] = <third slot, or false if empty>
        ...
        [N] = <last slot, or false if empty>
        n = <total number of slots with items>
      }
      ...
    }
    --]]
    
    -- Populate the currentStockSlots table with information from stockedItems. This keeps track of the next available slots in the internal inventory where stock items can be pulled.
    -- It is also fast to check if more stock items are available by checking the first index for a given stock item type (as stock items deplete, they get removed from the greatest index first).
    self.currentStockSlots = {}
    local slot = 1
    local minimumLevelsReached = true
    for stockIndex, stockEntry in ipairs(self.stockLevels) do
      local stockSlots = {n = 0}
      self.currentStockSlots[stockIndex] = stockSlots
      for i = 1, stockEntry[1] do
        if stockedItems[slot] then
          stockSlots[#stockSlots + 1] = slot
          stockSlots.n = stockSlots.n + 1
        elseif stockSlots[1] then
          stockSlots[#stockSlots + 1] = false
        end
        slot = slot + 1
      end
      if stockSlots.n < self.stockLevelsMinimum[stockIndex] then
        minimumLevelsReached = false
      end
    end
    
    if minimumLevelsReached then
      break
    end
    
    os.sleep(2.0)
    dlog.out("fullResupply", "waiting for more items...")
  end
  dlog.out("fullResupply", "self.currentStockSlots:", self.currentStockSlots)
  
  crobot.select(1)
  robnav.turnTo(sides.front)
end

function Quarry:run()
  local co = coroutine.create(function()
    self:quarryStart()
    self:quarryMain()
    self:quarryEnd()
    return ReturnReasons.quarryDone
  end)
  
  self:fullResupply()
  
  while true do
    self.withinMainCoroutine = true
    local status, ret = coroutine.resume(co)
    self.withinMainCoroutine = false
    if not status then
      error(ret)
    end
    dlog.out("run", "return reason = ", ReturnReasons[ret])
    
    -- Return to home position.
    dlog.out("run", "moving to home position.")
    local xLast, yLast, zLast, rLast = robnav.getCoords()
    local lastSelectedStockType = self.selectedStockType
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
    
    if ret == ReturnReasons.quarryDone then
      self:itemDeposit({}, self.inventoryOutput)
      crobot.select(1)
      robnav.turnTo(sides.front)
      io.write("Quarry finished!\n")
      return
    end
    
    self:fullResupply()
    
    -- Wait until fully recharged.
    while computer.maxEnergy() - computer.energy() > 50 do
      os.sleep(2.0)
      dlog.out("run", "waiting for energy...")
    end
    
    -- Go back to working area.
    dlog.out("run", "moving back to working position.")
    self:selectStockType(lastSelectedStockType)
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
    xassert(robnav.x == xLast and robnav.y == yLast and robnav.z == zLast and robnav.r == rLast)
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


local function main(...)
  -- Get command-line arguments.
  local args = {...}
  
  io.write("Starting quarry!\n")
  --local quarry = BasicQuarry:new(6, 6, 8)
  local quarry = BasicQuarry:new(3, 3, 3)
  --local quarry = FastQuarry:new(3, 2, 3)
  
  quarry:run()
end

dlog.handleError(xpcall(main, debug.traceback, ...))
dlog.osBlockNewGlobals(false)
