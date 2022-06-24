--[[

Requirements:
  * only one client connects at a time (due to network bandwidth and single user system)

Planning:
  * start ocvnc daemon [<port>]
  * should we collect all chars on screen to send to client, or start client with black screen (probably first one)?
  * do we bind to first active screen (if it exists) and stay that way, or dynamically rebind?

--]]

-- OS libraries.
local component = require("component")
local computer = require("computer")
local event = require("event")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include("mnet")
local mrpc_server = include("mrpc").newServer(123)

mrpc_server.addDeclarations(dofile("net_testing/ocvnc_mrpc.lua"))

local DLOG_FILE_OUT = "/tmp/messages"

-- VncServer class definition.
local VncServer = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(VncServer, {
  __index = function(t, k)
    dlog.verboseError("Attempt to read undefined member " .. tostring(k) .. " in VncServer class.", 4)
  end
})

function VncServer:new()
  self.__index = self
  self = setmetatable({}, self)
  
  self.activeClient = false
  self.gpuRealFuncs = false
  
  return self
end


function VncServer:destroy()
  if self.gpuRealFuncs then
    for k, v in pairs(self.gpuRealFuncs) do
      component.gpu[k] = v
    end
  end
  print("restored gpu calls")
end


function VncServer:handleConnect(host)
  self.activeClient = host
  
  local gpuRealFuncs = {}
  self.gpuRealFuncs = gpuRealFuncs
  for k, v in pairs(component.gpu) do
    
    if k == "setForeground" then
      local count = 0
      local lastTime = 0
      
      gpuRealFuncs[k] = v
      component.gpu[k] = function(...)
        gpuRealFuncs[k](...)
        count = count + 1
        if computer.uptime() >= lastTime + 0.2 then
          lastTime = computer.uptime()
          mrpc_server.async.gpu_set_foreground(host, count)
          count = 0
        end
      end
    end
  end
  
  print("replaced gpu calls!")
  os.sleep(1)
  print("one")
  component.gpu.setForeground(8, true)
  print("two")
end
mrpc_server.functions.connect = VncServer.handleConnect


function VncServer:networkThreadFunc(mainContext)
  dlog.out("main", "Network thread starts.")
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(self, host, port, message)
  end
  dlog.out("main", "Network thread ends.")
end


-- Command-line arguments, and forward declaration for cleanup tasks.
local args = {...}
local cleanup

-- Main program starts here.
local function main()
  local mainContext = {}
  mainContext.threadSuccess = false
  mainContext.killProgram = false
  
  -- Wrapper for os.exit() that restores the blocking of globals. Threads
  -- spawned from main() can just call os.exit() instead of this version.
  local function exit(code)
    cleanup()
    os.exit(code)
  end
  
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  -- Blocks until any of the given threads finish. If threadSuccess is still
  -- false and a thread exits, reports error and exits program.
  local function waitThreads(threads)
    thread.waitForAny(threads)
    if interruptThread:status() == "dead" or mainContext.killProgram then
      exit()
    elseif not mainContext.threadSuccess then
      io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
      exit()
    end
    mainContext.threadSuccess = false
  end
  
  if DLOG_FILE_OUT ~= "" then
    dlog.setFileOut(DLOG_FILE_OUT, "w")
  end
  
  -- Check for any command-line arguments passed to the program.
  if next(args) ~= nil then
    if args[1] == "test" then
      io.write("Tests not yet implemented.\n")
      exit()
    else
      io.stderr:write("Unknown argument \"", tostring(args[1]), "\".\n")
      exit()
    end
  end
  
  dlog.setStdOut(false)
  
  local vncServer = VncServer:new()
  
  cleanup = function()
    vncServer:destroy()
    dlog.osBlockNewGlobals(false)
  end
  
  local networkThread = thread.create(VncServer.networkThreadFunc, vncServer, mainContext)
  
  waitThreads({interruptThread, networkThread})
  
  dlog.out("main", "Killing threads and stopping program.")
  interruptThread:kill()
  networkThread:kill()
end

main()
cleanup()
