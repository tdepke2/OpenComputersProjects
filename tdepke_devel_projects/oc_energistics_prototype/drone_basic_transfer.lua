local drone = component.proxy(component.list("drone")())

local sides = {}
sides.negy = 0
sides.posy = 1
sides.negz = 2
sides.posz = 3
sides.negx = 4
sides.posx = 5

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
          computer.pullSignal(0.1)
        end
      end
      return false
    end
    
    offsetAverage = offsetAverage * #offsetHistory
    offsetAverage = offsetAverage - offsetHistory[offsetIndex] + offset
    offsetAverage = offsetAverage / #offsetHistory
    offsetHistory[offsetIndex] = offset
    offsetIndex = offsetIndex % #offsetHistory + 1
    
    computer.pullSignal(0.1)
  end
  
  pos.x = x
  pos.y = y
  pos.z = z
  return true
end

computer.beep(500, 0.2)
computer.beep(700, 0.2)
computer.beep(900, 0.2)

drone.setStatusText("Start!")
local i = 0
while true do
  --computer.pullSignal(4)
  --drone.setStatusText(tostring(i))
  if i % 2 == 0 then
    --moveTo(5, 1, 0)
  else
    --moveTo(0, 0, 0)
  end
  --moveTo(5123 + 2, 42 + 2, 6 + 2, 1)
  --moveTo(5123 - 2, 42 + 2, 6 + 2, 1)
  --moveTo(5123 - 2, 42 + 2, 6 - 2, 1)
  --moveTo(5123 + 2, 42 + 2, 6 - 2, 1)
  moveTo(5123 + 0, 42 + 0, 6 + 0)
  drone.suck(sides.negy)
  moveTo(5123 + 4, 42 + 0, 6 + 0)
  drone.drop(sides.negy)
  i = i + 1
end
