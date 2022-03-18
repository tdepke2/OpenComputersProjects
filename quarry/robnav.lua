--[[
Robot navigation without a navigation upgrade. Extends the base robot component
move() and turn() functions with local coordinates tracking.


--]]

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

-- robnav.getCoords(): number, number, number, number
-- 
-- Gets the current coordinates of the robot. This is just for convenience,
-- directly accessing the robnav.x, robnav.y, etc. values is fine too.
function robnav.getCoords()
  return robnav.x, robnav.y, robnav.z, robnav.r
end

-- robnav.setCoords(x: number, y: number, z: number, side: number)
-- 
-- Sets the current coordinates of the robot, effectively changing the
-- local-space point of reference. If these match the block coordinates of the
-- robot in the world (where sides.front points to the south), then the robot's
-- coordinate system will be put in world-space.
function robnav.setCoords(x, y, z, side)
  robnav.x = x
  robnav.y = y
  robnav.z = z
  robnav.r = side
end

-- robnav.move(direction: number): boolean[, string]
-- 
-- Moves the robot 1 block just like component.robot.move(), but updates the
-- coords of the robot. The direction can be either front, back, top, or bottom.
-- Returns true on success, or false and an error message on failure.
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

-- robnav.turn(clockwise: boolean): boolean[, string]
-- 
-- Rotates the robot 90 degrees just like component.robot.turn(), but updates
-- the coords of the robot. The clockwise parameter refers to the direction as
-- observed from the top of the robot. Returns true on success, or false and an
-- error message on failure.
function robnav.turn(clockwise)
  local result, err = crobot.turn(clockwise)
  if result then
    robnav.r = clockwise and turnCW[robnav.r] or turnCCW[robnav.r]
    return true
  else
    return false, err
  end
end

-- robnav.moveN(direction: number, count: number): boolean
-- 
-- Moves the robot N blocks in the specified direction. The direction can be
-- either front, back, top, or bottom and the count must be non-negative. If
-- unsuccessful, stops early and returns false.
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

-- robnav.moveTo(x: number, y: number, z: number): boolean
-- 
-- Moves to the specified coordinates in an X -> Y -> Z ordering. This does not
-- apply any path-finding to get to the destination. If unsuccessful, stops
-- early and returns false.
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

-- robnav.turnTo(side: number): boolean
-- 
-- Rotates the robot to the requested side in the fewest number of turns. If the
-- side is bottom, top, or the side the robot is already facing, no action is
-- taken. If unsuccessful, stops early and returns false.
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
