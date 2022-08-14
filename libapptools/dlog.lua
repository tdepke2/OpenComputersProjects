--------------------------------------------------------------------------------
-- Diagnostic logger and debugging utilities.
-- 
-- @see file://libapptools/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local dlog = {}


--- **Configuration options:**

--- `dlog.logErrorsToOutput = true`
-- 
-- Set errors to direct to `dlog.out()` using the `error` subsystem.
dlog.logErrorsToOutput = true

--- `dlog.defineGlobalXassert = true`
-- 
-- Enables the `xassert()` call as a global function. To disable, this must be
-- set to false here before loading dlog module.
dlog.defineGlobalXassert = true

--- `dlog.maxMessageLength = nil`
-- 
-- Sets a maximum string length on the output from `dlog.out()`. A message that
-- exceeds this size will be trimmed to fit. Set this value to nil for unlimited
-- size messages.
dlog.maxMessageLength = nil


-- Private data members, no touchy:
local dlogFileOutput = nil
local dlogStandardOutput = true
local dlogSubsystems = {["error"] = true}
local dlogEnv2 = nil
local dlogMode = 2
local dlogFunctionBackups = {}


--- `dlog.mode([newMode: string]): string`
-- 
-- Configure mode of operation for dlog. The mode sets defaults for logging and
-- can disable some dlog features completely to increase performance. If newMode
-- is provided, the mode is set to this value. The valid modes are:
--   * debug (all subsystems on, logging enabled for stdout and `/tmp/messages`)
--   * release (default mode, only error logging to stdout)
--   * optimize1 (function `dlog.osBlockNewGlobals()` is disabled)
--   * optimize2 (function `dlog.checkArgs()` is disabled)
--   * optimize3 (functions `dlog.out()` and `dlog.fileOutput()` are disabled)
--   * optimize4 (functions `xassert()` and `dlog.xassert()` are disabled)
-- 
-- Each mode includes behavior from the previous modes (optimize4 pretty much
-- disables everything). The mode is intended to be set once right after dlog is
-- loaded in the main program, it can be changed at any time though. Returns the
-- current mode.
function dlog.mode(newMode)
  local modes = {"debug", "release", "optimize1", "optimize2", "optimize3", "optimize4"}
  if not newMode then
    return modes[dlogMode]
  end
  local doNothing = function() end
  dlogMode = 0
  
  -- debug
  for k, v in pairs(dlogFunctionBackups) do
    dlog[k] = v
  end
  dlogFunctionBackups = {}
  if dlog.defineGlobalXassert then
    xassert = dlog.xassert
  end
  dlogMode = dlogMode + 1
  if newMode == modes[dlogMode] then
    if dlog.subsystems()["*"] == nil then
      dlog.subsystems()["*"] = true
    end
    if not dlog.fileOutput() then
      dlog.fileOutput("/tmp/messages", "w")
    end
    dlog.standardOutput(true)
    return newMode
  end
  
  -- release
  dlog.subsystems({["error"] = true})
  dlog.fileOutput("")
  dlogMode = dlogMode + 1
  if newMode == modes[dlogMode] then
    dlog.standardOutput(true)
    return newMode
  end
  
  -- optimize1
  dlogFunctionBackups["osBlockNewGlobals"] = dlog.osBlockNewGlobals
  dlog.osBlockNewGlobals = doNothing
  dlogMode = dlogMode + 1
  if newMode == modes[dlogMode] then
    return newMode
  end
  
  -- optimize2
  dlogFunctionBackups["checkArgs"] = dlog.checkArgs
  dlog.checkArgs = doNothing
  dlogMode = dlogMode + 1
  if newMode == modes[dlogMode] then
    return newMode
  end
  
  -- optimize3
  dlogFunctionBackups["fileOutput"] = dlog.fileOutput
  dlog.fileOutput = doNothing
  dlogFunctionBackups["out"] = dlog.out
  dlog.out = doNothing
  dlogMode = dlogMode + 1
  if newMode == modes[dlogMode] then
    return newMode
  end
  
  -- optimize4
  dlogFunctionBackups["xassert"] = dlog.xassert
  dlog.xassert = doNothing
  if dlog.defineGlobalXassert then
    xassert = doNothing
  end
  dlogMode = dlogMode + 1
  if newMode == modes[dlogMode] then
    return newMode
  end
  
  error("specified mode \"" .. tostring(newMode) .. "\" is not a valid mode.")
end


--- `dlog.xassert(v: boolean, ...): ...`<br>
-- `xassert(v: boolean, ...): ...`
-- 
-- Extended assert, a global replacement for the standard `assert()` function.
-- This improves performance by delaying the concatenation of strings to form
-- the message until the message is actually needed. The arguments after v are
-- optional and can be anything that `tostring()` will convert. Returns v and
-- all other arguments.
-- Original idea from: http://lua.space/general/assert-usage-caveat
function dlog.xassert(v, ...)
  if not v then
    local argc = select("#", ...)
    if argc > 0 then
      error(string.rep("%s", argc):format(...), 2)
    else
      error("assertion failed!", 2)
    end
  end
  return v, ...
end
if dlog.defineGlobalXassert then
  xassert = dlog.xassert
end


--- `dlog.handleError(status: boolean, ...): boolean, ...`
-- 
-- Logs an error message/object if status is false and `dlog.logErrorsToOutput`
-- is enabled. This is designed to be called with the results of `pcall()` or
-- `xpcall()` to echo any errors that occurred. Returns the same arguments
-- passed to the function.
function dlog.handleError(status, ...)
  if not status and dlog.logErrorsToOutput then
    local message = select(1, ...)
    -- Format tabs to spaces created from debug.traceback().
    if type(message) == "string" then
      message = string.gsub(message, "\t", "  ")
    end
    -- Avoid sending an error message for an exit code (os.exit() throws an error with table message).
    if type(message) ~= "table" or message.reason == nil then
      dlog.out("error", "\27[31m", message, "\27[0m")
    end
  end
  return status, ...
end


-- FIXME this should be used everywhere and same for the block globals stuff #############################################################################################################
--- `dlog.checkArgs(val: any, typ: string, ...)`
-- 
-- Re-implementation of the `checkArg()` built-in function. Asserts that the
-- given arguments match the types they are supposed to. This version fixes
-- issues the original function had with tables as arguments and allows the
-- types string to be a comma-separated list.
-- 
-- Example:
-- `dlog.checkArgs(my_first_arg, "number", my_second_arg, "table,nil")`
local checkArgsHelper
function dlog.checkArgs(val, typ, ...)
  if not string.find(typ, type(val), 1, true) and typ ~= "any" then
    error("bad argument at index #1 (" .. typ .. " expected, got " .. type(val) .. ")", 2)
  end
  return checkArgsHelper(3, ...)
end
checkArgsHelper = function(i, val, typ, ...)
  if typ then
    if not string.find(typ, type(val), 1, true) and typ ~= "any" then
      error("bad argument at index #" .. i .. " (" .. typ .. " expected, got " .. type(val) .. ")", 2)
    end
    return checkArgsHelper(i + 2, ...)
  end
end


--- `dlog.osBlockNewGlobals(state: boolean)`
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
  local environmentMetatable = getmetatable(_ENV)    -- Module-level ENV.
  
  -- The _ENV in OpenOS is set up like a hierarchy of tables that delegate access/modification to the parent.
  -- The top of this hierarchy is _G where Lua/OpenOS globals are defined, and next in line is the table where user globals declared in main process and modules get defined.
  -- Typically in Lua, _G is the same as _ENV._G and globals get added directly in the _ENV table.
  -- See /boot/01_process.lua for details.
  if state and not dlogEnv2 then
    local env2 = rawget(environmentMetatable, "__index")    -- ENV at next level up.
    
    -- Be careful here: Certain globals (or undefined ones) need to be aliased to local vars when used in these metamethods, otherwise we get stack overflow.
    local error, tostring = error, tostring
    rawset(environmentMetatable, "__index", function(t, key)
      local v = env2[key]
      if v == nil then
        error("attempt to read from undeclared global variable " .. tostring(key), 2)
        --print("__index invoked for " .. key)
      end
      return v
    end)
    rawset(environmentMetatable, "__newindex", function(_, key, value)
      if env2[key] == nil then
        error("attempt to write to undeclared global variable " .. tostring(key), 2)
        --print("__newindex invoked for " .. key)
      end
      env2[key] = value
    end)
    
    dlogEnv2 = env2
  elseif not state and dlogEnv2 then
    local env2 = dlogEnv2
    
    -- Reset the metatable to the same way it is set up in /boot/01_process.lua in the intercept_load() function.
    rawset(environmentMetatable, "__index", env2)
    rawset(environmentMetatable, "__newindex", function(_, key, value)
      env2[key] = value
    end)
    
    dlogEnv2 = nil
  end
end


--- `dlog.osGetGlobalsList(): table`
-- 
-- Collects a table of all global variables currently defined. Specifically,
-- this shows the contents of _G and any globals accessible by the running
-- process. This function is designed for debugging purposes only.
function dlog.osGetGlobalsList()
  local envLevel = _ENV
  local result = {}
  
  while envLevel do
    --print(tostring(envLevel) .. " {")
    -- Iterate without using pairs() to avoid __pairs metamethod.
    for k, v in next, envLevel do
      --print("  " .. tostring(k) .. ": " .. tostring(v))
      result[k] = v
    end
    --print("}")
    
    envLevel = getmetatable(envLevel)
    if envLevel then
      envLevel = rawget(envLevel, "__index")
      -- If we find an __index set to a function, assume dlog.osBlockNewGlobals() is in effect and jump to the cached _ENV value.
      if type(envLevel) == "function" then
        envLevel = dlogEnv2
      end
    end
  end
  
  return result
end


--- `dlog.fileOutput([filename: string[, mode: string]]): table|nil`
-- 
-- Open/close a file to output logging data to. If filename is provided then
-- this file is opened (an empty string will close any opened one instead).
-- Default mode is `a` to append to end of file. Returns the currently open file
-- (or nil if closed).
function dlog.fileOutput(filename, mode)
  if filename ~= nil then
    if dlogFileOutput then
      dlogFileOutput:close()
      dlogFileOutput = nil
    end
    if filename ~= "" then
      dlogFileOutput = io.open(filename, mode or "a")
    end
  elseif io.type(dlogFileOutput) == "closed file" then
    -- File may have been closed by an external method, so delete our copy of the file descriptor.
    dlogFileOutput = nil
  end
  return dlogFileOutput
end


--- `dlog.standardOutput([state: boolean]): boolean`
-- 
-- Set output of logging data to standard output. This can be used in
-- conjunction with file output. If state is provided, logging to standard
-- output is enabled/disabled based on the value. Returns true if logging to
-- standard output is enabled and false otherwise.
function dlog.standardOutput(state)
  if state ~= nil then
    dlogStandardOutput = state
  end
  return dlogStandardOutput
end


--- `dlog.subsystems([subsystems: table]): table`
-- 
-- Set the subsystems to log from the provided table. The table keys are the
-- subsystem names (strings, case sensitive) and the values should be true or
-- false. The special subsystem name `*` can be used to enable all subsystems,
-- except ones that are explicitly disabled with the value of false. If the
-- subsystems are provided, these overwrite the old table contents. Returns the
-- current subsystems table.
function dlog.subsystems(subsystems)
  if subsystems ~= nil then
    dlogSubsystems = subsystems
  end
  return dlogSubsystems
end


--- `dlog.tableToString(t: table): string`
-- 
-- Serializes a table to a string using a user-facing format. String keys/values
-- in the table are escaped and enclosed in double quotes. Handles nested tables
-- and tables with cycles. This is just a helper function for `dlog.out()`.
local tableToStringHelper
function dlog.tableToString(t)
  local tableData = {"\n", n = 1}
  tableToStringHelper(tableData, t, "")
  return table.concat(tableData, "", 1, tableData.n)
end
tableToStringHelper = function(tableData, t, spacing)
  -- Check if table already expanded.
  if tableData[t] then
    tableData.n = tableData.n + 1
    tableData[tableData.n] = tostring(t) .. " (duplicate)\n"
    return
  end
  tableData.n = tableData.n + 1
  tableData[tableData.n] = tostring(t) .. " {\n"
  tableData[t] = true
  
  -- Step through table keys/values (raw iteration) and add to tableData.
  for k, v in next, t do
    if type(k) == "string" then
      k = string.format("%q", k):gsub("\\\n","\\n")
    else
      k = tostring(k)
    end
    if type(v) == "table" then
      tableData.n = tableData.n + 1
      tableData[tableData.n] = spacing .. "  " .. k .. " = "
      tableToStringHelper(tableData, v, spacing .. "  ")
    elseif type(v) == "string" then
      tableData.n = tableData.n + 1
      tableData[tableData.n] = spacing .. "  " .. k .. " = " .. string.format("%q", v):gsub("\\\n","\\n") .. "\n"
    else
      tableData.n = tableData.n + 1
      tableData[tableData.n] = spacing .. "  " .. k .. " = " .. tostring(v) .. "\n"
    end
  end
  tableData.n = tableData.n + 1
  tableData[tableData.n] = spacing .. "}\n"
end


--- `dlog.out(subsystem: string, ...)`
-- 
-- Writes a string to active logging outputs (the output is suppressed if the
-- subsystem is not currently being monitored). To enable monitoring of a
-- subsystem, use `dlog.subsystems()`. The arguments provided after the
-- subsystem can be anything that can be passed through `tostring()` with a
-- couple exceptions:
-- 1. Tables will be printed recursively and show key-value pairs.
-- 2. Functions are evaluated and their return value gets output instead of the
--    function pointer. This is handy to wrap some potentially slow debugging
--    info in an anonymous function and pass it into `dlog.out()` to prevent
--    execution if logging is not enabled.
function dlog.out(subsystem, ...)
  if (dlogStandardOutput or dlogFileOutput) and (dlogSubsystems[subsystem] or (dlogSubsystems["*"] and dlogSubsystems[subsystem] == nil)) then
    local varargs = table.pack(...)
    for i = 1, varargs.n do
      if type(varargs[i]) == "function" then
        varargs[i] = varargs[i]()
      end
      if type(varargs[i]) == "table" then
        varargs[i] = dlog.tableToString(varargs[i])
      elseif type(varargs[i]) ~= "string" then
        varargs[i] = tostring(varargs[i])
      end
    end
    local message = "dlog:" .. subsystem .. " " .. table.concat(varargs, "", 1, varargs.n)
    if dlog.maxMessageLength and #message > dlog.maxMessageLength then
      message = string.sub(message, 1, dlog.maxMessageLength - 3) .. "..."
    end
    if dlogFileOutput then
      dlogFileOutput:write(os.date(), " ", message, "\n")
    end
    if dlogStandardOutput then
      io.write(message, "\n")
    end
  end
end

return dlog
