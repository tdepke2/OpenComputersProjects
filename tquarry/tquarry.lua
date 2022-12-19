--[[
todo:
  * cache state to file (for current level) and prompt to pick up at that point so some state is remembered during sudden program halt?
  * show robot status with setLightColor().
  * we could get a bit more speed by suppressing some of the durability checks done in Miner:forceSwing(). for example, if lastToolDurability > toolDurabilityReturn * 2.0 then count every toolHealthReturn ticks before sampling the durability.

done:
  * convert the coroutine checks to a function? maybe nah
  * move iterators and item rearrange logic into separate module.
  * need to build staircase and walls if enabled.
  * load data from config file (and generate one if not found).
  * dynamically compute energyLevelMin?
  * support for generators?
  * do not stock building blocks if we are not building anything

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
local icontroller = component.inventory_controller
local shell = require("shell")
local sides = require("sides")

local include = require("include")
local dlog = include("dlog")
dlog.mode("debug")
dlog.osBlockNewGlobals(true)
local config = include("config")
local enum = include("enum")
local miner = include("miner")
local robnav = include("robnav")


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
    quarryType = {_order_ = 4, "QuarryType", "Fast", [[

Controls mining and building patterns for the quarry, options are: "Basic"
simply mines out the rectangular area, "Fast" mines three layers at a time
but may not remove all liquids, "FillFloor" ensures a solid floor below each
working layer (for when a flight upgrade is not in use), "FillWall" ensures a
solid wall at the borders of the rectangular area (prevents liquids from
spilling into quarry).]]
    },
    buildStaircase = {_order_ = 5, "boolean", false, [[

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
  
  self.inventoryInput = sides[cfg.inventoryInput]
  self.inventoryOutput = sides[cfg.inventoryOutput]
  
  self.xDir = 1
  self.zDir = 1
  
  self.xMax = length - 1
  self.yMin = -depth
  self.zMax = width - 1
  
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
  
end

-- Called after quarryStart() to mine the full area, layer by layer.
-- Implementations are free to change this to whatever. By default this will
-- move the robot in a zig-zag pattern, going left-to-right on one layer
-- followed by right-to-left on the next.
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

-- Applies any finishing actions the robot should take at the end. This is a
-- no-op by default.
function Quarry:quarryEnd()
  
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
  
  self.miner:fullResupply(self.inventoryInput, self.inventoryOutput)
  
  local buildStairsQueued = self.cfg.buildStaircase
  
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
        if self.miner.stockLevels[self.miner.StockTypes.stairBlock][1] < 1 then
          self.miner.stockLevels[self.miner.StockTypes.stairBlock][1] = 3
        end
        
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
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
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
  self.miner:forceDig(sides.bottom)
  self.miner:forceMove(sides.bottom)
  if robnav.y <= self.yMin + 1 then
    FastQuarry.layerMine = BasicQuarry.layerMine
    FastQuarry.layerTurn = BasicQuarry.layerTurn
    FastQuarry.layerDown = BasicQuarry.layerDown
    FastQuarry.quarryMain = Quarry.quarryMain
  else
    self.miner:forceDig(sides.bottom)
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
  self.miner:selectStockType(self.miner.StockTypes.buildBlock, true)
  self.miner:forceDig(sides.bottom)
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
end


-- Move test just moves straight to the end corner of the rectangular area. It's
-- useful for testing safe energy-level thresholds, chunkloading, generator
-- performance, etc.
local MoveTestQuarry = Quarry:new()
function MoveTestQuarry:quarryStart()
  self.miner:forceMove(sides.bottom)
end
function MoveTestQuarry:quarryMain()
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
end


local USAGE_STRING = [[Usage: tquarry [OPTION]... LENGTH WIDTH DEPTH

Options:
  -h, --help        display help message and exit

To configure, run: edit /etc/tquarry.cfg
For more information, run: man tquarry
]]


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
  
  if #args ~= 3 or opts["h"] or opts["help"] then
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
  
  io.write("Starting quarry!\n")
  local quarry = quarryClass:new(args[1], args[2], args[3], cfg)
  quarry:run()
  return 0
end

local status, ret = dlog.handleError(xpcall(main, debug.traceback, ...))
dlog.osBlockNewGlobals(false)
os.exit(status and ret or 1)
