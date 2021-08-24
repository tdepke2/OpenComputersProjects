local drone = component.proxy(component.list("drone")())
local modem = component.proxy(component.list("modem")())
local sides = {}
sides.negy = 0
sides.posy = 1
sides.negz = 2
sides.posz = 3
sides.negx = 4
sides.posx = 5

local COMMS_PORT = 0xE298

-- Absolute position in world.
local pos = {}
pos.x = 5123
pos.y = 42
pos.z = 6

local function moveTo(x, y, z, threshold, resetOnFail)
  threshold = threshold or 0.5
  resetOnFail = resetOnFail or false
  
  drone.move(x - pos.x, y - pos.y, z - pos.z)
  local offsetHistory = {1, 1, 1}
  local offsetIndex = 1
  local offsetAverage = 1
  
  while true do
    local offset = drone.getOffset()
    if offset < threshold then
      if threshold >= 1 or drone.getVelocity() < threshold then
        break
      end
    elseif math.abs(offset - offsetAverage) < threshold / 10 then
      drone.move(-x + pos.x, -y + pos.y, -z + pos.z)
      if resetOnFail then
        while drone.getOffset() >= threshold do
          coroutine.yield()
        end
      end
      return false
    end
    
    offsetAverage = offsetAverage * #offsetHistory
    offsetAverage = offsetAverage - offsetHistory[offsetIndex] + offset
    offsetAverage = offsetAverage / #offsetHistory
    offsetHistory[offsetIndex] = offset
    offsetIndex = offsetIndex % #offsetHistory + 1
    
    coroutine.yield()
  end
  
  pos.x = x
  pos.y = y
  pos.z = z
  return true
end

local function main()
  computer.beep(600, 0.05)
  computer.beep(800, 0.05)
  
  local flightThread = coroutine.create(function()
    --while true do
      moveTo(5123, 46, 6)
      moveTo(5123, 42, 6)
    --end
  end)
  
  while true do
    local ev = {computer.pullSignal(0.05)}
    
    if coroutine.status(flightThread) == "dead" then
      break
    end
    local status, msg = coroutine.resume(flightThread)
    if not status then
      computer.beep(300, 0.2)
      computer.beep(300, 0.2)
      wnet.send(modem, nil, COMMS_PORT, "drone_error,runtime," .. msg)
      break
    end
  end
  
  computer.beep(800, 0.05)
  computer.beep(600, 0.05)
end

main()
