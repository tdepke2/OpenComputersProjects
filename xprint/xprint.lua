--------------------------------------------------------------------------------
-- Extended print function, can be used to recursively print tables, format
-- numbers/strings in hexadecimal, and more.
-- 
-- The main function here, xprint.print() (or just xprint()), will accept a
-- configuration table and any number of arguments to format as strings and
-- print these to stdout (or custom stream). The function supports cyclic
-- tables, tables with metatables, depth-limiting, raw iteration, and more. See
-- the comments for xprint.print() for full details.
-- 
-- Another available utility is xprint.hexdump(). It behaves just like the UNIX
-- hexdump command, but currently only supports canonical hex+ASCII display.
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


local xprint = {}


-- Enables xprint() function call as a shortcut to xprint.print().
setmetatable(xprint, {
  __call = function(func, ...)
  return xprint.print(...)
  end
})


-- Outputs a single value v to the stream. Does not recurse on table values.
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
    stream:write("0x", string.format(string.rep("%.2x", #v), string.byte(v, 1, #v)), endOfLine)
  elseif not config.rawString and typeV == "string" then
    stream:write("0x")
    for i = 1, #v, 100 do
      local endIndex = math.min(i + 99, #v)
      stream:write(string.format(string.rep("%.2x ", endIndex - i + 1), string.byte(v, i, endIndex)))
    end
    stream:write(endOfLine)
  else
    stream:write(tostring(v), endOfLine)
  end
end


-- Recursively prints the contents of table t. Keys are sorted such that numbers
-- appear first, then strings, then other types. The metatable is recursively
-- printed at the end (if enabled).
local function writeTableToStream(config, t, stream, spacing, depth)
  if config.traversedTables[t] then
    stream:write(tostring(t), " (duplicate)\n")
    return
  end
  stream:write(tostring(t), " {\n")
  config.traversedTables[t] = true
  
  local function rawPairs(t)
    return next, t
  end
  
  if not config.maxDepth or depth <= config.maxDepth then
    -- Collect all table keys and sort them (the iteration order of pairs() is undefined). This make the data more human-readable.
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
    
    -- Write each value to the stream.
    for _, k in ipairs(sortedKeys) do
      stream:write(spacing, "  ")
      writeValueToStream(config, k, stream, "")
      stream:write(" = ")
      if type(t[k]) == "table" then
        writeTableToStream(config, t[k], stream, spacing .. "  ", depth + 1)
      else
        writeValueToStream(config, t[k], stream, "\n")
      end
    end
  elseif next(t) ~= nil then
    stream:write(spacing, "  ...\n")
  end
  
  -- Write ending brace, and metatable if enabled.
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


--- `xprint.print(config: table, ...)`
-- 
-- Prints the given arguments to stdout or other stream. A newline is added
-- between each value instead of a tab (like the print() function). Tables are
-- displayed in an expanded format, but any that have already been expanded
-- within the current call just show the table address (prevents duplicate table
-- display and allows cyclic tables). The config parameter allows setting the
-- output format, the supported options are below:
--   * `config[t] = true` prevents expansion of table t
--   * `config.stream = s` sends output to stream s (default is stdout, can be
--     any regular files opened in write/append mode)
--   * `config.hideMeta = true` hides display of metatable data on tables
--   * `config.maxDepth = n` sets max table depth level to n in range [0, inf)
--   * `config.rawAccess = true` enables raw table iteration without pairs()
--   * `config.rawString = true` disables string escaping
--   * `config.formatHex = true` displays number/string values in hexadecimal
-- 
-- The config can be an empty table to use the default settings.
function xprint.print(config, ...)
  assert(type(config) == "table", "config table must be first argument to xprint()")
  local stream = config.stream or io.stdout
  config.traversedTables = setmetatable({}, {
    __index = config
  })
  
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
  config.traversedTables = nil
end


--- `xprint.hexdump(istream: table)`
-- 
-- Reads in bytes from the input stream and prints the hexadecimal values to
-- stdout. The offset address of the first byte in a row is shown in the left
-- column, and the ASCII data is shown in the right column.
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

return xprint
