local crafting = requireComponent("crafting")
local ic = requireComponent("inventory_controller")
local modem = requireComponent("modem")
local robot = requireComponent("robot")
local sides = require("sides")

local include = require("include")
local packer = include("packer")

local COMMS_PORT = 0xE298

local facingSide = sides.front

local function getItemFullName(item)
  return item.name .. "/" .. math.floor(item.damage) .. (item.hasTag and "n" or "")
end

-- Rotate the robot from the current side to the given side. Does nothing if
-- side is top or bottom, or robot is already facing the given side.
local function rotateToSide(side)
  if side == sides.bottom or side == sides.top or side == facingSide then
    return
  end
  
  -- Convert to back = 0, right = 2, front = 4, left = 6 notation.
  local rotation = side - 2 + (side % 2) * 3
  local facingRotation = facingSide - 2 + (facingSide % 2) * 3
  local diffRotation = (rotation - facingRotation + 2) % 8 - 2
  if diffRotation == 2 then
    robot.turnLeft()
  elseif diffRotation == 4 then
    robot.turnAround()
  elseif diffRotation == -2 then
    robot.turnRight()
  end
  facingSide = side
end


-- Scan inventories on all sides. Find one that has the requested item in the
-- slot and report the side number back.
local function handleRobotScanAdjacent(_, address, _, itemName, slotNum)
  local foundSide
  print("name = " .. itemName)
  print("slot = " .. slotNum)
  
  local function checkForItem(scanSide, facingSide)
    local item = ic.getStackInSlot(scanSide, slotNum)
    if item and getItemFullName(item) == itemName then
      foundSide = facingSide
    end
  end
  
  checkForItem(sides.bottom, sides.bottom)
  checkForItem(sides.top, sides.top)
  checkForItem(sides.front, sides.front)
  robot.turn(true)
  checkForItem(sides.front, sides.right)
  robot.turn(true)
  checkForItem(sides.front, sides.back)
  robot.turn(true)
  checkForItem(sides.front, sides.left)
  robot.turn(true)
  
  print("foundSide = " .. tostring(foundSide))
  wnet.send(modem, address, COMMS_PORT, packer.pack.robot_scan_adjacent_result(foundSide))
end
packer.callbacks.robot_scan_adjacent = handleRobotScanAdjacent

-- 
local function handleRobotPrepareCraft(_, _, _, craftingTask)
  print("cool")
end
packer.callbacks.robot_prepare_craft = handleRobotPrepareCraft

-- Exit program and return control to firmware.
local function handleRobotHalt(_, _, _)
  os.exit()
end
packer.callbacks.robot_halt = handleRobotHalt


local function main()
  computer.pullSignal(math.random() * 0.4)
  computer.beep(600, 0.05)
  computer.beep(800, 0.05)
  
  local mainThread = coroutine.create(function()
    while true do
      coroutine.yield()
    end
  end)
  
  --[[
  incoming craft request:
  robot turns to face inv
  cache operation until we receive start
  
  on start:
  robot pulls items into crafting slots sequentially (pull table is padded with zeros, starts at first slot and goes to last used)
  robot selects slot 13, calls craft(), confirms success, and reduces craftAmount by getStackInInternalSlot()
  robot.drop() into inventory (may need to call a few times while it fails, like up to 20?), repeat above step if craftAmount > 0
  if outputs > 1, scan entire inventory for residual items (use getStackInInternalSlot()) and push them out
  send packet with ticket, drone inv index, crafted items
  if we didn't craft exactly the amount of required stuff, send error back
  
  receive packet looks like:
  droneInvIndex: <number>
  side: <number>
  numBatches: <number>
  ticket: <string>
  recipe: {    -- whoops, we actually want to use the same recipe format as in crafting.
    pull {
      <drone inv slot>: <amount>
      2: 0
      3: 0
      4: 2
    }
    outputs {
      <item name>: amount
      ...
    }
  }
  
  send packet looks like:
  ticket,
  index,
  items
  
  send error uses robot_error and specifies message
  
  --]]
  
  while true do
    local ev = {computer.pullSignal(0.05)}
    local address, port, message = wnet.receive(ev)
    if port == COMMS_PORT then
      packer.handlePacket(nil, address, port, message)
    end
    
    if coroutine.status(mainThread) == "dead" then
      break
    end
    assert(coroutine.resume(mainThread))
  end
end

-- Catch exceptions in main() so that we can restore robot orientation and play a sound when robot shuts off normally or encounters error.
local status, ret = pcall(main)
rotateToSide(sides.front)
computer.pullSignal(math.random() * 0.4)
if not status and type(ret) == "string" then
  computer.beep(1000, 0.4)
  computer.beep(1000, 0.4)
  error(ret)
else
  computer.beep(800, 0.05)
  computer.beep(600, 0.05)
end
