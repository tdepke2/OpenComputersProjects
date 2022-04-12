--[[
Testing performance of new xassert() function (extended assert).
--]]

-- Doesn't work for values other than strings and numbers.
function xassert(v, ...)
  if not v then
    if ... == nil then
      error("assertion failed!")
    else
      error(table.concat{...})
    end
  end
  return v, ...
end

-- Fastest implementation.
function xassert2(v, ...)
  if not v then
    local argc = select("#", ...)
    if argc > 0 then
      error(("%s"):rep(argc):format(...))
    else
      error("assertion failed!")
    end
  end
  return v, ...
end

local function concat(n, x, ...)
  if n == 0 then return "" end
  return tostring(x) .. concat(n - 1, ...)
end

-- Seems to be a bit slower, even slower than xassert() despite the fact that we don't allocate a table in here.
function xassert3(v, ...)
  if not v then
    local argc = select("#", ...)
    if argc > 0 then
      error(concat(argc, ...))
    else
      error("assertion failed!")
    end
  end
  return v, ...
end

-- Same performance as xassert2().
function xassert4(v, ...)
  if not v then
    local argc = select("#", ...)
    if argc > 0 then
      error(string.rep("%s", argc):format(...))
    else
      error("assertion failed!")
    end
  end
  return v, ...
end

--[[
local NUM_VALUES = 40000

local function doTest1()
  local timeStart = os.clock()
  
  for i = 1, NUM_VALUES do
    pcall(xassert, true, "hello ", i, " world ", "cool test")
  end
  
  local timeEnd = os.clock()
  io.write("test1 took " .. timeEnd - timeStart .. "\n")
end

local function doTest2()
  local timeStart = os.clock()
  
  for i = 1, NUM_VALUES do
    pcall(xassert3, true, "hello ", i, " world ", "cool test")
  end
  
  local timeEnd = os.clock()
  io.write("test2 took " .. timeEnd - timeStart .. "\n")
end

local function doTest3()
  local timeStart = os.clock()
  
  for i = 1, NUM_VALUES do
    pcall(xassert, false, "hello ", i, " world ", "cool test")
  end
  
  local timeEnd = os.clock()
  io.write("test3 took " .. timeEnd - timeStart .. "\n")
end

local function doTest4()
  local timeStart = os.clock()
  
  for i = 1, NUM_VALUES do
    pcall(xassert3, false, "hello ", i, " world ", "cool test")
  end
  
  local timeEnd = os.clock()
  io.write("test4 took " .. timeEnd - timeStart .. "\n")
end

doTest1()
doTest2()
doTest3()
doTest4()
--]]

local dlog = {}

-- Original func.
function dlog.checkArgs(...)
  local arg = table.pack(...)
  for i = 2, arg.n, 2 do
    if not string.find(arg[i], type(arg[i - 1]), 1, true) then
      dlog.errorWithTraceback("bad argument at index #" .. i - 1 .. " (" .. arg[i] .. " expected, got " .. type(arg[i - 1]) .. ")")
    end
  end
end

-- Same performance, no more table alloc though.
function dlog.checkArgs2(...)
  for i = 2, select("#", ...), 2 do
    if not string.find((select(i, ...)), type(select(i - 1, ...)), 1, true) then
      dlog.errorWithTraceback("bad argument at index #" .. i - 1 .. " (" .. (select(i, ...)) .. " expected, got " .. type(select(i - 1, ...)) .. ")")
    end
  end
end

-- Faster than previous.
function dlog.checkArgs3(v, t, ...)
  if not string.find(t, type(v), 1, true) then
    dlog.errorWithTraceback("bad argument at index #" .. i - 1 .. " (" .. t .. " expected, got " .. type(v) .. ")")
  end
  if select("#", ...) > 0 then
    return dlog.checkArgs3(...)
  end
end

-- Slightly faster, about 10% faster compared to first one.
function dlog.checkArgs4(val, typ, ...)
  if typ then
    if not string.find(typ, type(val), 1, true) then
      dlog.errorWithTraceback("bad argument at index #" .. i - 1 .. " (" .. typ .. " expected, got " .. type(val) .. ")")
    end
    return dlog.checkArgs4(...)
  end
end

-- About same as previous, fixes issue with wrong stack trace level.
local checkArgsHelper
function dlog.checkArgs5(val, typ, ...)
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

--[[
local NUM_VALUES = 40000

local function doTest(testName, f)
  local timeStart = os.clock()
  
  for i = 1, NUM_VALUES do
    f(123, "number", dlog, "nil,table", xassert, "function")
  end
  
  local timeEnd = os.clock()
  io.write(testName .. " took " .. timeEnd - timeStart .. "\n")
end

doTest("test1", dlog.checkArgs)
doTest("test2", dlog.checkArgs5)
--]]

dlog.enableOutput = true
dlog.subsystems = {my_subsys = true}

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

-- Slight improvement (no more generated closure). Actually this doesn't work :(
local tableToStringHelper
function dlog.tableToString2(t)
  local str = "\n" .. tostring(t) .. " {\n"
  tableToStringHelper(t, str, "  ")
  return str .. "}"
end
tableToStringHelper = function(t, str, spacing)
  for k, v in pairs(t) do
    if type(v) == "table" then
      str = str .. spacing .. tostring(k) .. ": {\n"
      tableToStringHelper(v, str, spacing .. "  ")
      str = str .. spacing .. "}\n"
    else
      str = str .. spacing .. tostring(k) .. ": " .. tostring(v) .. "\n"
    end
  end
end

-- Slight improvement along with the new tableToString2(), now using table.concat().
function dlog.out2(subsystem, ...)
  if dlog.enableOutput and (dlog.subsystems[subsystem] or (dlog.subsystems["*"] and dlog.subsystems[subsystem] == nil)) then
    local arg = table.pack(...)
    for i = 1, arg.n do
      if type(arg[i]) == "function" then
        arg[i] = arg[i]()
      end
      if type(arg[i]) == "table" then
        arg[i] = dlog.tableToString2(arg[i])
      else
        arg[i] = tostring(arg[i])
      end
    end
    local str = table.concat(arg)
    if dlog.fileOutput then
      dlog.fileOutput:write(os.date(), " dlog:", subsystem, str, "\n")
    end
    if dlog.stdOutput then
      io.write("dlog:", subsystem, str, "\n")
    end
  end
end

-- Tiny bit faster, now checks for string type before assignment.
function dlog.out3(subsystem, ...)
  if dlog.enableOutput and (dlog.subsystems[subsystem] or (dlog.subsystems["*"] and dlog.subsystems[subsystem] == nil)) then
    local arg = table.pack(...)
    for i = 1, arg.n do
      if type(arg[i]) == "function" then
        arg[i] = arg[i]()
      end
      if type(arg[i]) == "table" then
        arg[i] = dlog.tableToString2(arg[i])
      elseif type(arg[i]) ~= "string" then
        arg[i] = tostring(arg[i])
      end
    end
    local str = table.concat(arg)
    if dlog.fileOutput then
      dlog.fileOutput:write(os.date(), " dlog:", subsystem, str, "\n")
    end
    if dlog.stdOutput then
      io.write("dlog:", subsystem, str, "\n")
    end
  end
end

----[[
local NUM_VALUES = 10000

local function returnStr()
  return "returnStr result"
end

local function doTest(testName, f)
  local timeStart = os.clock()
  
  for i = 1, NUM_VALUES do
    f("my_subsys", "value one is ", 123, ", func gives ", returnStr, ", dlog has contents:", dlog)
  end
  
  local timeEnd = os.clock()
  io.write(testName .. " took " .. timeEnd - timeStart .. "\n")
end

doTest("test1", dlog.out2)
doTest("test2", dlog.out3)
--]]
