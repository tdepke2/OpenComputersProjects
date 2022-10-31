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
    {{3, ".*stone/.*"}, {3, ".*stairs/.*"}, {2, ".*pickaxe.*"}},
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
    robnav.turnTo(sides.back)
    while robnav.z > 0 do
      self.miner:forceMove(sides.front)
    end
    robnav.turnTo(sides.right)
    while robnav.x > 0 do
      self.miner:forceMove(sides.front)
    end
    while robnav.y < 0 do
      self.miner:forceMove(sides.top)
    end
    
    if ret == self.miner.ReturnReasons.minerDone then
      self.miner:itemDeposit({}, self.inventoryOutput)
      crobot.select(1)
      robnav.turnTo(sides.front)
      io.write("Quarry finished!\n")
      return
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
    while robnav.y > yLast + 2 do
      self.miner:forceMove(sides.bottom)
    end
    robnav.turnTo(sides.left)
    while robnav.x < xLast do
      self.miner:forceMove(sides.front)
    end
    robnav.turnTo(sides.front)
    while robnav.z < zLast do
      self.miner:forceMove(sides.front)
    end
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
