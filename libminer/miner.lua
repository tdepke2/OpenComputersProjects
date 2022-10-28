
local component = require("component")
local computer = require("computer")
local crobot = component.robot
local icontroller = component.inventory_controller
local sides = require("sides")

local include = require("include")
local dlog = include("dlog")
dlog.mode("debug")
dlog.osBlockNewGlobals(true)
local enum = include("enum")
local itemutil = include("itemutil")
local robnav = include("robnav")
local xassert = dlog.xassert    -- this may be a good idea to do from now on? ###########################################################

-- Maximum number of attempts for the Miner:force* functions. If one of these
-- functions goes over the limit, the operation throws to indicate that the
-- robot is stuck. Having a limit is important so that the robot does not
-- continue to whittle down the equipped tool's health while whacking a mob with
-- a massive health pool.
local MAX_FORCE_OP_ATTEMPTS = 50

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

-- Wrapper for crobot.durability() to handle case of no tool and tools without
-- regular damage values. Returns -1.0 for no tool, and math.huge otherwise.
-- Note that this function is non-direct (blocks main thread), like other
-- inventory inspection operations.
-- 
---@return number durability
---@nodiscard
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


-- Miner class definition.
---@class Miner
local Miner = {}

-- Hook up errors to throw on access to nil class members.
setmetatable(Miner, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in Miner class.", 2)
  end
})

-- Construct a new Miner object with the given length, width, and height mining
-- dimensions. These correspond to the positive-x, positive-z, and negative-y
-- dimensions with the robot facing in the positive-z direction.
-- 
---@param length integer|nil
---@param width integer|nil
---@param height integer|nil
---@return Miner
function Miner:new(length, width, height)
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
  self.internalInventorySize = crobot.inventorySize()
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
-- 
---@param stockType integer
---@return boolean
function Miner:selectStockType(stockType)
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

-- Marks a slot previously selected with Miner:selectStockType() as empty. This
-- removes the slot from stock items tracking, and a new slot can be selected
-- with Miner:selectStockType().
function Miner:stockSlotDepleted()
  local stockSlots = self.currentStockSlots[self.selectedStockType]
  -- When a slot is selected, the last index in stockSlots is guaranteed to point to the active slot.
  xassert(self.selectedStockType > 0 and stockSlots[#stockSlots] == crobot.select())
  stockSlots[#stockSlots] = nil
  stockSlots.n = stockSlots.n - 1
end

-- Wrapper for robnav.move(), throws an exception on failure. Tries to clear
-- obstacles in the way (entities or blocks) until the movement succeeds or a
-- limit is reached.
-- 
---@param direction Sides
function Miner:forceMove(direction)
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
-- 
---@param clockwise boolean
function Miner:forceTurn(clockwise)
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelMin then
    coroutine.yield(ReturnReasons.energyLow)
  end
  local result, err = robnav.turn(clockwise)
  xassert(result, "Attempt to turn failed with \"", err, "\".")
end

-- Helper function for updating the durability thresholds for a given itemstack.
-- 
---@param self Miner
---@param toolItem Item
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
-- 
---@param direction Sides
---@param side Sides|nil
---@param sneaky boolean|nil
---@return boolean result
---@return string|nil message
function Miner:forceSwing(direction, side, sneaky)
  local result, msg
  if self.lastToolDurability <= self.toolDurabilityMin and self.lastToolDurability ~= -1.0 then
    xassert(icontroller.equip())
    result, msg = crobot.swing(direction, side, sneaky)
    xassert(icontroller.equip())
  else
    result, msg = crobot.swing(direction, side, sneaky)
  end
  xassert(result or (msg ~= "block" and msg ~= "replaceable" and msg ~= "passable"), "Attempt to swing tool failed, unable to break block.")
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
    elseif (self.emptySlotsMin > 0 and crobot.count(self.internalInventorySize - self.emptySlotsMin + 1) > 0) or crobot.space(self.internalInventorySize - self.emptySlotsMin) == 0 then
      coroutine.yield(ReturnReasons.inventoryFull)
    end
  end
  return result, msg
end

-- Wrapper for crobot.swing(), throws an exception on failure. Protects tool
-- like Miner:forceSwing() does, and continues to try and mine the target block
-- while an entity is blocking the way.
-- 
---@param direction Sides
---@param side Sides|nil
---@param sneaky boolean|nil
function Miner:forceMine(direction, side, sneaky)
  local preSwingTime = computer.uptime()
  local _, msg = self:forceSwing(direction, side, sneaky)
  if msg == "entity" then
    for i = 1, MAX_FORCE_OP_ATTEMPTS do
      -- Sleep as there is an entity in the way and we need to wait for iframes to deplete.
      os.sleep(math.max(0.5 + preSwingTime - computer.uptime(), 0))
      preSwingTime = computer.uptime()
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
-- 
---@param direction Sides
---@param side Sides|nil
---@param sneaky boolean|nil
function Miner:forcePlace(direction, side, sneaky)
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
        local preSwingTime = computer.uptime()
        self:forceSwing(direction)
        -- Sleep in case there is an entity in the way and we need to wait for iframes to deplete.
        os.sleep(math.max(0.5 + preSwingTime - computer.uptime(), 0))
      end
      result, err = crobot.place(direction, side, sneaky)
      if result then
        return
      end
    end
    xassert(false, "Attempt to place block failed with \"", err, "\".")
  end
end

-- Sorts the items in the robot inventory to match the format defined in
-- self.stockLevels as close as possible. This behaves roughly like a
-- stable-sort (based on selection sort to minimize swap operations). Returns a
-- table of stockedItems that tracks items in slots defined by the stock levels
-- (so they don't get dumped into storage in the following operations).
-- 
---@return StockedItems stockedItems
function Miner:itemRearrange()
  local internalInvItems = {}
  
  -- First pass scans internal inventory and categorizes each item by stock type.
  for slot, item in itemutil.internalInvIterator(self.internalInventorySize) do
    local itemName = itemutil.getItemFullName(item)
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
  
  ---@alias StockedItems table<integer, ItemFullName> Maps inventory slots to item names.
  ---@type StockedItems
  local stockedItems = {}
  
  -- Second pass iterates only the slots used for stocking items and does the sorting.
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
        for j = 1, self.internalInventorySize do
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
  
  return stockedItems
end


-- Dumps each item in robot inventory to the specified side. The currently
-- equipped item is dumped too if durability is low.
-- 
---@param stockedItems StockedItems
---@param outputSide Sides
function Miner:itemDeposit(stockedItems, outputSide)
  robnav.turnTo(outputSide)
  outputSide = outputSide < 2 and outputSide or sides.front
  
  -- Push remaining slots to output.
  for slot = 1, self.internalInventorySize do
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
  crobot.select(self.internalInventorySize)
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
-- 
---@param stockedItems StockedItems
---@param inputSide Sides
function Miner:itemRestock(stockedItems, inputSide)
  robnav.turnTo(inputSide)
  inputSide = inputSide < 2 and inputSide or sides.front
  
  -- Grab new tool if nothing is equipped.
  crobot.select(self.internalInventorySize)
  icontroller.equip()
  local toolItem = icontroller.getStackInInternalSlot()
  if not toolItem then
    local bestToolSlot = -1
    local bestToolHealth = -1
    while true do
      -- Check all items in input inventory for the highest durability tool that matches a mining item type.
      for slot, item in itemutil.invIterator(icontroller.getAllStacks(inputSide)) do
        local itemName = itemutil.getItemFullName(item)
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
  
  --[[
  Maps item names to their locations in the input inventory.
  ```
  inputItems = {
    [item full name] = {
      stockIndex = <index in self.stockLevels>
      [slot] = <item count in slot>
      ...
    }
    ...
  }
  ```
  ]]
  local inputItems = {}
  
  -- Categorize items in the input inventory based on their full name (and track which slots they are stored in).
  -- Note that we could skip storing items that don't have a valid stockIndex, but then we need to search for the category each time one of those items appears.
  for slot, item in itemutil.invIterator(icontroller.getAllStacks(inputSide)) do
    local itemName = itemutil.getItemFullName(item)
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
  
  dlog.out("itemRestock", "inputItems before:", inputItems)
  
  for slot = 1, self.internalInventorySize do
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
end

-- Performs a rearrangement of items, deposits excess, and pulls in new ones to
-- match the set stock levels. The equipped tool is replaced with a fresh one if
-- necessary.
function Miner:fullResupply()
  local stockedItems = self:itemRearrange()
  self:itemDeposit(stockedItems, self.inventoryOutput)
  
  while true do
    self:itemRestock(stockedItems, self.inventoryInput)
    
    --[[
    Maps stock index to slots where the items appear in the internal inventory.
    ```
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
    ```
    ]]
    self.currentStockSlots = {}
    
    -- Populate the currentStockSlots table with information from stockedItems. This keeps track of the next available slots in the internal inventory where stock items can be pulled.
    -- It is also fast to check if more stock items are available by checking the first index for a given stock item type (as stock items deplete, they get removed from the greatest index first).
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
