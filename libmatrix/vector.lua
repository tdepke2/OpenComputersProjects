--[[
Mathematical and generic vector library.

These vectors can be used to store numeric values in N dimensions, or just to
store N generic objects. At creation, the vector has a fixed size with bounds
checking but the size can be changed with append() and resize() operations. Most
functions are enabled through metamethods to add behavior with standard lua
operators, see the function definitions below.

Support for sparse vectors is also included (the vector can contain nil values
which get read as zeros) as this can be more memory efficient. Modifier
operations like insert(), erase(), append(), concatenate(), and resize() will
preserve nil values in the vector instead of filling with zeros. On the other
hand, mathematical operations will still result with a dense vector for
performance reasons. If this is not desired, a custom math function shouldn't be
too much of a challenge to create that preserves the sparse values.

Note: do not use ipairs() to iterate a vector. Instead use "for i = 1, vec.n do"
to step incrementally, or use pairs() when order doesn't matter and you need to
skip nil values.

Inspired by the following implementations:
https://hel.fomalhaut.me/#packages/libvector
https://en.cppreference.com/w/cpp/container/vector/vector
https://github.com/g-truc/glm

Example usage:
local vector = require("vector")

local v1 = vector(9, 10, 21)
local v2 = vector(-3.02, 5, 6.7) * vector(11, 12, 5.5) + v1
local v3 = vector("foo", "bar", 9000)

print(v1, v2:tostring("%.3f"))
print(v1:cross(v2))
print(v1.n, v1:magnitude())
v3:insert(3, "baz")
v3[4] = 9001
for i = 1, v3.n do
  print("index " .. i .. " = " .. tostring(v3[i]))
end
--]]


-- Check for optional dependency dlog.
local dlog, xassert
do
  local status, ret = pcall(require, "dlog")
  if status then
    dlog = ret
    xassert = dlog.xassert
  else
    -- Fallback option for xassert if dlog not found.
    xassert = function(v, ...)
      assert(v, string.rep("%s", select("#", ...)):format(...))
    end
  end
end

local vector = {}

-- Enables vector() function call as a shortcut to vector.new().
setmetatable(vector, {
  __call = function(func, ...)
    return vector.new(...)
  end
})

-- Custom table.move() implementation for Lua 5.2.
if not table.move then
  function table.move(a1, f, e, t, a2)
    a2 = a2 or a1
    local delta = t - f
    if f < t then
      for i = e, f, -1 do
        a2[i + delta] = a1[i]
      end
    else
      for i = f, e do
        a2[i + delta] = a1[i]
      end
    end
    return a2
  end
end

-- Metatable for vector types.
local vectorMeta = {
  type = "vector"
}

-- Secondary metatable that gets temporarily swapped in by certain functions to
-- bypass metamethods like __index and __newindex.
local vectorSecondaryMeta = {
  type = "vector"
}

setmetatable(vectorMeta, {
  __index = function(t, k)
    local message = "attempt to read undefined member \"" .. tostring(k) .. "\" in vector."
    if dlog then
      dlog.errorWithTraceback(message, 4)
    else
      error(message, 3)
    end
  end
})

-- Pass through table function in vectorMeta if lookup failed in object, or do
-- some bounds checking and return zero if the key is an integer (for sparse
-- vector entries).
function vectorMeta.__index(t, k)
  if type(k) == "number" then
    xassert(k == math.floor(k) and k >= 1 and k <= t.n, "index ", k, " is out of vector bounds or non-integer.")
    return 0
  end
  return vectorMeta[k]
end

-- Pass through setting value in object, or do bounds check and set vector
-- element if key is integer.
function vectorMeta.__newindex(t, k, v)
  if type(k) == "number" then
    xassert(k == math.floor(k) and k >= 1 and k <= t.n, "index ", k, " is out of vector bounds or non-integer.")
  end
  rawset(t, k, v)
end

-- vector:add(rhs: table): table
-- Can also use __add directly: lhs + rhs
-- 
-- Adds two vectors together, the vectors must be the same size. Returns new
-- vector with the component-wise sum.
function vectorMeta.add(lhs, rhs)
  xassert(lhs.type == "vector" and rhs.type == "vector" and lhs.n == rhs.n, "attempt to perform vector addition with invalid type or wrong dimensions.")
  local result = {}
  for i = 1, lhs.n do
    result[i] = lhs[i] + rhs[i]
  end
  return vector.new(lhs.n, result)
end
vectorMeta.__add = vectorMeta.add

-- vector:sub(rhs: table): table
-- Can also use __sub directly: lhs - rhs
-- 
-- Subtracts two vectors, the vectors must be the same size. Returns new vector
-- with the component-wise difference.
function vectorMeta.sub(lhs, rhs)
  xassert(lhs.type == "vector" and rhs.type == "vector" and lhs.n == rhs.n, "attempt to perform vector subtraction with invalid type or wrong dimensions.")
  local result = {}
  for i = 1, lhs.n do
    result[i] = lhs[i] - rhs[i]
  end
  return vector.new(lhs.n, result)
end
vectorMeta.__sub = vectorMeta.sub

-- vector:mul(rhs: table|number): table
-- Can also use __mul directly: lhs * rhs
-- 
-- Multiplies two vectors together (Hadamard product), the vectors must be the
-- same size. A number can be passed for lhs or rhs instead, in which case the
-- operation is treated as scalar multiplication. Returns new vector with the
-- component-wise product.
function vectorMeta.mul(lhs, rhs)
  local result = {}
  if type(lhs) == "number" then
    for i = 1, rhs.n do
      result[i] = lhs * rhs[i]
    end
    return vector.new(rhs.n, result)
  elseif type(rhs) == "number" then
    for i = 1, lhs.n do
      result[i] = lhs[i] * rhs
    end
    return vector.new(lhs.n, result)
  else
    xassert(lhs.type == "vector" and rhs.type == "vector" and lhs.n == rhs.n, "attempt to perform vector multiplication with invalid type or wrong dimensions.")
    for i = 1, lhs.n do
      result[i] = lhs[i] * rhs[i]
    end
    return vector.new(lhs.n, result)
  end
end
vectorMeta.__mul = vectorMeta.mul

-- vector:div(rhs: table|number): table
-- Can also use __div directly: lhs / rhs
-- 
-- Divides two vectors (Hadamard division), the vectors must be the
-- same size. A number can be passed for lhs or rhs instead, in which case the
-- operation is treated as scalar division. Returns new vector with the
-- component-wise quotient.
function vectorMeta.div(lhs, rhs)
  local result = {}
  if type(lhs) == "number" then
    for i = 1, rhs.n do
      result[i] = lhs / rhs[i]
    end
    return vector.new(rhs.n, result)
  elseif type(rhs) == "number" then
    for i = 1, lhs.n do
      result[i] = lhs[i] / rhs
    end
    return vector.new(lhs.n, result)
  else
    xassert(lhs.type == "vector" and rhs.type == "vector" and lhs.n == rhs.n, "attempt to perform vector division with invalid type or wrong dimensions.")
    for i = 1, lhs.n do
      result[i] = lhs[i] / rhs[i]
    end
    return vector.new(lhs.n, result)
  end
end
vectorMeta.__div = vectorMeta.div

-- vector:negate(): table
-- Can also use __unm directly: -vec
-- 
-- Same as multiplying with negative one. Returns new vector with the
-- component-wise negation.
function vectorMeta:negate()
  local result = {}
  for i = 1, self.n do
    result[i] = -self[i]
  end
  return vector.new(self.n, result)
end
vectorMeta.__unm = vectorMeta.negate

-- vector:insert(pos: number, value: any[, count: number])
-- 
-- Inserts a new element into the vector at index pos, or multiple copies of
-- this element if count is specified. The remaining elements starting at pos
-- are shifted down to make space. The pos must be an integer in the range
-- [1, vec.n + 1]. In the case that count is specified the size of the vector
-- will increase by this amount, otherwise the size increases by one.
function vectorMeta:insert(pos, value, count)
  xassert(pos == math.floor(pos) and pos >= 1 and pos <= self.n + 1, "index ", pos, " is out of vector bounds or non-integer.")
  if count then
    xassert(count == math.floor(count) and count >= 1, "number of elements to insert must be positive integer.")
    setmetatable(self, vectorSecondaryMeta)
    table.move(self, pos, self.n, pos + count)
    for i = pos, pos + count - 1 do
      self[i] = value
    end
    setmetatable(self, vectorMeta)
    self.n = self.n + count
  else
    setmetatable(self, vectorSecondaryMeta)
    table.move(self, pos, self.n, pos + 1)
    self[pos] = value
    setmetatable(self, vectorMeta)
    self.n = self.n + 1
  end
end

-- vector:erase(first: number[, last: number])
-- 
-- Removes elements in the vector within the indices first to last (inclusive).
-- Remaining elements after last are shifted down to fill the gap. The indices
-- must be integers in the range [1, vec.n], last will be set to first if it is
-- not specified. If first > last then no action is taken, otherwise the vector
-- size decreases by last - first + 1.
function vectorMeta:erase(first, last)
  xassert(first == math.floor(first) and first >= 1 and first <= self.n, "index ", first, " is out of vector bounds or non-integer.")
  if last then
    xassert(last == math.floor(last) and last >= 1 and last <= self.n, "index ", last, " is out of vector bounds or non-integer.")
    if first > last then
      return
    end
    setmetatable(self, vectorSecondaryMeta)
    table.move(self, last + 1, self.n, first)
    for i = self.n + first - last, self.n do
      self[i] = nil
    end
    setmetatable(self, vectorMeta)
    self.n = self.n + first - last - 1
  else
    setmetatable(self, vectorSecondaryMeta)
    table.move(self, first + 1, self.n, first)
    self[self.n] = nil
    setmetatable(self, vectorMeta)
    self.n = self.n - 1
  end
end

-- vector:append(value: any)
-- 
-- Adds a new element at the end of the vector. This is essentially the same as
-- calling vec:insert(vec.n + 1, value) and increases the vector size by one.
function vectorMeta:append(value)
  self.n = self.n + 1
  self[self.n] = value
end

-- vector:concatenate(rhs: table): table
-- Can also use __concat directly: lhs .. rhs
-- 
-- Combines two vectors together and returns a new one. The new vector
-- represents the union of the left vector and the right vector.
function vectorMeta.concatenate(lhs, rhs)
  xassert(lhs.type == "vector" and rhs.type == "vector", "attempt to perform vector concatenation with invalid type.")
  local result = {}
  setmetatable(lhs, vectorSecondaryMeta)
  for i = 1, lhs.n do
    result[i] = lhs[i]
  end
  setmetatable(lhs, vectorMeta)
  setmetatable(rhs, vectorSecondaryMeta)
  for i = 1, rhs.n do
    result[i + lhs.n] = rhs[i]
  end
  setmetatable(rhs, vectorMeta)
  return vector.new(lhs.n + rhs.n, result)
end
vectorMeta.__concat = vectorMeta.concatenate

-- vector:resize(size: number)
-- 
-- Changes the current vector size to the new size. The new size must be a
-- non-negative integer. Any elements that extend outside the new size of the
-- vector are removed.
function vectorMeta:resize(size)
  xassert(size == math.floor(size) and size >= 0, "vector size must be non-negative integer.")
  if size < self.n then
    setmetatable(self, vectorSecondaryMeta)
    for i = size + 1, self.n do
      self[i] = nil
    end
    setmetatable(self, vectorMeta)
  end
  self.n = size
end

-- vector:tostring([format: string]): string
-- Can also use __tostring directly: tostring(vec)
-- 
-- Converts vector to human-readable text. If the format string is provided,
-- this is used to format each value in the vector like string.format() does.
-- For example, the string "%.3f" will give a decimal precision of 3.
function vectorMeta:tostring(format)
  local vals = {}
  if not format then
    for i = 1, self.n do
      vals[i] = (type(self[i]) == "number" and self[i] or tostring(self[i]))
    end
  else
    for i = 1, self.n do
      vals[i] = string.format(format, self[i])
    end
  end
  return "{" .. table.concat(vals, ", ") .. "}"
end
vectorMeta.__tostring = vectorMeta.tostring

-- vector:magnitude(): number
-- Can also use __len directly: #vec
-- 
-- Computes the magnitude of the vector (the length).
function vectorMeta:magnitude()
  local sum = 0
  for i = 1, self.n do
    sum = sum + self[i] ^ 2
  end
  return math.sqrt(sum)
end
vectorMeta.__len = vectorMeta.magnitude

-- Custom iteration using pairs() to only return keys with numeric values. Note
-- that there is no equivalent for ipairs() right now since __ipairs has been
-- deprecated in recent Lua versions.
function vectorMeta.__pairs(vec)
  local function pairsIter(vec, k)
    local v
    repeat
      k, v = next(vec, k)
      if type(k) == "number" then
        return k, v
      end
    until k == nil
  end
  return pairsIter, vec, nil
end

-- vector:equals(rhs: table): boolean
-- Can also use __eq directly: lhs == rhs
-- 
-- Compares two vectors to determine if they are equivalent (i.e. the vectors
-- have the same size and all elements match). Use the double-equals operator to
-- safely compare a vector with other data types.
function vectorMeta.equals(lhs, rhs)
  if lhs.type ~= "vector" or rhs.type ~= "vector" or lhs.n ~= rhs.n then
    return false
  end
  for i = 1, lhs.n do
    if lhs[i] ~= rhs[i] then
      return false
    end
  end
  return true
end
vectorMeta.__eq = vectorMeta.equals

function vectorMeta:dot()
  
end

function vectorMeta:cross()
  
end

function vectorMeta:normalize()
  
end

function vectorMeta:angle()
  
end

function vectorMeta:rotate()
  
end

function vectorMeta:round()
  
end

-- vector.new(x: any, y: any, z: any, ...): table
-- vector.new(size: number, data: table): table
-- vector.new(vec: table): table
-- Can also use __call directly: vector(...): table
-- 
-- Construct new vector by passing each value in order (nil values are accepted
-- for sparse vectors), pass a number for the size and a table for the contents,
-- or pass a vector to make a copy from. If the size is specified, it must be a
-- non-negative integer. Returns the new vector.
function vector.new(...)
  local arg = table.pack(...)
  if arg.n == 1 and type(arg[1]) == "table" and arg[1].type == "vector" then
    local vec = {}
    for k, v in next, arg[1] do
      vec[k] = v
    end
    return setmetatable(vec, vectorMeta)
  elseif arg.n == 2 and type(arg[1]) == "number" and type(arg[2]) == "table" then
    xassert(arg[1] == math.floor(arg[1]) and arg[1] >= 0, "vector size must be non-negative integer.")
    arg[2].n = arg[1]
    return setmetatable(arg[2], vectorMeta)
  else
    return setmetatable(arg, vectorMeta)
  end
end

return vector
