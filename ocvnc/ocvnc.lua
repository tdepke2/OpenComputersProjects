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
dlog.mode("debug")
dlog.standardOutput(false)
app:pushCleanupTask(dlog.osBlockNewGlobals, true, false)
local mnet = include("mnet")
local mrpc_server = include("mrpc").newServer(123)
mrpc_server.addDeclarations(dofile("ocvnc/ocvnc_mrpc.lua"))

local TARGET_HOST = "1315"

-- VncClient class definition.
local VncClient = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(VncClient, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in VncClient class.", 2)
  end
})

function VncClient:new(vals)
  self.__index = self
  self = setmetatable({}, self)
  
  self.bufferedEventQueue = {}
  
  return self
end



local function gpuGetForeground()
  local color, isPalette = gpu.getForeground()
  return isPalette and -color - 1 or color
end

local function gpuSetForeground(color)
  local c, i = gpu.getForeground()
  if (i and -c - 1 or c) ~= color then
    gpu.setForeground(color < 0 and -color - 1 or color, color < 0)
  end
end

local function gpuSetBackground(color)
  local c, i = gpu.getBackground()
  if (i and -c - 1 or c) ~= color then
    gpu.setBackground(color < 0 and -color - 1 or color, color < 0)
  end
end



function VncClient:onRedrawDisplay(host, displayState)
  local width, height = gpu.getResolution()
  gpuSetBackground(0x000000)
  gpuSetForeground(0xFFFFFF)
  gpu.fill(1, 1, width, height, " ")
  term.setCursor(1, 1)
  
  gpu.setDepth(displayState.depth)
  gpu.setResolution(displayState.res[1], displayState.res[2])
  gpu.setViewport(displayState.view[1], displayState.view[2])
  for i = 1, 16 do
    gpu.setPaletteColor(i - 1, displayState.palette[i])
  end
  
  
  local i = 1
  local textBuffer = displayState.textBuffer
  local textBufferSize = #textBuffer
  local x, y
  while i < textBufferSize do
    x = textBuffer[i]
    i = i + 1
    if type(textBuffer[i]) == "number" then
      y = textBuffer[i]
      i = i + 1
      if type(textBuffer[i]) == "number" then
        gpuSetForeground(textBuffer[i])
        i = i + 1
        if type(textBuffer[i]) == "number" then
          gpuSetBackground(textBuffer[i])
          i = i + 1
        end
      end
    end
    gpu.set(x, y, textBuffer[i])
    i = i + 1
  end
  
  
  gpuSetBackground(displayState.bg)
  gpuSetForeground(displayState.fg)
  
  
  dlog.out("onRedrawDisplay", displayState)
end
mrpc_server.functions.redraw_display = VncClient.onRedrawDisplay


function VncClient:onUpdateDisplay(host, bufferedCalls)
  for _, v in ipairs(bufferedCalls) do
    gpu[v[1]](table.unpack(v, 2, v.n))
  end
end
mrpc_server.functions.update_display = VncClient.onUpdateDisplay


local trackedInputEvents = {
  touch = true,
  drag = true,
  drop = true,
  scroll = true,
  walk = true,
  key_down = true,
  key_up = true,
  clipboard = true
}
local trackedControlEvents = {
  interrupted = true,
  tablet_use = true
}

function VncClient:mainThreadFunc()
  mrpc_server.sync.connect(TARGET_HOST)
  
  local function eventFilter(name)
    return trackedInputEvents[name] or trackedControlEvents[name]
  end
  
  local nextBufferedEventTime = 0
  while true do
    local e = {event.pullFiltered(0.1, eventFilter)}
    if e[1] then
      -- Screen touch and keyboard events include the address of the device that was used, clear this field and substitute correct address on server side.
      if trackedInputEvents[e[1]] then
        e[2] = ""
      end
      self.bufferedEventQueue[#self.bufferedEventQueue + 1] = e
    end
    
    if self.bufferedEventQueue[1] and computer.uptime() >= nextBufferedEventTime then
      nextBufferedEventTime = computer.uptime() + 0.2
      local bufferedEvents = self.bufferedEventQueue
      self.bufferedEventQueue = {}
      mrpc_server.async.client_event(TARGET_HOST, bufferedEvents)
    end
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
    while true do
      event.pull("interrupted")
      
      -- FIXME: this doesn't work so well ################################################################################
    end
    --app:exit(1)
  end)
  app:createThread("Main", VncClient.mainThreadFunc, vncClient)
  app:createThread("Network", VncClient.networkThreadFunc, vncClient)
  
  app:waitAnyThreads()
end

main()
app:exit()
