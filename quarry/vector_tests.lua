local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local vector = include("vector")

-- Test construction, access/assignment of values.
local function test1()
  print("test1")
  local v1 = vector.new()
  assert(v1.n == 0)
  assert(v1.type == "vector")
  --print("v1 contents:")
  assert(not pcall(function() print(v1[0]) end))
  assert(not pcall(function() print(v1[1]) end))
  assert(not pcall(function() v1[0] = 1.2 end))
  
  local v2 = vector.new(1, 2, "banana")
  assert(v2.n == 3)
  assert(v2.type == "vector")
  --print("v2 contents:")
  assert(v2[1] == 1)
  assert(v2[2] == 2)
  assert(v2[3] == "banana")
  
  v2[1] = -99.999
  v2[2] = "apple"
  v2[3] = nil
  assert(not pcall(function() v2[-1] = 123 end))
  assert(not pcall(function() v2[4] = 456 end))
  
  --print("v2 contents:")
  assert(v2[1] == -99.999)
  assert(v2[2] == "apple")
  assert(v2[3] == 0)
  
  local v3 = vector(3.6, nil, -2.908, nil, nil, 5.008, nil)
  assert(v3.n == 7)
  --print("v3 contents:")
  assert(v3[1] == 3.6)
  assert(v3[2] == 0)
  assert(v3[3] == -2.908)
  assert(v3[4] == 0)
  assert(v3[5] == 0)
  assert(v3[6] == 5.008)
  assert(v3[7] == 0)
  assert(not pcall(function() print(v3[8]) end))
  assert(not pcall(function() print(v3[0]) end))
  
  local v4 = vector.new(-1, -2)
  assert(v4.n == 2)
  --print("v4 contents:")
  assert(v4[1] == -1)
  assert(v4[2] == -2)
  v4.thing = function(self, x) print("my next two vals are: ", self[x], self[x + 1]) end
  v4:thing(1)
  assert(not pcall(function() print(v4.idk) end))
  assert(not pcall(function() v4.notReal() end))
  assert(not pcall(function() v3:thing(1) end))
end

-- Test __call notation and construction with size and table.
local function test2()
  print("test2")
  local v1 = vector()
  assert(v1.n == 0)
  
  local v2 = vector(3, {})
  assert(v2.n == 3)
  assert(v2[1] == 0)
  assert(v2[2] == 0)
  assert(v2[3] == 0)
  assert(not pcall(function() print(v2[0]) end))
  assert(not pcall(function() print(v2[4]) end))
  
  local v3 = vector(2, {7.5, 11.9})
  assert(v3.n == 2)
  assert(v3[1] == 7.5)
  assert(v3[2] == 11.9)
  assert(not pcall(function() print(v3[0]) end))
  assert(not pcall(function() print(v3[3]) end))
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
  assert(not pcall(function() v = v1 + v2 end))
  assert(not pcall(function() v = v2 + v1 end))
  v = v1 + v1
  assert(v.n == 0)
  v = v2 + v3
  assert(v.n == 3)
  assert(v[1] == 5)
  assert(v[2] == 7)
  assert(v[3] == 9)
  assert(not pcall(function() v = v2 + v4 end))
  assert(not pcall(function() v = v4 + v3 end))
  assert(not pcall(function() v = v4 + v5 end))
  v = v2:add(v5)
  assert(v.n == 3)
  assert(v[1] == -4)
  assert(v[2] == 9)
  assert(v[3] == 3)
  assert(not pcall(function() v = 123 + v2 end))
  assert(not pcall(function() v = v2 + 123 end))
  
  -- Subtraction.
  assert(not pcall(function() v = v1 - v2 end))
  assert(not pcall(function() v = v2 - v1 end))
  v = v1 - v1
  assert(v.n == 0)
  v = v2 - v3
  assert(v.n == 3)
  assert(v[1] == -3)
  assert(v[2] == -3)
  assert(v[3] == -3)
  assert(not pcall(function() v = v2 - v4 end))
  assert(not pcall(function() v = v4 - v3 end))
  assert(not pcall(function() v = v4 - v5 end))
  v = v2:sub(v5)
  assert(v.n == 3)
  assert(v[1] == 6)
  assert(v[2] == -5)
  assert(v[3] == 3)
  assert(not pcall(function() v = 123 - v2 end))
  assert(not pcall(function() v = v2 - 123 end))
  
  -- Multiplication.
  assert(not pcall(function() v = v1 * v2 end))
  assert(not pcall(function() v = v2 * v1 end))
  v = v1 * v1
  assert(v.n == 0)
  v = v2 * v3
  assert(v.n == 3)
  assert(v[1] == 4)
  assert(v[2] == 10)
  assert(v[3] == 18)
  assert(not pcall(function() v = v2 * v4 end))
  assert(not pcall(function() v = v4 * v3 end))
  assert(not pcall(function() v = v4 * v5 end))
  v = v2:mul(v5)
  assert(v.n == 3)
  assert(v[1] == -5)
  assert(v[2] == 14)
  assert(v[3] == 0)
  v = 123 * v2
  assert(v.n == 3)
  assert(v[1] == 123)
  assert(v[2] == 246)
  assert(v[3] == 369)
  v = v2 * 321
  assert(v.n == 3)
  assert(v[1] == 321)
  assert(v[2] == 642)
  assert(v[3] == 963)
  
  -- Division.
  assert(not pcall(function() v = v1 / v2 end))
  assert(not pcall(function() v = v2 / v1 end))
  v = v1 / v1
  assert(v.n == 0)
  v = v2 / v3
  assert(v.n == 3)
  assert(v[1] == 1/4)
  assert(v[2] == 2/5)
  assert(v[3] == 3/6)
  assert(not pcall(function() v = v2 / v4 end))
  assert(not pcall(function() v = v4 / v3 end))
  assert(not pcall(function() v = v4 / v5 end))
  v = v2:div(v5)
  assert(v.n == 3)
  assert(v[1] == -1/5)
  assert(v[2] == 2/7)
  assert(v[3] == 3/0)
  v = 123 / v2
  assert(v.n == 3)
  assert(v[1] == 123)
  assert(v[2] == 123/2)
  assert(v[3] == 123/3)
  v = v2 / 321
  assert(v.n == 3)
  assert(v[1] == 1/321)
  assert(v[2] == 2/321)
  assert(v[3] == 3/321)
  
  -- Negation.
  v = -v1
  assert(v.n == 0)
  v = -v2
  assert(v.n == 3)
  assert(v[1] == -1)
  assert(v[2] == -2)
  assert(v[3] == -3)
  v = v5:negate()
  assert(v.n == 3)
  assert(v[1] == 5)
  assert(v[2] == -7)
  assert(v[3] == 0)
  
  -- Combined.
  v = v5 * 22 + (v3 / -v2)
  assert(v.n == 3)
  assert(v[1] == -114.0)
  assert(v[2] == 151.5)
  assert(v[3] == -2.0)
  v = -v2 / (v5 * 22 + v3)
  assert(v.n == 3)
  assert(v[1] == 1/106)
  assert(v[2] == -2/159)
  assert(v[3] == -3/6)
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
  assert(v.n == 3)
  print(v)
  print(v:tostring())
  print(v:tostring("%.3f"))
  
  assert(#v2 == math.sqrt(1 + 4 + 9))
  assert(v3:magnitude() == math.sqrt(16 + 25 + 36))
  
  assert((v1 == v2) == false)
  assert((v2 == v1) == false)
  assert((v1 == v1) == true)
  assert((v2 == v2) == true)
  assert((v2 == vector(1, 2, 3)) == true)
  assert((v2 == vector(1, 2)) == false)
  assert((v2 == vector(1, 2, 3, nil)) == false)
  assert((v5 == vector(-5, 7, 0)) == true)
  assert((vector(-5, 7, 0) == v5) == true)
  assert((v5 == vector(-5, 7.00001, 0)) == false)
  assert((v2 == 123) == false)
  assert((123 == v2) == false)
  assert((v2 == {}) == false)
  assert(({} == v2) == false)
  assert((v2 == {type = "vector", n = 3, [1] = 1, [2] = 2, [3] = 3}) == true)
end

-- Test modifiers.
local function test5()
  print("test5")
  local v1 = vector()
  local v2 = vector(1, 2, 3)
  local v3 = vector(4, 5, 6)
  local v4 = vector(-5, 7)
  local v5 = vector(-5, 7, nil)
  local v
  
  v = vector(v1)
  assert(v.n == 0)
  assert(v == v1)
  assert(v ~= v2)
  v = vector(v2)
  assert(v.n == 3)
  assert(v == v2)
  v[2] = 5
  assert(v ~= v2)
  
  assert(v == vector(1, 5, 3))
  assert(not pcall(function() v:insert(0, 9) end))
  assert(not pcall(function() v:insert(5, 9) end))
  assert(v.n == 3)
  v:insert(4, 9)
  assert(v == vector(1, 5, 3, 9))
  v:insert(1, -2)
  assert(v == vector(-2, 1, 5, 3, 9))
  
  -- FIXME need to test inserting multiple vals and sparse vectors with inserts #############################################################################
end

local function main()
  test1()
  test2()
  test3()
  test4()
  test5()
  print("all tests passing!")
end
local status, ret = pcall(main)
dlog.osBlockNewGlobals(false)
assert(status, ret)
