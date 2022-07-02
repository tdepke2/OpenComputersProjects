--[[

Planning:
  * ocvnc <host> [<port>]
  * send signals to server
  * call GPU funcs from server
  * special key combo stops the connection? (what about ctrl+c or hard ctrl+c)
  * options for ACPI shutdown or reboot?
  * what if server screen and client screen tier don't match? if server has tier 3 and client has tier 2 then this probably doesn't work.
  * use event library to pull signals we care about and send with RPC call (signals should not be suppressed on client, unless?)

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

mrpc_server.addDeclarations(dofile("ocvnc/ocvnc_mrpc.lua"))

local DLOG_FILE_OUT = "/tmp/messages"
local TARGET_HOST = "1315"

-- VncClient class definition.
local VncClient = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(VncClient, {
  __index = function(t, k)
    dlog.verboseError("Attempt to read undefined member " .. tostring(k) .. " in VncClient class.", 4)
  end
})

function VncClient:new(vals)
  self.__index = self
  self = setmetatable({}, self)
  
  
  
  return self
end


function VncClient:handleGpuSetForeground(host, count)
  dlog.out("d", "handleGpuSetForeground ", count)
end
mrpc_server.functions.gpu_set_foreground = VncClient.handleGpuSetForeground


function VncClient:mainThreadFunc(mainContext)
  dlog.out("main", "Main thread starts.")
  
  mrpc_server.sync.connect(TARGET_HOST)
  
  while true do
    os.sleep(10)
  end
  
  dlog.out("main", "Main thread ends.")
end


function VncClient:networkThreadFunc(mainContext)
  dlog.out("main", "Network thread starts.")
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(self, host, port, message)
  end
  dlog.out("main", "Network thread ends.")
end


-- Get command-line arguments.
local args = {...}

-- Main program starts here.
local function main()
  local mainContext = {}
  mainContext.threadSuccess = false
  mainContext.killProgram = false
  
  -- Wrapper for os.exit() that restores the blocking of globals. Threads
  -- spawned from main() can just call os.exit() instead of this version.
  local function exit(code)
    dlog.osBlockNewGlobals(false)
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
  
  local vncClient = VncClient:new()
  
  local mainThread = thread.create(VncClient.mainThreadFunc, vncClient, mainContext)
  local networkThread = thread.create(VncClient.networkThreadFunc, vncClient, mainContext)
  
  waitThreads({interruptThread, mainThread, networkThread})
  
  dlog.out("main", "Killing threads and stopping program.")
  interruptThread:kill()
  networkThread:kill()
end

main()
dlog.osBlockNewGlobals(false)
