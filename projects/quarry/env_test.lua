--[[
Continued experiments with global variables in OpenOS. This time, I think I have
a fix for the problems that were occurring in dlog.osBlockNewGlobals().

To recursively view the contents of the _ENV var:
Start the "lua" interactive shell, run "_ENV", and exit (to get the lua
environment exercised in OpenOS), then run the extendedTablePrint(_ENV) line by
itself.
--]]

local blockGlobalsCache = {}
blockGlobalsCache.env2 = nil

local function osBlockNewGlobals2(state)
  -- The _ENV in OpenOS is set up like a hierarchy of tables that delegate access/modification to the parent.
  -- The top of this hierarchy is _G where Lua/OpenOS globals are defined, and next in line is the table where user globals declared in main process and modules get defined.
  -- Typically in Lua, _G is the same as _ENV._G and globals get added directly in the _ENV table.
  -- See /boot/01_process.lua for details.
  local environmentMetatable = getmetatable(_ENV)    -- Module-level ENV.
  
  if state and not blockGlobalsCache.env2 then
    print("blocking enabled")
    local env2 = rawget(environmentMetatable, "__index")    -- ENV at next level up.
    
    --local print = print    -- Need to add any used globals as locals, otherwise we could get stack overflow.
    
    rawset(environmentMetatable, "__index", function(t, key)
      local v = env2[key]
      if v == nil then
        --dlog.verboseError("attempt to read from undeclared global variable " .. key, 3)
        print("__index invoked for " .. key)
      end
      return v
    end)
    rawset(environmentMetatable, "__newindex", function(_, key, value)
      if env2[key] == nil then
        --dlog.verboseError("attempt to write to undeclared global variable " .. key, 4)
        print("__newindex invoked for " .. key)
      end
      env2[key] = value
    end)
    
    blockGlobalsCache.env2 = env2
  elseif not state and blockGlobalsCache.env2 then
    print("blocking disabled")
    local env2 = blockGlobalsCache.env2
    
    -- Reset the metatable to the same way it is set up in /boot/01_process.lua in the intercept_load() function.
    rawset(environmentMetatable, "__index", env2)
    rawset(environmentMetatable, "__newindex", function(_, key, value)
      env2[key] = value
    end)
    
    blockGlobalsCache.env2 = nil
  end
end

myPredefinedGlobal = false
myPredefinedGlobal2 = "hello"

local function shallowTablePrint(t)
  if type(t) ~= "table" then
    return tostring(t) .. "\n"
  end
  local str = tostring(t) .. " {\n"
  --for k, v in pairs(t) do    -- Careful, we can have a __pairs metamethod.
    --str = str .. "  " .. tostring(k) .. ": " .. tostring(v) .. "\n"
  --end
  local k, v = next(t)
  while k do
    str = str .. "  " .. tostring(k) .. ": " .. tostring(v) .. "\n"
    k, v = next(t, k)
  end
  return str .. "}\n"
end

local function shallowPrintEnv()
  io.write("---- Printing full _ENV hierarchy ----\n")
  local envLevel = _ENV
  local i = 1
  while envLevel do
    io.write("_ENV __index ^ " .. (i - 1) .. " is:\n" .. shallowTablePrint(envLevel))
    envLevel = getmetatable(envLevel)
    if envLevel then
      io.write("_ENV meta ^ " .. i .. " is:\n" .. shallowTablePrint(envLevel))
      envLevel = rawget(envLevel, "__index")
    else
      io.write("_ENV meta ^ " .. i .. " is:\nnil\n")
    end
    io.write("\n")
    i = i + 1
  end
end

print("before lib loading")
--shallowPrintEnv()

local dlog = require("dlog")

for k, v in pairs(dlog.osGetGlobalsList()) do
  --print(k, v)
end
--dlog.osBlockNewGlobals(true)

--osBlockNewGlobals2(true)

-- Note here that the global defined in myLib does not get detected when we osBlockNewGlobals2() from within this chunk.
-- This is because lib is closer to _G in the _ENV hierarchy, so it bypasses the blocking.

local myLib = require("env_test_lib")

-- BUG: Seems like a minor bug in OpenOS here.
-- After this script is run, myTestGlobal is accessible elsewhere (like in the "lua" prompt) however if the value here is set to false instead of a number the global is returned as a nil value.
myTestGlobal = 123

local function extendedTablePrint(t)
  local foundTables = {[t] = true}
  local str = tostring(t) .. " {\n"
  local function tablePrintHelper(t, spacing)
    for k, v in pairs(t) do
      if type(v) == "table" then
        if foundTables[v] then
          str = str .. spacing .. tostring(k) .. ": " .. tostring(v) .. " (already found)\n"
        else
          foundTables[v] = true
          str = str .. spacing .. tostring(k) .. ": " .. tostring(v) .. " {\n"
          tablePrintHelper(v, spacing .. "  ")
          str = str .. spacing .. "}\n"
        end
      else
        str = str .. spacing .. tostring(k) .. ": " .. tostring(v) .. "\n"
      end
    end
  end
  
  tablePrintHelper(t, "  ")
  return str .. "}\n"
end

--io.write(extendedTablePrint(_ENV))

xassert(true, "xassert working?")

print("after lib load + global declared")
--shallowPrintEnv()
for k, v in pairs(dlog.osGetGlobalsList()) do
  --print(k, v)
end

print("myLibGlobalFunc = ", myLibGlobalFunc())

print("myPredefinedGlobal2 is", myPredefinedGlobal2)
myPredefinedGlobal2 = "world"
print("myPredefinedGlobal2 is", myPredefinedGlobal2)
myPredefinedGlobal2 = nil
print("myPredefinedGlobal2 is", myPredefinedGlobal2)

xassert(myPredefinedGlobal == false, "myPredefinedGlobal is false?")
xassert(myUndefinedGlobal == nil, "myUndefinedGlobal is nil?")

myUndefinedGlobal = 456

dlog.osBlockNewGlobals(false)
