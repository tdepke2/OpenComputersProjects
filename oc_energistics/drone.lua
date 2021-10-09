-- FIXME we now use this for both drones and robots, name should change ###########################################################

local drone
if component.list("drone")() then
  drone = component.proxy(component.list("drone")())
end
local gpu
if component.list("gpu")() then
  gpu = component.proxy(component.list("gpu")())
  local screenAddress = component.list("screen")()
  gpu.bind(screenAddress)
end
local modem = component.proxy(component.list("modem")())

local COMMS_PORT = 0xE298

-- See wnet.lua for uncompressed version.
wnet={}
wnet.life=5
wnet.len=computer.getDeviceInfo()[modem.address].capacity-32
wnet.n=1
wnet.b={}
function wnet.send(m,a,p,d)
  local c=math.ceil(#d/wnet.len)
  for i=1,c do
    if a then
      m.send(a,p,wnet.n..(i==1 and"/"..c or""),string.sub(d,(i-1)*wnet.len+1,i*wnet.len))
    else
      m.broadcast(p,wnet.n..(i==1 and"/"..c or""),string.sub(d,(i-1)*wnet.len+1,i*wnet.len))
    end
    wnet.n=wnet.n+1
  end
end
function wnet.receive(ev)
  local e,a,p,s,d=ev[1],ev[3],ev[4],ev[6],ev[7]
  if not(e and e=="modem_message"and type(s)=="string"and type(d)=="string"and string.find(s,"^%d+"))then return nil end
  p=math.floor(p)
  wnet.b[a..":"..p..","..s]={computer.uptime(),d}
  for k,v in pairs(wnet.b) do
    local ka,kp,kn = string.match(k,"([%w-]+):(%d+),(%d+)")
    kn=tonumber(kn)
    local kc=tonumber(string.match(k,"/(%d+)"))
    if computer.uptime()>v[1]+wnet.life then
      wnet.b[k]=nil
    elseif kc and(kc==1 or wnet.b[ka..":"..kp..","..(kn+kc-1)])then
      d=""
      for i=1,kc do
        if not wnet.b[ka..":"..kp..","..(kn+i-1)..(i==1 and"/"..kc or"")]then d=nil break end
      end
      if d then
        for i=1,kc do
          local k2=ka..":"..kp..","..(kn+i-1)..(i==1 and"/"..kc or"")
          d=d..wnet.b[k2][2]
          wnet.b[k2]=nil
        end
        return ka,tonumber(kp),d
      end
    end
  end
end


computer.beep(500, 0.1)
computer.beep(700, 0.1)
computer.beep(900, 0.1)

if drone then
  drone.setStatusText("Start!")
elseif gpu then
  gpu.set(1, 1, "Start!    ")
end

modem.open(COMMS_PORT)

while true do
  local ev = {computer.pullSignal()}
  --wnet.send(modem, nil, COMMS_PORT, "ev = " .. tostring(ev[1]) .. "," .. tostring(ev[2]) .. "," .. tostring(ev[3]) .. "," .. tostring(ev[4]) .. "," .. tostring(ev[5]) .. "," .. tostring(ev[6]))
  local address, port, data = wnet.receive(ev)
  
  if port == COMMS_PORT then
    local dataHeader = string.match(data, "[^,]*")
    data = string.sub(data, #dataHeader + 2)
    
    if dataHeader == "drone:upload" and drone then
      drone.setStatusText("Running.")
      local fn, err = load(data)
      if fn then
        wnet.send(modem, address, COMMS_PORT, "any:drone_start,")
        local status, err = pcall(fn)
        if not status then
          wnet.send(modem, address, COMMS_PORT, "drone_error,runtime," .. err)
        end
      else
        wnet.send(modem, address, COMMS_PORT, "drone_error,compile," .. err)
      end
      drone.setStatusText("Done.")
    elseif dataHeader == "robot:upload" and not drone then
      gpu.set(1, 1, "Running.  ")
      local fn, err = load(data)
      if fn then
        wnet.send(modem, address, COMMS_PORT, "any:robot_start,")
        local status, err = pcall(fn)
        if not status then
          wnet.send(modem, address, COMMS_PORT, "robot_error,runtime," .. err)
        end
      else
        wnet.send(modem, address, COMMS_PORT, "robot_error,compile," .. err)
      end
      gpu.set(1, 1, "Done.     ")
    end
  end
end
