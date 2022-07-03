--------------------------------------------------------------------------------
-- Application framework for multithreaded apps. Makes it easy to handle
-- multiple threads that must run in parallel and catch errors if any of them
-- fail. A cleanup task stack is also available for running functions right
-- before the application stops.
-- 
-- @see file://libapptools/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local thread = require("thread")

local include = require("include")
local dlog = include("dlog")

local app = {}


-- app:new(): table
-- 
-- Creates a new application context for tracking threads and cleanup tasks.
-- Returns the new app object.
function app:new()
  self.__index = self
  self = setmetatable({}, self)
  
  self.cleanupTasks = {}
  self.threads = {}
  self.threadNames = {}
  self.killProgram = false
  self.exitCode = nil
  
  return self
end


-- app:pushCleanupTask(func: function, startArgs: any, endArgs: any)
-- 
-- Adds a function to the top of the cleanup stack. This function will be popped
-- off the stack and run when app:doCleanup() or app:exit() is called or a
-- thread exits unexpectedly. If startArgs is not a table or nil, the function
-- will be called immediately with this argument. If endArgs is not a table or
-- nil, the function is called during cleanup with this argument. If either one
-- is a table then these are unpacked and passed as the arguments instead.
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
-- Starts the cleanup tasks early, the tasks run in first-in-last-out order.
-- This function is called automatically and generally doesn't need to be
-- manually run. Returns the number of tasks that executed.
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
-- Creates a new thread executing the function threadProc and registers it to
-- the app. Any additional provided arguments are passed to threadProc. Returns
-- the thread handle.
function app:createThread(name, threadProc, ...)
  dlog.checkArgs(name, "string", threadProc, "function")
  local i = #self.threads + 1
  self.threadNames[i] = name
  dlog.out("app", name, " thread starts.")
  local t = thread.create(threadProc, ...)
  self.threads[i] = t
  return t
end


-- app:registerThread(name: string, t: table): number, string|boolean|nil
-- 
-- Registers an existing thread to the app. Returns the index and name if the
-- thread has already been registered, or just an index if the thread was added
-- successfully. If the thread was already registered and exited successfully, a
-- value of true is returned for the name instead. Registering a dead thread is
-- considered an error.
function app:registerThread(name, t)
  dlog.checkArgs(name, "string", t, "table")
  for i, v in ipairs(self.threads) do
    if v == t then
      return i, self.threadNames[i]
    end
  end
  local i = #self.threads + 1
  self.threadNames[i] = name
  dlog.out("app", name, " thread registered.")
  self.threads[i] = t
  return i
end


-- app:unregisterThread(t: table): boolean
-- 
-- Unregisters a thread from the app. The app will not consider this thread in
-- app:waitAnyThreads() or app:waitAllThreads() and the thread will no longer be
-- checked for exceptions. Returns true if thread was removed, or false if
-- thread is not currently registered.
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


-- Helper function to kill threads and run cleanup before stopping application.
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
-- Stops the app and ends the program, this kills any active threads and runs
-- cleanup tasks. This must be explicitly called before exiting the program to
-- run the cleanup (but it is implicitly called when a registered thread throws
-- an exception). This is designed to replace calls to os.exit() and can be used
-- inside or outside of a thread.
function app:exit(code)
  self.killProgram = true
  self.exitCode = code
  if not self:threadDone() then
    exitProgram(self, code)
  end
end


-- app:threadDone(): boolean|nil
-- 
-- Kills the current thread and reports successful execution. If a thread
-- becomes dead in any other way then this is considered an error and the app
-- will stop. A thread can end up dead if the function body ends, os.exit() is
-- called, exception is thrown, or thread is suspended while a call to
-- app:waitAnyThreads() or app:waitAllThreads() is running. This function does
-- nothing if called outside of a thread. Returns true if thread was killed (but
-- the thread will end execution before that anyways).
function app:threadDone()
  local t = thread.current()
  if t then
    for i, v in ipairs(self.threads) do
      if v == t then
        dlog.out("app", self.threadNames[i], " thread ends.")
        -- Set the name to true to indicate successful execution.
        self.threadNames[i] = true
        t:kill()
        os.sleep()
        return true
      end
    end
    -- It's possible for the thread to finish during construction in app:createThread(), and the handle will not yet be in self.threads.
    dlog.out("app", self.threadNames[#self.threadNames], " thread ends.")
    self.threadNames[#self.threadNames] = true
    t:kill()
    os.sleep()
    return true
  end
end


-- Helper function to remove tracking of dead threads and check for exceptions.
local function cleanDeadThreads(self)
  local threadError = false
  for i = #self.threads, 1, -1 do
    if self.threads[i]:status() == "dead" then
      if self.threadNames[i] ~= true then
        dlog.out("error", "\27[31m", self.threadNames[i], " thread exited unexpectedly, check log file \"/tmp/event.log\" for exception details.\27[0m")
        threadError = true
      end
      table.remove(self.threads, i)
      table.remove(self.threadNames, i)
    end
  end
  if threadError then
    exitProgram(self, 1)
  elseif self.killProgram then
    exitProgram(self, self.exitCode)
  end
end


-- app:waitAnyThreads([timeout: number])
-- 
-- Waits for any of the registered threads to complete or for timeout (seconds)
-- to pass. A thread completes if it dies or is suspended.
function app:waitAnyThreads(timeout)
  thread.waitForAny(self.threads, timeout)
  cleanDeadThreads(self)
end


-- app:waitAllThreads([timeout: number])
-- 
-- Waits for all of the registered threads to complete or for timeout (seconds)
-- to pass. A thread completes if it dies or is suspended.
function app:waitAllThreads(timeout)
  thread.waitForAll(self.threads, timeout)
  cleanDeadThreads(self)
end

return app
