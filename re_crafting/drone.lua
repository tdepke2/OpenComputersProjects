local drone = component.proxy(component.list("drone")())
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


computer.beep(500, 0.2)
computer.beep(700, 0.2)
computer.beep(900, 0.2)

drone.setStatusText("Start!")

modem.open(COMMS_PORT)

while true do
  local ev = {computer.pullSignal()}
  wnet.send(modem, nil, COMMS_PORT, "ev = " .. tostring(ev[1]) .. "," .. tostring(ev[2]) .. "," .. tostring(ev[3]) .. "," .. tostring(ev[4]) .. "," .. tostring(ev[5]) .. "," .. tostring(ev[6]))
  local address, port, data = wnet.receive(ev)
  
  if port == COMMS_PORT then
    local dataType = string.match(data, "[^,]*")
    data = string.sub(data, #dataType + 2)
    
    if dataType == "drone_upload" then
      drone.setStatusText("Running.")
      local fn, err = load(data)
      if fn then
        local status, err = pcall(fn)
        if not status then
          wnet.send(modem, address, COMMS_PORT, "drone_runtime_error," .. err)
        end
      else
        wnet.send(modem, address, COMMS_PORT, "drone_compile_error," .. err)
      end
      drone.setStatusText("Done.")
    end
  end
end

--[[
local baseStation
while true do
  local ev, _, sender, port, _, message, arg1 = computer.pullSignal()
  
  if ev == "modem_message" and port == COMMS_PORT then
    --if message == "FIND_DRONE" then
      --drone.setStatusText("Link:\n" .. sender:sub(1, 4))
      --modem.send(sender, COMMS_PORT, "FIND_DRONE_ACK")
      --baseStation = sender
    if message == "drone_upload" and arg1 then
      drone.setStatusText("Running.")
      local fn, err = load(arg1)
      if fn then
        local status, err = pcall(fn)
        if not status then
          modem.send(sender, COMMS_PORT, "drone_runtime_error", err)
        end
      else
        modem.send(sender, COMMS_PORT, "drone_compile_error", err)
      end
      drone.setStatusText("Done.")
    end
  end
end
--]]
