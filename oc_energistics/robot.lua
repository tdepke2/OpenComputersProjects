-- Wrapper for loading components.
function requireComponent(comp, optional)
  local c = component.list(comp)()
  assert(c or optional, "Component " .. comp .. " not found.")
  return component.proxy(c or "")
end

local gpu = requireComponent("gpu", true)
local modem = requireComponent("modem")

-- Implementation for loading libraries without OpenOS.
local libs = {}
function require(libName)
  assert(libs[libName], "Library look-up for " .. libName .. " failed.")
  return libs[libName]
end
libs.include = require

-- Bare minimum print functionality.
function print(str)
  local w, h = gpu.getResolution()
  repeat
    gpu.copy(1, 2, w, h - 2, 0, -1)
    gpu.set(1, h - 1, str .. string.rep(" ", w - #str))
    str = string.sub(str, w + 1)
  until str == ""
end
if gpu then
  gpu.bind(component.list("screen")() or "")
else
  print = function() end
end

function os.exit(val)
  error({code=val, reason="terminated"})
end

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

local COMMS_PORT = 0xE298


computer.beep(500, 0.1)
computer.beep(700, 0.1)
computer.beep(900, 0.1)
modem.open(COMMS_PORT)

print("Ready! Listening on port " .. COMMS_PORT .. ".")

while true do
  local ev = {computer.pullSignal()}
  local address, port, data = wnet.receive(ev)
  
  if port == COMMS_PORT then
    local header = string.match(data, "[^,]*")
    data = string.sub(data, #header + 2)
    
    if header == "robot_upload" then
      local libName = string.match(data, "[^,]*")
      local fn, ret = load(string.sub(data, #libName + 2))
      if fn then
        if libName == "" then
          print("Running...")
          wnet.send(modem, address, COMMS_PORT, "robot_started,")
        else
          print("Loading lib " .. libName .. ".")
        end
        local status, ret = pcall(fn)
        if status then
          libs[libName] = ret
        else
          print("Error in file " .. libName .. ": " .. ret)
          wnet.send(modem, address, COMMS_PORT, "robot_error,runtime,In file " .. libName .. ": " .. ret)
        end
      else
        print("Error in file " .. libName .. ": " .. ret)
        wnet.send(modem, address, COMMS_PORT, "robot_error,compile,In file " .. libName .. ": " .. ret)
      end
      if libName == "" then
        print("Done.")
      end
    end
  end
end
