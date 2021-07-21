local drone = component.proxy(component.list("drone")())
local modem = component.proxy(component.list("modem")())
local sides = {}
sides.negy = 0
sides.posy = 1
sides.negz = 2
sides.posz = 3
sides.negx = 4
sides.posx = 5

local COMMS_PORT = 0x1F48

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

modem.open(COMMS_PORT)

local baseStation
while true do
  local ev, _, sender, port, _, message, arg1 = computer.pullSignal()
  
  if ev == "modem_message" and port == COMMS_PORT then
    if message == "FIND_DRONE" then
      drone.setStatusText("Link:\n" .. sender:sub(1, 4))
      modem.send(sender, COMMS_PORT, "FIND_DRONE_ACK")
      baseStation = sender
    elseif message == "UPLOAD" and arg1 then
      drone.setStatusText("Running");
      local fn, err = load(arg1)
      if fn then
        local status, err = pcall(fn)
        if not status then
          modem.send(sender, COMMS_PORT, "RUNTIME_ERR", err)
        end
      else
        modem.send(sender, COMMS_PORT, "COMPILE_ERR", err)
      end
      drone.setStatusText("Done");
    end
  end
end
