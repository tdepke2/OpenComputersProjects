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
local gpu = component.gpu
local term = require("term")
local thread = require("thread")

-- User libraries.
local include = require("include")
local app = include("app"):new()
local dlog = include("dlog")
app:pushCleanupTask(dlog.osBlockNewGlobals, true, false)
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


function VncClient:onRedrawDisplay(host, displayState)
  local width, height = gpu.getResolution()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  --gpu.fill(1, 1, width, height, " ")
  --term.setCursor(1, 1)
  
  --gpu.setDepth()
  --gpu.setResolution()
  --gpu.setViewport()
  
  --gpu.setPaletteColor()
  
  --for 
  --gpu.set()
  --end
  
  --gpu.setBackground()
  --gpu.setForeground()
  
  
  dlog.out("onRedrawDisplay", displayState)
end
mrpc_server.functions.redraw_display = VncClient.onRedrawDisplay


function VncClient:onUpdateDisplay(host, bufferedCalls)
  for _, v in ipairs(bufferedCalls) do
    gpu[v[1]](table.unpack(v, 2, v.n))
  end
end
mrpc_server.functions.update_display = VncClient.onUpdateDisplay


function VncClient:mainThreadFunc()
  mrpc_server.sync.connect(TARGET_HOST)
  
  while true do
    os.sleep(10)
  end
end


function VncClient:networkThreadFunc()
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(self, host, port, message)
  end
end


-- Get command-line arguments.
local args = {...}

-- Main program starts here.
local function main()
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
  
  app:createThread("Interrupt", function()
    event.pull("interrupted")
    app:exit(1)
  end)
  app:createThread("Main", VncClient.mainThreadFunc, vncClient)
  app:createThread("Network", VncClient.networkThreadFunc, vncClient)
  
  app:waitAnyThreads()
end

main()
app:exit()
