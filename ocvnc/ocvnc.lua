--[[

Planning:
  * ocvnc <host> [<port>]
  * send signals to server
  * call GPU funcs from server
  * special key combo stops the connection? (what about ctrl+c or hard ctrl+c)
  * options for ACPI shutdown or reboot?
  * what if server screen and client screen tier don't match? if server has tier 3 and client has tier 2 then this probably doesn't work.
  * use event library to pull signals we care about and send with RPC call (signals should not be suppressed on client, unless?)

  * ctrl+a q disconnects
  * ctrl+a r redraws the window
  * ctrl+a ctrl+a sends ctrl+a

--]]

-- OS libraries.
local component = require("component")
local computer = require("computer")
local event = require("event")
local gpu = component.gpu
local keyboard = require("keyboard")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.mode("debug")
dlog.standardOutput(false)
local app = include("app"):new()
app:pushCleanupTask(dlog.osBlockNewGlobals, true, false)

local dcap = include("dcap")
local mnet = include("mnet")
local mrpc_server = include("mrpc").newServer(530)
mrpc_server.addDeclarations(dofile("ocvnc/ocvnc_mrpc.lua"))

local TARGET_HOST = "1315ba5c"
local KEEPALIVE_INTERVAL = 30

-- Creates a new enumeration from a given table (matches keys to values and vice
-- versa). The given table is intended to use numeric keys and string values,
-- but doesn't have to be a sequence.
-- Based on: https://unendli.ch/posts/2016-07-22-enumerations-in-lua.html
local function enum(t)
  local result = {}
  for i, v in pairs(t) do
    result[i] = v
    result[v] = i
  end
  return result
end

local ClientState = enum {
  "init",
  "connected",
  "disconnecting",
}

-- VncClient class definition.
local VncClient = {}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(VncClient, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in VncClient class.", 2)
  end
})

function VncClient:new()
  self.__index = self
  self = setmetatable({}, self)
  
  -- Client functions like a state machine, this is the current state.
  self.state = ClientState.init
  -- The displayState table representing the screen contents before overwriting with the remote server screen.
  self.originalDisplayState = false
  -- Sequence of signals caught be client machine that are batched in a queue and sent to server later.
  self.bufferedEventQueue = {}
  -- 
  self.commandMode = false
  -- 
  self.disconnectTimeout = false
  
  return self
end


function VncClient:onRedrawDisplay(host, displayState)
  if self.state == ClientState.disconnecting then
    return
  end
  if not self.originalDisplayState then
    self.originalDisplayState = dcap.captureDisplayState()
  end
  dcap.restoreDisplayState(displayState)
  
  dlog.out("onRedrawDisplay", displayState)
end
mrpc_server.functions.redraw_display = VncClient.onRedrawDisplay


function VncClient:onUpdateDisplay(host, bufferedCalls)
  if self.state == ClientState.disconnecting then
    return
  end
  for _, v in ipairs(bufferedCalls) do
    gpu[v[1]](table.unpack(v, 2, v.n))
  end
end
mrpc_server.functions.update_display = VncClient.onUpdateDisplay


function VncClient:onServerDisconnect(host)
  if self.state == ClientState.disconnecting then
    io.write("Done.\n")
    app:exit()
  else
    if self.originalDisplayState then
      dcap.restoreDisplayState(self.originalDisplayState)
      self.originalDisplayState = false
    end
    io.write("Connection closed by remote host.\n")
    app:exit()
  end
end
mrpc_server.functions.server_disconnect = VncClient.onServerDisconnect


function VncClient:mainThreadFunc()
  mrpc_server.sync.client_connect(TARGET_HOST)
  self.state = ClientState.connected
  
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
  local function eventFilter(name)
    return trackedInputEvents[name] or trackedControlEvents[name]
  end
  
  local nextBufferedEventTime = 0
  while true do
    if self.state ~= ClientState.disconnecting then
      local e = {event.pullFiltered(0.1, eventFilter)}
      if e[1] then
        -- Screen touch and keyboard events include the address of the device that was used, clear this field and substitute correct address on server side.
        if trackedInputEvents[e[1]] then
          e[2] = ""
        end
        if e[1] == "key_down" then
          local newCommandMode = false
          if keyboard.isControl(e[3]) then
            if e[4] == keyboard.keys.a and not self.commandMode then
              newCommandMode = true
              e = nil
            end
          elseif self.commandMode then
            if e[3] == string.byte("q") then
              self.state = ClientState.disconnecting
              self.disconnectTimeout = computer.uptime() + 10
              if self.originalDisplayState then
                dcap.restoreDisplayState(self.originalDisplayState)
                self.originalDisplayState = false
              end
              io.write("Disconnecting... ")
              mrpc_server.async.client_disconnect(TARGET_HOST)
              e = nil
            end
          end
          self.commandMode = newCommandMode
        end
        self.bufferedEventQueue[#self.bufferedEventQueue + 1] = e
      end
      
      if self.bufferedEventQueue[1] and computer.uptime() >= nextBufferedEventTime then
        nextBufferedEventTime = computer.uptime() + 0.2
        local bufferedEvents = self.bufferedEventQueue
        self.bufferedEventQueue = {}
        mrpc_server.async.client_events(TARGET_HOST, bufferedEvents)
      end
    elseif computer.uptime() < self.disconnectTimeout then
      os.sleep(0.1)
    else
      io.write("No response from server, connection closed abruptly.\n")
      app:exit()
    end
  end
end


function VncClient:networkThreadFunc()
  while true do
    local host, port, message = mnet.receive(0.1)
    mrpc_server.handleMessage(self, host, port, message)
  end
end


-- Main program starts here.
local function main(...)
  -- Check for any command-line arguments passed to the program.
  local args = {...}
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

app:run(main, ...)
