
-- cool idea, what if we had a tool that could print almost anything? binary floats, _ENV, and even process.info() vals (with metatables?).
-- hmm, how to save output? maybe use dlog idk
-- xprint() is like print() but better
-- xprint.table() can do depth limiting
-- xprint.hex() can do hex dump on number or string (or file?)


local xprint = {}

-- Enables xprint() function call as a shortcut to xprint.print().
setmetatable(xprint, {
  __call = function(func, ...)
  return xprint.print(...)
  end
})

local function writeValueToStream(config, v, stream, endOfLine)
  local typeV = type(v)
  if not config.formatHex then
    if not config.rawString and typeV == "string" then
      stream:write(string.format("%q", v):gsub("\\\n","\\n"), endOfLine)
    else
      stream:write(tostring(v), endOfLine)
    end
  elseif typeV == "number" then
    if math.type and math.type(v) == "integer" then
      v = string.pack(">l", v)
    else
      v = string.pack(">n", v)
    end
    stream:write("0x", string.format(string.rep("%.2X", #v), string.byte(v, 1, #v)), endOfLine)
  elseif not config.rawString and typeV == "string" then
    stream:write("0x")
    for i = 1, #v, 100 do
      local endIndex = math.min(i + 99, #v)
      stream:write(string.format(string.rep("%.2X ", endIndex - i + 1), string.byte(v, i, endIndex)))
    end
    stream:write(endOfLine)
  else
    stream:write(tostring(v), endOfLine)
  end
end

local function writeTableToStream(config, t, stream, spacing, depth)
  if config[t] then
    stream:write(tostring(t), " (duplicate)\n")
    return
  end
  stream:write(tostring(t), " {\n")
  config[t] = true
  
  local function rawPairs(t)
    return next, t
  end
  
  if depth <= config.maxDepth then
    local sortedKeys, stringKeys, otherKeys = {}, {}, {}
    local iterationMethod = config.rawAccess and rawPairs or pairs
    for k, v in iterationMethod(t) do
      if type(k) == "number" then
        sortedKeys[#sortedKeys + 1] = k
      elseif type(k) == "string" then
        stringKeys[#stringKeys + 1] = k
      else
        otherKeys[#otherKeys + 1] = k
      end
    end
    table.sort(sortedKeys)
    table.sort(stringKeys)
    local sortedKeysSize = #sortedKeys
    for i, v in ipairs(stringKeys) do
      sortedKeys[sortedKeysSize + i] = v
    end
    sortedKeysSize = #sortedKeys
    for i, v in ipairs(otherKeys) do
      sortedKeys[sortedKeysSize + i] = v
    end
    
    for _, k in ipairs(sortedKeys) do
      stream:write(spacing, "  ")
      writeValueToStream(config, k, stream, "")
      stream:write(": ")
      if type(t[k]) == "table" then
        writeTableToStream(config, t[k], stream, spacing .. "  ", depth + 1)
      else
        writeValueToStream(config, t[k], stream, "\n")
      end
    end
  elseif next(t) ~= nil then
    stream:write(spacing, "  ...\n")
  end
  
  if config.hideMeta or not getmetatable(t) then
    stream:write(spacing, "}\n")
  else
    stream:write(spacing, "} meta ")
    local tMeta = getmetatable(t)
    if type(tMeta) == "table" then
      writeTableToStream(config, tMeta, stream, spacing, depth)
    else
      writeValueToStream(config, tMeta, stream, "\n")
    end
  end
end

-- config[t] hides table t
-- config.stream sends output to stream
-- config.hideMeta hides metatable data
-- config.maxDepth sets max table depth level [0, inf)
-- config.rawAccess enables raw table iteration
-- config.rawString disables string escaping
-- config.formatHex shows values in hex
function xprint.print(config, ...)
  assert(type(config) == "table", "config table must be first argument to xprint()")
  local stream = config.stream or io.stdout
  config.maxDepth = config.maxDepth or math.huge
  
  local arg = table.pack(...)
  for i = 1, arg.n do
    if type(arg[i]) == "table" then
      writeTableToStream(config, arg[i], stream, "", 1)
    else
      writeValueToStream(config, arg[i], stream, "\n")
    end
  end
  if arg.n == 0 then
    stream:write("\n")
  end
end

-- The hexdump format uses the "canonical hex+ASCII display".
function xprint.hexdump(istream)
  local address = 0
  local bytes = istream:read(16)
  while bytes do
    io.write(string.format("%.8x  ", address))
    io.write(string.format(string.rep("%.2x ", math.min(#bytes, 8)), string.byte(bytes, 1, math.min(#bytes, 8))), " ")
    if #bytes > 8 then
      io.write(string.format(string.rep("%.2x ", #bytes - 8), string.byte(bytes, 9, #bytes)))
    end
    if #bytes < 16 then
      io.write(string.rep("   ", 16 - #bytes))
    end
    io.write(" |", string.gsub(bytes, "[^%g ]", "."), "|\n")
    address = address + #bytes
    bytes = istream:read(16)
  end
  if address ~= 0 then
    io.write(string.format("%.8x  ", address), "\n")
  end
end


local t1 = {
  abc = 123,
  [1] = "first",
  [2] = "sec",
  [3] = "third",
  my = -1,
  sample = -2,
  text = -3,
  here = -4,
  [{}] = -5,
  [function() end] = "cooler",
  [ [["! level2
    ]] ] = setmetatable({
    "a",
    "b",
    "c",
    thing = "cool",
    [function() end] = {
      __index = " ",
      __metatable = 123.456,
    },
  }, {__index = function() print("ok") end, [3] = "test"}),
  hidden = setmetatable({
    "not here",
    123,
    function() return 6 end,
    "secret ",
  }, {__pairs = function() return function() end end, __metatable = "you can\'t see my secret pairs func!"}),
}
t1[11] = t1
setmetatable(t1, getmetatable(t1[ [["! level2
    ]] ]))


--xprint({}, nil, 12.345, "test\ncool  ", t1, t1, function() end)
--xprint({rawAccess = true}, t1)
--print("(END)")

return xprint
