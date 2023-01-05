--[[
todo:
  track data for number of blocks mined? pickaxes used?

done:
  * convert the coroutine checks to a function? maybe nah
  * move iterators and item rearrange logic into separate module.
  * need to build staircase and walls if enabled.
  * load data from config file (and generate one if not found).
  * dynamically compute energyLevelMin?
  * support for generators?
  * do not stock building blocks if we are not building anything
  * cache state to file and prompt to pick up at that point so some state is remembered during sudden program halt.
  * config option to use generators only, ignore any chargers. also should have robot wait for energy to fill completely at start.
  * show robot status with setLightColor().

to test:
  * 

issues:
  * 

potential problems:
  * Items that the robot is instructed to keep in inventory (blocks for building, tools, etc) that have unique NBT tags. Items with NBT are not handled well in general, because OC provides only limited support for these.
  * Tools that have durability values but don't record this in the damage metadata (for example, the tool may store durability in NBT tags).
  * Tools must all be strong enough to mine blocks in the way.
  * Tinker's tools? These show durability values where a zero means the tool is broken. To handle them, just set toolHealthMin to zero.
    * Small correction: a wooden pickaxe (and possibly other self-healing tools) sometimes breaks at 1 durability. To be safe, set toolHealthMin a bit above zero.

future work:
  * option for 3 x 3 mining tools? this could be tricky to make sure all of the blocks get mined, might require a geolyzer to scan area.
  * currently all mining tools are considered the same, but we could use specific tools depending on the material to dig (shovels and axes). an easy solution is to always use multi-purpose tools like a paxel or AIOT, but these are provided by other mods. other options could be predicting the tool to use based on a geolyzer hardness scan, or measure the time taken to mine a block and decide if another tool should be attempted.
  * we could get a bit more speed by suppressing some of the durability checks done in Miner:forceSwing(). for example, if lastToolDurability > toolDurabilityReturn * 2.0 then count every toolHealthReturn ticks before sampling the durability.
  * the CrashHandler is far from perfect, and has required that a lot of functionality be replaced with ugly state machines. maybe there is a better way to implement this? it seems like a general problem of caching the current program state (call stack and everything) and returning to this later.
--]]


local component = require("component")
local computer = require("computer")
local crobot = component.robot
local event = require("event")
local filesystem = require("filesystem")
local icontroller = component.inventory_controller
local keyboard = require("keyboard")
local serialization = require("serialization")
local shell = require("shell")
local sides = require("sides")
local term = require("term")

local include = require("include")
local dlog = include("dlog")
dlog.mode("env", "/tmp/tquarry.log")
dlog.osBlockNewGlobals(true)

local config = include("config")
local enum = include("enum")
local miner = include("miner")
local robnav = include("robnav")


-- Quarry states used by Quarry:run().
local QuarryStatus = enum {
  "init",
  "working",
  "resupply",
  "returnToWork",
}


-- Quarry class definition.
---@class Quarry
local Quarry = {}

-- Hook up errors to throw on access to nil class members.
setmetatable(Quarry, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in Quarry class.", 2)
  end
})


-- Create tables to describe the configuration format. This is used in
-- conjunction with the config module to save/load/verify the configuration.
-- 
---@return table cfgTypes
---@return table cfgFormat
---@nodiscard
function Quarry.makeConfigTemplate()
  local cfgTypes, minerCfgFormat = miner.makeConfigTemplate()
  cfgTypes.Sides = {
    "bottom", "top", "back", "front", "right", "left"
  }
  cfgTypes.QuarryType = {
    "Basic", "Fast", "FillFloor", "FillWall", "MoveTest"
  }
  
  -- Configure new stock types we add in addition to the mining and fuel types.
  minerCfgFormat._order_ = 1
  minerCfgFormat.stockLevelsItems.buildBlock = {
    _order_ = 1,
    _ipairs_ = {"string",
      ".*stone/.*",
      ".*dirt/.*",
    },
  }
  minerCfgFormat.stockLevelsItems.stairBlock = {
    _order_ = 2,
    _ipairs_ = {"string",
      ".*stairs/.*",
    },
  }
  minerCfgFormat.stockLevelsItems.mining._order_ = 3
  minerCfgFormat.stockLevelsItems.fuel._order_ = 4
  
  minerCfgFormat.stockLevelsMin.buildBlock = {_order_ = 1, "Integer", 1}
  minerCfgFormat.stockLevelsMin.stairBlock = {_order_ = 2, "Integer", 1}
  minerCfgFormat.stockLevelsMin.mining._order_ = 3
  minerCfgFormat.stockLevelsMin.fuel._order_ = 4
  
  minerCfgFormat.stockLevelsMax.buildBlock = {_order_ = 1, "Integer", 0}
  minerCfgFormat.stockLevelsMax.stairBlock = {_order_ = 2, "Integer", 0}
  minerCfgFormat.stockLevelsMax.mining._order_ = 3
  minerCfgFormat.stockLevelsMax.fuel._order_ = 4
  
  local cfgFormat = {
    miner = minerCfgFormat,
    inventoryInput = {_order_ = 2, "Sides", "right", [[

The side of the robot where items will be taken from (an inventory like a
chest is expected to be here). This is from the robot's perspective when at
the restock point. Valid sides are: "bottom", "top", "back", "front",
"right", and "left".]],
    },
    inventoryOutput = {_order_ = 3, "Sides", "back", [[

Similar to inventoryInput, but for the inventory robot will dump items to.]]
    },
    energyStartLevel = {_order_ = 4, "string|number", "99%", [[

Minimum energy level for quarry to start running or finish a resupply trip.
If using only generators on the robot and no charger, set this below the
generator.enableLevel value. This can be a number that specifies the exact
energy amount, or a string value with percent sign for a percentage level.]]
    },
    quarryType = {_order_ = 5, "QuarryType", "Fast", [[

Controls mining and building patterns for the quarry, options are: "Basic"
simply mines out the rectangular area, "Fast" mines three layers at a time
but may not remove all liquids, "FillFloor" ensures a solid floor below each
working layer (for when a flight upgrade is not in use), "FillWall" ensures a
solid wall at the borders of the rectangular area (prevents liquids from
spilling into quarry).]]
    },
    buildStaircase = {_order_ = 6, "boolean", false, [[

When set to true, the robot will build a staircase once the quarry is
finished (stairs go clockwise around edges of quarry to the top and end at
the restock point). This adjusts miner.stockLevelsMax.stairBlock to stock
stairs if needed.]]
    },
  }
  
  return cfgTypes, cfgFormat
end


-- Construct a new Quarry object with the given length, width, and depth mining
-- dimensions. These correspond to the positive-x, positive-z, and negative-y
-- dimensions with the robot facing in the positive-z direction.
-- 
---@param length integer|nil
---@param width integer|nil
---@param depth integer|nil
---@param cfg table|nil
---@return Quarry
---@nodiscard
function Quarry:new(length, width, depth, cfg)
  self.__index = self
  self = setmetatable({}, self)
  
  -- A nil cfg will return a stub Quarry instance for inheritance purposes.
  if not cfg then
    return self
  end
  
  length = length or 1
  width = width or 1
  depth = depth or 1
  
  robnav.setCoords(0, 0, 0, sides.front)
  
  self.miner = miner:new(
    enum {"buildBlock", "stairBlock", "mining", "fuel"},
    cfg.miner
  )
  
  self.cfg = cfg
  
  -- Sides where robot will look to transfer items at the restock point.
  self.inventoryInput = sides[cfg.inventoryInput]
  self.inventoryOutput = sides[cfg.inventoryOutput]
  
  -- Energy level required to start working.
  self.energyStartLevel = cfg.energyStartLevel
  if type(self.energyStartLevel) == "string" then
    if string.find(self.energyStartLevel, "%%") then
      self.energyStartLevel = tonumber((string.gsub(self.energyStartLevel, "%%", ""))) * 0.01 * computer.maxEnergy()
    else
      self.energyStartLevel = tonumber(self.energyStartLevel)
    end
  end
  
  -- Direction robot is moving in the current layer (position delta).
  self.xDir = 1
  self.zDir = 1
  
  -- Bounds for mining area.
  self.xMax = length - 1
  self.yMin = -depth
  self.zMax = width - 1
  
  -- Various properties about the current quarry state. These are pretty much
  -- exclusively used in Quarry:run() and related functions for caching and
  -- restoring state in the CrashHandler.
  self.quarryStatus = QuarryStatus.init
  self.quarryWorkingStage = 0
  self.mainCoroutine = false
  self.xLast, self.yLast, self.zLast, self.rLast = robnav.getCoords()
  self.lastSelectedStockType = self.miner.selectedStockType
  self.lastReturnReason = 0
  self.buildStairsStage = 0
  
  return self
end

-- Mines a block in the layer. This can mine more blocks, but shouldn't move the
-- robot.
function Quarry:layerMine()
  xassert(false, "Abstract method Quarry:layerMine() not implemented.")
end

-- Turns the robot around (usually 180 degrees) to start on the next row in the
-- layer. The convention is to make a clockwise turn when turnDir is true.
-- 
---@param turnDir boolean
function Quarry:layerTurn(turnDir)
  xassert(false, "Abstract method Quarry:layerTurn() not implemented.")
end

-- Moves the robot down to start on the first row in the next layer.
function Quarry:layerDown()
  xassert(false, "Abstract method Quarry:layerDown() not implemented.")
end

-- Puts the robot in position for the first row on the first layer. This is a
-- no-op by default.
function Quarry:quarryStart()
  if self.quarryWorkingStage ~= 0 then
    return
  end
  self.quarryWorkingStage = 1
end

-- Called after quarryStart() to mine the full area, layer by layer.
-- Implementations are free to change this to whatever. By default this will
-- move the robot in a zig-zag pattern, going right-to-left on one layer
-- followed by left-to-right on the next.
function Quarry:quarryMain()
  if self.quarryWorkingStage ~= 1 then
    return
  end
  while true do
    self:layerMine()
    if (robnav.z >= self.zMax and self.zDir == 1) or (robnav.z <= 0 and self.zDir == -1) then
      if (robnav.x >= self.xMax and self.xDir == 1) or (robnav.x <= 0 and self.xDir == -1) then
        if robnav.y <= self.yMin then
          self.quarryWorkingStage = 2
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
      self.miner:forceMove(sides.front)
    end
  end
end

-- Applies any finishing actions the robot should take at the end. This is a
-- no-op by default.
function Quarry:quarryEnd()
  if self.quarryWorkingStage ~= 2 then
    return
  end
  self.quarryWorkingStage = 3
end


-- Builds a staircase that wraps around the walls of the quarry in a spiral
-- (going clockwise if moving up). The stairs end at the top directly below the
-- robot in the home position.
function Quarry:buildStairs()
  self.miner:selectStockType(self.miner.StockTypes.stairBlock, true)
  
  -- Simulate starting the robot from the home position, then follow the path the stairs will take to reach the bottom.
  local position = {
    x = 0,
    y = 0,
    z = 0,
    r = sides.front
  }
  while position.y > self.yMin + 1 do
    robnav.computeMove(sides.front, position)
    robnav.computeMove(sides.bottom, position)
    if
      position.r == sides.front and position.z == self.zMax
      or position.r == sides.left and position.x == self.xMax
      or position.r == sides.back and position.z == 0
      or position.r == sides.right and position.x == 0
    then
      robnav.computeTurn(false, position)
    end
  end
  robnav.computeMove(sides.front, position)
  robnav.computeMove(sides.bottom, position)
  robnav.computeTurn(false, position)
  robnav.computeTurn(false, position)
  
  -- Get robot into position, then build the stairs until we reach the top.
  self:moveTo(position.x, position.y, position.z)
  robnav.turnTo(position.r)
  
  while robnav.y < 0 do
    -- Only place stairs in front, it doesn't seem possible to get the right rotation when placing above or below.
    self.miner:forcePlace(sides.front)
    
    self.miner:forceMove(sides.top)
    self.miner:forceMove(sides.front)
    if
      robnav.r == sides.front and robnav.z == self.zMax
      or robnav.r == sides.left and robnav.x == self.xMax
      or robnav.r == sides.back and robnav.z == 0
      or robnav.r == sides.right and robnav.x == 0
    then
      self.miner:forceTurn(true)
    end
  end
end


-- Moves the robot to the specified coordinates. This is similar to
-- `robnav.moveTo()` but uses `miner:forceMove()` to protect against obstacles.
-- Movement follows an X -> Z -> Y ordering when the target position is above
-- the robot, and the reverse when the target is below (ensures clear movement
-- within the quarry area).
-- 
---@param x integer
---@param y integer
---@param z integer
function Quarry:moveTo(x, y, z)
  -- Moves the robot in the vector specified by forwardDir and backwardDir, with
  -- delta as the magnitude.
  local function moveVec(delta, forwardDir, backwardDir)
    if forwardDir ~= sides.top then
      if delta > 0 then
        robnav.turnTo(forwardDir)
      elseif delta < 0 then
        robnav.turnTo(backwardDir)
      end
      forwardDir = sides.front
    elseif delta < 0 then
      forwardDir = backwardDir
    end
    for _ = 1, math.abs(delta) do
      self.miner:forceMove(forwardDir)
    end
  end
  
  if y - robnav.y >= 0 then
    moveVec(x - robnav.x, sides.left, sides.right)
    moveVec(z - robnav.z, sides.front, sides.back)
    moveVec(y - robnav.y, sides.top, sides.bottom)
  else
    moveVec(y - robnav.y, sides.top, sides.bottom)
    moveVec(z - robnav.z, sides.front, sides.back)
    moveVec(x - robnav.x, sides.left, sides.right)
  end
end


-- Sends the robot back to the restock point to clean up items in inventory and
-- recharge. Returns true if the quarry is not yet done working.
-- 
---@return boolean continueWork
function Quarry:resupply()
  dlog.out("run", "moving to home position.")
  
  if robnav.y < -1 then
    self.miner:forceMove(sides.top)
  end
  if robnav.y < -1 then
    self.miner:forceMove(sides.top)
  end
  self:moveTo(0, 0, 0)
  
  if self.lastReturnReason == self.miner.ReturnReasons.minerDone then
    if self.cfg.buildStaircase and self.buildStairsStage == 0 then
      -- Queue the replacement of the old coroutine with new tasks to build staircase. The coroutine will start after the resupply finishes.
      self.mainCoroutine = false
      
      -- Request stairs to be stocked in inventory.
      if self.miner.stockLevels[self.miner.StockTypes.stairBlock][1] < 1 then
        self.miner.stockLevels[self.miner.StockTypes.stairBlock][1] = 3
      end
      
      self.xLast, self.yLast, self.zLast, self.rLast = 0, 0, 0, sides.front
      self.buildStairsStage = 1
    else
      -- Operations finished, dump inventory and return.
      self.miner:itemDeposit({}, self.inventoryOutput)
      crobot.select(1)
      robnav.turnTo(sides.front)
      io.write("Quarry finished!\n")
      return false
    end
  end
  
  io.write("Restocking items and equipment...\n")
  self.miner:fullResupply(self.inventoryInput, self.inventoryOutput)
  if not dlog.standardOutput() then
    term.setCursor(1, select(2, term.getCursor()) - 1)
    term.clearLine()
  end
  
  -- Wait until fully recharged.
  io.write("Waiting for battery to charge...\n")
  while computer.energy() < self.energyStartLevel do
    dlog.out("resupply", "waiting for energy...")
    self.miner:updateGenerators()
    os.sleep(2.0)
  end
  if not dlog.standardOutput() then
    term.setCursor(1, select(2, term.getCursor()) - 1)
    term.clearLine()
  end
  return true
end


-- Sends the robot to the last working position to continue where it left off.
function Quarry:returnToWork()
  dlog.out("run", "moving back to working position.")
  self.miner:selectStockType(self.lastSelectedStockType)
  self:moveTo(self.xLast, math.min(self.yLast + 2, -1), self.zLast)
  if robnav.y > self.yLast then
    self.miner:forceMove(sides.bottom)
  end
  if robnav.y > self.yLast then
    self.miner:forceMove(sides.bottom)
  end
  robnav.turnTo(self.rLast)
  xassert(robnav.x == self.xLast and robnav.y == self.yLast and robnav.z == self.zLast and robnav.r == self.rLast)
end


-- Starts the quarry process so that the robot mines out the rectangular area.
-- The mining actions run within a coroutine so that any problems that occur
-- (tools depleted, energy low, etc.) will cause the robot to return home for
-- resupply and then go back to the working area. When the robot is finished, it
-- dumps its inventory and this function returns.
-- 
-- This function makes heavy use of tail calls so that it behaves like a state
-- machine. This allows us to recover the state later with the CrashHandler.
function Quarry:run()
  if not self.mainCoroutine then
    if self.buildStairsStage ~= 1 then
      self.mainCoroutine = coroutine.create(function()
        self:quarryStart()
        self:quarryMain()
        self:quarryEnd()
        return self.miner.ReturnReasons.minerDone
      end)
    else
      self.mainCoroutine = coroutine.create(function()
        self:buildStairs()
        return self.miner.ReturnReasons.minerDone
      end)
      
      -- Request stairs to be stocked in inventory (should already be done in Quarry:resupply() but we may recover from a crash during stair building).
      if self.miner.stockLevels[self.miner.StockTypes.stairBlock][1] < 1 then
        self.miner.stockLevels[self.miner.StockTypes.stairBlock][1] = 3
      end
    end
  end
  
  if self.quarryStatus == QuarryStatus.init then
    crobot.setLightColor(0x00FFFF)  -- Cyan
    
    -- Confirm valid inventories are at the input and output sides.
    robnav.turnTo(self.inventoryInput)
    if not icontroller.getInventorySize(self.inventoryInput < 2 and self.inventoryInput or sides.front) then
      robnav.turnTo(sides.front)
      error("no valid input inventory found, config[\"inventoryInput\"] is set to side " .. sides[self.inventoryInput])
    end
    robnav.turnTo(self.inventoryOutput)
    if not icontroller.getInventorySize(self.inventoryOutput < 2 and self.inventoryOutput or sides.front) then
      robnav.turnTo(sides.front)
      error("no valid output inventory found, config[\"inventoryOutput\"] is set to side " .. sides[self.inventoryOutput])
    end
    
    self.lastReturnReason = 0
    self:resupply()
    
    self.quarryStatus = QuarryStatus.working
    return self:run()
    
  elseif self.quarryStatus == QuarryStatus.working then
    crobot.setLightColor(0x00FF00)  -- Green
    self.miner.withinMainCoroutine = true
    local status, result = coroutine.resume(self.mainCoroutine)
    self.miner.withinMainCoroutine = false
    if not status then
      error(result)
    end
    dlog.out("run", "return reason = ", self.miner.ReturnReasons[result])
    self.lastReturnReason = result
    self.xLast, self.yLast, self.zLast, self.rLast = robnav.getCoords()
    self.lastSelectedStockType = self.miner.selectedStockType
    
    self.quarryStatus = QuarryStatus.resupply
    return self:run()
    
  elseif self.quarryStatus == QuarryStatus.resupply then
    crobot.setLightColor(0x00FFFF)  -- Cyan
    io.write("Returning to resupply point: ", self.miner.ReturnReasons[self.lastReturnReason], "\n")
    if not self:resupply() then
      return
    end
    self.quarryStatus = QuarryStatus.returnToWork
    return self:run()
    
  elseif self.quarryStatus == QuarryStatus.returnToWork then
    crobot.setLightColor(0xFF00FF)  -- Magenta
    self:returnToWork()
    self.quarryStatus = QuarryStatus.working
    return self:run()
    
  end
end


-- Basic quarry mines out the rectangular area and nothing more.
local BasicQuarry = Quarry:new()
function BasicQuarry:layerMine()
  if (robnav.z ~= self.zMax or self.zDir ~= 1) and (robnav.z ~= 0 or self.zDir ~= -1) then
    self.miner:forceDig(sides.front)
  end
end
function BasicQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceDig(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(turnDir)
end
function BasicQuarry:layerDown()
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function BasicQuarry:quarryStart()
  if self.quarryWorkingStage ~= 0 then
    return
  end
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.quarryWorkingStage = 1
end


-- Fast quarry mines three layers at a time, may not clear all liquids.
local FastQuarry = Quarry:new()
function FastQuarry:layerMine()
  self.miner:forceDig(sides.top)
  if (robnav.z ~= self.zMax or self.zDir ~= 1) and (robnav.z ~= 0 or self.zDir ~= -1) then
    self.miner:forceDig(sides.front)
  end
  self.miner:forceDig(sides.bottom)
end
function FastQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceDig(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(turnDir)
end
function FastQuarry:layerDown()
  self.miner:forceMove(sides.bottom)
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function FastQuarry:quarryStart()
  if self.yMin >= -2 then
    FastQuarry.layerMine = BasicQuarry.layerMine
    FastQuarry.layerTurn = BasicQuarry.layerTurn
    FastQuarry.layerDown = BasicQuarry.layerDown
    FastQuarry.quarryMain = Quarry.quarryMain
  end
  if self.quarryWorkingStage ~= 0 then
    return
  end
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  if self.yMin < -2 then
    self.miner:forceDig(sides.bottom)
    self.miner:forceMove(sides.bottom)
  end
  self.quarryWorkingStage = 1
end
function FastQuarry:quarryMain()
  if self.quarryWorkingStage ~= 1 then
    return
  end
  local useBasicQuarryMain = false
  while true do
    self:layerMine()
    if (robnav.z >= self.zMax and self.zDir == 1) or (robnav.z <= 0 and self.zDir == -1) then
      if (robnav.x >= self.xMax and self.xDir == 1) or (robnav.x <= 0 and self.xDir == -1) then
        if robnav.y <= self.yMin + (useBasicQuarryMain and 0 or 1) then
          self.quarryWorkingStage = 2
          return
        elseif not useBasicQuarryMain and robnav.y <= self.yMin + 3 then
          FastQuarry.layerMine = BasicQuarry.layerMine
          FastQuarry.layerTurn = BasicQuarry.layerTurn
          FastQuarry.layerDown = BasicQuarry.layerDown
          self.miner:forceMove(sides.bottom)
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
      self.miner:forceMove(sides.front)
    end
    --self.xLayer, self.yLayer, self.zLayer = robnav.getCoords()
  end
end


-- Fill floor quarry ensures a solid floor below each working layer, needed for
-- when a flight upgrade is not in use.
local FillFloorQuarry = Quarry:new()
function FillFloorQuarry:layerMine()
  -- Testing shows that blocks categorized as "replaceable", "liquid", and "passable" allow movement too, but we only accept solid blocks here for safety.
  if select(2, crobot.detect(sides.bottom)) ~= "solid" then
    self.miner:forcePlace(sides.bottom)
  end
  if (robnav.z ~= self.zMax or self.zDir ~= 1) and (robnav.z ~= 0 or self.zDir ~= -1) then
    self.miner:forceDig(sides.front)
  end
end
function FillFloorQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceDig(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(turnDir)
end
function FillFloorQuarry:layerDown()
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function FillFloorQuarry:quarryStart()
  if self.quarryWorkingStage ~= 0 then
    return
  end
  self.miner:selectStockType(self.miner.StockTypes.buildBlock, true)
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.quarryWorkingStage = 1
end


-- Fill wall quarry creates a solid wall at the borders of the rectangular area
-- (keeps liquids out). Requires angel upgrade.
local FillWallQuarry = Quarry:new()
function FillWallQuarry:layerMine()
  -- Check to place wall on left/right sides.
  if robnav.x == 0 or robnav.x == self.xMax then
    local wallDir = ((robnav.x == 0) == (self.zDir == 1))
    self.miner:forceTurn(wallDir)
    if select(2, crobot.detect(sides.front)) ~= "solid" then
      self.miner:forcePlace(sides.front)
    end
    self.miner:forceTurn(not wallDir)
  end
  -- Check to place wall on front/back sides. Otherwise, mine straight ahead.
  if (robnav.z == self.zMax and self.zDir == 1) or (robnav.z == 0 and self.zDir == -1) then
    if select(2, crobot.detect(sides.front)) ~= "solid" then
      self.miner:forcePlace(sides.front)
    end
  else
    self.miner:forceDig(sides.front)
  end
end
function FillWallQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceDig(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(not turnDir)
  if select(2, crobot.detect(sides.front)) ~= "solid" then
    self.miner:forcePlace(sides.front)
  end
  self.miner:forceTurn(turnDir)
  self.miner:forceTurn(turnDir)
end
function FillWallQuarry:layerDown()
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  if select(2, crobot.detect(sides.front)) ~= "solid" then
    self.miner:forcePlace(sides.front)
  end
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function FillWallQuarry:quarryStart()
  if self.quarryWorkingStage ~= 0 then
    return
  end
  self.miner:selectStockType(self.miner.StockTypes.buildBlock, true)
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
  if select(2, crobot.detect(sides.front)) ~= "solid" then
    self.miner:forcePlace(sides.front)
  end
  self.miner:forceTurn(false)
  self.miner:forceTurn(false)
  self.quarryWorkingStage = 1
end


-- Move test just moves straight to the end corner of the rectangular area. It's
-- useful for testing safe energy-level thresholds, chunkloading, generator
-- performance, etc.
local MoveTestQuarry = Quarry:new()
function MoveTestQuarry:quarryStart()
  self.miner:forceMove(sides.bottom)
end
function MoveTestQuarry:quarryMain()
  if self.quarryWorkingStage ~= 1 then
    return
  end
  while robnav.z < self.zMax do
    self.miner:forceMove(sides.front)
  end
  self.miner:forceTurn(false)
  while robnav.x < self.xMax do
    self.miner:forceMove(sides.front)
  end
  while robnav.y > self.yMin do
    self.miner:forceMove(sides.bottom)
  end
  self.quarryWorkingStage = 2
end


-- The CrashHandler runs right before the program ends in a failed state. This
-- captures a detailed error and the current state of the system, which are
-- written to a file. The state can be restored the next time the program runs
-- to pick up where it was stopped previously. In order for this to work, state
-- machines need to be used quite frequently in the program control flow.
---@class CrashHandler
local CrashHandler = {}

-- Hook up errors to throw on access to nil class members.
setmetatable(CrashHandler, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in CrashHandler class.", 2)
  end
})


-- Create a new CrashHandler instance. The `reportFilename` is the path to the
-- crash report that will be generated.
-- 
---@param reportFilename string
---@return CrashHandler
function CrashHandler:new(reportFilename)
  self.__index = self
  self = setmetatable({}, self)
  
  self.reportFilename = reportFilename
  self.state = {}
  
  return self
end


-- Sets up data structures that reports will pull state from. If this is not
-- set, attempting to create or restore reports will have no effect.
-- 
---@param quarry Quarry
---@param robnav table
function CrashHandler:register(quarry, robnav)
  self.state.quarry = quarry
  self.state.robnav = robnav
end


-- Serializes state from cached data structures and writes this to a file. The
-- `message` is written in a comment at the top, it can contain a full stack
-- trace of the error. If unsuccessful, returns false and an error message.
-- 
---@param message string
---@return boolean success
---@return string|nil err
function CrashHandler:createReport(message)
  if next(self.state) == nil then
    return false, "CrashHandler not yet registered."
  end
  local reportData = {}
  
  local quarryState, quarryReport = self.state.quarry, {}
  local quarryTrackedVars = [[
    xDir zDir
    xMax yMin zMax
    quarryStatus
    quarryWorkingStage
    xLast yLast zLast rLast
    lastSelectedStockType
    lastReturnReason
    buildStairsStage
  ]]
  for k in string.gmatch(quarryTrackedVars, "%S+") do
    quarryReport[k] = quarryState[k]
  end
  reportData.quarry = quarryReport
  
  local minerState, minerReport = self.state.quarry.miner, {}
  local minerTrackedVars = [[
    toolDurabilityReturn toolDurabilityMin lastToolDurability
    currentStockSlots
    selectedStockType
  ]]
  for k in string.gmatch(minerTrackedVars, "%S+") do
    minerReport[k] = minerState[k]
  end
  reportData.miner = minerReport
  
  local robnavState, robnavReport = self.state.robnav, {}
  for k in string.gmatch("x y z r", "%S+") do
    robnavReport[k] = robnavState[k]
  end
  reportData.robnav = robnavReport
  
  local file = io.open(self.reportFilename, "w")
  if not file then
    return false, "Failed to write to file \"" .. self.reportFilename .. "\"."
  end
  file:write("-- Last error (", os.date(), "):\n")
  message = string.gsub(message, "\t", "  ")
  file:write("-- ", string.gsub(message, "\n", "\n-- "), "\n\n")
  
  file:write(serialization.serialize(reportData), "\n")
  file:close()
  
  return true
end


-- Returns state that was saved in an error report file. If unsuccessful,
-- returns false and an error message.
-- 
---@return boolean success
---@return string|table
function CrashHandler:loadReport()
  local file = io.open(self.reportFilename, "r")
  if not file then
    return false, "Failed to read from file \"" .. self.reportFilename .. "\"."
  end
  
  local reportData
  local lineNum = 1
  for line in file:lines() do
    if line ~= "" and not string.find(line, "^%s*%-%-") then
      if reportData then
        return false, "In file " .. self.reportFilename .. ":" .. lineNum .. ": Unexpected data."
      end
      reportData = serialization.unserialize(line)
    end
    lineNum = lineNum + 1
  end
  file:close()
  if not reportData then
    return false, "In file " .. self.reportFilename .. ":" .. lineNum .. ": End of file reached, no report data found."
  end
  
  dlog.out("CrashHandler:loadReport", "reportData:", reportData)
  
  return true, reportData
end


-- Deserializes state saved in an error report file and writes this back into
-- cached data structures. Not all of the state is written over as-is, some of
-- the cached data requires modification through specific functions so there is
-- some flexibility here. If unsuccessful, returns false and an error message.
-- 
---@return boolean success
---@return string|nil err
function CrashHandler:restoreReport()
  if next(self.state) == nil then
    return false, "CrashHandler not yet registered."
  end
  
  local status, reportData = self:loadReport()
  if not status then
    return false, reportData
  end
  ---@cast reportData -string
  
  local quarryState = self.state.quarry
  for k, v in pairs(reportData.quarry) do
    quarryState[k] = v
  end
  local minerState = self.state.quarry.miner
  for k, v in pairs(reportData.miner) do
    minerState[k] = v
  end
  self.state.robnav.setCoords(reportData.robnav.x, reportData.robnav.y, reportData.robnav.z, reportData.robnav.r)
  
  return true
end


local USAGE_STRING = [[
Usage: tquarry [OPTION]... LENGTH WIDTH DEPTH

Options:
  -h, --help        display help message and exit

To configure, run: edit /etc/tquarry.cfg
For more information, run: man tquarry
]]

local crashHandler = CrashHandler:new("/home/tquarry.crash")

-- Waits for an interrupt signal to create a CrashHandler report before shutting
-- down the system. Using a shutdown to stop the program isn't ideal, but it
-- allows the main program to run without depending on the thread library (which
-- would add a bit of memory overhead). Also note that we bind this to signals
-- of type "key_down" instead of "interrupted". Some experiments have shown that
-- the "interrupted" signal is very unlikely to get processed while the robot is
-- constantly doing work (like mining and moving).
local function interruptHandler(_, _, char, code, _)
  if keyboard.isControl(char) then
    if code == keyboard.keys.c then
      dlog.out("interruptHandler", "Caught SIGINT.")
      crashHandler:createReport("received interrupt signal.")
      dlog.osBlockNewGlobals(false)
      crobot.setLightColor(0xF23030)
      computer.shutdown()
      return false
    elseif code == keyboard.keys.lcontrol then
      -- Pull events for a little bit since we anticipate the control-c combo.
      computer.pullSignal(0.1)
    end
  end
end


local function main(...)
  -- Get command-line arguments.
  local args, opts = shell.parse(...)
  
  -- Load config file, or use default config if not found.
  local cfgPath = "/etc/tquarry.cfg"
  local cfgTypes, cfgFormat = Quarry.makeConfigTemplate()
  local cfg, loadedDefaults = config.loadFile(cfgPath, cfgFormat, true)
  config.verify(cfg, cfgFormat, cfgTypes)
  if loadedDefaults then
    io.write("Configuration not found, saving defaults to \"", cfgPath, "\".\n")
    config.saveFile(cfgPath, cfg, cfgFormat, cfgTypes)
  end
  
  if opts["h"] or opts["help"] then
    io.write(USAGE_STRING)
    return 0
  end
  
  -- Check for a crash report from a previous run of the program.
  local restoreFromCrash = false
  if filesystem.exists(crashHandler.reportFilename) then
    local status, reportData = crashHandler:loadReport()
    xassert(status, reportData)
    ---@cast reportData -string
    io.write("Found previous state cached in \"", crashHandler.reportFilename, "\".\n")
    io.write("Quarry size: ", reportData.quarry.xMax + 1, " ", reportData.quarry.zMax + 1, " ", -reportData.quarry.yMin, "\n")
    io.write("Position: ", reportData.robnav.x, ", ", reportData.robnav.y, ", ", reportData.robnav.z, ", ", sides[reportData.robnav.r], "\n")
    io.write("Do you want to continue from this state?\n(Y/n): ")
    local input = io.read()
    if type(input) ~= "string" then
      io.write("Exiting...\n")
      return 0
    elseif string.lower(input) ~= "n" and string.lower(input) ~= "no" then
      io.write("Restoring quarry state...\n")
      restoreFromCrash = true
      args[1] = reportData.quarry.xMax + 1
      args[2] = reportData.quarry.zMax + 1
      args[3] = -reportData.quarry.yMin
    else
      filesystem.remove(crashHandler.reportFilename)
    end
  end
  
  if #args ~= 3 then
    io.write(USAGE_STRING)
    return 0
  end
  for i = 1, 3 do
    args[i] = tonumber(args[i])
    if not args[i] or args[i] ~= math.floor(args[i]) or args[i] < 1 then
      io.stderr:write("tquarry: quarry dimensions must be positive integer values\n")
      return 2
    end
  end
  
  -- Check hardware and config options for problems.
  if crobot.inventorySize() <= 0 then
    io.stderr:write("tquarry: robot is missing inventory upgrade\n")
    return 2
  end
  if component.isAvailable("chunkloader") then
    -- Activate the chunkloader if disabled, the chunkloader is automatically enabled during boot so usually this isn't necessary.
    if not (component.chunkloader.isActive() or component.chunkloader.setActive(true)) then
      io.stderr:write("tquarry: chunkloader failed to acquire chunk loading ticket\n")
      return 2
    end
  end
  if cfg.buildStaircase and (args[1] < 2 or args[2] < 2) then
    io.stderr:write("tquarry: building a staircase requires at least 2 blocks space for length and width\n")
    return 2
  end
  if cfg.quarryType == "FillFloor" or cfg.quarryType == "FillWall" or cfg.buildStaircase then
    -- Confirm that we have an angel upgrade installed.
    local hardwareList = {}
    for _, v in pairs(computer.getDeviceInfo()) do
      hardwareList[v.description] = (hardwareList[v.description] or 0) + 1
    end
    if not hardwareList["Angel upgrade"] then
      io.write("Current configuration meets requirements for an\n")
      io.write("Angel Upgrade, but this upgrade was not found.\n")
      io.write("Do you want to continue anyways? (Y/n): ")
      local input = io.read()
      if type(input) ~= "string" or string.lower(input) == "n" or string.lower(input) == "no" then
        io.write("Exiting...\n")
        return 0
      end
    end
    
    -- Request construction blocks to be stocked in inventory if needed.
    if cfg.quarryType == "FillFloor" or cfg.quarryType == "FillWall" then
      if cfg.miner.stockLevelsMax.buildBlock < 1 then
        cfg.miner.stockLevelsMax.buildBlock = 3
      end
    end
  end
  
  local quarryClass
  if cfg.quarryType == "Basic" then
    quarryClass = BasicQuarry
  elseif cfg.quarryType == "Fast" then
    quarryClass = FastQuarry
  elseif cfg.quarryType == "FillFloor" then
    quarryClass = FillFloorQuarry
  elseif cfg.quarryType == "FillWall" then
    quarryClass = FillWallQuarry
  elseif cfg.quarryType == "MoveTest" then
    quarryClass = MoveTestQuarry
  end
  
  local quarry = quarryClass:new(args[1], args[2], args[3], cfg)
  crashHandler:register(quarry, robnav)
  if restoreFromCrash then
    local status, err = crashHandler:restoreReport()
    if not status then
      io.stderr:write("tquarry: unable to restore state: ", err)
      return 2
    end
    filesystem.remove(crashHandler.reportFilename)
  end
  
  event.listen("key_down", interruptHandler)
  io.write("Starting quarry!\n")
  io.write("Press Ctrl+C for emergency shutdown.\n")
  quarry:run()
  return 0
end

local status, ret = dlog.handleError(xpcall(main, debug.traceback, ...))
event.ignore("key_down", interruptHandler)
if not status then
  crashHandler:createReport(tostring(ret))
end
dlog.osBlockNewGlobals(false)
crobot.setLightColor(0xF23030)
os.exit(status and ret or 1)
