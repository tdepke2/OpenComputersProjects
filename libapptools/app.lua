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


-- app:new([mainThread: table]): table
-- 
-- Creates a new application context for tracking threads and cleanup tasks. If
-- mainThread is not provided, it defaults to the current execution context (the
-- thread running this function if any). If this function is run inside a thread
-- where the system process should be used as the main "thread", a value of
-- false can be passed to mainThread. Returns the new app object.
function app:new(mainThread)
  self.__index = self
  self = setmetatable({}, self)
  
  if mainThread == nil then
    self.mainThread = thread.current()
  else
    self.mainThread = mainThread
  end
  self.cleanupTasks = {}
  -- Sequence of thread handles. The value "false" is used as a placeholder for a thread that is initializing.
  self.threads = {}
  -- Sequence of names for threads. Each name begins with a character prefix separated by a comma.
  -- The prefix is "r" for running or "d" for done (thread exited successfully).
  self.threadNames = {}
  self.killProgram = false
  self.exitCode = nil
  
  return self
end


-- app:run(func: function, ...)
-- 
-- Starts the application with body function func in a protected call. Any
-- additional provided arguments are passed to func (when called from the main
-- thread, use "..." to pass all arguments sent to the program). After func
-- completes or returns an error, app:exit() is called to run cleanup and end
-- the program.
function app:run(func, ...)
  local status, result
  if dlog.logErrorsToOutput then
    status, result = dlog.handleError(xpcall(func, debug.traceback, ...))
  else
    status, result = dlog.handleError(pcall(func, ...))
  end
  if status then
    self:exit()
  elseif type(result) == "table" and result.reason ~= nil then
    self:exit(result.code)
  else
    self:exit(1)
  end
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
-- the app. Any additional provided arguments are passed to threadProc. If
-- dlog.logErrorsToOutput is enabled, threadProc is wrapped inside an xpcall()
-- to capture exceptions with a stack trace. Returns the thread handle.
function app:createThread(name, threadProc, ...)
  dlog.checkArgs(name, "string", threadProc, "function")
  local i = #self.threads + 1
  self.threads[i] = false
  self.threadNames[i] = "r," .. name
  dlog.out("app", name, " thread starts.")
  local t
  if dlog.logErrorsToOutput then
    t = thread.create(function(...)
      local status, result = dlog.handleError(xpcall(threadProc, debug.traceback, ...))
      if not status then
        error(result, 0)
      end
    end, ...)
  else
    t = thread.create(threadProc, ...)
  end
  self.threads[i] = t
  return t
end


-- app:registerThread(name: string, t: table): number, string|nil
-- 
-- Registers an existing thread to the app. Returns the index and name if the
-- thread has already been registered, or just an index if the thread was added
-- successfully. Registering a dead thread is considered an error.
function app:registerThread(name, t)
  dlog.checkArgs(name, "string", t, "table")
  for i, v in ipairs(self.threads) do
    if v == t then
      return i, string.sub(self.threadNames[i], 3)
    end
  end
  local i = #self.threads + 1
  self.threads[i] = t
  self.threadNames[i] = "r," .. name
  dlog.out("app", name, " thread registered.")
  return i
end


-- app:unregisterThread(t: table): boolean
-- 
-- Unregisters a thread from the app. The app will not consider this thread in
-- app:waitAnyThreads() or app:waitAllThreads() and the thread will no longer
-- stop the application if an error occurs. Returns true if thread was removed,
-- or false if thread is not currently registered.
function app:unregisterThread(t)
  dlog.checkArgs(t, "table")
  for i, v in ipairs(self.threads) do
    if v == t then
      dlog.out("app", string.sub(self.threadNames[i], 3), " thread unregistered.")
      table.remove(self.threads, i)
      table.remove(self.threadNames, i)
      return true
    end
  end
  return false
end


-- Helper function to kill threads and run cleanup before stopping application.
local function exitProgram(self, code)
  if #self.threads > 0 or #self.cleanupTasks > 0 then
    dlog.out("app", "Stopping ", #self.threads, " threads and running ", #self.cleanupTasks, " cleanup tasks.")
  end
  for i = #self.threads, 1, -1 do
    if self.threads[i]:status() ~= "dead" then
      dlog.out("app", string.sub(self.threadNames[i], 3), " thread ends.")
      self.threads[i]:kill()
    end
    self.threads[i] = nil
    self.threadNames[i] = nil
  end
  self:doCleanup()
  os.exit(code ~= nil and code or 0)
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


-- app:threadDone(): boolean
-- 
-- Kills the current thread and reports successful execution. If a thread
-- becomes dead in any other way then this is considered an error and the app
-- will stop. A thread can end up dead if the function body ends, os.exit() is
-- called, exception is thrown, or thread is suspended while a call to
-- app:waitAnyThreads() or app:waitAllThreads() is running. This function does
-- nothing if called outside of a thread (or within mainThread). Returns true if
-- thread was killed (but the thread will end execution before that anyways).
function app:threadDone()
  local t = thread.current()
  if t and t ~= self.mainThread then
    local numThreads = #self.threads
    for i, v in ipairs(self.threads) do
      -- Check for the matching entry for current thread (if it's still initializing, it will be the last entry).
      if v == t or (i == numThreads and v == false) then
        dlog.out("app", string.sub(self.threadNames[i], 3), " thread ends.")
        -- Set the done flag in the name to indicate successful execution.
        self.threadNames[i] = "d," .. string.sub(self.threadNames[i], 3)
        t:kill()
        os.sleep()
        return true
      end
    end
  end
  return false
end


-- Helper function to remove tracking of dead threads and check for exceptions.
local function cleanDeadThreads(self)
  local threadError = false
  for i = #self.threads, 1, -1 do
    if self.threads[i]:status() == "dead" then
      if string.byte(self.threadNames[i]) ~= string.byte("d") then
        dlog.handleError(false, string.sub(self.threadNames[i], 3) .. " thread exited unexpectedly, check log file \"/tmp/event.log\" for exception details.")
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
