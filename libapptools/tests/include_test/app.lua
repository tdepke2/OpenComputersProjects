local include = require("include")
local first = include("include_test.first")
local second = include("include_test.second")
local third = include("include_test.third")
local fourth = include("include_test.fourth")
local first = include("include_test.first")
local fifth = include("include_test.fifth")

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
  if first.x == nil then
    -- If x has been marked as an optional dependency, it could be nil.
    print("first.x was nil, updating the value...")
    first.x = {thing = function() return "sample text" end}
    assert(third.x == nil and fourth.x == nil)
    third.x = first.x
    fourth.x = first.x
  end
  print("first.x.thing() gives " .. first.x.thing())
  print("first.y.thing() gives " .. first.y.thing())
  
  assert(first.x.thing() == third.x.thing())
  assert(first.x.thing() == fourth.x.thing())
  assert(first.x.thing() == fourth.first.x.thing())
  assert(first.x.thing() == fifth.third.x.thing())
  assert(first.y.thing() == fifth.third.first.y.thing())
  assert(first.x.thing() ~= first.y.thing())
  
  assert(include.moduleDepth == 0)
  assert(include.moduleDependencies == nil)
  assert(include.scannedModules == nil)
  print("contents of include.loaded:")
  for k, v in pairs(include.loaded) do
    print(k, v)
  end
  
  print("\nSave any of the files (or change the x/y thing() value) to see dependent modules reload.")
  return 0
end
local status, ret = xpcall(main, debug.traceback, ...)
if not status then
  print("Error: " .. ret)
end
os.exit(status and ret or 1)
