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
local thread = require("thread")
local unicode = require("unicode")

-- User libraries.
local include = require("include")
local app = include("app"):new()
local dlog = include("dlog")

-- FIXME something bad happened here when running in the daemon, huh #####################################################################
--app:pushCleanupTask(dlog.osBlockNewGlobals, true, false)

local mnet = include("mnet")
local mrpc_server = include("mrpc").newServer(123)
mrpc_server.addDeclarations(dofile("/home/ocvnc/ocvnc_mrpc.lua"))

local DLOG_FILE_OUT = ""--"/tmp/messages"

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
  
  self.bufferedCallQueue = {}
  
  app:pushCleanupTask(VncServer.restoreOverrides, nil, {self})
  
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


function VncServer:onConnect(host)
  
  assert(not self.activeClient)
  
  self.activeClient = host
  
  
  
  local displayState = {}
  displayState.depth = gpu.getDepth()
  displayState.res = {gpu.getResolution()}
  displayState.view = {gpu.getViewport()}
  local palette = {}
  for i = 1, 16 do
    palette[i] = gpu.getPaletteColor(i - 1)
  end
  displayState.palette = palette
  
  -- capture screen contents, maybe store in something like:
  --[[
  textTable: {
    <bg>: {
      <fg>: {
        1: {
          1: <x>
          2: <y>
          3: <string>
        }
        2: {
          1: <x>
          2: <y>
          3: <string>
        }
        ...
      }
      ...
    }
    ...
  }
  --]]
  
  
  
  -- alternative single array design for textBuffer:
  -- {<entry>, ...}
  -- entry types:
  -- x: number[, y: number[, fg: number[, bg: number]]], str: string
  -- ordered to minimize state changes of fg and bg
  -- for fg and bg, negative values means palette index
  
  --[[
  textBufferInflated: {
    <bg>: {
      <fg>: {
        1: <x>
        2: <y>
        3: <line>
        4: <x>
        5: <y>
        6: <line>
        ...
      }
      ...
    }
    ...
  }
  
  textBuffer: {
    1: <x>
    2: [<y>]
    3: [<fg>]
    4: [<bg>]
    5: <line>
    ...
  }
  --]]
  
  local textBufferInflated = setmetatable({}, {
    __index = function(t, k)
      t[k] = setmetatable({}, {
        __index = function(t2, k2)
          t2[k2] = {}
          return t2[k2]
        end
      })
      return t[k]
    end
  })
  
  -- Scan each character in the screen buffer row-by-row, and insert them into the textBufferInflated. Any white-on-black text that is a contiguous line of spaces is simply discarded to optimize.
  local foundWBNonSpace = false
  local width, height = gpu.getResolution()
  for y = 1, height do
    local x = 1
    while x <= width do
      local char, fg, bg, fgIndex, bgIndex = gpu.get(x, y)
      fg = math.floor(fgIndex and -fgIndex - 1 or fg)
      bg = math.floor(bgIndex and -bgIndex - 1 or bg)
      
      local colorWB = (fg == 0xFFFFFF and bg == 0x0)
      
      if not colorWB or char ~= " " or foundWBNonSpace then
        local lineGroup = textBufferInflated[bg][fg]
        local lineGroupSize = #lineGroup
        
        -- Add the character to the last line if the y and x position line up (considering the true length in characters in case we have unicode ones).
        if lineGroup[lineGroupSize - 1] == y and lineGroup[lineGroupSize - 2] + unicode.wlen(lineGroup[lineGroupSize]) == x then
          if char ~= " " and colorWB then
            foundWBNonSpace = true
          end
          lineGroup[lineGroupSize] = lineGroup[lineGroupSize] .. char
        else
          if foundWBNonSpace then
            local lineGroupWB = textBufferInflated[0x0][0xFFFFFF]
            lineGroupWB[#lineGroupWB] = string.match(lineGroupWB[#lineGroupWB], "(.-) *$")
            foundWBNonSpace = false
          end
          if char ~= " " or not colorWB then
            lineGroup[lineGroupSize + 1] = x
            lineGroup[lineGroupSize + 2] = y
            lineGroup[lineGroupSize + 3] = char
          end
        end
        x = x + unicode.wlen(char)
      else
        x = x + 1
      end
    end
  end
  if foundWBNonSpace then
    local lineGroupWB = textBufferInflated[0x0][0xFFFFFF]
    lineGroupWB[#lineGroupWB] = string.match(lineGroupWB[#lineGroupWB], "(.-) *$")
  end
  
  local textBuffer = {}
  local textBufferSize = 0
  local lineOffset
  for bg, fgGroup in pairs(textBufferInflated) do
    -- Add bg color (color changed).
    textBuffer[textBufferSize + 4] = bg
    lineOffset = 5
    for fg, lineGroup in pairs(fgGroup) do
      -- Add fg color (color changed).
      textBuffer[textBufferSize + 3] = fg
      lineOffset = math.max(lineOffset, 4)
      
      local lastY
      
      for i = 1, #lineGroup, 3 do
        -- Add x position.
        textBuffer[textBufferSize + 1] = lineGroup[i]
        -- Add y position if it changed.
        if lineGroup[i + 1] ~= lastY then
          lastY = lineGroup[i + 1]
          textBuffer[textBufferSize + 2] = lastY
          lineOffset = math.max(lineOffset, 3)
        end
        -- Add the line to the end.
        textBufferSize = textBufferSize + lineOffset
        textBuffer[textBufferSize] = lineGroup[i + 2]
        lineOffset = 2
      end
    end
  end
  
  
  displayState.textBufferInflated = textBufferInflated
  displayState.textBuffer = textBuffer
  
  
  local c, i = gpu.getBackground()
  displayState.bg = i and -c - 1 or c
  c, i = gpu.getForeground()
  displayState.fg = i and -c - 1 or c
  
  
  mrpc_server.async.redraw_display(host, displayState)
  
  local gpuRealFuncs = {}
  self.gpuRealFuncs = gpuRealFuncs
  for k, v in pairs(gpu) do
    if gpuTrackedCalls[k] then
      gpuRealFuncs[k] = v
      gpu[k] = function(...)
        self.bufferedCallQueue[#self.bufferedCallQueue + 1] = table.pack(k, ...)
        return v(...)
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
mrpc_server.functions.connect = VncServer.onConnect


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

function VncServer:onClientEvent(host, bufferedEvents)
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
mrpc_server.functions.client_event = VncServer.onClientEvent


function VncServer:mainThreadFunc()
  local nextBufferedCallTime = 0
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(self, host, port, message)
    if self.activeClient and self.bufferedCallQueue[1] and computer.uptime() >= nextBufferedCallTime then
      nextBufferedCallTime = computer.uptime() + 0.2
      local bufferedCalls = self.bufferedCallQueue
      self.bufferedCallQueue = {}
      mrpc_server.async.update_display(self.activeClient, bufferedCalls)
    end
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
  
  dlog.setStdOut(false)
  
  local vncServer = VncServer:new()
  
  --[[
  app:createThread("Interrupt", function()
    event.pull("interrupted")
    app:exit(1)
  end)
  --]]
  app:createThread("Main", VncServer.mainThreadFunc, vncServer)
  
  app:waitAnyThreads()
end

main()
app:exit()
