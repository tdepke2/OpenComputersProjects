
local function approxEqual(a, b)
  return math.abs(a - b) < 0.000001
end
local function isNaN(a)
  return a ~= a
end

local tests = {}

-- Test construction, access/assignment of values.
tests[1] = function()
  local m1 = matrix.new()
  xassert(m1.r == 0)
  xassert(m1.c == 0)
  xassert(m1.type == "matrix")
  xassert(not pcall(function() print(m1.badkey) end))
  xassert(rawObjectsEqual(m1, {r = 0, c = 0}))
  xassert(rawObjectsEqual(m1[0], {}))
  xassert(rawObjectsEqual(m1[1], {}))
  xassert(m1[1][1] == 0)
  xassert(rawObjectsEqual(m1, {[0] = {}, [1] = {}, r = 0, c = 0}))
  xassert(m1[0][-6] == 0)
  m1[1][1] = 8.9
  m1[2][3] = "my string"
  m1[5][2] = {}
  m1[-1][8] = 3
  xassert(m1[1][1] == 8.9)
  xassert(rawObjectsEqual(m1, {[-1] = {[8] = 3}, [0] = {}, [1] = {[1] = 8.9}, [2] = {[3] = "my string"}, [5] = {[2] = {}}, r = 0, c = 0}))
  
  xassert(not pcall(function() matrix.new({}) end))
  xassert(not pcall(function() matrix.new({[1.3] = {2}}) end))
  
  local m2 = matrix.new({{1, 2, 3}, {4, 5, 6.7}})
  xassert(m2.r == 2)
  xassert(m2.c == 3)
  xassert(m2.type == "matrix")
  xassert(rawObjectsEqual(m2, {{1, 2, 3}, {4, 5, 6.7}, r = 2, c = 3}))
  
  xassert(not pcall(function() matrix.new("apple") end))
  xassert(not pcall(function() matrix.new(1.2) end))
  xassert(not pcall(function() matrix.new(3, -9) end))
  xassert(rawObjectsEqual(matrix.new(0, 0), {r = 0, c = 0}))
  xassert(rawObjectsEqual(matrix.new(3, 1), {r = 3, c = 1}))
  
  xassert(rawObjectsEqual(matrix.new(3, 1, "x"), {{"x"}, {"x"}, {"x"}, r = 3, c = 1}))
  xassert(rawObjectsEqual(matrix.new(1, 3, 9.2), {{9.2, 9.2, 9.2}, r = 1, c = 3}))
  xassert(rawObjectsEqual(matrix.new(3, 2, {}), {r = 3, c = 2}))
  xassert(not pcall(function() matrix.new(3, 2, {4}) end))
  xassert(not pcall(function() matrix.new(3, 2, {[8] = "my val"}) end))
  xassert(rawObjectsEqual(matrix.new(3, 1, {"a", "b", "c", "d", "e"}), {{"a"}, {"b"}, {"c"}, r = 3, c = 1}))
  xassert(rawObjectsEqual(matrix.new(1, 3, {"a", "b", "c", "d", "e"}), {{"a", "b", "c"}, r = 1, c = 3}))
  xassert(rawObjectsEqual(matrix.new(1, 1, {"a", "b", "c", "d", "e"}), {{"a"}, r = 1, c = 1}))
  xassert(not pcall(function() matrix.new(3, 0, {"a", "b", "c", "d", "e"}) end))
  xassert(not pcall(function() matrix.new(0, 3, {"a", "b", "c", "d", "e"}) end))
  
  xassert(rawObjectsEqual(matrix.new(3, 2, {{5.7}}), {{5.7}, r = 3, c = 2}))
  
  xassert(not pcall(function() matrix.identity(3.006) end))
  xassert(not pcall(function() matrix.identity(-1) end))
  xassert(rawObjectsEqual(matrix.identity(0), {r = 0, c = 0}))
  xassert(rawObjectsEqual(matrix.identity(1), {{1}, r = 1, c = 1}))
  xassert(rawObjectsEqual(matrix.identity(2), {{1, 0}, {0, 1}, r = 2, c = 2}))
  xassert(rawObjectsEqual(matrix.identity(3), {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, r = 3, c = 3}))
end

-- Test basic arithmetic.
tests[2] = function()
  local m1 = matrix.new({{-4, 2, 7.2}, {0, 3.1, 6.8}})
  local m2 = matrix.new({{11, -5, -1}, {5, 1.23, 0}})
  local m3 = matrix.new({{1, 2}, {3, 4}})
  local m4 = matrix.new({{5, 6}, {7, -8}})
  local m
  
  xassert(not pcall(function() m = m1 + m3 end))
  xassert(not pcall(function() m = m3 + m1 end))
  xassert(not pcall(function() m = m1:add(m3) end))
  xassert(rawObjectsEqual(m1 + m2, {{7, -3, 6.2}, {5, 4.33, 6.8}, r = 2, c = 3}))
  xassert(rawObjectsEqual(m1:add(m2), {{7, -3, 6.2}, {5, 4.33, 6.8}, r = 2, c = 3}))
  xassert(not pcall(function() m = m3 - m1 end))
  xassert(not pcall(function() m = m1:sub(m3) end))
  xassert(rawObjectsEqual(m1 - m2, {{-15, 7, 8.2}, {-5, 1.87, 6.8}, r = 2, c = 3}))
  xassert(rawObjectsEqual(m2:sub(m1), {{15, -7, -8.2}, {5, -1.87, -6.8}, r = 2, c = 3}))
end

local function main()
  for k, v in ipairs(tests) do
    print("test" .. k)
    v()
  end
  print("all tests passing!")
end
local status, ret = xpcall(main, debug.traceback)
if not status then
  print(ret)
end
