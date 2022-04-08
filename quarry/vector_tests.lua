local include = require("include")
local dlog = include("dlog")
dlog.logErrorsToOutput = false
dlog.osBlockNewGlobals(true)
local vector = include("vector")

-- FIXME might want to put this in dstructs.lua instead ##################################################################################################################

-- Modified version of dstructs.objectsEqual() to use rawget() compares and
-- avoid __pairs calls. See "dstructs.lua" for original implementation.
local function rawObjectsEqual(obj1, obj2)
  if type(obj1) ~= type(obj2) then
    return false
  elseif type(obj1) ~= "table" then
    return obj1 == obj2
  end
  
  -- Confirm all items in obj1 are in obj2 (and they are equal).
  local n1 = 0
  for k1, v1 in next, obj1 do
    local v2 = rawget(obj2, k1)
    if v2 == nil or not rawObjectsEqual(v1, v2) then
      return false
    end
    n1 = n1 + 1
  end
  
  -- Count items in obj2, and confirm this matches the length of obj1.
  local n2 = 0
  for k2, _ in next, obj2 do
    n2 = n2 + 1
  end
  
  return n1 == n2
end

-- Test construction, access/assignment of values.
local function test1()
  print("test1")
  local v1 = vector.new()
  xassert(v1.n == 0)
  xassert(v1.type == "vector")
  --print("v1 contents:")
  xassert(not pcall(function() print(v1[0]) end))
  xassert(not pcall(function() print(v1[1]) end))
  xassert(not pcall(function() v1[0] = 1.2 end))
  
  local v2 = vector.new(1, 2, "banana")
  xassert(v2.n == 3)
  xassert(v2.type == "vector")
  --print("v2 contents:")
  xassert(v2[1] == 1)
  xassert(v2[2] == 2)
  xassert(v2[3] == "banana")
  
  v2[1] = -99.999
  v2[2] = "apple"
  v2[3] = nil
  xassert(not pcall(function() v2[-1] = 123 end))
  xassert(not pcall(function() v2[4] = 456 end))
  
  --print("v2 contents:")
  xassert(v2[1] == -99.999)
  xassert(v2[2] == "apple")
  xassert(v2[3] == 0)
  
  local v3 = vector(3.6, nil, -2.908, nil, nil, 5.008, nil)
  xassert(v3.n == 7)
  --print("v3 contents:")
  xassert(v3[1] == 3.6)
  xassert(v3[2] == 0)
  xassert(v3[3] == -2.908)
  xassert(v3[4] == 0)
  xassert(v3[5] == 0)
  xassert(v3[6] == 5.008)
  xassert(v3[7] == 0)
  xassert(not pcall(function() print(v3[8]) end))
  xassert(not pcall(function() print(v3[0]) end))
  
  local v4 = vector.new(-1, -2)
  xassert(v4.n == 2)
  --print("v4 contents:")
  xassert(v4[1] == -1)
  xassert(v4[2] == -2)
  v4.thing = function(self, x) print("my next two vals are: ", self[x], self[x + 1]) end
  v4:thing(1)
  xassert(not pcall(function() print(v4.idk) end))
  xassert(not pcall(function() v4.notReal() end))
  xassert(not pcall(function() v3:thing(1) end))
end

-- Test __call notation and construction with size and table.
local function test2()
  print("test2")
  local v1 = vector()
  xassert(v1.n == 0)
  
  local v2 = vector(3, {})
  xassert(v2.n == 3)
  xassert(v2[1] == 0)
  xassert(v2[2] == 0)
  xassert(v2[3] == 0)
  xassert(not pcall(function() print(v2[0]) end))
  xassert(not pcall(function() print(v2[4]) end))
  
  local v3 = vector(2, {7.5, 11.9})
  xassert(v3.n == 2)
  xassert(v3[1] == 7.5)
  xassert(v3[2] == 11.9)
  xassert(not pcall(function() print(v3[0]) end))
  xassert(not pcall(function() print(v3[3]) end))
end

-- Test basic arithmetic.
local function test3()
  print("test3")
  local v1 = vector()
  local v2 = vector(1, 2, 3)
  local v3 = vector(4, 5, 6)
  local v4 = vector(-5, 7)
  local v5 = vector(-5, 7, nil)
  local v
  
  -- Addition.
  xassert(not pcall(function() v = v1 + v2 end))
  xassert(not pcall(function() v = v2 + v1 end))
  v = v1 + v1
  xassert(v.n == 0)
  v = v2 + v3
  xassert(v.n == 3)
  xassert(v[1] == 5)
  xassert(v[2] == 7)
  xassert(v[3] == 9)
  xassert(not pcall(function() v = v2 + v4 end))
  xassert(not pcall(function() v = v4 + v3 end))
  xassert(not pcall(function() v = v4 + v5 end))
  v = v2:add(v5)
  xassert(v.n == 3)
  xassert(v[1] == -4)
  xassert(v[2] == 9)
  xassert(v[3] == 3)
  xassert(not pcall(function() v = 123 + v2 end))
  xassert(not pcall(function() v = v2 + 123 end))
  
  -- Subtraction.
  xassert(not pcall(function() v = v1 - v2 end))
  xassert(not pcall(function() v = v2 - v1 end))
  v = v1 - v1
  xassert(v.n == 0)
  v = v2 - v3
  xassert(v.n == 3)
  xassert(v[1] == -3)
  xassert(v[2] == -3)
  xassert(v[3] == -3)
  xassert(not pcall(function() v = v2 - v4 end))
  xassert(not pcall(function() v = v4 - v3 end))
  xassert(not pcall(function() v = v4 - v5 end))
  v = v2:sub(v5)
  xassert(v.n == 3)
  xassert(v[1] == 6)
  xassert(v[2] == -5)
  xassert(v[3] == 3)
  xassert(not pcall(function() v = 123 - v2 end))
  xassert(not pcall(function() v = v2 - 123 end))
  
  -- Multiplication.
  xassert(not pcall(function() v = v1 * v2 end))
  xassert(not pcall(function() v = v2 * v1 end))
  v = v1 * v1
  xassert(v.n == 0)
  v = v2 * v3
  xassert(v.n == 3)
  xassert(v[1] == 4)
  xassert(v[2] == 10)
  xassert(v[3] == 18)
  xassert(not pcall(function() v = v2 * v4 end))
  xassert(not pcall(function() v = v4 * v3 end))
  xassert(not pcall(function() v = v4 * v5 end))
  v = v2:mul(v5)
  xassert(v.n == 3)
  xassert(v[1] == -5)
  xassert(v[2] == 14)
  xassert(v[3] == 0)
  v = 123 * v2
  xassert(v.n == 3)
  xassert(v[1] == 123)
  xassert(v[2] == 246)
  xassert(v[3] == 369)
  v = v2 * 321
  xassert(v.n == 3)
  xassert(v[1] == 321)
  xassert(v[2] == 642)
  xassert(v[3] == 963)
  
  -- Division.
  xassert(not pcall(function() v = v1 / v2 end))
  xassert(not pcall(function() v = v2 / v1 end))
  v = v1 / v1
  xassert(v.n == 0)
  v = v2 / v3
  xassert(v.n == 3)
  xassert(v[1] == 1/4)
  xassert(v[2] == 2/5)
  xassert(v[3] == 3/6)
  xassert(not pcall(function() v = v2 / v4 end))
  xassert(not pcall(function() v = v4 / v3 end))
  xassert(not pcall(function() v = v4 / v5 end))
  v = v2:div(v5)
  xassert(v.n == 3)
  xassert(v[1] == -1/5)
  xassert(v[2] == 2/7)
  xassert(v[3] == 3/0)
  v = 123 / v2
  xassert(v.n == 3)
  xassert(v[1] == 123)
  xassert(v[2] == 123/2)
  xassert(v[3] == 123/3)
  v = v2 / 321
  xassert(v.n == 3)
  xassert(v[1] == 1/321)
  xassert(v[2] == 2/321)
  xassert(v[3] == 3/321)
  
  -- Negation.
  v = -v1
  xassert(v.n == 0)
  v = -v2
  xassert(v.n == 3)
  xassert(v[1] == -1)
  xassert(v[2] == -2)
  xassert(v[3] == -3)
  v = v5:negate()
  xassert(v.n == 3)
  xassert(v[1] == 5)
  xassert(v[2] == -7)
  xassert(v[3] == 0)
  
  -- Combined.
  v = v5 * 22 + (v3 / -v2)
  xassert(v.n == 3)
  xassert(v[1] == -114.0)
  xassert(v[2] == 151.5)
  xassert(v[3] == -2.0)
  v = -v2 / (v5 * 22 + v3)
  xassert(v.n == 3)
  xassert(v[1] == 1/106)
  xassert(v[2] == -2/159)
  xassert(v[3] == -3/6)
end

-- Test vector calculation functions.
local function test4()
  print("test4")
  local v1 = vector()
  local v2 = vector(1, 2, 3)
  local v3 = vector(4, 5, 6)
  local v4 = vector(-5, 7)
  local v5 = vector(-5, 7, nil)
  local v
  
  v = -v2 / (v5 * 22 + v3)
  xassert(v.n == 3)
  print(v)
  print(v:tostring())
  print(v:tostring("%.3f"))
  
  xassert(#v2 == math.sqrt(1 + 4 + 9))
  xassert(v3:magnitude() == math.sqrt(16 + 25 + 36))
  
  xassert((v1 == v2) == false)
  xassert((v2 == v1) == false)
  xassert((v1 == v1) == true)
  xassert((v2 == v2) == true)
  xassert((v2 == vector(1, 2, 3)) == true)
  xassert((v2 == vector(1, 2)) == false)
  xassert((v2 == vector(1, 2, 3, nil)) == false)
  xassert((v4 == v5) == false)
  xassert((v5 == v4) == false)
  xassert((v5 == vector(-5, 7, 0)) == true)
  xassert((vector(-5, 7, 0) == v5) == true)
  xassert((v5 == vector(-5, 7.00001, 0)) == false)
  xassert((v2 == 123) == false)
  xassert((123 == v2) == false)
  xassert((v2 == {}) == false)
  xassert(({} == v2) == false)
  xassert((v2 == {type = "vector", n = 3, [1] = 1, [2] = 2, [3] = 3}) == true)
end

-- Test table.move custom implementation (if used).
local function test5()
  print("test5")
  -- Test with plain tables.
  local t1 = {}
  local t2 = {[1] = 1.1, [2] = 2.2, [3] = 3.3}
  local t3 = {[2] = -7.6, [3] = 8, [6] = 9.9}
  
  table.move(t2, 3, 1, 1, t1)
  xassert(rawObjectsEqual(t1, {}))
  xassert(rawObjectsEqual(t2, {[1] = 1.1, [2] = 2.2, [3] = 3.3}))
  table.move(t3, 3, 3, 0, t1)
  xassert(rawObjectsEqual(t1, {[0] = 8}))
  xassert(rawObjectsEqual(t3, {[2] = -7.6, [3] = 8, [6] = 9.9}))
  table.move(t2, 1, 3, 1, t1)
  xassert(rawObjectsEqual(t1, {[0] = 8, [1] = 1.1, [2] = 2.2, [3] = 3.3}))
  xassert(rawObjectsEqual(t2, {[1] = 1.1, [2] = 2.2, [3] = 3.3}))
  table.move(t3, 1, 6, 3, t2)
  xassert(rawObjectsEqual(t2, {[1] = 1.1, [2] = 2.2, [4] = -7.6, [5] = 8, [8] = 9.9}))
  xassert(rawObjectsEqual(t3, {[2] = -7.6, [3] = 8, [6] = 9.9}))
  table.move(t1, 2, 4, -1, t2)
  xassert(rawObjectsEqual(t1, {[0] = 8, [1] = 1.1, [2] = 2.2, [3] = 3.3}))
  xassert(rawObjectsEqual(t2, {[-1] = 2.2, [0] = 3.3, [2] = 2.2, [4] = -7.6, [5] = 8, [8] = 9.9}))
  table.move(t2, -1, 4, 0)
  xassert(rawObjectsEqual(t2, {[-1] = 2.2, [0] = 2.2, [1] = 3.3, [3] = 2.2, [5] = -7.6, [8] = 9.9}))
  table.move(t2, 3, 9, 2)
  xassert(rawObjectsEqual(t2, {[-1] = 2.2, [0] = 2.2, [1] = 3.3, [2] = 2.2, [4] = -7.6, [7] = 9.9}))
  
  -- Test with internal vector tables.
  local v1 = vector()
  local v2 = vector(1, 2, 3)
  local v3 = vector(4, 5, nil, nil, 6, 7, nil)
  local v4 = vector(nil, nil, -5, nil, 7, nil)
  
  -- Illegally change vector sizes to suppress range checks.
  v1.n = 11
  v2.n = 12
  v3.n = 13
  v4.n = 14
  
  xassert(rawObjectsEqual(v1, {n = 11}))
  xassert(rawObjectsEqual(v2, {n = 12, [1] = 1, [2] = 2, [3] = 3}))
  table.move(v2, 1, 3, 1, v1)
  xassert(rawObjectsEqual(v1, {n = 11, [1] = 1, [2] = 2, [3] = 3}))
  xassert(rawObjectsEqual(v2, {n = 12, [1] = 1, [2] = 2, [3] = 3}))
  table.move(v3, 7, 4, -2, v2)
  xassert(rawObjectsEqual(v2, {n = 12, [1] = 1, [2] = 2, [3] = 3}))
  xassert(rawObjectsEqual(v3, {n = 13, [1] = 4, [2] = 5, [5] = 6, [6] = 7}))
  table.move(v3, 4, 7, 1, v2)
  xassert(rawObjectsEqual(v2, {n = 12, [1] = 0, [2] = 6, [3] = 7, [4] = 0}))
  xassert(rawObjectsEqual(v3, {n = 13, [1] = 4, [2] = 5, [5] = 6, [6] = 7}))
  table.move(v3, 1, 7, 2)
  xassert(rawObjectsEqual(v3, {n = 13, [1] = 4, [2] = 4, [3] = 5, [4] = 0, [5] = 0, [6] = 6, [7] = 7, [8] = 0}))
end

-- Test modifiers.
local function test6()
  print("test6")
  local v1 = vector()
  local v2 = vector(1, 2, 3)
  local v3 = vector(4, 5, 6)
  local v4 = vector(-5, 7)
  local v5 = vector(-5, 7, nil)
  local v
  
  v = vector(v1)
  xassert(v.n == 0)
  xassert(v == v1)
  xassert(v ~= v2)
  v = vector(v2)
  xassert(v.n == 3)
  xassert(v == v2)
  v[2] = 5
  xassert(v ~= v2)
  
  xassert(v == vector(1, 5, 3))
  xassert(not pcall(function() v:insert(0, 9) end))
  xassert(not pcall(function() v:insert(5, 9) end))
  xassert(v.n == 3)
  v:insert(4, 9)
  xassert(v == vector(1, 5, 3, 9))
  v:insert(1, -2)
  xassert(v == vector(-2, 1, 5, 3, 9))
  
  -- FIXME need to test inserting multiple vals and sparse vectors with inserts #############################################################################
  
  -- FIXME do we need to add __pairs or __ipairs functionality?? #########################
  
  -- FIXME refactor dlog.errorWithTraceback -> verboseError and add a config option to enable/disable the stack trace.
end

local function main()
  test1()
  test2()
  test3()
  test4()
  test5()
  test6()
  print("all tests passing!")
end
local status, ret = pcall(main)
dlog.osBlockNewGlobals(false)
if not status then
  error(ret)
end
