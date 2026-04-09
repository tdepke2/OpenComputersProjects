--------------------------------------------------------------------------------
-- Utilities for creating an rc service with a systemd style interface.
-- 
-- @see file://libapptools/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local computer = require("computer")
local thread = require("thread")

local systemd_utils = {}

-- Private data.
local priv = {
  serviceSerial = 0,
  serviceStartCounter = 0,
}

-- RcInterface class definition.
local RcInterface = {}
systemd_utils.RcInterface = RcInterface

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(RcInterface, {
  __index = function(t, k)
    error("attempt to read undefined member " .. tostring(k) .. " in RcInterface class.", 2)
  end
})


---@docdef `systemd_utils.RcInterface:new(name, description, programPath)`
-- 
-- Creates a new RcInterface context. The programPath must point to a file that
-- defines and returns a class for the rc program. This class must at least
-- implement `new()`, `start()`, and `stop()` members.
-- 
---@param name string
---@param description string
---@param programPath string
---@return table
function RcInterface:new(name, description, programPath)
  self.__index = self
  self = setmetatable({}, self)

  self.name = name
  self.description = description
  self.programPath = programPath

  self.mainThread = false
  self.serviceInstance = false

  self.isStarting = false
  self.isStopping = false
  self.lastStatusDate, self.lastStatusRealTime = os.date("%c"), computer.uptime()

  return self
end


---@docdef `systemd_utils.RcInterface:startAfterBootFinished(...)`
-- 
-- Queue the rc program to start once the boot process has finished. The program
-- will be initialized and started. This runs within a thread so that pulling
-- events can be done safely without blocking the system thread.
-- 
-- Ideally the arguments passed should come from the `start()` function called
-- by rc, or the global variable `args` (defined by rc if there is an entry in
-- the config) if no arguments were provided. These will be passed along when
-- calling `new()` on the rc program.
-- 
---@param ... any
function RcInterface:startAfterBootFinished(...)
  if self.mainThread and self.mainThread:status() ~= "dead" then
    io.write(self.name, " already running\n")
    return
  end
  self.isStarting = true
  self.lastStatusDate, self.lastStatusRealTime = os.date("%c"), computer.uptime()

  -- In order to ensure the load order of the rc programs remains the same, use a counter to queue them up.
  local currentSerial = priv.serviceSerial
  priv.serviceSerial = priv.serviceSerial + 1

  local args = table.pack(...)
  self.mainThread = thread.create(function()
    -- Wait for system to finish booting before attempting to start server.
    while currentSerial ~= priv.serviceStartCounter or computer.runlevel() == "S" do
      os.sleep(0.05)
    end
    priv.serviceStartCounter = priv.serviceStartCounter + 1

    local ProgramClass = dofile(self.programPath)

    self.serviceInstance = ProgramClass:new(table.unpack(args, 1, args.n))
    self.isStarting = false
    self.lastStatusDate, self.lastStatusRealTime = os.date("%c"), computer.uptime()
    self.serviceInstance:start()
  end):detach()
end


---@docdef `systemd_utils.RcInterface:requestStop()`
-- 
-- Gracefully shuts down the rc program by joining on the thread. If it doesn't
-- join after some time, the process is assumed to be hung and the thread will
-- be killed.
function RcInterface:requestStop()
  if not self:isActive() then
    io.write(self.name, " already stopped\n")
    return
  end
  self.isStopping = true
  self.lastStatusDate, self.lastStatusRealTime = os.date("%c"), computer.uptime()
  self.serviceInstance:stop()
  if not self.mainThread:join(15) then
    io.stderr:write("Process still running after 15s, killing threads.\n")
    self.mainThread:kill()
  end
  self.serviceInstance = false
  self.mainThread = false
  self.isStopping = false
  self.lastStatusDate, self.lastStatusRealTime = os.date("%c"), computer.uptime()
end


---@docdef `systemd_utils.RcInterface:isActive()`
-- 
-- Check if the rc program has finished starting and is currently running.
-- 
---@return boolean
function RcInterface:isActive()
  if self.mainThread and self.mainThread:status() ~= "dead" and self.serviceInstance then
    return true
  else
    return false
  end
end


---@docdef `systemd_utils.RcInterface:status()`
-- 
-- Prints the current status of the rc program (is it running, is it enabled,
-- recent logs, etc).
function RcInterface:status()
  -- Check the rc config to see if service is enabled.
  local enabledStatus = "\27[33munknown\27[0m"
  do
    local env = {}
    local fn = loadfile('/etc/rc.cfg', 't', env)
    if fn and pcall(fn) and type(env.enabled) == "table" then
      for _, v in pairs(env.enabled) do
        if v == self.name then
          enabledStatus = "\27[32menabled\27[0m"
        end
      end
      if enabledStatus ~= "\27[32menabled\27[0m" then
        enabledStatus = "disabled"
      end
    end
  end

  local statusColor, loadStatus, activeStatus
  if self.isStarting then
    statusColor, loadStatus, activeStatus = "\27[33m", "unloaded (" .. enabledStatus .. ")", "activating"
    io.write(statusColor, "⬤")
  elseif self.isStopping then
    statusColor, loadStatus, activeStatus = "\27[33m", "loaded (" .. self.programPath .. "; " .. enabledStatus .. ")", "deactivating"
    io.write(statusColor, "◯")
  elseif self:isActive() then
    statusColor, loadStatus, activeStatus = "\27[32m", "loaded (" .. self.programPath .. "; " .. enabledStatus .. ")", "active (running)"
    io.write(statusColor, "⬤")
  else
    statusColor, loadStatus, activeStatus = "\27[31m", "unloaded (" .. enabledStatus .. ")", "inactive (dead)"
    io.write(statusColor, "◯")
  end
  io.write("\27[0m ", self.description, "\n")
  io.write("   Loaded: ", loadStatus, "\n")
  io.write("   Active: ", statusColor, activeStatus, "\27[0m since ", self.lastStatusDate, "; ", math.floor(computer.uptime() - self.lastStatusRealTime), "s ago\n")
  if self.mainThread then
    io.write(" Main PID: ", tostring(self.mainThread and self.mainThread.pco and self.mainThread.pco.root), "\n")
  else
    io.write(" Main PID: none\n")
  end

  -- Show recent logs if they are found.
  local filename = "/tmp/event.log"
  local file = io.open(filename, "r")
  if not file then
    filename = "/tmp/messages"
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

return systemd_utils
