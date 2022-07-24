--------------------------------------------------------------------------------
-- An rc daemon for running a virtual network computing server.
-- 
-- @see file://ocvnc/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local computer = require("computer")
local thread = require("thread")

local SERVICE_MAIN_PROGRAM = "/home/ocvnc/ocvnc_server.lua"

local mainThread, vncServer
local isStarting, isStopping = false, false
local lastStatusDate, lastStatusRealTime = os.date("%c"), computer.uptime()


-- Called by rc for "start" and "restart" commands, and during boot if enabled.
-- Initializes and starts the VNC server.
function start()
  if mainThread and mainThread:status() ~= "dead" then
    io.write("ocvncd already running\n")
    return
  end
  isStarting = true
  lastStatusDate, lastStatusRealTime = os.date("%c"), computer.uptime()
  
  mainThread = thread.create(function()
    -- Wait for system to finish booting before attempting to start server.
    while computer.runlevel() == "S" do
      os.sleep(0.05)
    end
    
    local VncServer = dofile(SERVICE_MAIN_PROGRAM)
    
    vncServer = VncServer:new()
    isStarting = false
    lastStatusDate, lastStatusRealTime = os.date("%c"), computer.uptime()
    vncServer:start()
  end):detach()
end


-- Called by rc for "stop" and "restart" commands. Shuts down the VNC server.
function stop()
  if not mainThread or mainThread:status() == "dead" or not vncServer then
    io.write("ocvncd already stopped\n")
    return
  end
  isStopping = true
  lastStatusDate, lastStatusRealTime = os.date("%c"), computer.uptime()
  vncServer:stop()
  if not mainThread:join(15) then
    io.stderr:write("Process still running after 15s, killing threads.\n")
    mainThread:kill()
  end
  vncServer = nil
  mainThread = nil
  isStopping = false
  lastStatusDate, lastStatusRealTime = os.date("%c"), computer.uptime()
end


-- Called by rc for "status" command. Displays status much like the UNIX
-- systemctl program does.
function status()
  local statusColor, loadStatus, activeStatus
  if isStarting then
    statusColor, loadStatus, activeStatus = "\27[33m", "unloaded", "activating"
    io.write(statusColor, "⬤")
  elseif isStopping then
    statusColor, loadStatus, activeStatus = "\27[33m", "loaded (" .. SERVICE_MAIN_PROGRAM .. ")", "deactivating"
    io.write(statusColor, "◯")
  elseif mainThread and mainThread:status() ~= "dead" then
    statusColor, loadStatus, activeStatus = "\27[32m", "loaded (" .. SERVICE_MAIN_PROGRAM .. ")", "active (running)"
    io.write(statusColor, "⬤")
  else
    statusColor, loadStatus, activeStatus = "\27[31m", "unloaded", "inactive (dead)"
    io.write(statusColor, "◯")
  end
  io.write("\27[0m  ocvncd.lua - Virtual Network Computing Daemon\n")
  io.write("   Loaded: ", loadStatus, "\n")
  io.write("   Active: ", statusColor, activeStatus, "\27[0m since ", lastStatusDate, "; ", math.floor(computer.uptime() - lastStatusRealTime), "s ago\n")
  io.write(" Main PID: ", tostring(mainThread and mainThread.pco and mainThread.pco.root), "\n")
  
  -- Show recent logs if they are found.
  local filename = "/tmp/messages"
  local file = io.open(filename, "r")
  if not file then
    filename = "/tmp/event.log"
    file = io.open(filename, "r")
    if not file then
      io.write("\nNo logs to show.\n")
      return
    end
  end
  
  local ringBuffer = {}
  local ringBufferMax = 8
  local firstIndex = 1
  for line in file:lines() do
    ringBuffer[firstIndex] = line
    firstIndex = (firstIndex % ringBufferMax) + 1
  end
  
  io.write("\nLog \"", filename, "\" (last 8 lines):\n")
  while next(ringBuffer) ~= nil do
    if ringBuffer[firstIndex] then
      io.write(ringBuffer[firstIndex], "\n")
      ringBuffer[firstIndex] = nil
    end
    firstIndex = (firstIndex % ringBufferMax) + 1
  end
  io.write("\27[7m(END)\27[0m\n")
  
  file:close()
end
