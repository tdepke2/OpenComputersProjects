local gpu = component.proxy(component.list("gpu")())
local ic = component.proxy(component.list("inventory_controller")())
local modem = component.proxy(component.list("modem")())
local robot = component.proxy(component.list("robot")())
local sides = {}
sides.bottom = 0
sides.top = 1
sides.back = 2
sides.front = 3
sides.right = 4
sides.left = 5

local COMMS_PORT = 0xE298

local function getItemFullName(item)
  return item.name .. "/" .. math.floor(item.damage) .. (item.hasTag and "n" or "")
end

local function main()
  computer.pullSignal(math.random() * 0.4)
  computer.beep(600, 0.05)
  computer.beep(800, 0.05)
  
  local flightThread = coroutine.create(function()
    while true do
      coroutine.yield()
    end
  end)
  
  while true do
    local ev = {computer.pullSignal(0.05)}
    local address, port, data = wnet.receive(ev)
    
    if port == COMMS_PORT then
      local dataHeader = string.match(data, "[^,]*")
      data = string.sub(data, #dataHeader + 2)
      
      if dataHeader == "robot_scan_adjacent" then
        local itemName = string.match(data, "[^,]*")
        local slotNum = tonumber(string.match(data, "[^,]*", #itemName + 2))
        local foundSide
        gpu.set(1, 2, "name = " .. itemName)
        gpu.set(1, 3, "slot = " .. slotNum)
        
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
        
        gpu.set(1, 4, "foundSide = " .. tostring(foundSide))
        wnet.send(modem, address, COMMS_PORT, "robot_scan_adjacent_result," .. tostring(foundSide))
      elseif dataHeader == "robot_halt" then
        computer.pullSignal(math.random() * 0.4)
        computer.beep(800, 0.05)
        computer.beep(600, 0.05)
        os.exit()
      end
    end
    
    if coroutine.status(flightThread) == "dead" then
      break
    end
    local status, msg = coroutine.resume(flightThread)
    if not status then
      computer.beep(300, 0.2)
      computer.beep(300, 0.2)
      wnet.send(modem, nil, COMMS_PORT, "robot_error,runtime," .. msg)    -- FIXME can we change this to use packer? ########################################
      break
    end
  end
  
  computer.beep(800, 0.05)
  computer.beep(600, 0.05)
end

main()
