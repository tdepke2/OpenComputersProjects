

-- FIXME: just tested everything and it seems to be good, need to update comments and start using in ocvnc. ##############################################



local thread = require("thread")

local include = require("include")
local dlog = include("dlog")

local app = {}

-- app:new(): table
-- 
-- 
function app:new()
  self.__index = self
  self = setmetatable({}, self)
  
  self.cleanupTasks = {}
  self.threads = {}
  self.threadNames = {}
  self.threadSuccess = nil
  self.killProgram = false
  self.exitCode = nil
  
  return self
end

-- app:pushCleanupTask(func: function, startArgs: any, endArgs: any)
-- 
-- 
function app:pushCleanupTask(func, startArgs, endArgs)
  dlog.checkArgs(func, "function")
  if startArgs ~= nil then
    if type(startArgs) == "table" then
      func(table.unpack(startArgs, 1, startArgs.n))
    else
      func(startArgs)
    end
  end
  if endArgs ~= nil then
    self.cleanupTasks[#self.cleanupTasks + 1] = {func, endArgs}
  else
    self.cleanupTasks[#self.cleanupTasks + 1] = func
  end
end

-- app:doCleanup(): number
-- 
-- 
function app:doCleanup()
  local numTasks = #self.cleanupTasks
  for i = numTasks, 1, -1 do
    local task = self.cleanupTasks[i]
    if type(task) == "table" then
      if type(task[2]) == "table" then
        task[1](table.unpack(task[2], 1, task[2].n))
      else
        task[1](task[2])
      end
    else
      task()
    end
    self.cleanupTasks[i] = nil
  end
  return numTasks
end

-- app:createThread(name: string, threadProc: function, ...): table
-- 
-- 
function app:createThread(name, threadProc, ...)
  dlog.checkArgs(name, "string", threadProc, "function")
  dlog.out("app", name, " thread starts.")
  local t = thread.create(threadProc, ...)
  local i = #self.threads + 1
  self.threads[i] = t
  self.threadNames[i] = name
  return t
end

-- app:registerThread(name: string, t: table): number, string|nil
-- 
-- 
function app:registerThread(name, t)
  dlog.checkArgs(name, "string", t, "table")
  for i, v in ipairs(self.threads) do
    if v == t then
      return i, self.threadNames[i]
    end
  end
  dlog.out("app", name, " thread registered.")
  local i = #self.threads + 1
  self.threads[i] = t
  self.threadNames[i] = name
  return i
end

-- app:unregisterThread(t: table): boolean
-- 
-- 
function app:unregisterThread(t)
  dlog.checkArgs(t, "table")
  for i, v in ipairs(self.threads) do
    if v == t then
      table.remove(self.threads, i)
      table.remove(self.threadNames, i)
      return true
    end
  end
  return false
end

local function exitProgram(self, code)
  dlog.out("app", "Stopping ", #self.threads, " threads and running ", #self.cleanupTasks, " cleanup tasks.")
  for i = #self.threads, 1, -1 do
    if self.threads[i]:status() ~= "dead" then
      dlog.out("app", self.threadNames[i], " thread ends.")
      self.threads[i]:kill()
    end
  end
  self:doCleanup()
  os.exit(code)
end

-- app:exit([code: boolean|number])
-- 
-- 
function app:exit(code)
  local t = thread.current()
  if t then
    self.killProgram = true
    self.exitCode = code
    t:kill()
  else
    exitProgram(self, code)
  end
end

-- app:threadDone()
-- 
-- 
function app:threadDone()
  local t = thread.current()
  if t then
    if self.threadSuccess == nil then
      self.threadSuccess = true
    end
    t:kill()
  end
end

local function cleanDeadThreads(self)
  for i = #self.threads, 1, -1 do
    if self.threads[i]:status() == "dead" then
      dlog.out("app", self.threadNames[i], " thread ends.")
      table.remove(self.threads, i)
      table.remove(self.threadNames, i)
    end
  end
  if self.killProgram then
    exitProgram(self, self.exitCode)
  elseif not self.threadSuccess then
    dlog.out("error", "Exception occurred in thread, check log file \"/tmp/event.log\" for details.")
    exitProgram(self, false)
  end
  self.threadSuccess = nil
end

-- app:waitAnyThreads([timeout: number])
-- 
-- 
function app:waitAnyThreads(timeout)
  thread.waitForAny(self.threads, timeout)
  cleanDeadThreads(self)
end

-- app:waitAllThreads([timeout: number])
-- 
-- 
function app:waitAllThreads(timeout)
  thread.waitForAll(self.threads, timeout)
  cleanDeadThreads(self)
end

return app
