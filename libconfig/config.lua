--[[

-- My sample config file
stuff = {
  foo = {
    ["number"]   = "number  ",
    ["string"]   = "string  ",
    
    -- can be one of: apple, banana, or cherry
    enumVal = "apple",
  },
  bar = {
    "set",
    "test",
    "first",
    123,
  },
  -- idk what this is...
  -- must be at least 3 items
  baz = {
    [0] = "z",
    [1] = "o",
    [2] = "t",
  },
  mixedPairs = {
    [1] = "a",
    [2] = "b",
    another = "c",
    even_more = "d",
  },
}

properties = {
  color1 = 0xAABBCC,
  color2 = 0x000000,
  useColors = true,
  [1] = {
    true,
    "height",
    4.67,
  },
  [2] = {
    false,
    "length",
    2.89,
  },
  [3] = {
    true,
    "width",
    3.00,
  },
}


]]


local typeListDemo = {
  Fruits = {
    "apple", "banana", "cherry"
  },
  DataTypes = {
    "number", "string", "table"
  },
  Table3Plus = {
    verify = function(v)
      
      
      -- maybe don't do this??
      
      
    end,
  },
  Color = {
    encode = function(v)
      return string.format("0x%06X", v)
    end,
    decode = function(v)
      return v
    end,
    verify = function(v)
      assert(type(v) == "number" and math.floor(v) == v and v >= 0 and v <= 0xFFFFFF, "provided Color must be a 24 bit integer value.")
    end,
  },
  Float2 = {
    encode = function(v)
      return string.format("%.2f", v)
    end,
    verify = function(v)
      assert(type(v) == "number", "provided Float2 must be a number.")
    end
  },
}

local propList = {
  {"boolean"},
  {"string"},
  {"Float2"},
}

local cfgFormatDemo = {
  stuff = {
    _comment_ = "My sample config file",
    _order_ = 1,
    foo = {
      enumVal = {"Fruits", "apple", "\ncan be one of: apple, banana, or cherry"},
      _pairs_ = {"DataTypes", "string",
        ["number"]   = "number  ",
        ["string"]   = "string  ",
      },
    },
    bar = {
      _ipairs_ = {"string|number",
        "set",
        "test",
        "first",
        123,
      },
    },
    baz = {
      _comment_ = "\nidk what this is...\nmust be at least 3 items",
      --_iter_ = {"number", "any",
        
        -- not finished yet, would this even be useful?
        -- I think we should skip this, complex iteration checking should be done outside of the config.
        
      --},
      _ipairs_ = {"string"}
    },
    mixedPairs = {
      _ipairs_ = {"string",
        "a",
        "b",
      },
      _pairs_ = {"string", "string",
        another = "c",
        even_more = "d",
      },
    },
  },
  properties = {
    _order_ = 2,
    color1 = {"Color", 0xAABBCC},
    color2 = {"Color", 0x000000},
    useColors = {"boolean", true},
    _ipairs_ = {propList,
      {
        true,
        "height",
        4.67,
      },
      {
        false,
        "length",
        2.89,
      },
      {
        true,
        "width",
        3.00,
      },
    },
  },
  ["while"] = {"table|nil", {"bam", "boozled", 1234, {["for"] = true}}},
  _ipairs_ = {"string"},
}

--[[
for table t in cfgFormat, if t[1] is string then t represents a value definition



]]



local config = {}

local formatFields = {
  _comment_ = true,
  _order_ = true,
  _pairs_ = true,
  _ipairs_ = true,
}

local luaTypes = {
  ["nil"] = true,
  ["boolean"] = true,
  ["number"] = true,
  ["string"] = true,
  ["function"] = true,
  ["userdata"] = true,
  ["thread"] = true,
  ["table"] = true,
}

-- Makes a deep copy of a table (or just returns the given argument otherwise).
-- This uses raw iteration (metamethods are ignored) and also makes deep copies
-- of metatables. Currently does not behave with cycles in tables.
-- 
---@param src any
---@return any srcCopy
local function deepCopy(src)
  if type(src) == "table" then
    local srcCopy = {}
    for k, v in next, src do
      srcCopy[k] = deepCopy(v)
    end
    local meta = getmetatable(src)
    if meta ~= nil then
      setmetatable(srcCopy, deepCopy(meta))
    end
    return srcCopy
  else
    return src
  end
end

-- Recursively updates `dest` to become the union of tables `src` and `dest`
-- (these don't have to be tables though). Values from `src` will overwrite ones
-- in `dest`, except when `src` is nil. The same process is applied to
-- metatables in `src` and `dest`.
-- 
---@param src any
---@param dest any
---@return any merged
local function mergeTables(src, dest)
  if type(src) == "table" then
    if type(dest) == "table" then
      for k, v in next, src do
        dest[k] = mergeTables(v, dest[k])
      end
      local srcMeta, destMeta = getmetatable(src), getmetatable(dest)
      if srcMeta ~= nil or destMeta ~= nil then
        setmetatable(dest, mergeTables(srcMeta, destMeta))
      end
    else
      return deepCopy(src)
    end
  elseif src ~= nil then
    return src
  end
  return dest
end


---@param filename string
---@param cfgFormat table
---@param allowDefaults boolean
---@param localEnv table|nil
---@return table cfg
function config.loadFile(filename, cfgFormat, allowDefaults, localEnv)
  localEnv = localEnv or {}
  local file = io.open(filename)
  local cfg
  if file then
    file:close()
    cfg = {}
    
    -- Add metamethods to localEnv so we can index back to the global
    -- environment, and new global variables will be added in cfg instead of
    -- modifying the environment.
    setmetatable(localEnv, {
      __index = _ENV,
      __newindex = function(t, k, v)
        rawset(t, k, v)
        cfg[k] = v
      end,
    })
    
    local fn, err = loadfile(filename, "t", localEnv)
    if not fn then
      error("failed to load config: " .. tostring(err) .. "\n")
    end
    local status, result = pcall(fn)
    if not status then
      error("failed to load config: " .. tostring(result) .. "\n")
    end
  elseif allowDefaults then
    local function getDefaults(t)
      if type(t[1]) == "string" then
        return t[2]
      end
      
      local result = {}
      for k, v in pairs(t) do
        if not formatFields[k] then
          result[k] = getDefaults(v)
        elseif k == "_pairs_" or k == "_ipairs_" then
          local valueTypeIndex = (k == "_pairs_" and 2 or 1)
          for pairKey, pairVal in pairs(v) do
            if type(pairKey) ~= "number" then
              result[pairKey] = pairVal
            elseif pairKey <= 0 or pairKey > valueTypeIndex or math.floor(pairKey) ~= pairKey then
              if pairKey > valueTypeIndex and math.floor(pairKey) == pairKey then
                pairKey = pairKey - valueTypeIndex
              end
              result[pairKey] = pairVal
            end
          end
        end
      end
      return result
    end
    
    cfg = getDefaults(cfgFormat)
  else
    error("failed to open file \"" .. filename .. "\" for reading.")
  end
  
  return cfg
end

-- Compares the given value with the string typeNames of acceptable types. If no
-- match is found for any of the types, this function throws an error with the
-- address where it occurred. Otherwise, returns the first name in typeNames
-- that matched the value type.
-- 
---@param value any
---@param typeNames string
---@param typeList table
---@param valueName string
---@param address string
---@return string typeVerified
local function verifyType(value, typeNames, typeList, valueName, address)
  -- Iterate type names (separated by vertical bars) until we find a match with value.
  local typeVerified, typeCheckError
  for typeName in string.gmatch(typeNames, "[%w_]+") do
    if typeName == "any" then
      typeVerified = typeName
      break
    elseif luaTypes[typeName] then
      if type(value) == typeName then
        typeVerified = typeName
        break
      end
    elseif typeList[typeName] then
      local status, result = pcall(typeList[typeName].verify or function() end, value)
      if status then
        typeVerified = typeName
        break
      else
        typeCheckError = result
      end
    else
      error("at \"" .. address .. "\": undefined type \"" .. typeName .. "\".")
    end
  end
  
  if typeCheckError then
    error("at \"" .. address .. "\": bad " .. valueName .. ": " .. tostring(typeCheckError))
  elseif not typeVerified then
    error("at \"" .. address .. "\": " .. valueName .. " with type \"" .. type(value) .. "\" does not match any of the allowed types \"" .. typeNames .. "\".")
  end
  return typeVerified
end

-- Helper function to concatenate the next key onto the address, using a dot or
-- brackets where appropriate.
-- 
---@param address string
---@param key any
---@return string
local function nextAddress(address, key)
  if type(key) == "string" then
    return address .. "." .. key
  else
    return address .. "[" .. tostring(key) .. "]"
  end
end

local function keyUnionIter(a, b)
  local t, k = a, nil
  local function iter()
    k = next(t, k)
    if t == a then
      if k == nil then
        t = b
        return iter()
      end
    elseif a[k] ~= nil then
      return iter()
    end
    return k
  end
  return iter
end

-- Helper function for `config.verify()` to check for errors in configuration.
-- 
---@param cfg any
---@param cfgFormat table
---@param typeList table
---@param address string
local function verifySubconfig(cfg, cfgFormat, typeList, address)
  if type(cfgFormat) ~= "table" then
    error("at \"" .. address .. "\": expected table in configuration format.")
  end
  
  -- If first index in cfgFormat is a string, the table represents a value definition.
  -- Value format: `{<type names>, [default value], [comment]}`.
  if type(cfgFormat[1]) == "string" then
    verifyType(cfg, cfgFormat[1], typeList, "value", address)
    return
  end
  
  -- Find the union of keys in cfg and cfgFormat (except for format fields). This is similar to the result of sortKeys() but unsorted.
  local unifiedKeys, unifiedKeysSize = {}, 0
  for k in keyUnionIter(cfg, cfgFormat) do
    if not formatFields[k] then
      unifiedKeysSize = unifiedKeysSize + 1
      unifiedKeys[unifiedKeysSize] = k
    end
  end
  
  print("unifiedKeys:")
  for i = -100, 100 do
    if unifiedKeys[i] then
      print(i, unifiedKeys[i])
    end
  end
  print()
  
  -- Check for "_ipairs_" first and iterate sequential keys in cfg. We mark these as processed so they won't get picked up a second time in the following iterations.
  local processedKeys = {}
  if cfgFormat._ipairs_ then
    local valueTypes = cfgFormat._ipairs_[1]
    for i, v in ipairs(cfg) do
      processedKeys[i] = true
      if type(valueTypes) == "string" then
        verifyType(v, valueTypes, typeList, "value", nextAddress(address, i))
      else
        verifySubconfig(v, valueTypes, typeList, nextAddress(address, i))
      end
    end
  end
  
  -- Match keys in cfgFormat with existing/non-existing ones in cfg second. Iterates with unifiedKeys for a defined ordering.
  for i = 1, unifiedKeysSize do
    local k = unifiedKeys[i]
    if not processedKeys[k] and cfgFormat[k] then
      processedKeys[k] = true
      verifySubconfig(cfg[k], cfgFormat[k], typeList, nextAddress(address, k))
    end
  end
  
  -- Check for "_pairs_" third and iterate remaining keys/values in cfg (we already got all of the cfgFormat ones in above step). Iterates with unifiedKeys for a defined ordering.
  if cfgFormat._pairs_ then
    local keyTypes, valueTypes = cfgFormat._pairs_[1], cfgFormat._pairs_[2]
    for i = 1, unifiedKeysSize do
      local k = unifiedKeys[i]
      if not processedKeys[k] then
        local address2 = nextAddress(address, k)
        processedKeys[k] = true
        verifyType(k, keyTypes, typeList, "key", address2)
        if type(valueTypes) == "string" then
          verifyType(cfg[k], valueTypes, typeList, "value", address2)
        else
          verifySubconfig(cfg[k], valueTypes, typeList, address2)
        end
      end
    end
  end
  
  -- Confirm no extra fields are defined in cfg that we didn't match previously.
  for k, v in pairs(cfg) do
    if not processedKeys[k] then
      error("at \"" .. nextAddress(address, k) .. "\": key is undefined in configuration format.")
    end
  end
end

-- Checks the format of config cfg to make sure it matches cfgFormat. An error
-- is thrown if any inconsistencies with the format are found.
-- 
---@param cfg any
---@param cfgFormat table
---@param typeList table
function config.verify(cfg, cfgFormat, typeList)
  verifySubconfig(cfg, cfgFormat, typeList, "config")
end


-- List of Lua keywords. If a table has any of these as string keys, they need to be escaped in quotes during serialization.
local luaReservedWords = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"] = true,
  ["while"] = true,
}

-- Writes a value out to the given file. This uses typeNames and verifyType() if
-- provided to determine if the value is a custom type. Includes checking when
-- valueName is the string `key` to wrap the value in brackets.
-- 
---@param file file*
---@param value any
---@param typeNames string|nil
---@param typeList table
---@param valueName string
---@param address string
---@param spacing string
---@param endOfLine string
local function writeValue(file, value, typeNames, typeList, valueName, address, spacing, endOfLine)
  local valueType = type(value)
  local typeVerified = typeNames and verifyType(value, typeNames, typeList, valueName, address) or "any"
  
  -- For custom types, use the encode() function if found to convert the value to a code chunk.
  if typeList[typeVerified] and typeList[typeVerified].encode then
    local status, result = pcall(typeList[typeVerified].encode, value)
    if not status or type(result) ~= "string" then
      if status then
        result = "result is type " .. type(result)
      end
      error("at \"" .. address .. "\": failed to convert " .. typeVerified .. " to string: " .. tostring(result))
    end
    value = result
    -- Pseudo type for strings that need to be written as a Lua chunk (and not wrapped in quotes like normal strings, the below code does this).
    valueType = "string_code"
  end
  
  -- Brackets are needed for table keys (except when the key is a string, valid identifier, and not a reserved word).
  local addBrackets = (valueName == "key")
  if addBrackets and valueType == "string" and string.find(value, "^[%a_][%w_]*$") and not luaReservedWords[value] then
    addBrackets = false
  end
  if addBrackets then
    file:write("[")
  end
  
  if valueType == "table" then
    -- Recursively print the contents of the table. Custom types are not considered in the table (there's no way to define them in there).
    local newSpacing = spacing .. "  "
    file:write("{\n")
    for k, v in pairs(value) do
      file:write(spacing)
      writeValue(file, k, nil, typeList, "key", address, newSpacing, " = ")
      writeValue(file, v, nil, typeList, "value", address, newSpacing, ",\n")
    end
    file:write(string.sub(spacing, 3), "}")
  elseif valueType == "string" and (valueName ~= "key" or addBrackets) then
    file:write((string.format("%q", value):gsub("\\\n","\\n")))
  else
    file:write(tostring(value))
  end
  
  if addBrackets then
    file:write("]", endOfLine)
  else
    file:write(endOfLine)
  end
end

local function writeComment(file, comment, spacing)
  local prefixNewlines = true
  for line in string.gmatch(comment .. "\n", "(.-)\n") do
    if line ~= "" or not prefixNewlines then
      file:write(spacing, "-- ", line, "\n")
      prefixNewlines = false
    else
      file:write("\n")
    end
  end
end

--[[

local cfg = {
    stuff = {
        
    },
    properties = {
        
    },
    cum = "succ",
    [0] = {
        
    },
    [1] = {
        
    },
    [2] = nil,
    [-3] = {
        
    },
}

local cfgFormat = {
    stuff = {
        _order_ = 3
    },
    properties = {
        _order_ = 1
    },
    cum = {_order_ = 6},
    [0] = {
        _order_ = 4
    },
    [1] = {
        _order_ = 7
    },
    [2] = {
        _order_ = 2
    },
    [-3] = {
        _order_ = 5
    },
}

]]--

local function sortKeys(cfg, cfgFormat)
  -- Collect all cfg and cfgFormat keys and sort them. Based on code used in xprint module.
  local sortedKeys, stringKeys, otherKeys = {}, {}, {}
  for k in keyUnionIter(cfg, cfgFormat) do
    if not formatFields[k] then
      if type(k) == "number" then
        sortedKeys[#sortedKeys + 1] = k
      elseif type(k) == "string" then
        stringKeys[#stringKeys + 1] = k
      else
        otherKeys[#otherKeys + 1] = k
      end
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
  
  print("sortedKeys:")
  for i = -100, 100 do
    if sortedKeys[i] then
      print(i, sortedKeys[i])
    end
  end
  print()
  
  --[=[
  local customOrder = {}
  for i = 1, sortedKeysSize do
    local formatValue = cfgFormat[sortedKeys[i]]
    if type(formatValue) == "table" and formatValue._order_ then
      customOrder[formatValue._order_] = i
    end
  end
  local customOrderSize = #customOrder
  print("customOrderSize = ", customOrderSize)
  if customOrderSize > 0 then
    local newSortedKeys = {}
    --table.move(sortedKeys, 1, customOrderSize, customOrderSize + 1, sortedKeys)
    for i = 1, customOrderSize do
      newSortedKeys[i] = sortedKeys[customOrder[i]]
      sortedKeys[customOrder[i]] = nil
    end
    local newIndex = customOrderSize + 1
    for i = 1, sortedKeysSize do
      if sortedKeys[i] ~= nil then
        newSortedKeys[newIndex] = sortedKeys[i]
        newIndex = newIndex + 1
      end
    end
    sortedKeys = newSortedKeys
    
    --[[
    for i = sortedKeysSize + customOrderSize, 1, -1 do
      if sortedKeys[i] == nil and sortedKeys[i + 1] ~= nil then
        table.remove(sortedKeys, i)
        print("removed ", i)
      end
    end]]
  end]=]
  
  -- Search for cfg keys that have a corresponding "_order_" field in cfgFormat. This marks an override for the ordering.
  local customOrder = setmetatable({}, {
    __index = function() return math.huge end
  })
  for _, v in ipairs(sortedKeys) do
    local formatValue = cfgFormat[v]
    if type(formatValue) == "table" and formatValue._order_ then
      customOrder[v] = formatValue._order_
      print("customOrder[", v, "] = ", formatValue._order_)
    end
  end
  
  -- Apply insertion sort (stable sorting) over the sortedKeys. Keys defined in customOrder are sorted to the front, and the rest are left where they are.
  for i = 2, #sortedKeys do
    local j = i
    while j > 1 and customOrder[sortedKeys[j]] < customOrder[sortedKeys[j - 1]] do
      sortedKeys[j], sortedKeys[j - 1] = sortedKeys[j - 1], sortedKeys[j]
      j = j - 1
    end
  end
  
  print("\nsortedKeys after:")
  for i = -100, 100 do
    if sortedKeys[i] then
      print(i, sortedKeys[i])
    end
  end
end

-- FIXME this is very similar to verification code, can we merge the two somehow? #############################################################
---@param file file*
---@param cfg any
---@param cfgFormat table
---@param typeList table
---@param address string
---@param spacing string
local function writeSubconfig(file, cfg, cfgFormat, typeList, address, spacing)
  if type(cfgFormat) ~= "table" then
    error("at \"" .. address .. "\": expected table in configuration format.")
  end
  
  -- Special case to handle first level of cfg. The first level is written to the file such that the values are not within a table.
  local endOfLine = ",\n"
  if #spacing <= 2 then
    endOfLine = "\n"
  end
  
  if type(cfgFormat[1]) == "string" then
    writeValue(file, cfg, cfgFormat[1], typeList, "value", address, spacing, endOfLine)
    return
  end
  
  -- FIXME implement this when ready ################################
  --local sortedKeys = sortKeys(cfg, cfgFormat)
  
  -- do we need to change order of below 3 code blocks to get better sort order?
  -- FIXME the 3 code blocks can be put in a separate function? ##########################
  
  
  
  if spacing ~= "" then
    file:write("{\n")
  end
  
  local newSpacing = spacing .. "  "
  
  local processedKeys = {}
  for k, v in pairs(cfgFormat) do
    if not formatFields[k] then
      if type(v) == "table" then
        if v._comment_ then
          writeComment(file, v._comment_, spacing)
        elseif type(v[1]) == "string" and v[3] then
          writeComment(file, v[3], spacing)
        end
      end
      file:write(spacing)
      writeValue(file, k, nil, typeList, "key", address, newSpacing, " = ")
      processedKeys[k] = true
      writeSubconfig(file, cfg[k], v, typeList, nextAddress(address, k), newSpacing)
    end
  end
  
  if cfgFormat._ipairs_ then
    local valueTypes = cfgFormat._ipairs_[1]
    for i, v in ipairs(cfg) do
      if processedKeys[i] then
        break
      end
      processedKeys[i] = true
      file:write(spacing)
      if type(valueTypes) == "string" then
        --verifyType(v, valueTypes, "value", nextAddress(address, i))
        writeValue(file, v, valueTypes, typeList, "value", nextAddress(address, i), newSpacing, endOfLine)
      else
        --verifySubconfig(v, valueTypes, typeList, nextAddress(address, i))
        writeSubconfig(file, v, valueTypes, typeList, nextAddress(address, i), newSpacing)
      end
    end
  end
  
  if cfgFormat._pairs_ then
    local keyTypes, valueTypes = cfgFormat._pairs_[1], cfgFormat._pairs_[2]
    for k, v in pairs(cfg) do
      if not processedKeys[k] then
        local address2 = nextAddress(address, k)
        processedKeys[k] = true
        --verifyType(k, keyTypes, "key", address2)
        file:write(spacing)
        writeValue(file, k, keyTypes, typeList, "key", address2, newSpacing, " = ")
        if type(valueTypes) == "string" then
          --verifyType(v, valueTypes, "value", address2)
          writeValue(file, v, valueTypes, typeList, "value", address2, newSpacing, endOfLine)
        else
          --verifySubconfig(v, valueTypes, typeList, address2)
          writeSubconfig(file, v, valueTypes, typeList, address2, newSpacing)
        end
      end
    end
  end
  
  if spacing ~= "" then
    file:write(string.sub(spacing, 3), "}", endOfLine)
  end
  
end


-- FIXME still need to implement decode() handling in typeList. #########################################################



-- 
-- 
---@param filename string
---@param cfg any
---@param cfgFormat table
---@param typeList table
function config.saveFile(filename, cfg, cfgFormat, typeList)
  --local file = io.open(filename, "w")
  --if not file then
    --error("failed to open file \"" .. filename .. "\" for writing.")
  --end
  
  writeSubconfig(io.stdout, cfg, cfgFormat, typeList, "config", "")
end


--local xprint = require("xprint")
local cfg = config.loadFile("/home/configTest2", cfgFormatDemo, true)
xprint.print({}, cfg)
print("verify cfg")
config.verify(cfg, cfgFormatDemo, typeListDemo)




local cfg2 = {
  -- My sample config file
  stuff = {
    bar = {
      "set",
      "test",
      "first",
      123,
    },
    -- idk what this is...
    -- must be at least 3 items
    baz = {
      --[0] = "z",
      [1] = "o",
      [2] = "t",
    },
    foo = {
      
      -- can be one of: apple, banana, or cherry
      enumVal = "apple",
      ["number"]   = "number  ",
      ["string"]   = "string  ",
    },
    mixedPairs = {
      [1] = "a",
      [2] = "b",
      another = "c",
      even_more = "d",
    },
  },
  properties = {
    [1] = {
      true,
      "height",
      4.67,
    },
    [2] = {
      false,
      "length",
      2.89,
    },
    [3] = {
      true,
      "width",
      3.00,
    },
    color1 = 0xAABBCC,
    color2 = 0x000000,
    useColors = true,
  },
  ["while"] = {
    "bam",
    "boozled",
    1234,
    {
      ["for"] = true,
    },
  },
  [1] = "-1.234",
  [2] = "cool",
}

print("verify cfg2")
config.verify(cfg2, cfgFormatDemo, typeListDemo)
config.saveFile(nil, cfg2, cfgFormatDemo, typeListDemo)
