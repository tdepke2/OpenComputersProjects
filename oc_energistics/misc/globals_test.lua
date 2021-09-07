local dlog = require("dlog")
local wnet = require("wnet")
local computer = require("computer")
local component = require("component")
local print2 = io.write

-- yeah this probably is not very safe, idk
local function blockGlobalDeclaration()
  local envThing = _ENV --rawget(getmetatable(_ENV), "__index")
  local globalMetatable = getmetatable(envThing) or {}
  local env = rawget(globalMetatable, "__index")
  local g = _G
  --for k, v in pairs(_G) do
    --g[k] = v
  --end
  
  --print(globalMetatable.__newindex)
  globalMetatable.__newindex = function(_, key, value)
    --error("attempt to write to undeclared global variable " .. n)
    print2("__newindex invoked for " .. key .. "\n")
    env[key] = value
  end
  --print(globalMetatable.__index)
  globalMetatable.__index = function(t, key)
    --error("attempt to read from undeclared global variable " .. n)
    if not g[key] then
      print2("__index invoked for " .. key .. "\n")
    end
    return env[key]
  end
  setmetatable(envThing, globalMetatable)
end

dlog.osBlockNewGlobals(false)

myGlobal = 2

dlog.osBlockNewGlobals(true)

--dlog.setSubsystem("*", true)
--dlog.out("d", "_ENV =", _ENV)
--dlog.out("d", "getmetatable(_ENV) =", getmetatable(_ENV))
--dlog.out("d", debug.getinfo(getmetatable(_ENV).__newindex))

--dlog.out("d", tostring(_ENV))
--dlog.out("d", tostring(rawget(getmetatable(_ENV), "__index")))
--dlog.out("d", "getmetatable(_ENV).__index =", rawget(getmetatable(_ENV), "__index"))
--dlog.out("d", "getmetatable(getmetatable(_ENV).__index) =", getmetatable(rawget(getmetatable(_ENV), "__index")))
--dlog.out("d", "getmetatable(getmetatable(_ENV).__index).__index =", rawget(getmetatable(rawget(getmetatable(_ENV), "__index")), "__index"))
--dlog.out("d", "getmetatable(getmetatable(getmetatable(_ENV).__index).__index) =", getmetatable(rawget(getmetatable(rawget(getmetatable(_ENV), "__index")), "__index")))
--dlog.out("d", getmetatable(getmetatable(_ENV).__index))

local x = 4

--myGlobal2 = 7

local t = {"cool stuff", "noice"}

--t2 = "uh oh"

--print("t3 is ", t3)

computer.beep(800, 0.1)
computer.beep(900, 0.1)

dlog.setStdOut(true)

wnet.send(component.modem, nil, 123, "broadcastin sum datas")

dlog.osBlockNewGlobals(false)

--[[
local env2 = {}
setmetatable(env2, {
  __newindex = function(_, key, value)
    env2[key] = value
  end,
  __index = env2
})
--]]

--print("read =", env2["beef"])
--env2["beef"] = "bamboozled"
--print("read2 =", env2["beef"])
