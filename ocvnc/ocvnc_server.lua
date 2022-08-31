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
local gpu = component.gpu
local keyboard_c = component.keyboard
local screen_c = component.screen
local term = require("term")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.mode("release")
local app = include("app"):new()

-- FIXME something bad happened here when running in the daemon, huh #####################################################################
--app:pushCleanupTask(dlog.osBlockNewGlobals, true, false)

local dcap = include("dcap")
local mnet = include("mnet")
local mrpc_server = include("mrpc").newServer(530)
mrpc_server.addDeclarations(dofile("/home/ocvnc/ocvnc_mrpc.lua"))

local PREVENT_CURSOR_BLINK = true
local ENABLE_PASSIVE_BUFFER = true
local KEEPALIVE_INTERVAL = 35

-- VncServer class definition.
local VncServer = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(VncServer, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in VncServer class.", 2)
  end
})

function VncServer:new()
  self.__index = self
  self = setmetatable({}, self)
  
  self.activeClient = false
  self.gpuRealFuncs = false
  
  self.bufferedCallQueue = false
  
  self.running = true
  
  -- Disable cursor blinking. The blinking doesn't work very well because the constant network events reset blink timer.
  -- It would be ideal to only turn off blinking when a client connects, but it seems like term.setCursorBlink() only has an effect when run in a foreground process.
  if PREVENT_CURSOR_BLINK then
    term.setCursorBlink(false)
  end
  
  app:pushCleanupTask(function()
    if self.activeClient then
      mrpc_server.async.server_disconnect(self.activeClient)
    end
    if PREVENT_CURSOR_BLINK then
      term.setCursorBlink(true)
    end
    self:restoreOverrides()
  end)
  
  return self
end


function VncServer:restoreOverrides()
  if self.gpuRealFuncs then
    for k, v in pairs(self.gpuRealFuncs) do
      gpu[k] = v
    end
    self.gpuRealFuncs = false
    print("restored gpu calls")
  else
    print("nothing to restore")
  end
end


--[[
state that we need to sync (and then restore later):
* current character array with fg/bg
* current fg/bg
* current palette colors
* current depth
* current resolution
* current viewport

* make sure the client screen and gpu tier >= server screen or gpu tier!
--]]

local gpuTrackedCalls = {
  bind = true,  -- this one is tricky
  setBackground = true,
  setForeground = true,
  setPaletteColor = true,
  setDepth = true,
  setResolution = true,
  setViewport = true,
  set = true,
  copy = true,
  fill = true
  
  -- potentially more when using video ram buffers
}
local gpuIgnoredCalls = {
  getScreen = true,
  getBackground = true,
  getForeground = true,
  getPaletteColor = true,
  maxDepth = true,
  getDepth = true,
  maxResolution = true,
  getResolution = true,
  getViewport = true,
  get = true
}


function VncServer:onClientConnect(host)
  
  assert(not self.activeClient)
  
  self.activeClient = host
  self.bufferedCallQueue = {}
  
  mrpc_server.async.redraw_display(host, dcap.captureDisplayState())
  
  local gpuPreCallbacks
  if ENABLE_PASSIVE_BUFFER then
    gpuPreCallbacks = dcap.setupFramebuffers()
  else
    gpuPreCallbacks = {}
  end
  
  local gpuRealFuncs = {}
  self.gpuRealFuncs = gpuRealFuncs
  for k, v in pairs(gpu) do
    if gpuTrackedCalls[k] then
      gpuRealFuncs[k] = v
      local preCallback = gpuPreCallbacks[k]
      if preCallback then
        gpu[k] = function(...)
          preCallback(...)
          self.bufferedCallQueue[#self.bufferedCallQueue + 1] = table.pack(k, ...)
          return v(...)
        end
      else
        gpu[k] = function(...)
          self.bufferedCallQueue[#self.bufferedCallQueue + 1] = table.pack(k, ...)
          return v(...)
        end
      end
    elseif not gpuIgnoredCalls[k] then
      --print("unknown gpu key ", k)
    end
  end
  
  --print("replaced gpu calls!")
  --os.sleep(1)
  --print("one")
  --gpu.setForeground(8, true)
  --print("two")
end
mrpc_server.functions.client_connect = VncServer.onClientConnect


local trackedScreenEvents = {
  touch = true,
  drag = true,
  drop = true,
  scroll = true,
  walk = true
}
local trackedKeyboardEvents = {
  key_down = true,
  key_up = true,
  clipboard = true
}

function VncServer:onClientEvents(host, bufferedEvents)
  for i, v in ipairs(bufferedEvents) do
    --print(i, table.unpack(v))
    if trackedScreenEvents[v[1]] then
      v[2] = screen_c.address
    elseif trackedKeyboardEvents[v[1]] then
      v[2] = keyboard_c.address
    end
    computer.pushSignal(table.unpack(v))
  end
end
mrpc_server.functions.client_events = VncServer.onClientEvents


function VncServer:onClientDisconnect(host)
  mrpc_server.async.server_disconnect(self.activeClient)
  self.activeClient = false
  self:restoreOverrides()
end
mrpc_server.functions.client_disconnect = VncServer.onClientDisconnect


function VncServer:mainThreadFunc()
  local nextBufferedCallTime = 0
  while self.running do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(self, host, port, message)
    
    if self.activeClient then
      if computer.uptime() >= nextBufferedCallTime and self.bufferedCallQueue[1] then
        if not ENABLE_PASSIVE_BUFFER or dcap.checkFramebufferUpdate() then
          nextBufferedCallTime = computer.uptime() + 0.2
          local bufferedCalls = self.bufferedCallQueue
          self.bufferedCallQueue = {}
          mrpc_server.async.update_display(self.activeClient, bufferedCalls)
        else
          nextBufferedCallTime = computer.uptime() + 0.2
          self.bufferedCallQueue = {}
        end
        if ENABLE_PASSIVE_BUFFER then
          dcap.swapFramebuffers()
        end
      end
    end
  end
  app:threadDone()
end


function VncServer:start()
  app:createThread("Main", VncServer.mainThreadFunc, self)
  app:waitAnyThreads()
  app:exit()
  
  -- FIXME should this use app:run() instead? why even bother to run main in another thread ######################################################################
end


function VncServer:stop()
  self.running = false
end

return VncServer
