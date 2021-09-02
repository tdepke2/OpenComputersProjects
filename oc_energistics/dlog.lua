--[[
Diagnostic logger.

Allows writing logging data to standard output and/or a file for debugging code.
Log messages include a subsystem name and a list of space-separated values
(preferably including some extra text to identify the values). Outputs to a file
also prefix the message with a timestamp, much like how syslog output appears on
unix systems.

Subsystem names can be any strings like "storage", "command:info",
"main():debug", etc. Note that logging output is only show for enabled
subsystems, see dlog.setSubsystems() and dlog.setSubsystem(). Also note that
through the magic of require(), the active subsystems will persist even after a
restart of the program that is being tested.
--]]

local dlog = {}

-- Private data members, no touchy.
dlog.fileOutput = nil
dlog.stdOutput = true
dlog.enableOutput = true
dlog.subsystems = {}

-- FIXME this should be used everywhere #############################################################################################################
-- dlog.checkArg(n: number, value, type: string, ...)
-- 
-- Re-implementation of the checkArg() built-in function. Asserts that the given
-- parameters match the types they are supposed to. This version fixes issues
-- the original function had with tables as arguments.
-- Example: dlog.checkArg(1, my_first_arg, "number", 2, my_second_arg, "table")
function dlog.checkArg(...)
  local arg = table.pack(...)
  for i = 1, arg.n do
    if i % 3 == 0 and arg[i] ~= type(arg[i - 1]) then
      assert(false, string.gsub(debug.traceback("bad argument #" .. arg[i - 2] .. " (" .. arg[i] .. " expected, got " .. type(arg[i - 1]) .. ")"), "\t", "  "))
    end
  end
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
  dlog.enableOutput = dlog.fileOutput or dlog.stdOutput
end

-- dlog.setStdOut(state: boolean)
-- 
-- Set output of logging data to standard output on/off. This can be used in
-- conjunction with file output.
function dlog.setStdOut(state)
  dlog.stdOutput = state
  dlog.enableOutput = dlog.fileOutput or dlog.stdOutput
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
        str = str .. spacing .. tostring(k) .. ": {\n"
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
    local str = ""
    for i = 1, arg.n do
      if type(arg[i]) == "function" then
        arg[i] = arg[i]()
      end
      if type(arg[i]) == "table" then
        str = str .. dlog.tableToString(arg[i])
      else
        str = str .. " " .. tostring(arg[i])
      end
    end
    if dlog.fileOutput then
      dlog.fileOutput:write(os.date(), " dlog:", subsystem, str, "\n")
    end
    if dlog.stdOutput then
      io.write("dlog:", subsystem, str, "\n")
    end
  end
end

return dlog
