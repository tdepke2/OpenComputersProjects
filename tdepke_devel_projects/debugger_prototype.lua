
-- Improved error handling with xpcall and simple debugger.
-- This isn't working too well in OpenComputers for two reasons:
--   1. The debug library is very stripped down, you can't check the values of
--      upvalues or local vars.
--   2. Hooking into xpcall() and blocking for IO is a no-no, no chance of
--      prompting user to evaluate code during exception handling. The data
--      would need to be cached before leaving xpcall(), but there's not much
--      useful information available besides a stack trace.


local dlog = {}

-- Option 1: show variables and values in the stack.
function dlog.debugFrame()
  print(debug.traceback())
  
  local level = 1
  
  while true do
  local info = debug.getinfo(level)
  if not info then
    return
  end
  
  io.write(info.short_src or "?", (info.currentline or -1) > 0 and ":" .. info.currentline .. ": in " or ": in ")
  if info.what == "main" then
    io.write("main chunk\n")
  else
    local funcName = info.name and "\'" .. info.name .. "\'"
    if not funcName and info.short_src and (info.linedefined or -1) > 0 then
      funcName = "<" .. info.short_src .. ":" .. info.linedefined .. ">"
    end
    if funcName then
      io.write((info.namewhat == "global" or info.namewhat == "") and "function" or info.namewhat, " ", funcName, "\n")
    else
      io.write("?\n")
    end
  end
  
  --for k, v in pairs(info) do
    --print("    ", k, v)
  --end
  
  -- is debug.getlocal() available in oc??? see https://www.lua.org/pil/23.1.1.html
  
  print("  ", "local vars:")
  local i = 1
  while true do
    local n, v = debug.getlocal(level, i)
    if not n then
      break
    end
    print("    ", n, v)
    i = i + 1
  end
  i = -1
  while true do
    local n, v = debug.getlocal(level, i)
    if not n then
      break
    end
    print("    ", n, v)
    i = i - 1
  end
  
  print("  ", "upvals:")
  local i = 1
  while true do
    local n, v = debug.getupvalue(info.func, i)
    if not n then
      break
    end
    print("    ", n, v)
    i = i + 1
  end
  
  level = level + 1
  end
end

function dlog.debugPrint(name)
  
end

-- Option 2: interactively prompt for user input and execute code.
function dlog.debug(err)
  print("entered debug mode")
  --local info = debug.getinfo(3)
  --print(tostring(info.short_src) .. ":" .. tostring(info.currentline) .. " in function \"" .. tostring(info.name) .. "\"")
  print("last error:", err)
  --print(debug.getinfo())
  
  local localEnv = setmetatable({dlog=dlog}, {
    __index = _ENV,
    __newindex = _ENV
  })
  
  --[[
  local myf = load("print(\"my vars:\") local i = 1 while debug.getupvalue(..., i) do print(debug.getupvalue(..., i)) i = i + 1 end")
  myf(myf)
  print("ENV is ", _ENV)
  --]]
  
  local inp = io.read()
  while inp do
    print(inp)
    local result, err = load(inp, inp, "t", localEnv)
    if result then
      result, err = pcall(result)
    end
    if not result then
      print(err)
    end
    inp = io.read()
  end
  return debug.traceback(err)
end





my_var = "test-cool"

local function my_func(arg1, ...)
  print("in my_func called with", arg1, ...)
  local new_local = "thing"
  error("bomb has been planted")
end

local function main(beef)
  local test123 = 5
  print("running main()")
  --for k, v in pairs(debug.getinfo(1)) do
    --print(k, v)
  --end
  --error("rip in pepperoni")
  my_func(12, "beef", "cake")
  print("done")
  return "ok"
end
--print(main)
--main(42)
print(xpcall(main, dlog.debugFrame))
print("end of program")
