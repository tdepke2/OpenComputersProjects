--[[
Diagnostic logger and debugging utilities.

Allows writing logging data to standard output and/or a file for debugging code.
Log messages include a subsystem name and any number of values (preferably
including some extra text to identify the values). Outputs to a file also prefix
the message with a timestamp, much like how syslog output appears on unix
systems.

Subsystem names can be any strings like "storage", "command:info",
"main():debug", etc. Note that logging output is only shown for enabled
subsystems, see dlog.setSubsystems() and dlog.setSubsystem(). Also note that
through the magic of require(), the active subsystems will persist even after a
restart of the program that is being tested.
--]]

local dlog = {}

-- Configuration options.
dlog.logErrorsToOutput = true

-- Private data members, no touchy.
dlog.fileOutput = nil
dlog.stdOutput = true
dlog.enableOutput = true
dlog.subsystems = {
  ["*"] = true,
  ["wnet:d"] = false,
  routeItems = false,
  insertStor = false,
  extractStor = false,
  addStor = false,
  removeStor = false,
} -- FIXME just setting some defaults for when I reboot servers, should change this table back to empty later on. #################################################################
dlog.env2 = nil

-- xassert(v: boolean, ...): ...
-- 
-- Extended assert, a global replacement for the standard assert() function.
-- This improves performance by delaying the concatenation of strings to form
-- the message until the message is actually needed, and also appends a stack
-- trace. The arguments after v are optional and can be anything that tostring()
-- will convert. Returns v and all other arguments.
-- Note that if an exception is caught, it should not be re-thrown with this
-- function. Use error() instead to avoid adding another stack trace onto the
-- message.
-- Original idea from: http://lua.space/general/assert-usage-caveat
function xassert(v, ...)
  if not v then
    local argc = select("#", ...)
    if argc > 0 then
      dlog.errorWithTraceback(string.rep("%s", argc):format(...), 3)
    else
      dlog.errorWithTraceback("assertion failed!", 3)
    end
  end
  return v, ...
end

-- dlog.errorWithTraceback(message: string[, level: number])
-- 
-- Throws the error message, and includes a stack trace in the output. An
-- optional level number specifies the level to start the traceback (defaults to
-- 1, and usually should be set to 2).
function dlog.errorWithTraceback(message, level)
  local traceMsg = string.gsub(debug.traceback(message, level), "\t", "  ")
  if dlog.logErrorsToOutput then
    dlog.out("error", traceMsg)
  end
  error(traceMsg, level)
end

-- FIXME this should be used everywhere and same for the block globals stuff #############################################################################################################
-- dlog.checkArgs(val: any, typ: string, ...)
-- 
-- Re-implementation of the checkArg() built-in function. Asserts that the given
-- arguments match the types they are supposed to. This version fixes issues
-- the original function had with tables as arguments and allows the types
-- string to be a comma-separated list.
-- Example: dlog.checkArgs(my_first_arg, "number", my_second_arg, "table,nil")
local checkArgsHelper
function dlog.checkArgs(val, typ, ...)
  if not string.find(typ, type(val), 1, true) then
    dlog.errorWithTraceback("bad argument at index #1 (" .. typ .. " expected, got " .. type(val) .. ")", 3)
  end
  return checkArgsHelper(3, ...)
end
checkArgsHelper = function(i, val, typ, ...)
  if typ then
    if not string.find(typ, type(val), 1, true) then
      dlog.errorWithTraceback("bad argument at index #" .. i .. " (" .. typ .. " expected, got " .. type(val) .. ")", 3)
    end
    return checkArgsHelper(i + 2, ...)
  end
end

-- dlog.osBlockNewGlobals(state: boolean)
-- 
-- Modifies the global environment to stop creation/access to new global
-- variables. This is to help prevent typos in code from unintentionally
-- creating new global variables that cause bugs later on (also, globals are
-- generally a bad practice). In the case that some globals are needed in the
-- code, they can be safely declared before calling this function. Also see
-- https://www.lua.org/pil/14.2.html for other options and the following link:
-- https://stackoverflow.com/questions/35910099/how-special-is-the-global-variable-g
-- 
-- Note: this function uses some extreme fuckery and modifies the system
-- behavior, use at your own risk!
function dlog.osBlockNewGlobals(state)
  local environmentMetatable = getmetatable(_ENV) or {}    -- Package-level ENV used by OS.
  
  if state then
    local env2 = rawget(environmentMetatable, "__index")    -- ENV at next level down?
    if type(env2) ~= "table" then
      return
    end
    local _G = _G    -- Need to add any used globals as locals, otherwise we get stack overflow.
    
    environmentMetatable.__newindex = function(_, key, value)
      dlog.errorWithTraceback("attempt to write to undeclared global variable " .. key)
      --print("__newindex invoked for " .. key)
      env2[key] = value
    end
    environmentMetatable.__index = function(t, key)
      if not _G[key] then
        dlog.errorWithTraceback("attempt to read from undeclared global variable " .. key)
        --print("__index invoked for " .. key)
      end
      return env2[key]
    end
    
    dlog.env2 = env2
  elseif dlog.env2 then
    local env2 = dlog.env2
    
    -- Reset the metatable to the same way it is set up in /boot/01_process.lua in the intercept_load() function.
    environmentMetatable.__newindex = function(_, key, value)
      env2[key] = value
    end
    environmentMetatable.__index = env2
    
    dlog.env2 = nil
  else
    return
  end
  
  setmetatable(_ENV, environmentMetatable)
end

-- dlog.setFileOut(filename: string[, mode: string])
-- 
-- Open/close a file to output logging data to. Pass a string filename to open
-- file, or empty string to close any opened one. Default mode is append to end
-- of file.
function dlog.setFileOut(filename, mode)
  mode = mode or "a"
  if dlog.fileOutput then
    dlog.fileOutput:close()
    dlog.fileOutput = nil
  end
  if filename ~= "" then
    dlog.fileOutput = io.open(filename, mode)
  end
  dlog.enableOutput = false
  if dlog.fileOutput or dlog.stdOutput then
    dlog.enableOutput = true
  end
end

-- dlog.setStdOut(state: boolean)
-- 
-- Set output of logging data to standard output on/off. This can be used in
-- conjunction with file output.
function dlog.setStdOut(state)
  dlog.stdOutput = state
  dlog.enableOutput = false
  if dlog.fileOutput or dlog.stdOutput then
    dlog.enableOutput = true
  end
end

-- dlog.setSubsystems(subsystems: table)
-- 
-- Set the subsystems to log from the provided table. The table keys are the
-- subsystem names (strings, case sensitive) and the values should be true or
-- false. The special subsystem name "*" can be used to enable all subsystems,
-- except ones that are explicitly disabled with the value of false.
function dlog.setSubsystems(subsystems)
  dlog.subsystems = subsystems
end

-- dlog.setSubsystem(subsystem: string, state: boolean|nil)
-- 
-- Similar to dlog.setSubsystems() for setting individual subsystems. The same
-- behavior in dlog.setSubsystems() applies here.
function dlog.setSubsystem(subsystem, state)
  dlog.subsystems[subsystem] = state
end

-- dlog.tableToString(t: table): string
-- 
-- Serializes a table to a string using a user-facing format. Handles nested
-- tables, but doesn't currently behave with cycles. This is just a helper
-- function for dlog.out().
function dlog.tableToString(t)
  local str = "\n" .. tostring(t) .. " {\n"
  local function tableToStringHelper(t, spacing)
    for k, v in pairs(t) do
      if type(v) == "table" then
        str = str .. spacing .. tostring(k) .. ": " .. tostring(v) .. " {\n"
        tableToStringHelper(v, spacing .. "  ")
        str = str .. spacing .. "}\n"
      else
        str = str .. spacing .. tostring(k) .. ": " .. tostring(v) .. "\n"
      end
    end
  end
  
  tableToStringHelper(t, "  ")
  return str .. "}"
end

-- dlog.out(subsystem: string, ...)
-- 
-- Writes a string to active logging outputs (the output is suppressed if the
-- subsystem is not currently being monitored). To enable monitoring of a
-- subsystem, use dlog.setSubsystems() or dlog.setSubsystem(). The arguments
-- provided after the subsystem can be anything that can be passed through
-- tostring() with a couple exceptions:
-- 1. Tables will be printed recursively and show key-value pairs.
-- 2. Functions are evaluated and their return value gets output instead of the
--    function pointer. This is handy to wrap some potentially slow debugging
--    info in an anonymous function and pass it into dlog.out() to prevent
--    execution if logging is not enabled.
function dlog.out(subsystem, ...)
  if dlog.enableOutput and (dlog.subsystems[subsystem] or (dlog.subsystems["*"] and dlog.subsystems[subsystem] == nil)) then
    local arg = table.pack(...)
    for i = 1, arg.n do
      if type(arg[i]) == "function" then
        arg[i] = arg[i]()
      end
      if type(arg[i]) == "table" then
        arg[i] = dlog.tableToString(arg[i])
      elseif type(arg[i]) ~= "string" then
        arg[i] = tostring(arg[i])
      end
    end
    local str = table.concat(arg)
    if dlog.fileOutput then
      dlog.fileOutput:write(os.date(), " dlog:", subsystem, " ", str, "\n")
    end
    if dlog.stdOutput then
      io.write("dlog:", subsystem, " ", str, "\n")
    end
  end
end

return dlog
