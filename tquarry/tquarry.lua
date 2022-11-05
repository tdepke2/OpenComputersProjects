--[[
todo:
  * convert the coroutine checks to a function? maybe nah
  * move iterators and item rearrange logic into separate module.
  * need to build staircase and walls if enabled.
  * load data from config file (and generate one if not found).
  * support for generators?
  * cache state to file (for current level) and prompt to pick up at that point so some state is remembered during sudden program halt?
  * dynamically compute energyLevelMin?

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
--]]

local component = require("component")
local computer = require("computer")
local crobot = component.robot
local sides = require("sides")

local include = require("include")
local dlog = include("dlog")
dlog.mode("debug")
dlog.osBlockNewGlobals(true)
local enum = include("enum")
local miner = include("miner")
local robnav = include("robnav")
local xassert = dlog.xassert    -- this may be a good idea to do from now on? ###########################################################


-- Quarry class definition.
---@class Quarry
local Quarry = {}

-- Hook up errors to throw on access to nil class members.
setmetatable(Quarry, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in Quarry class.", 2)
  end
})


-- Construct a new Quarry object with the given length, width, and height mining
-- dimensions. These correspond to the positive-x, positive-z, and negative-y
-- dimensions with the robot facing in the positive-z direction.
-- 
---@param length integer|nil
---@param width integer|nil
---@param height integer|nil
---@return Quarry
---@nodiscard
function Quarry:new(length, width, height)
  self.__index = self
  self = setmetatable({}, self)
  
  length = length or 1
  width = width or 1
  height = height or 1
  
  robnav.setCoords(0, 0, 0, sides.front)
  
  self.miner = miner:new(
    enum {"buildBlock", "stairBlock", "mining"},
    {{3, ".*stone/.*"}, {0, ".*stairs/.*"}, {2, ".*pickaxe.*"}},
    {1, 1, 0}
  )
  
  --[[self.stockLevels = {
    {2, "minecraft:stone/0", "minecraft:cobblestone/0"},
    {1, "minecraft:stone_stairs/0"}
  }--]]
  
  self.miner.toolHealthReturn = 5
  self.miner.toolHealthMin = 0
  self.miner.toolHealthBias = 5
  
  self.miner.energyLevelMin = 1000
  self.miner.emptySlotsMin = 1
  
  self.inventoryInput = sides.right
  self.inventoryOutput = sides.right
  
  self.xDir = 1
  self.zDir = 1
  
  self.xMax = length - 1
  self.yMin = -height
  self.zMax = width - 1
  
  return self
end

function Quarry:layerMine()
  xassert(false, "Abstract method Quarry:layerMine() not implemented.")
end

function Quarry:layerTurn(turnDir)
  xassert(false, "Abstract method Quarry:layerTurn() not implemented.")
end

function Quarry:layerDown()
  xassert(false, "Abstract method Quarry:layerDown() not implemented.")
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
      self.miner:forceMove(sides.front)
    end
  end
end

function Quarry:quarryEnd()
  
end


-- Builds a staircase that wraps around the walls of the quarry in a spiral
-- (going clockwise if moving up). The stairs end at the top directly below the
-- robot in the home position.
function Quarry:buildStairs()
  
  -- FIXME the min area to build stairs is 2 by 2, recommended angel upgrade
  
  self.miner:selectStockType(self.miner.StockTypes.stairBlock)
  
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


-- Starts the quarry process so that the robot mines out the rectangular area.
-- The mining actions run within a coroutine so that any problems that occur
-- (tools depleted, energy low, etc.) will cause the robot to return home for
-- resupply and then go back to the working area. When the robot is finished, it
-- dumps its inventory and this function returns.
function Quarry:run()
  local co = coroutine.create(function()
    self:quarryStart()
    self:quarryMain()
    self:quarryEnd()
    return self.miner.ReturnReasons.minerDone
  end)
  
  self.miner:fullResupply(self.inventoryInput, self.inventoryOutput)
  
  local buildStairsQueued = true
  
  while true do
    self.miner.withinMainCoroutine = true
    local status, ret = coroutine.resume(co)
    self.miner.withinMainCoroutine = false
    if not status then
      error(ret)
    end
    dlog.out("run", "return reason = ", self.miner.ReturnReasons[ret])
    
    -- Return to home position.
    dlog.out("run", "moving to home position.")
    local xLast, yLast, zLast, rLast = robnav.getCoords()
    local lastSelectedStockType = self.miner.selectedStockType
    if robnav.y < 0 then
      self.miner:forceMove(sides.top)
    end
    if robnav.y < 0 then
      self.miner:forceMove(sides.top)
    end
    self:moveTo(0, 0, 0)
    
    if ret == self.miner.ReturnReasons.minerDone then
      if buildStairsQueued then
        -- Replace the old coroutine with new tasks to build staircase. The coroutine will start after the resupply finishes.
        co = coroutine.create(function()
          self:buildStairs()
          return self.miner.ReturnReasons.minerDone
        end)
        
        -- Request stairs to be stocked in inventory.
        self.miner.stockLevels[self.miner.StockTypes.stairBlock][1] = 3
        
        xLast, yLast, zLast, rLast = 0, 0, 0, sides.front
        buildStairsQueued = false
      else
        -- Operations finished, dump inventory and return.
        self.miner:itemDeposit({}, self.inventoryOutput)
        crobot.select(1)
        robnav.turnTo(sides.front)
        io.write("Quarry finished!\n")
        return
      end
    end
    
    self.miner:fullResupply(self.inventoryInput, self.inventoryOutput)
    
    -- Wait until fully recharged.
    while computer.maxEnergy() - computer.energy() > 50 do
      os.sleep(2.0)
      dlog.out("run", "waiting for energy...")
    end
    
    -- Go back to working area.
    dlog.out("run", "moving back to working position.")
    self.miner:selectStockType(lastSelectedStockType)
    self:moveTo(xLast, math.min(yLast + 2, 0), zLast)
    if robnav.y > yLast then
      self.miner:forceMove(sides.bottom)
    end
    if robnav.y > yLast then
      self.miner:forceMove(sides.bottom)
    end
    robnav.turnTo(rLast)
    xassert(robnav.x == xLast and robnav.y == yLast and robnav.z == zLast and robnav.r == rLast)
  end
end


-- Basic quarry mines out the rectangular area and nothing more.
local BasicQuarry = Quarry:new()
function BasicQuarry:layerMine()
  if (robnav.z ~= self.zMax or self.zDir ~= 1) and (robnav.z ~= 0 or self.zDir ~= -1) then
    self.miner:forceMine(sides.front)
  end
end
function BasicQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceMine(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(turnDir)
end
function BasicQuarry:layerDown()
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function BasicQuarry:quarryStart()
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
end


-- Fast quarry mines three layers at a time, may not clear all liquids.
local FastQuarry = Quarry:new()
function FastQuarry:layerMine()
  self.miner:forceMine(sides.top)
  if (robnav.z ~= self.zMax or self.zDir ~= 1) and (robnav.z ~= 0 or self.zDir ~= -1) then
    self.miner:forceMine(sides.front)
  end
  self.miner:forceMine(sides.bottom)
end
function FastQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceMine(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(turnDir)
end
function FastQuarry:layerDown()
  self.miner:forceMove(sides.bottom)
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function FastQuarry:quarryStart()
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
  if robnav.y <= self.yMin + 1 then
    FastQuarry.layerMine = BasicQuarry.layerMine
    FastQuarry.layerTurn = BasicQuarry.layerTurn
    FastQuarry.layerDown = BasicQuarry.layerDown
    FastQuarry.quarryMain = Quarry.quarryMain
  else
    self.miner:forceMine(sides.bottom)
    self.miner:forceMove(sides.bottom)
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
    self.miner:forceMine(sides.front)
  end
end
function FillFloorQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceMine(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(turnDir)
end
function FillFloorQuarry:layerDown()
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function FillFloorQuarry:quarryStart()
  self.miner:selectStockType(self.miner.StockTypes.buildBlock)
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
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
    self.miner:forceMine(sides.front)
  end
end
function FillWallQuarry:layerTurn(turnDir)
  self.miner:forceTurn(turnDir)
  self.miner:forceMine(sides.front)
  self.miner:forceMove(sides.front)
  self.miner:forceTurn(not turnDir)
  if select(2, crobot.detect(sides.front)) ~= "solid" then
    self.miner:forcePlace(sides.front)
  end
  self.miner:forceTurn(turnDir)
  self.miner:forceTurn(turnDir)
end
function FillWallQuarry:layerDown()
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
  if select(2, crobot.detect(sides.front)) ~= "solid" then
    self.miner:forcePlace(sides.front)
  end
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
end
function FillWallQuarry:quarryStart()
  self.miner:selectStockType(self.miner.StockTypes.buildBlock)
  self.miner:forceMine(sides.bottom)
  self.miner:forceMove(sides.bottom)
  self.miner:forceTurn(true)
  self.miner:forceTurn(true)
  if select(2, crobot.detect(sides.front)) ~= "solid" then
    self.miner:forcePlace(sides.front)
  end
  self.miner:forceTurn(false)
  self.miner:forceTurn(false)
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
