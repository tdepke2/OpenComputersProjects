local include = require("include")
local bitset = include("bitset")

local b1 = bitset:new(1)
assert(b1:test(0) == false)
assert(b1:count() == 0)
b1:set(0)
assert(b1:test(0) == false)
assert(b1:count() == 0)
b1:set(0, true)
assert(b1:test(0) == true)
assert(b1:count() == 1)
b1:set(0, false)
assert(b1:test(0) == false)
assert(b1:count() == 0)
b1:clear(true)
assert(b1:test(0) == true)
assert(b1:count() == 1)
b1:clear(false)
assert(b1:test(0) == false)
assert(b1:count() == 0)

local function testN(size)
  local arr = {}
  for i = 0, size - 1 do
    arr[i] = false
  end
  local b = bitset:new(size)
  
  -- Fill b and arr with random bits.
  for _ = 1, size do
    local index = math.random(0, size - 1)
    local value = math.random() < 0.1
    b:set(index, value)
    arr[index] = value
  end
  
  -- Test each bit, build string, count bits, etc.
  local arrBitCount = 0
  local arrString = ""
  local arrSetBits = {}
  for i = 0, size - 1 do
    assert(b:test(i) == arr[i])
    arrString = (arr[i] and "1" or "0") .. arrString
    arrBitCount = arrBitCount + (arr[i] and 1 or 0)
    if arr[i] then
      arrSetBits[#arrSetBits + 1] = i
    end
  end
  assert(arrBitCount == b:count())
  --print(b)
  assert(arrString == b:tostring())
  
  -- Confirm iteration order.
  local i = 1
  for j in b:iterateSetBits() do
    assert(arrSetBits[i] == j)
    i = i + 1
  end
  assert(arrSetBits[i] == nil)
  
  -- Clear b and confirm bits and count.
  b:clear(true)
  for i = 0, size - 1 do
    assert(b:test(i) == true)
  end
  assert(b:count() == size)
  
  -- Confirm iteration order again (for cleared bitset).
  local i = 0
  for j in b:iterateSetBits() do
    assert(i == j)
    i = i + 1
  end
  assert(i == size)
  
  --print(b)
end

local t1 = os.clock()
for i = 1, 140 do
  testN(i)
end
local t2 = os.clock()

print("tests passed")
print("elapsed:", t2 - t1)
