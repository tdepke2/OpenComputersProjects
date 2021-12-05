local crafting = requireComponent("crafting")
local eeprom = requireComponent("eeprom")
local ic = requireComponent("inventory_controller")
local modem = requireComponent("modem")
local robot = requireComponent("robot")
local sides = require("sides")

local include = require("include")
local packer = include("packer")

local COMMS_PORT = 0xE298

local facingSide = sides.front
local craftingServerAddress
local craftingTask2
local craftingState

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
    robot.turn(false)
  elseif diffRotation == 4 then
    robot.turn(true)
    robot.turn(true)
  elseif diffRotation == -2 then
    robot.turn(true)
  end
  facingSide = side
end

-- Stop the currently running crafting task and report error back to crafting
-- server. This is different from throwing an exception because exceptions
-- indicate an error that will require a manual restart of system(s). We can
-- still recover from a failed crafting task.
local function cancelCraftingTask(errMessage)
  print("Error: " .. errMessage)
  wnet.send(modem, craftingServerAddress, COMMS_PORT, packer.pack.robot_error("crafting_failed", craftingTask2.ticket .. ";" .. errMessage))
  rotateToSide(sides.front)
end


-- Replace EEPROM contents and power off device.
local function handleRobotUploadEeprom(_, _, _, srcCode)
  eeprom.set(srcCode)
  computer.shutdown()
end
packer.callbacks.robot_upload_eeprom = handleRobotUploadEeprom

-- Run the given lua script and report the result.
local function handleRobotUploadRlua(_, address, _, srcCode)
  local fn, ret = load(srcCode)
  if fn then
    local ret = table.pack(pcall(fn))
    if ret[1] then
      local message = "Returned: "
      for i = 2, ret.n do
        message = message .. tostring(ret[i]) .. ", "
      end
      message = string.sub(message, 1, -3)
      print(message)
      wnet.send(modem, address, COMMS_PORT, packer.pack.robot_upload_rlua_result(message))
    else
      print("Error: " .. ret[2])
      wnet.send(modem, address, COMMS_PORT, packer.pack.robot_upload_rlua_result("Error: " .. ret[2]))
    end
  else
    print("Error: " .. ret)
    wnet.send(modem, address, COMMS_PORT, packer.pack.robot_upload_rlua_result("Error: " .. ret))
  end
end
packer.callbacks.robot_upload_rlua = handleRobotUploadRlua

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
local function handleRobotPrepareCraft(_, address, _, craftingTask)
  print("prepare")
  craftingServerAddress = address
  assert(not craftingTask2, "Attempt to start crafting task that is already pending.")
  assert(not craftingTask.recipe.station, "Attempt to start crafting task with non-crafting recipe.")
  rotateToSide(craftingTask.side)
  craftingTask2 = craftingTask
end
packer.callbacks.robot_prepare_craft = handleRobotPrepareCraft

-- Pull items from drone inventory on targetSide (should only be top, front, or
-- bottom). The item totals are reduced from craftingState.extractRemaining so
-- we don't pull more than we need.
local function fillCraftingSlots(targetSide)
  -- FIXME this format should probably be used for other getAllStacks() calls. also, note that getAllStacks() is not listed in documentation for ic but it is there. ###############################
  -- also, just for reference the iter from getAllStacks() takes a snapshot of the inventory (that's why it blocks for 1 tick only). calling reset() does not take a new snapshot, you have to call getAllStacks() for new iter. ############
  -- Scan target inventory for the extract items.
  local slot = 1
  for item in ic.getAllStacks(targetSide) do
    if next(item) ~= nil then
      local fullName = getItemFullName(item)
      
      -- If item is one we need, go through each slot where it is needed and try to extract it there.
      if craftingState.extractRemaining[fullName] then
        for destSlot, amount in pairs(craftingState.extractRemaining[fullName]) do
          -- Transform destSlot from crafting indexed (1 to 9) to robot indexed (1 to 16). Compute the remaining amount we can actually extract too.
          local destSlotRobot = destSlot + math.floor((destSlot - 1) / 3)
          local extractAmount = math.min(amount, math.floor(robot.space(destSlotRobot)))
          if extractAmount > 0 then
            robot.select(destSlotRobot)
            craftingState.extractRemaining[fullName][destSlot] = amount - math.floor(ic.suckFromSlot(targetSide, slot, extractAmount) or 0)
            
            -- Remove slot entry if amount is zero, and whole item entry if table is empty.
            if craftingState.extractRemaining[fullName][destSlot] == 0 then
              craftingState.extractRemaining[fullName][destSlot] = nil
              if next(craftingState.extractRemaining[fullName]) == nil then
                craftingState.extractRemaining[fullName] = nil
                break
              end
            end
          end
        end
      end
    end
    slot = slot + 1
  end
end

-- Get a comma-separated string of recipe output item types. This is used to
-- identify the recipe for the user.
local function getRecipeOutputStr(recipe)
  local str = ""
  for outputName, amount in pairs(recipe.out) do
    str = str .. amount .. " " .. outputName .. ", "
  end
  return string.sub(str, 1, -3)
end

-- 
local function handleRobotStartCraft(_, _, _)
  print("start")
  assert(craftingTask2, "Attempt to start nil crafting task.")
  
  -- multiple iterations of pull-craft-push may be needed.
  -- always pull batchSize (or amount remaining) into slot, we may or may not get all of the items depending on if other bots grabbed them or if max slot size reached.
  
  -- The side to interact with will be in front, top, or bottom only.
  local targetSide = sides.front
  if craftingTask2.side == sides.top or craftingTask2.side == sides.bottom then
    targetSide = craftingTask2.side
  end
  
  --[[
  craftingState: {
    extractRemaining: {
      <item name>: {
        <slot>: <remaining amount>
        ...
      }
      ...
    }
    insertRemaining: {
      <item name>: <remaining amount>
      ...
    }
  }
  --]]
  
  if not craftingState then
    craftingState = {}
    
    -- Keep track of remaining items to pull from inventory (and slot numbers to put them).
    craftingState.extractRemaining = {}
    for _, input in ipairs(craftingTask2.recipe.inp) do
      craftingState.extractRemaining[input[1]] = {}
      for i = 2, #input do
        craftingState.extractRemaining[input[1]][input[i]] = craftingTask2.numBatches
      end
    end
    
    -- Keep track of remaining items to push back into inventory.
    craftingState.insertRemaining = {}
    for outputName, amount in pairs(craftingTask2.recipe.out) do
      craftingState.insertRemaining[outputName] = amount * craftingTask2.numBatches
    end
  else
    -- DroneInv must have been full, so it got emptied out a bit and start-craft called again.
    -- we should try to push items in selected slot and continue.
  end
  
  -- Continuously extract items into drone slots until we run out. Push completed items back into the drone inventory.
  while next(craftingState.extractRemaining) ~= nil do
    fillCraftingSlots(targetSide)
    
    robot.select(13)
    if not crafting.craft() then
      cancelCraftingTask("Recipe for " .. getRecipeOutputStr(craftingTask2.recipe) .. " failed to craft. Please check recipe.")
      return
    end
    
    
    -- FIXME need to break this up to run asynchronous with packet handler thread
    
    -- FIXME below probably not gonna work for crafting operations that give more than one output. #####################################
    
    
    local craftedItem = ic.getStackInInternalSlot(13)
    local craftedItemName = getItemFullName(craftedItem)
    craftingState.insertRemaining[craftedItemName] = (craftingState.insertRemaining[craftedItemName] or 0) - math.floor(craftedItem.size)
    if craftingState.insertRemaining[craftedItemName] == 0 then
      craftingState.insertRemaining[craftedItemName] = nil
    elseif craftingState.insertRemaining[craftedItemName] < 0 then
      cancelCraftingTask("Recipe for " .. getRecipeOutputStr(craftingTask2.recipe) .. " crafted extra " .. craftedItemName .. ". Please check recipe.")
      return
    end
    
    if not robot.drop(targetSide) then
      -- FIXME need to report full and return
    end
  end
  
  if next(craftingState.insertRemaining) ~= nil then
    cancelCraftingTask("Recipe for " .. getRecipeOutputStr(craftingTask2.recipe) .. " did not craft enough items. Please check recipe.")
    return
  end
  
  print("finished task " .. craftingTask2.taskID .. " for " .. craftingTask2.ticket)
  wnet.send(modem, craftingServerAddress, COMMS_PORT, packer.pack.robot_finished_craft(craftingTask2.ticket, craftingTask2.taskID))
  
  --print("ready to craft, extractRemaining=")
  --for k, _ in pairs(craftingState.extractRemaining) do
  --  print("fullName -> " .. k)
  --end
  
  rotateToSide(sides.front)
  craftingTask2 = nil
  craftingState = nil
end
packer.callbacks.robot_start_craft = handleRobotStartCraft

-- Exit program and return control to firmware.
local function handleRobotHalt(_, _, _)
  os.exit()
end
packer.callbacks.robot_halt = handleRobotHalt


local function main()
  computer.pullSignal(math.random() * 0.4)
  computer.beep(600, 0.05)
  computer.beep(800, 0.05)
  
  -- FIXME should change to include modem address? then we don't have to worry about extra delay before sending beep when robot starts (because each device has a unique packet to start it) #################
  modem.setWakeMessage("robot_activate")
  
  --[[
  
  --delet this
  
  
  
  
  local s = ""
  for k, v in pairs(robot) do
    s = s .. k .. ", "
  end
  print(s)
  
  --print(tostring(robot.drop(sides.front, 1)))
  --print(tostring(robot.drop(sides.top, 1)))
  --print(tostring(robot.drop(sides.bottom, 1)))
  --print(tostring(robot.drop(sides.back, 1))) -- unsupported side error
  --print(tostring(robot.drop(sides.left, 1)))
  --print(tostring(robot.drop(sides.right, 1))) -- unsupported side error
  --
  local ret = {ic.suckFromSlot(sides.front, 2, 5)}
  for _, v in pairs(ret) do
    print(tostring(v))
  end
  print("doing it")
  
  --
  for i = 1, 80 do
    robot.select((i % 16) + 1)
  end
  print("finished 80 calls to select()")
  
  for i = 1, 80 do
    robot.space((i % 16) + 1)
  end
  print("finished 80 calls to space()")    -- actually a free operation!
  
  for i = 1, 80 do
    robot.count((i % 16) + 1)
  end
  print("finished 80 calls to count()")    -- actually a free operation!
  
  for i = 1, 80 do
    ic.getStackInInternalSlot(1)
  end
  print("finished 80 calls to getStackInInternalSlot()")
  for i = 1, 80 do
    ic.getSlotStackSize(sides.front, 1)
  end
  print("finished 80 calls to getSlotStackSize()")
  for i = 1, 80 do
    ic.getStackInSlot(sides.front, 1)
  end
  print("finished 80 calls to getStackInSlot()")
  --]]
  
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
