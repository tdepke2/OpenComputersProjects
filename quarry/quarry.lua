local component = require("component")
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
  
  self.xLast = 0
  self.yLast = 0
  self.zLast = 0
  self.xDir = 1
  self.zDir = 1
  
  self.xMax = length - 1
  self.yMin = -height + 1
  self.zMax = width - 1
  
  return self
end

function Quarry:selectBuildBlock()
  return false
end

function Quarry:selectStairBlock()
  return false
end

-- Wrapper for robnav.move(), throws an exception on failure. Tries to clear
-- obstacles in the way (entities or blocks) until the movement succeeds or a
-- limit is reached.
function Quarry:forceMove(direction)
  local result, err = robnav.move(direction)
  if not result then
    for i = 1, MAX_FORCE_OP_ATTEMPTS do
      if err == "entity" or err == "solid" or err == "replaceable" or err == "passable" then
        self:forceSwing(direction)
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
  local result, err = crobot.place(direction, side, sneaky)
  if not result then
    for i = 1, MAX_FORCE_OP_ATTEMPTS do
      if err ~= "nothing selected" then
        self:forceSwing(direction)
        -- Sleep in case there is an entity in the way and we need to wait for iframes to deplete.
        os.sleep(0.5)
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

function Quarry:tick()
  self:layerMine()
  
  if (robnav.z == self.zMax and self.zDir == 1) or (robnav.z == 0 and self.zDir == -1) then
    if (robnav.x == self.xMax and self.xDir == 1) or (robnav.x == 0 and self.xDir == -1) then
      if robnav.y <= self.yMin then
        assert(false, "we done!")
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

-- Basic quarry mines out the rectangular area and nothing more.
local BasicQuarry = Quarry:new()
function BasicQuarry:layerMine()
  self:forceMine(sides.bottom)
end
function BasicQuarry:layerTurn(turnDir)
  robnav.turn(turnDir)
  self:forceMove(sides.front)
  robnav.turn(turnDir)
end
function BasicQuarry:layerDown()
  self:forceMove(sides.bottom)
  robnav.turn(true)
  robnav.turn(true)
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
  robnav.turn(turnDir)
  self:forceMine(sides.front)
  self:forceMove(sides.front)
  robnav.turn(turnDir)
end
function FastQuarry:layerDown()
  self:forceMove(sides.bottom)
  self:forceMine(sides.bottom)
  self:forceMove(sides.bottom)
  self:forceMine(sides.bottom)
  self:forceMove(sides.bottom)
  robnav.turn(true)
  robnav.turn(true)
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
  local quarry = FastQuarry:new(4, 5, 3)
  while true do
    quarry:tick()
  end
end

main()
