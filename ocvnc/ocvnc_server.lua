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
  
  --self.scheduleCursorDraw = false
  
  self.running = true
  --term.setCursorBlink(false)
  
  app:pushCleanupTask(function()
    if self.activeClient then
      mrpc_server.async.server_disconnect(self.activeClient)
    end
    term.setCursorBlink(true)
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
  -- Disable cursor blinking. The blinking doesn't work very well because the constant network events reset blink timer.
  
  
  
  
  
  
  
  mrpc_server.async.redraw_display(host, dcap.captureDisplayState())
  
  local lastBg, lastBgPalette = gpu.getBackground()
  local lastFg, lastFgPalette = gpu.getForeground()
  local currentBg, currentBgPalette = gpu.getBackground()
  local currentFg, currentFgPalette = gpu.getForeground()
  
  do
    --local cx, cy = term.getCursor()
    --local char, fg, bg, fgIndex, bgIndex = gpu.get(cx, cy)
    --[[local lastCursor = false--[[{cx, cy, char,
      bgIndex or bg, bgIndex and true or false,
      fgIndex or fg, fgIndex and true or false
    }--]]
  end
  
  local lastCursor, cursorSuppressed
  do
    local cx, cy = term.getCursor()
    local char, fg, bg, fgIndex, bgIndex = gpu.get(cx, cy)
    lastCursor = {cx, cy, char,
      bgIndex or bg, not not bgIndex,
      fgIndex or fg, not not fgIndex
    }
    cursorSuppressed = false
  end
  
  --[[
  lastCursor = {
    1: <x (number)>
    2: <y (number)>
    3: <char (string)>
    4: <bg (number)>
    5: <bgPalette (boolean)>
    6: <fg (number)>
    7: <fgPalette (boolean)>
  }
  --]]
  
  local function addCursorDraw(x, y, str, bg, bgPalette, fg, fgPalette)
    if lastBg ~= bg or lastBgPalette ~= bgPalette then
      self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"setBackground", bg, bgPalette, n = 3}
      lastBg = bg
      lastBgPalette = bgPalette
    end
    if lastFg ~= fg or lastFgPalette ~= fgPalette then
      self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"setForeground", fg, fgPalette, n = 3}
      lastFg = fg
      lastFgPalette = fgPalette
    end
    self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"set", x, y, str, n = 4}
  end
  
  -- FIXME rename to cursor flush or something? #######################################
  local function scheduleCursorDraw()
    --[[local char, fg, bg, fgIndex, bgIndex = gpu.get(lastCursor[1], lastCursor[2])
    bg = bgIndex or bg
    bgIndex = bgIndex and true or false
    fg = fgIndex or fg
    fgIndex = fgIndex and true or false
    
    -- Return early if no change to cursor.
    if char == lastCursor[3] and bg == lastCursor[4] and bgIndex == lastCursor[5] and fg == lastCursor[6] and fgIndex == lastCursor[7] then
      return
    end
    
    -- Add calls to set background, foreground, and cursor character to the queue.
    if lastBg ~= bg or lastBgPalette ~= bgIndex then
      self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"setBackground", bg, bgIndex, n = 3}
      lastBg = bg
      lastBgPalette = bgIndex
    end
    if lastFg ~= fg or lastFgPalette ~= fgIndex then
      self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"setForeground", fg, fgIndex, n = 3}
      lastFg = fg
      lastFgPalette = fgIndex
    end
    self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"set", lastCursor[1], lastCursor[2], char, n = 4}
    lastCursor[3] = char
    lastCursor[4] = bg
    lastCursor[5] = bgIndex
    lastCursor[6] = fg
    lastCursor[7] = fgIndex--]]
    
    if cursorSuppressed then
      local char, fg, bg, fgIndex, bgIndex = gpu.get(lastCursor[1], lastCursor[2])
      bg = bgIndex or bg
      bgIndex = not not bgIndex
      fg = fgIndex or fg
      fgIndex = not not fgIndex
      
      if char ~= lastCursor[3] or bg ~= lastCursor[4] or bgIndex ~= lastCursor[5] or fg ~= lastCursor[6] or fgIndex ~= lastCursor[7] then
        addCursorDraw(lastCursor[1], lastCursor[2], char, bg, bgIndex, fg, fgIndex)
        lastCursor[3] = char
        lastCursor[4] = bg
        lastCursor[5] = bgIndex
        lastCursor[6] = fg
        lastCursor[7] = fgIndex
      end
      cursorSuppressed = false
    end
  end
  self.scheduleCursorDraw = scheduleCursorDraw
  
  local gpuRealFuncs = {}
  self.gpuRealFuncs = gpuRealFuncs
  for k, v in pairs(gpu) do
    if gpuTrackedCalls[k] then
      gpuRealFuncs[k] = v
      if k == "setBackground" then
        gpu[k] = function(...)
          currentBg, currentBgPalette = ...
          return v(...)
        end
      elseif k == "setForeground" then
        gpu[k] = function(...)
          currentFg, currentFgPalette = ...
          return v(...)
        end
      else
        gpu[k] = function(...)
          if k == "set" then
            local x, y, str = ...
            local cx, cy = term.getCursor()
            if x == cx and y == cy and #str == 1 then
              --[[
              -- Redraw the cursor if it moved, then capture the new cursor state.
              if lastCursor[1] ~= x or lastCursor[2] ~= y then
                scheduleCursorDraw()
                local char, fg, bg, fgIndex, bgIndex = gpu.get(x, y)
                lastCursor = {x, y, char,
                  bgIndex or bg, bgIndex and true or false,
                  fgIndex or fg, fgIndex and true or false
                }
              end
              --currentCursor = {x, y, str,
                --currentBg, currentBgPalette,
                --currentFg, currentFgPalette
              --}
              --]]
              
              if lastCursor[1] ~= x or lastCursor[2] ~= y then
                if cursorSuppressed then
                  local char, fg, bg, fgIndex, bgIndex = gpu.get(lastCursor[1], lastCursor[2])
                  addCursorDraw(lastCursor[1], lastCursor[2], char, bgIndex or bg, not not bgIndex, fgIndex or fg, not not fgIndex)
                end
                local char, fg, bg, fgIndex, bgIndex = gpu.get(x, y)
                lastCursor = {x, y, char,
                  bgIndex or bg, not not bgIndex,
                  fgIndex or fg, not not fgIndex
                }
              end
              cursorSuppressed = true
              
              return v(...)
            end
          end
          --[[if k == "set" and #select(3, ...) == 1 then
            -- Ignore a call to gpu.set() that would write a single character where the character and colors at that position on screen are the exact same.
            -- This fixes some problems with the cursor spamming draw calls every time an event is pulled.
            local x, y, str = ...
            local lastStr, fg, bg, fgIndex, bgIndex = gpu.get(x, y)
            if str == lastStr and currentBg == (bgIndex or bg) and currentBgPalette == (not not bgIndex) and currentFg == (fgIndex or fg) and currentFgPalette == (not not fgIndex) then
              return v(...)
            end
          end--]]
          if currentBg ~= lastBg or currentBgPalette ~= lastBgPalette then
            self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"setBackground", currentBg, currentBgPalette, n = 3}
            lastBg = currentBg
            lastBgPalette = currentBgPalette
          end
          if currentFg ~= lastFg or currentFgPalette ~= lastFgPalette then
            self.bufferedCallQueue[#self.bufferedCallQueue + 1] = {"setForeground", currentFg, currentFgPalette, n = 3}
            lastFg = currentFg
            lastFgPalette = currentFgPalette
          end
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
      --term.setCursorBlink(false)
      if computer.uptime() >= nextBufferedCallTime then
        self.scheduleCursorDraw()
        if self.bufferedCallQueue[1] then
          nextBufferedCallTime = computer.uptime() + 0.2
          local bufferedCalls = self.bufferedCallQueue
          self.bufferedCallQueue = {}
          mrpc_server.async.update_display(self.activeClient, bufferedCalls)
        end
      end
    else
      --term.setCursorBlink(true)
    end
  end
  app:threadDone()
end


function VncServer:start()
  term.setCursorBlink(false)
  
  
  
  
  
  app:createThread("Main", VncServer.mainThreadFunc, self)
  app:waitAnyThreads()
  app:exit()
  
  -- FIXME should this use app:run() instead? why even bother to run main in another thread ######################################################################
end


function VncServer:stop()
  self.running = false
end

return VncServer
