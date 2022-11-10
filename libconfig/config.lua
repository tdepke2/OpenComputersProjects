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


local typeList = {
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
    tostring = function(v)
      return string.format("0x%06X", v)
    end,
    fromstring = function(s)
      return tonumber(s)
    end,
    verify = function(v)
      assert(type(v) == "number" and math.floor(v) == v and v >= 0 and v <= 0xFFFFFF, "provided Color must be a 24 bit integer value.")
    end,
  },
  Float2 = {
    tostring = function(v)
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

local cfgFormat = {
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
      _comment_ = "idk what this is...\nmust be at least 3 items",
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
---@param valueName string
---@param address string
---@return string typeVerified
local function verifyType(value, typeNames, valueName, address)
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
    error("at \"" .. address .. "\": " .. valueName .. " does not match any of the allowed types \"" .. typeNames .. "\".")
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

-- Helper function for `config.verify()` to check for errors in configuration.
-- 
---@param cfg table
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
    verifyType(cfg, cfgFormat[1], "value", address)
    return
  end
  
  -- Match keys in cfgFormat with ones in cfg (format fields are skipped). We mark these as processed so they won't get picked up a second time in "_ipairs_" or "_pairs_".
  local processedKeys = {}
  for k, v in pairs(cfgFormat) do
    if not formatFields[k] then
      if cfg[k] == nil then
        error("at \"" .. nextAddress(address, k) .. "\": key must be provided in configuration.")
      end
      processedKeys[k] = true
      verifySubconfig(cfg[k], v, typeList, nextAddress(address, k))
    end
  end
  
  -- Check for "_ipairs" second and iterate sequential keys in cfg.
  if cfgFormat._ipairs_ then
    local valueTypes = cfgFormat._ipairs_[1]
    for i, v in ipairs(cfg) do
      if not processedKeys[i] then
        processedKeys[i] = true
        if type(valueTypes) == "string" then
          verifyType(v, valueTypes, "value", nextAddress(address, i))
        else
          verifySubconfig(v, valueTypes, typeList, nextAddress(address, i))
        end
      end
    end
  end
  
  -- Check for "_pairs" third and iterate remaining keys/values in cfg.
  if cfgFormat._pairs_ then
    local keyTypes, valueTypes = cfgFormat._pairs_[1], cfgFormat._pairs_[2]
    for k, v in pairs(cfg) do
      if not processedKeys[k] then
        local address2 = nextAddress(address, k)
        processedKeys[k] = true
        verifyType(k, keyTypes, "key", address2)
        if type(valueTypes) == "string" then
          verifyType(v, valueTypes, "value", address2)
        else
          verifySubconfig(v, valueTypes, typeList, address2)
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
---@param cfg table
---@param cfgFormat table
---@param typeList table
function config.verify(cfg, cfgFormat, typeList)
  verifySubconfig(cfg, cfgFormat, typeList, "config")
end



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

local id = "^[%a_][%w_]*$"



local function writeValue()
  
end


-- FIXME this is very similar to verification code, can we merge the two somehow? #############################################################
local function writeSubconfig(file, cfg, cfgFormat, typeList, address)
  if type(cfgFormat) ~= "table" then
    error("at \"" .. address .. "\": expected table in configuration format.")
  end
  
  if type(cfgFormat[1]) == "string" then
    local typeVerified = verifyType(cfg, cfgFormat[1], "value", address)
    if typeList[typeVerified] and typeList[typeVerified].tostring then
      local status, result = pcall(typeList[typeVerified].tostring, cfg)
      if not status or type(result) ~= "string" then
        if status then
          result = "result is type " .. type(result)
        end
        error("at \"" .. address .. "\": failed to convert " .. typeVerified .. " to string: " .. tostring(result))
      end
      file:write(result, "\n")
    elseif false then --FIXME #################  type(cfg) == "table" then
      
      -- need to recursively print the table
      
    else
      file:write(tostring(cfg), "\n")
    end
    return
  end
  
  local customOrder = {}
  for k, v in pairs(cfgFormat) do
    if type(v) == "table" and v._order_ then
      customOrder[v._order_] = k
    end
  end
  
  
  -- Collect all table keys and sort them. Based on code used in xprint module.
  local sortedKeys, stringKeys, otherKeys = {}, {}, {}
  for k, v in pairs(cfg) do
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
  
  
  
  
  -- left off here, need to iterate keys in the sortedKeys order, and factor in customOrder if provided
  
  
  
  
  local processedKeys = {}
  for k, v in pairs(cfgFormat) do
    if not formatFields[k] then
      if cfg[k] == nil then
        error("at \"" .. nextAddress(address, k) .. "\": key must be provided in configuration.")
      end
      if type(v) == "table" and v._comment_ then
        file:write("-- ", v._comment_, "\n")    -- FIXME need better comment handling. #######################
      end
      processedKeys[k] = true
      writeSubconfig(file, cfg[k], v, typeList, nextAddress(address, k))
    end
  end
  
  
  
  
end


-- FIXME still need to implement fromstring() handling in typeList. #########################################################



-- 
-- 
---@param filename string
---@param cfg table
---@param cfgFormat table
---@param typeList table
function config.saveFile(filename, cfg, cfgFormat, typeList)
  --local file = io.open(filename, "w")
  --if not file then
    --error("failed to open file \"" .. filename .. "\" for writing.")
  --end
  
  writeSubconfig(io.stdout, cfg, cfgFormat, typeList, "config")
end


--local xprint = require("xprint")
local cfg = config.loadFile("/home/configTest2", cfgFormat, true)
xprint.print({}, cfg)




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
      [0] = "z",
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
  }
}

config.verify(cfg2, cfgFormat, typeList)
