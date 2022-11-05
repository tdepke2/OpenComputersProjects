--------------------------------------------------------------------------------
-- Robot navigation without a navigation upgrade. Extends the base robot
-- component move() and turn() functions with local coordinates tracking. To use
-- this correctly, first call `robnav.setCoords()` to specify the robot's
-- coordinates and then always use `robnav.move()` and `robnav.turn()` instead
-- of the corresponding functions in the robot component.
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


local component = require("component")
local crobot = component.robot
local sides = require("sides")

local robnav = {}

-- Current robot coordinates in local-space. These are read-only!
robnav.x = 0
robnav.y = 0
robnav.z = 0
robnav.r = sides.front

-- Internal LUT to map clockwise/counter-clockwise rotations.
local turnCW = {
  [sides.back] = sides.left,
  [sides.front] = sides.right,
  [sides.right] = sides.back,
  [sides.left] = sides.front
}
local turnCCW = {
  [sides.back] = sides.right,
  [sides.front] = sides.left,
  [sides.right] = sides.front,
  [sides.left] = sides.back
}


-- Gets the current coordinates of the robot. This is just for convenience,
-- directly accessing the robnav.x, robnav.y, etc. values is fine too.
-- 
---@return integer x
---@return integer y
---@return integer z
---@return Sides r
---@nodiscard
function robnav.getCoords()
  return robnav.x, robnav.y, robnav.z, robnav.r
end


-- Sets the current coordinates of the robot, effectively changing the
-- local-space point of reference. If these match the block coordinates of the
-- robot in the world (where sides.front points to the south), then the robot's
-- coordinate system will be put in world-space.
-- 
---@param x integer
---@param y integer
---@param z integer
---@param side Sides
function robnav.setCoords(x, y, z, side)
  robnav.x = x
  robnav.y = y
  robnav.z = z
  robnav.r = side
end


-- Moves the robot 1 block just like `component.robot.move()`, but updates the
-- coords of the robot. The direction can be either front, back, top, or bottom.
-- Returns true on success, or false and an error message on failure.
-- 
---@param direction Sides
---@return boolean success
---@return string|nil err
function robnav.move(direction)
  local result, err = crobot.move(direction)
  if result then
    if direction < 2 then
      robnav.y = robnav.y + direction * 2 - 1
    elseif robnav.r < 4 then
      robnav.z = robnav.z + (direction * 2 - 5) * (robnav.r * 2 - 5)
    else
      robnav.x = robnav.x + (direction * 2 - 5) * (robnav.r * 2 - 9)
    end
    return true
  else
    return false, err
  end
end


-- Similar to `robnav.move()`, but doesn't actually change the robots position.
-- This only calculates and updates the given position (as if the robot was
-- there).
-- 
---@param direction Sides
---@param position {x: integer, y: integer, z: integer, r: Sides}
function robnav.computeMove(direction, position)
  assert(direction >= 0 and direction < 4)
  if direction < 2 then
    position.y = position.y + direction * 2 - 1
  elseif position.r < 4 then
    position.z = position.z + (direction * 2 - 5) * (position.r * 2 - 5)
  else
    position.x = position.x + (direction * 2 - 5) * (position.r * 2 - 9)
  end
end


-- Rotates the robot 90 degrees just like `component.robot.turn()`, but updates
-- the coords of the robot. The clockwise parameter refers to the direction as
-- observed from the top of the robot. Returns true on success, or false and an
-- error message on failure.
-- 
---@param clockwise boolean
---@return boolean success
---@return string|nil err
function robnav.turn(clockwise)
  local result, err = crobot.turn(clockwise)
  if result then
    robnav.r = clockwise and turnCW[robnav.r] or turnCCW[robnav.r]
    return true
  else
    return false, err
  end
end


-- Similar to `robnav.turn()`, but doesn't actually change the robots direction.
-- This only calculates and updates the given position (as if the robot was
-- there).
-- 
---@param clockwise boolean
---@param position {x: integer, y: integer, z: integer, r: Sides}
function robnav.computeTurn(clockwise, position)
  position.r = clockwise and turnCW[position.r] or turnCCW[position.r]
end


-- Moves the robot N blocks in the specified direction. The direction can be
-- either front, back, top, or bottom and the count must be non-negative. If
-- unsuccessful, stops early and returns false.
-- 
---@param direction Sides
---@param count integer
---@return boolean success
function robnav.moveN(direction, count)
  if direction < 2 then
    local dy = direction * 2 - 1
    while count > 0 do
      if crobot.move(direction) then
        robnav.y = robnav.y + dy
        count = count - 1
      else
        return false
      end
    end
  elseif robnav.r < 4 then
    local dz = (direction * 2 - 5) * (robnav.r * 2 - 5)
    while count > 0 do
      if crobot.move(direction) then
        robnav.z = robnav.z + dz
        count = count - 1
      else
        return false
      end
    end
  else
    local dx = (direction * 2 - 5) * (robnav.r * 2 - 9)
    while count > 0 do
      if crobot.move(direction) then
        robnav.x = robnav.x + dx
        count = count - 1
      else
        return false
      end
    end
  end
  return true
end


-- Moves to the specified coordinates in an X -> Y -> Z ordering. This does not
-- apply any path-finding to get to the destination. If unsuccessful, stops
-- early and returns false.
-- 
---@param x integer
---@param y integer
---@param z integer
---@return boolean success
function robnav.moveTo(x, y, z)
  if x - robnav.x > 0 then
    robnav.turnTo(sides.left)
    if not robnav.moveN(sides.front, x - robnav.x) then
      return false
    end
  elseif robnav.x - x > 0 then
    robnav.turnTo(sides.right)
    if not robnav.moveN(sides.front, robnav.x - x) then
      return false
    end
  end
  
  if y - robnav.y > 0 then
    if not robnav.moveN(sides.top, y - robnav.y) then
      return false
    end
  elseif robnav.y - y > 0 then
    if not robnav.moveN(sides.bottom, robnav.y - y) then
      return false
    end
  end
  
  if z - robnav.z > 0 then
    robnav.turnTo(sides.front)
    if not robnav.moveN(sides.front, z - robnav.z) then
      return false
    end
  elseif robnav.z - z > 0 then
    robnav.turnTo(sides.back)
    if not robnav.moveN(sides.front, robnav.z - z) then
      return false
    end
  end
  return x == robnav.x and y == robnav.y and z == robnav.z
end


-- Rotates the robot to the requested side in the fewest number of turns. If the
-- side is bottom, top, or the side the robot is already facing, no action is
-- taken. If unsuccessful, stops early and returns false.
-- 
---@param side Sides
---@return boolean success
function robnav.turnTo(side)
  if side == sides.bottom or side == sides.top or side == robnav.r then
    return true
  end
  
  if side == turnCW[robnav.r] then
    robnav.r = crobot.turn(true) and turnCW[robnav.r] or robnav.r
  elseif side == turnCCW[robnav.r] then
    robnav.r = crobot.turn(false) and turnCCW[robnav.r] or robnav.r
  else
    robnav.r = crobot.turn(true) and turnCW[robnav.r] or robnav.r
    robnav.r = crobot.turn(true) and turnCW[robnav.r] or robnav.r
  end
  return robnav.r == side
end

return robnav
