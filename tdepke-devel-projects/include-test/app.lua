local include = require("include")
local first = include("include-test.first")
local second = include("include-test.second")
local third = include("include-test.third")
local fourth = include("include-test.fourth")
local first = include("include-test.first")
local fifth = include("include-test.fifth")

--[[
Dependency tree:

  app
  |-- first
  |   |-- x
  |   '-- y
  |-- second
  |-- third
  |   |-- x
  |   '-- first
  |       |-- x
  |       '-- y
  |-- fourth
  |   |-- first
  |   |   |-- x
  |   |   '-- y
  |   '-- x
  |-- first
  |   |-- x
  |   '-- y
  '-- fifth
      |-- fourth
      |   |-- first
      |   |   |-- x
      |   |   '-- y
      |   '-- x
      |-- second
      '-- third
          |-- x
          '-- first
              |-- x
              '-- y
--]]

local function main()
  print("running app...")
  print("first.x.thing() gives " .. first.x.thing())
  print("fourth.first.x.thing() gives " .. fourth.first.x.thing())
  print("fifth.third.x.thing() gives " .. fifth.third.x.thing())
  
  assert(include.moduleDepth == 0)
  assert(include.moduleDependencies == nil)
  assert(include.scannedModules == nil)
  print("contents of include.loaded:")
  for k, v in pairs(include.loaded) do
    print(k, v)
  end
end
main()
