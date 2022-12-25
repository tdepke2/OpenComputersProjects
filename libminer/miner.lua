
local component = require("component")
local computer = require("computer")
local crobot = component.robot
local icontroller = component.inventory_controller
local sides = require("sides")

local include = require("include")
local dlog = include("dlog")
local config = include("config")
local enum = include("enum")
local itemutil = include("itemutil")
local robnav = include("robnav")


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


-- Create tables to describe the configuration format for the Miner. This is
-- used in conjunction with the config module to save/load/verify the
-- configuration.
-- 
---@return table cfgTypes
---@return table cfgFormat
---@nodiscard
function Miner.makeConfigTemplate()
  local cfgTypes = {
    Integer = {
      verify = function(v)
        xassert(type(v) == "number" and math.floor(v) == v, "provided Integer must not be a fractional number.")
      end
    },
  }
  local cfgFormat = {
    maxForceAttempts = {_order_ = 1, "Integer", 50, [[

Maximum number of attempts for the robot to clear an obstacle until it
considers it is stuck. Having a limit is important so that the robot does not
continue to whittle down the equipped tool's health while whacking a mob with
a massive health pool.]],
    },
    toolHealthReturn = {_order_ = 2, "Integer", 5, [[

The tool health (number of uses remaining) threshold for triggering the robot
to return to restock point. The return threshold is only considered if the
robot is out of spare tools.]],
    },
    toolHealthMin = {_order_ = 3, "Integer", 2, [[

The tool minimum health. Zero means only one use remains until the tool
breaks (which is good for keeping that precious unbreaking/efficiency/mending
diamond pickaxe for repairs later). If set to negative one, tools will be
used up completely.]],
    },
    toolHealthBias = {_order_ = 4, "Integer", 5, [[

Bias added to the health return/min values when robot is selecting new tools
during resupply (prevents selecting poor quality tools).]],
    },
    energyPerBlock = {_order_ = 5, "number", 26, [[

Estimate of the energy units consumed for the robot to move one block. This
is used to call the robot back to the resupply point if the energy required
to get back there is almost more than what the robot has available.

Assuming: basic screen and fully lit (1 energy/s), chunkloader active
(1.2 energy/s), runtime cost (0.5 energy/s), a little extra (0.5 energy/s),
robot uses 15 energy to move, and robot pauses 0.4s each movement.
Therefore, N blocks requires N * 15 energy/block + N * 0.4 s/block * 3.2
energy/s or 16.28 energy/block, which we arbitrarily round to 26 for safety.]],
    },
    emptySlotsMin = {_order_ = 6, "Integer", 1, [[

Minimum number of empty slots before robot needs to resupply. Setting this to
zero can allow all inventory slots to fill completely, but some items that
fail to stack with others in inventory will get lost.]],
    },
    generator = {
      _order_ = 7,
      _comment_ = [[

Settings for generator upgrade. These only apply if one or more generators
are installed in the robot.]],
      enableLevel = {_order_ = 1, "string|number", "80%", [[

Energy level for generators to kick in. This can be a number that specifies
the exact energy amount, or a string value with percent sign for a percentage
level.]],
      },
      batchSize = {_order_ = 2, "Integer", 2, [[

Number of items to insert into each generator at once. Set this higher if
using fuel with a low burn time.]],
      },
      batchInterval = {_order_ = 3, "Integer", 1600, [[

Number of ticks to wait in-between each batch before checking if the next one
can be sent. The generator functions just like a furnace burning fuel, so we
use the burn time of coal here.]],
      },
    },
    stockLevelsItems = {
      _order_ = 8,
      _comment_ = [[

Item name patterns (supports Lua string patterns, see
https://www.lua.org/manual/5.3/manual.html#6.4.1) for each type of item the
robot keeps stocked. These can be exact items too, like "minecraft:stone/5"
for andesite.]],
      mining = {
        _ipairs_ = {"string",
          ".*pickaxe.*",
        },
      },
      fuel = {
        _ipairs_ = {"string",
          "minecraft:coal/.*",
          "minecraft:coal_block/0",
        },
      },
    },
    stockLevelsMin = {
      _order_ = 9,
      _comment_ = [[

Minimum number of slots the robot must fill for each stock type during
resupply. Zeros are only allowed for consumable stock types that the robot
does not use for construction (like fuel and tools).]],
      mining = {"Integer", 0},
      fuel = {"Integer", 0},
    },
    stockLevelsMax = {
      _order_ = 10,
      _comment_ = [[

Maximum number of slots the robot will fill for each stock type during
resupply. Can be less than the minimum level, and a value of zero will skip
stocking items of that type.]],
      mining = {"Integer", 2},
      fuel = {"Integer", 1},
    },
  }
  return cfgTypes, cfgFormat
end


-- Creates a Miner instance. This provides safe wrappers for robot actions,
-- inventory and tool management, and utilizes robnav for navigation. The miner
-- is also able to cache the state it was in when a sudden resupply trip is
-- needed. To do this, miner functions should be run within a coroutine and the
-- `self.withinMainCoroutine` flag set accordingly before and after the
-- coroutine is resumed. When `self.withinMainCoroutine` is true, the coroutine
-- will yield with a value from `self.ReturnReasons` if a resupply event occurs.
-- 
---@param stockTypes Enum|nil
---@param cfg table|nil
---@return Miner
---@nodiscard
function Miner:new(stockTypes, cfg)
  self.__index = self
  self = setmetatable({}, self)
  
  -- Yield results from the coroutine that trigger the robot to return home (and
  -- the reason why).
  self.ReturnReasons = enum {
    "energyLow",
    "toolLow",
    "blocksLow",
    "inventoryFull",
    "minerDone"
  }
  
  -- Types of items the robot should keep in its inventory (tools, construction
  -- blocks, etc). All other items get dumped into the output inventory when
  -- robot returns home to resupply.
  self.StockTypes = stockTypes or enum {
    "mining", "fuel"
  }
  xassert(self.StockTypes.mining and self.StockTypes.fuel, "provided stockTypes enum must define \"mining\" and \"fuel\".")
  
  -- If config not provided, get the default values.
  ---@cast cfg -nil
  if not cfg then
    local _, cfgFormat = Miner.makeConfigTemplate()
    cfg = config.loadDefaults(cfgFormat)
  end
  self.cfg = cfg
  
  -- The following values are pulled straight from the config, see `Miner.makeConfigTemplate()` for descriptions.
  self.maxForceAttempts = cfg.maxForceAttempts
  self.toolHealthReturn = cfg.toolHealthReturn
  self.toolHealthMin = cfg.toolHealthMin
  self.toolHealthBias = cfg.toolHealthBias
  self.energyLevelReturn = cfg.energyPerBlock
  self.emptySlotsMin = cfg.emptySlotsMin
  self.generatorEnableLevel = cfg.generator.enableLevel
  if type(self.generatorEnableLevel) == "string" then
    if string.find(self.generatorEnableLevel, "%%") then
      self.generatorEnableLevel = tonumber((string.gsub(self.generatorEnableLevel, "%%", ""))) * 0.01 * computer.maxEnergy()
    else
      self.generatorEnableLevel = tonumber(self.generatorEnableLevel)
    end
  end
  self.generatorBatchSize = cfg.generator.batchSize
  self.generatorBatchInterval = cfg.generator.batchInterval
  
  -- Similar to tool health, but calculated as a float value in range [0, 1] per
  -- tool.
  self.toolDurabilityReturn = 0.0
  self.toolDurabilityMin = 0.0
  self.lastToolDurability = -1.0
  
  -- Suppresses self:updateGenerators() calls based on self.generatorBatchInterval.
  self.generatorBatchTimeout = 0
  
  -- Indicates if functions are running within a coroutine or not. The coroutine
  -- should be created and this value set by external code.
  self.withinMainCoroutine = false
  
  self.internalInventorySize = crobot.inventorySize()
  
  -- Collect all of the generators if the hardware is available.
  if component.isAvailable("generator") then
    self.generators = {}
    for address, _ in component.list("generator", true) do
      self.generators[address] = component.proxy(address)
    end
  else
    self.generators = false
  end
  
  --[[
  For each of the StockTypes, defines how many slots in the robot inventory will
  be partitioned for items of that type (zeros are allowed). These are tightly
  packed starting at the first slot in inventory.
  ```
  stockLevels = {
    [stock index] = {
      [1] = <number of slots>
      [2] = <item name pattern 1>
      ...
      [N] = <item name pattern N>
    }
    ...
  }
  ```
  ]]
  self.stockLevels = {}
  for i, v in ipairs(self.StockTypes) do
    local stockEntry = {cfg.stockLevelsMax[v]}
    for j, itemNamePattern in ipairs(cfg.stockLevelsItems[v]) do
      stockEntry[j + 1] = itemNamePattern
    end
    self.stockLevels[i] = stockEntry
  end
  dlog.out("Miner:new", "self.stockLevels:", self.stockLevels)
  xassert(#self.stockLevels == #self.StockTypes, "length of stockLevels and StockTypes must match (", #self.StockTypes, " expected, got ", #self.stockLevels, ")")
  
  -- For each of the StockTypes, defines the minimum number of slots that must
  -- contain items for that type before the robot can finish resupply. Note that
  -- zeros are only allowed for temporary stock types that the robot does not
  -- use for construction (like fuel and tools).
  self.stockLevelsMinimum = {}
  for i, v in ipairs(self.StockTypes) do
    self.stockLevelsMinimum[i] = cfg.stockLevelsMin[v]
  end
  dlog.out("Miner:new", "self.stockLevelsMinimum:", self.stockLevelsMinimum)
  xassert(#self.stockLevelsMinimum == #self.StockTypes, "length of stockLevelsMinimum and StockTypes must match (", #self.StockTypes, " expected, got ", #self.stockLevelsMinimum, ")")
  
  self.currentStockSlots = setmetatable({}, {
    __index = function() return {n = 0} end
  })
  self.selectedStockType = 0
  
  return self
end


-- Checks if items of the given StockTypes kind are currently available.
-- 
---@param stockType integer
---@return boolean
function Miner:isStockTypeAvailable(stockType)
  return self.currentStockSlots[stockType][1] ~= nil
end


-- Selects the next available slot (starting from the highest index) for one of
-- the StockTypes items. The special value zero just selects the first slot in
-- inventory. If required is true, this function will trigger a coroutine yield
-- if stock is not available so that the robot can run a trip to resupply.
-- Returns true if slot was available and selected, and false otherwise.
-- 
---@param stockType integer
---@param required boolean|nil
---@return boolean
function Miner:selectStockType(stockType, required)
  if stockType == 0 then
    crobot.select(1)
    self.selectedStockType = 0
    return true
  end
  -- Check if stock is empty and do coroutine yield here, because we better find that stock is available after resupply.
  if required and self.withinMainCoroutine and not self.currentStockSlots[stockType][1] then
    coroutine.yield(self.ReturnReasons.blocksLow)
    xassert(self.currentStockSlots[stockType][1], "unable to select stock type ", self.StockTypes[stockType], " after finishing resupply.")
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
  if self.selectedStockType == stockType then
    self.selectedStockType = 0
  end
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


-- Adds fuel to generators on the robot if generators and fuel are available,
-- and the current energy level drops below a threshold. Fuel gets added in a
-- batch because generators aren't very fast and we can't query how long the
-- fuel will last. We can only check how many items are queued up to burn in the
-- generator's inventory. The batch also helps ensure that each generator can
-- run with 100% uptime without constantly trying to count or insert fuel (both
-- are non-direct calls).
function Miner:updateGenerators()
  if not self.generators or not self:isStockTypeAvailable(self.StockTypes.fuel) or computer.energy() > self.generatorEnableLevel or self.generatorBatchTimeout > computer.uptime() then
    return
  end
  self.generatorBatchTimeout = computer.uptime() + self.generatorBatchInterval / 20.0
  local lastSelectedStockType = self.selectedStockType
  self:selectStockType(self.StockTypes.fuel)
  
  for _, generator in pairs(self.generators) do
    local batchAmount = self.generatorBatchSize - math.floor(generator.count())
    if batchAmount > 0 then
      local status, err = generator.insert(batchAmount)
      while not status do
        if string.find(err, "slot is empty") or string.find(err, "slot does not contain fuel") then
          self:stockSlotDepleted()
          if not self:selectStockType(self.StockTypes.fuel) then
            break
          end
        else
          dlog.out("Miner:updateGenerators", "Unable to insert fuel: ", err)
          break
        end
        status, err = generator.insert(batchAmount)
      end
      if not self:isStockTypeAvailable(self.StockTypes.fuel) then
        break
      end
    end
    dlog.out("Miner:updateGenerators", "batchAmount = ", batchAmount)
  end
  self:selectStockType(lastSelectedStockType, true)
end


-- Get robnav coordinates of the restock point. This is assumed to be at zero
-- all the time, override this function if that's not the case.
-- 
---@return integer x
---@return integer y
---@return integer z
---@return Sides r
---@nodiscard
function Miner:getRestockCoords()
  return 0, 0, 0, sides.front
end


-- Wrapper for robnav.move(), throws an exception on failure. Tries to clear
-- obstacles in the way (entities or blocks) until the movement succeeds or a
-- limit is reached.
-- 
---@param direction Sides
function Miner:forceMove(direction)
  computer.pullSignal(0)
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelReturn then
    coroutine.yield(self.ReturnReasons.energyLow)
  end
  local result, err = robnav.move(direction)
  
  -- Assuming we moved, recompute the energyLevelReturn based on the Manhattan distance to the restock point and cfg.energyPerBlock.
  local xOrigin, yOrigin, zOrigin = self:getRestockCoords()
  self.energyLevelReturn = self.cfg.energyPerBlock * (math.abs(robnav.x - xOrigin) + math.abs(robnav.y - yOrigin) + math.abs(robnav.z - zOrigin))
  self:updateGenerators()
  
  if not result then
    for i = 1, self.maxForceAttempts do
      if err == "entity" or err == "solid" or err == "replaceable" or err == "passable" then
        self:forceSwing(direction)
      elseif self.withinMainCoroutine and computer.energy() <= self.energyLevelReturn then
        coroutine.yield(self.ReturnReasons.energyLow)
      end
      result, err = robnav.move(direction)
      if result then
        return
      end
    end
    if err == "impossible move" then
      -- Impossible move can happen if the robot has reached a flight limitation, or tries to move into an unloaded chunk.
      xassert(false, "attempt to move failed with \"", err, "\", a flight upgrade or chunkloader may be required.")
    else
      -- Other errors might be "not enough energy", etc.
      xassert(false, "attempt to move failed with \"", err, "\".")
    end
  end
end


-- Wrapper for robnav.turn(), throws an exception on failure.
-- 
---@param clockwise boolean
function Miner:forceTurn(clockwise)
  computer.pullSignal(0)
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelReturn then
    coroutine.yield(self.ReturnReasons.energyLow)
  end
  local result, err = robnav.turn(clockwise)
  xassert(result, "attempt to turn failed with \"", err, "\".")
end


-- Helper function for updating the durability thresholds for a given itemstack.
-- 
---@param self Miner
---@param toolItem Item
local function computeDurabilityThresholds(self, toolItem)
  if toolItem.maxDamage > 0 then
    -- A small bias of half a health unit is added to deal with rounding errors.
    self.toolDurabilityReturn = (self.toolHealthReturn + 0.5) / toolItem.maxDamage
    self.toolDurabilityMin = (self.toolHealthMin + 0.5) / toolItem.maxDamage
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
  computer.pullSignal(0)
  local result, msg
  if self.lastToolDurability <= self.toolDurabilityMin and self.lastToolDurability ~= -1.0 then
    xassert(icontroller.equip())
    result, msg = crobot.swing(direction, side, sneaky)
    xassert(icontroller.equip())
  else
    result, msg = crobot.swing(direction, side, sneaky)
  end
  xassert(result or (msg ~= "block" and msg ~= "replaceable" and msg ~= "passable"), "attempt to swing tool failed, unable to break block.")
  self.lastToolDurability = equipmentDurability()
  
  -- Check if the current tool is almost/all used up and needs to be replaced.
  if self.lastToolDurability <= (self:isStockTypeAvailable(self.StockTypes.mining) and self.toolDurabilityMin or self.toolDurabilityReturn) then
    if self:isStockTypeAvailable(self.StockTypes.mining) then
      -- Select the next available mining tool, and swap it into the equipment slot.
      -- The old tool (now in current slot) gets removed from stock items.
      local lastSelectedStockType = self.selectedStockType
      self:selectStockType(self.StockTypes.mining)
      local toolItem = icontroller.getStackInInternalSlot()
      icontroller.equip()
      self:stockSlotDepleted()
      computeDurabilityThresholds(self, toolItem)
      self:selectStockType(lastSelectedStockType, true)
    elseif self.withinMainCoroutine then
      coroutine.yield(self.ReturnReasons.toolLow)
    end
  end
  
  if self.withinMainCoroutine then
    if computer.energy() <= self.energyLevelReturn then
      coroutine.yield(self.ReturnReasons.energyLow)
    elseif (self.emptySlotsMin > 0 and crobot.count(self.internalInventorySize - self.emptySlotsMin + 1) > 0) or crobot.space(self.internalInventorySize - self.emptySlotsMin) == 0 then
      coroutine.yield(self.ReturnReasons.inventoryFull)
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
function Miner:forceDig(direction, side, sneaky)
  local preSwingTime = computer.uptime()
  local _, msg = self:forceSwing(direction, side, sneaky)
  if msg == "entity" then
    for i = 1, self.maxForceAttempts do
      -- Sleep as there is an entity in the way and we need to wait for iframes to deplete.
      os.sleep(math.max(0.5 + preSwingTime - computer.uptime(), 0))
      preSwingTime = computer.uptime()
      _, msg = self:forceSwing(direction, side, sneaky)
      if msg ~= "entity" then
        return
      end
    end
    xassert(false, "attempt to swing tool failed with message \"", msg, "\".")
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
  if self.withinMainCoroutine and computer.energy() <= self.energyLevelReturn then
    coroutine.yield(self.ReturnReasons.energyLow)
  end
  local result, err = crobot.place(direction, side, sneaky)
  if not result then
    for i = 1, self.maxForceAttempts do
      if err == "nothing selected" then
        local stockSlots = self.currentStockSlots[self.selectedStockType]
        xassert(stockSlots[#stockSlots], "attempt to place block with nothing selected.")
        self:stockSlotDepleted()
        self:selectStockType(self.selectedStockType, true)
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
    xassert(false, "attempt to place block failed with \"", err, "\".")
  end
end


-- Sorts the items in the robot inventory to match the format defined in
-- `self.stockLevels` as close as possible. This behaves roughly like a
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
    if stockIndex == self.StockTypes.mining then
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
-- defined in `self.stockLevels`. If there is no equipped item then a new one is
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
        local stockEntry = self.stockLevels[self.StockTypes.mining]
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
      if stockIndex == self.StockTypes.mining then
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
-- 
---@param inputSide Sides
---@param outputSide Sides
function Miner:fullResupply(inputSide, outputSide)
  local stockedItems = self:itemRearrange()
  self:itemDeposit(stockedItems, outputSide)
  
  while true do
    self:itemRestock(stockedItems, inputSide)
    
    --[[
    Maps stock index to slots where the items appear in the internal inventory.
    ```
    currentStockSlots = {
      [stock index] = {
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
      if stockSlots.n < math.min(self.stockLevelsMinimum[stockIndex], stockEntry[1]) then
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

return Miner
