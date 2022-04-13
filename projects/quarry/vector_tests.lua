local include = require("include")
local dlog = include("dlog")
dlog.logErrorsToOutput = false
dlog.osBlockNewGlobals(true)
local dstructs = include("dstructs")
local vector = include("vector")

-- Compare two numeric values and determine if they are close enough to being equal.
local function approxEqual(a, b)
  return math.abs(a - b) < 0.000001
end

-- Check if a numeric value is not-a-number (by definition, the number is not equal to itself).
local function isNaN(a)
  return a ~= a
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
  local v6 = vector(2.67, -0.4, 3.34)
  local v7 = vector(9.76, 5.2, -4.8)
  local v
  
  -- Test tostring().
  v = -v2 / (v5 * 22 + v3)
  xassert(v.n == 3)
  print(v)
  print(v:tostring())
  print(v:tostring("%.3f"))
  print(vector(6.7, {}, function() return 2 end, nil, nil, "test", nil))
  
  -- Test magnitude().
  xassert(#v2 == math.sqrt(1 + 4 + 9))
  xassert(v3:magnitude() == math.sqrt(16 + 25 + 36))
  
  -- Test equals().
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
  
  -- Test dot product.
  xassert(not pcall(function() v2:dot(123) end))
  xassert(not pcall(function() v2:dot(v4) end))
  xassert(not pcall(function() v4:dot(v2) end))
  xassert(v2:dot(v3) == 32)
  xassert(v2:dot(v3) == v3:dot(v2))
  xassert(v2:dot(v5) == 9)
  xassert(approxEqual(v6:dot(v7), 7.9472))
  xassert(approxEqual(v7:dot(v6), 7.9472))
  
  -- Test cross product.
  xassert(not pcall(function() v2:cross(123) end))
  xassert(not pcall(function() v2:cross(v4) end))
  xassert(not pcall(function() v4:cross(v2) end))
  xassert(not pcall(function() v4:cross(v4) end))
  xassert(v2:cross(v3) == vector(-3, 6, -3))
  xassert(v3:cross(v2) == vector(3, -6, 3))
  v = v6:cross(v7)
  xassert(v.n == 3)
  xassert(approxEqual(v[1], -15.448))
  xassert(approxEqual(v[2], 45.4144))
  xassert(approxEqual(v[3], 17.788))
  
  -- Test normalize().
  xassert(v2:normalize() == vector(1/math.sqrt(14), 2/math.sqrt(14), 3/math.sqrt(14)))
  xassert(v4:normalize() == vector(-5/math.sqrt(74), 7/math.sqrt(74)))
  v = v6:normalize()
  xassert(v.n == 3)
  xassert(approxEqual(v[1], 0.6216956))
  xassert(approxEqual(v[2], -0.0931379))
  xassert(approxEqual(v[3], 0.7777017))
  xassert(vector(1, 0, 0):normalize() == vector(1, 0, 0))
  xassert(vector(0, -1, 0):normalize() == vector(0, -1, 0))
  v = vector(0, 0, 0):normalize()
  xassert(v.n == 3)
  xassert(isNaN(v[1]))
  xassert(isNaN(v[2]))
  xassert(isNaN(v[3]))
  
  -- Test angle().
  xassert(not pcall(function() v1:angle(123) end))
  xassert(not pcall(function() v1:angle(v2) end))
  xassert(not pcall(function() v2:angle(v1) end))
  xassert(not pcall(function() v2:angle(v4) end))
  xassert(v2:angle(v2) == 0)
  xassert(v2:angle(v3) == math.acos(32 / math.sqrt(14) / math.sqrt(77)))
  xassert(v2:angle(v3) == v3:angle(v2))
  xassert(approxEqual(v6:angle(v7), 1.4166930))
  
  -- Test round().
  xassert(v1:round() == v1)
  xassert(v2:round() == v2)
  xassert(v4:round() == v4)
  xassert(v5:round() == v5)
  xassert(v6:round() == vector(3, 0, 3))
  xassert(v7:round() == vector(10, 5, -5))
  xassert(v5:round(1) == v5)
  xassert(v6:round(1) == vector(2, -1, 3))
  xassert(v7:round(1) == vector(9, 5, -5))
  xassert(v5:round(0.000001) == v5)
  xassert(v6:round(0.000001) == vector(3, 0, 4))
  xassert(v7:round(0.000001) == vector(10, 6, -4))
end

-- Test table.move custom implementation (if used).
local function test5()
  print("test5")
  -- Test with plain tables.
  local t1 = {}
  local t2 = {[1] = 1.1, [2] = 2.2, [3] = 3.3}
  local t3 = {[2] = -7.6, [3] = 8, [6] = 9.9}
  
  table.move(t2, 3, 1, 1, t1)
  xassert(dstructs.rawObjectsEqual(t1, {}))
  xassert(dstructs.rawObjectsEqual(t2, {[1] = 1.1, [2] = 2.2, [3] = 3.3}))
  table.move(t3, 3, 3, 0, t1)
  xassert(dstructs.rawObjectsEqual(t1, {[0] = 8}))
  xassert(dstructs.rawObjectsEqual(t3, {[2] = -7.6, [3] = 8, [6] = 9.9}))
  table.move(t2, 1, 3, 1, t1)
  xassert(dstructs.rawObjectsEqual(t1, {[0] = 8, [1] = 1.1, [2] = 2.2, [3] = 3.3}))
  xassert(dstructs.rawObjectsEqual(t2, {[1] = 1.1, [2] = 2.2, [3] = 3.3}))
  table.move(t3, 1, 6, 3, t2)
  xassert(dstructs.rawObjectsEqual(t2, {[1] = 1.1, [2] = 2.2, [4] = -7.6, [5] = 8, [8] = 9.9}))
  xassert(dstructs.rawObjectsEqual(t3, {[2] = -7.6, [3] = 8, [6] = 9.9}))
  table.move(t1, 2, 4, -1, t2)
  xassert(dstructs.rawObjectsEqual(t1, {[0] = 8, [1] = 1.1, [2] = 2.2, [3] = 3.3}))
  xassert(dstructs.rawObjectsEqual(t2, {[-1] = 2.2, [0] = 3.3, [2] = 2.2, [4] = -7.6, [5] = 8, [8] = 9.9}))
  table.move(t2, -1, 4, 0)
  xassert(dstructs.rawObjectsEqual(t2, {[-1] = 2.2, [0] = 2.2, [1] = 3.3, [3] = 2.2, [5] = -7.6, [8] = 9.9}))
  table.move(t2, 3, 9, 2)
  xassert(dstructs.rawObjectsEqual(t2, {[-1] = 2.2, [0] = 2.2, [1] = 3.3, [2] = 2.2, [4] = -7.6, [7] = 9.9}))
  
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
  
  xassert(dstructs.rawObjectsEqual(v1, {n = 11}))
  xassert(dstructs.rawObjectsEqual(v2, {n = 12, [1] = 1, [2] = 2, [3] = 3}))
  table.move(v2, 1, 3, 1, v1)
  xassert(dstructs.rawObjectsEqual(v1, {n = 11, [1] = 1, [2] = 2, [3] = 3}))
  xassert(dstructs.rawObjectsEqual(v2, {n = 12, [1] = 1, [2] = 2, [3] = 3}))
  table.move(v3, 7, 4, -2, v2)
  xassert(dstructs.rawObjectsEqual(v2, {n = 12, [1] = 1, [2] = 2, [3] = 3}))
  xassert(dstructs.rawObjectsEqual(v3, {n = 13, [1] = 4, [2] = 5, [5] = 6, [6] = 7}))
  table.move(v3, 4, 7, 1, v2)
  xassert(dstructs.rawObjectsEqual(v2, {n = 12, [1] = 0, [2] = 6, [3] = 7, [4] = 0}))
  xassert(dstructs.rawObjectsEqual(v3, {n = 13, [1] = 4, [2] = 5, [5] = 6, [6] = 7}))
  table.move(v3, 1, 7, 2)
  xassert(dstructs.rawObjectsEqual(v3, {n = 13, [1] = 4, [2] = 4, [3] = 5, [4] = 0, [5] = 0, [6] = 6, [7] = 7, [8] = 0}))
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
  
  -- Test copy constructor.
  v = vector(v1)
  xassert(v.n == 0)
  xassert(v == v1)
  xassert(v ~= v2)
  v = vector(v2)
  xassert(v.n == 3)
  xassert(v == v2)
  v[2] = 5
  xassert(v ~= v2)
  
  -- Test insert, erase, and append.
  xassert(v == vector(1, 5, 3))
  xassert(not pcall(function() v:insert(0, 9) end))
  xassert(not pcall(function() v:insert(5, 9) end))
  xassert(v.n == 3)
  v:insert(4, 9)
  xassert(dstructs.rawObjectsEqual(v, {n = 4, [1] = 1, [2] = 5, [3] = 3, [4] = 9}))
  v:insert(1, -2)
  xassert(dstructs.rawObjectsEqual(v, {n = 5, [1] = -2, [2] = 1, [3] = 5, [4] = 3, [5] = 9}))
  v:insert(3, 5.78)
  xassert(dstructs.rawObjectsEqual(v, {n = 6, [1] = -2, [2] = 1, [3] = 5.78, [4] = 5, [5] = 3, [6] = 9}))
  xassert(not pcall(function() v:erase(0) end))
  xassert(not pcall(function() v:erase(7) end))
  v:erase(6)
  xassert(dstructs.rawObjectsEqual(v, {n = 5, [1] = -2, [2] = 1, [3] = 5.78, [4] = 5, [5] = 3}))
  v:erase(1)
  xassert(dstructs.rawObjectsEqual(v, {n = 4, [1] = 1, [2] = 5.78, [3] = 5, [4] = 3}))
  v:erase(3)
  xassert(dstructs.rawObjectsEqual(v, {n = 3, [1] = 1, [2] = 5.78, [3] = 3}))
  v:insert(3, nil, 2)
  v:insert(1, nil)
  xassert(dstructs.rawObjectsEqual(v, {n = 6, [2] = 1, [3] = 5.78, [6] = 3}))
  v:insert(7, nil, 3)
  xassert(dstructs.rawObjectsEqual(v, {n = 9, [2] = 1, [3] = 5.78, [6] = 3}))
  xassert(not pcall(function() v:insert(1, -2.3, 2.1) end))
  v:insert(1, -2.3, 2)
  xassert(dstructs.rawObjectsEqual(v, {n = 11, [1] = -2.3, [2] = -2.3, [4] = 1, [5] = 5.78, [8] = 3}))
  v:insert(5, 1.05, 3)
  xassert(dstructs.rawObjectsEqual(v, {n = 14, [1] = -2.3, [2] = -2.3, [4] = 1, [5] = 1.05, [6] = 1.05, [7] = 1.05, [8] = 5.78, [11] = 3}))
  xassert(not pcall(function() v:erase(4, 9.2) end))
  v:erase(4, 9)
  xassert(dstructs.rawObjectsEqual(v, {n = 8, [1] = -2.3, [2] = -2.3, [5] = 3}))
  v:erase(1, 1)
  xassert(dstructs.rawObjectsEqual(v, {n = 7, [1] = -2.3, [4] = 3}))
  v:append(6.78)
  xassert(dstructs.rawObjectsEqual(v, {n = 8, [1] = -2.3, [4] = 3, [8] = 6.78}))
  v:append(2.5)
  xassert(dstructs.rawObjectsEqual(v, {n = 9, [1] = -2.3, [4] = 3, [8] = 6.78, [9] = 2.5}))
  v:append(7.9)
  xassert(dstructs.rawObjectsEqual(v, {n = 10, [1] = -2.3, [4] = 3, [8] = 6.78, [9] = 2.5, [10] = 7.9}))
  v:erase(10, 9)
  xassert(dstructs.rawObjectsEqual(v, {n = 10, [1] = -2.3, [4] = 3, [8] = 6.78, [9] = 2.5, [10] = 7.9}))
  v:erase(9, 10)
  xassert(dstructs.rawObjectsEqual(v, {n = 8, [1] = -2.3, [4] = 3, [8] = 6.78}))
  v:append(nil)
  v:append(1.23)
  xassert(dstructs.rawObjectsEqual(v, {n = 10, [1] = -2.3, [4] = 3, [8] = 6.78, [10] = 1.23}))
  v:erase(1, 10)
  xassert(dstructs.rawObjectsEqual(v, {n = 0}))
  
  -- Test concatenate and resize.
  v = v2:concatenate(v3)
  xassert(dstructs.rawObjectsEqual(v, {n = 6, [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6}))
  v = v3 .. v2
  xassert(dstructs.rawObjectsEqual(v, {n = 6, [1] = 4, [2] = 5, [3] = 6, [4] = 1, [5] = 2, [6] = 3}))
  v = v1 .. v5 .. v3 .. v4 .. v1
  xassert(dstructs.rawObjectsEqual(v, {n = 8, [1] = -5, [2] = 7, [4] = 4, [5] = 5, [6] = 6, [7] = -5, [8] = 7}))
  xassert(not pcall(function() print(v2 .. 123) end))
  xassert(not pcall(function() print(123 .. v2) end))
  v = v5 .. v3
  xassert(not pcall(function() v:resize(3.01) end))
  v:resize(4)
  xassert(dstructs.rawObjectsEqual(v, {n = 4, [1] = -5, [2] = 7, [4] = 4}))
  v:resize(4)
  xassert(dstructs.rawObjectsEqual(v, {n = 4, [1] = -5, [2] = 7, [4] = 4}))
  v:resize(3)
  xassert(dstructs.rawObjectsEqual(v, {n = 3, [1] = -5, [2] = 7}))
  v:resize(2)
  xassert(dstructs.rawObjectsEqual(v, {n = 2, [1] = -5, [2] = 7}))
  v:resize(11)
  xassert(dstructs.rawObjectsEqual(v, {n = 11, [1] = -5, [2] = 7}))
  v:resize(0)
  xassert(dstructs.rawObjectsEqual(v, {n = 0}))
  v:resize(100)
  xassert(dstructs.rawObjectsEqual(v, {n = 100}))
  
  -- FIXME refactor dlog.errorWithTraceback -> verboseError and add a config option to enable/disable the stack trace.
end

-- Test iteration.
local function test7()
  print("test7")
  local t1 = {}
  local v1 = vector()
  local v2 = vector(1, 2, 3.6, "stuff", t1)
  local v3 = vector(nil, -5, 7, nil, nil, 0.032)
  local checklist, counter
  
  checklist = {}
  counter = 1
  for k, v in pairs(v1) do
    xassert(k ~= nil)
    xassert(checklist[k] == v)
    checklist[k] = nil
    counter = counter + 1
  end
  xassert(next(checklist) == nil)
  xassert(counter == 0 + 1)
  
  checklist = {1, 2, 3.6, "stuff", t1}
  counter = 1
  for k, v in pairs(v2) do
    xassert(k ~= nil)
    xassert(checklist[k] == v)
    checklist[k] = nil
    counter = counter + 1
  end
  xassert(next(checklist) == nil)
  xassert(counter == 5 + 1)
  
  checklist = {[2] = -5, [3] = 7, [6] = 0.032}
  counter = 1
  for k, v in pairs(v3) do
    xassert(k ~= nil)
    xassert(checklist[k] == v)
    checklist[k] = nil
    counter = counter + 1
  end
  xassert(next(checklist) == nil)
  xassert(counter == 3 + 1)
end

local function main()
  test1()
  test2()
  test3()
  test4()
  test5()
  test6()
  test7()
  print("all tests passing!")
end
local status, ret = pcall(main)
dlog.osBlockNewGlobals(false)
if not status then
  error(ret)
end
