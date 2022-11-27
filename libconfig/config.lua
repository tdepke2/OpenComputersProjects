--------------------------------------------------------------------------------
-- Provides a flexible interface for defining a configuration structure, with
-- the ability to save and load from a file. Defining the configuration format
-- is done with a single table, and optionally a list of custom data types.
-- Strict type checking is optional and can be used to verify the configuration
-- for user-made errors.
-- 
-- @see file://libconfig/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local config = {}

-- Meta-fields used in defining the config format.
local formatFields = {
  _comment_ = true,
  _order_ = true,
  _pairs_ = true,
  _ipairs_ = true,
}

-- Lua types that type() could return, these can be used to specify key/value types in config format.
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


-- Checks if a value is a free Lua identifier (a string, contains only
-- alphanumeric characters and underscores, doesn't start with a number, and not
-- a reserved word). If this function returns true, the value is safe to use as
-- a table key without needing to wrap it in brackets.
-- 
---@param v any
---@return boolean
local function isFreeIdentifier(v)
  return (type(v) == "string" and string.find(v, "^[%a_][%w_]*$") and not luaReservedWords[v])
end


---@docdef
-- 
-- Load configuration from a text file and return it. The file is expected to
-- contain executable Lua code, but doesn't need to have the structure specified
-- in `cfgFormat` (no verification is done). If `defaultIfMissing` is true, the
-- default config is returned if the file cannot be opened. Use `localEnv` to
-- provide a custom environment during file code execution. This defaults to
-- `_ENV` but an empty table could be used, for example, to prevent code in the
-- file from accessing external globals (make sure that `math.huge` is still
-- defined if using this method).
-- 
---@param filename string
---@param cfgFormat table
---@param defaultIfMissing boolean
---@param localEnv table|nil
---@return table cfg
function config.loadFile(filename, cfgFormat, defaultIfMissing, localEnv)
  localEnv = localEnv or _ENV
  local file = io.open(filename, "r")
  local cfg
  if file then
    file:close()
    cfg = {}
    
    -- Add new loadEnv with metamethods to index back to localEnv. New global variables in config will be added in cfg instead of modifying the current environment.
    local loadEnv = setmetatable({}, {
      __index = localEnv,
      __newindex = function(t, k, v)
        rawset(t, k, v)
        cfg[k] = v
      end,
    })
    
    local fn, err = loadfile(filename, "t", loadEnv)
    if not fn then
      error("failed to load config: " .. tostring(err) .. "\n")
    end
    local status, result = pcall(fn)
    if not status then
      error("failed to load config: " .. tostring(result) .. "\n")
    end
  elseif defaultIfMissing then
    cfg = config.loadDefaults(cfgFormat)
  else
    error("failed to open file \"" .. filename .. "\" for reading.")
  end
  
  return cfg
end


---@docdef
-- 
-- Get the default configuration and return it. Depending on how `cfgFormat` is
-- structured, the result may or may not be a valid config format.
-- 
---@param cfgFormat table
---@return table cfg
function config.loadDefaults(cfgFormat)
  local function getDefaults(t)
    if type(t[1]) == "string" then
      return t[2]
    end
    
    local result = {}
    for k, v in pairs(t) do
      if not formatFields[k] then
        result[k] = getDefaults(v)
      elseif k == "_pairs_" or k == "_ipairs_" then
        -- The "_ipairs_" field has value types defined in key 1, "_pairs_" has key types and value types in keys 1 and 2 respectively. Store this offset in valueTypeIndex.
        local valueTypeIndex = (k == "_pairs_" and 2 or 1)
        for pairKey, pairVal in pairs(v) do
          if type(pairKey) ~= "number" then
            result[pairKey] = pairVal
          elseif pairKey <= 0 or pairKey > valueTypeIndex or math.floor(pairKey) ~= pairKey then
            -- In order to allow default values at the first integer keys reserved for "_pairs_" and "_ipairs_", we subtract valueTypeIndex for larger indices to normalize the value.
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
  
  return getDefaults(cfgFormat)
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
      if typeList[typeName][1] then
        -- The typeList for this type contains a sequence of valid values, if none of them match then the current value is invalid.
        for _, v in ipairs(typeList[typeName]) do
          if v == value then
            typeVerified = typeName
            break
          end
        end
        if typeVerified then
          break
        else
          typeCheckError = "no match found for options of type " .. typeName
        end
      else
        -- The typeList for this type is not a sequence, and should define a function to handle the type checking (with table key "verify").
        local status, result = pcall(typeList[typeName].verify or function() end, value)
        if status then
          typeVerified = typeName
          break
        else
          typeCheckError = result
        end
      end
    else
      error("at " .. address .. ": undefined type \"" .. typeName .. "\".")
    end
  end
  
  if typeVerified then
    return typeVerified
  elseif typeCheckError then
    error("at " .. address .. ": bad " .. valueName .. ": " .. tostring(typeCheckError))
  end
  error("at " .. address .. ": " .. valueName .. " with type \"" .. type(value) .. "\" does not match any of the allowed types \"" .. typeNames .. "\".")
end


-- Helper function to concatenate the next key onto the address, using quotes
-- for strings where appropriate.
-- 
---@param address string
---@param key any
---@return string
local function nextAddress(address, key)
  if type(key) == "string" then
    return address .. "[" .. string.format("%q", key):gsub("\\\n","\\n") .. "]"
  else
    return address .. "[" .. tostring(key) .. "]"
  end
end


-- Helper function for `config.verify()` to check for errors in configuration.
-- 
---@param cfg any
---@param cfgFormat table
---@param typeList table
---@param address string
local function verifySubconfig(cfg, cfgFormat, typeList, address)
  if type(cfgFormat) ~= "table" then
    error("at " .. address .. ": expected table in configuration format.")
  end
  
  -- If first index in cfgFormat is a string, the table represents a value definition.
  -- Format: `{<type names>, [default value], [comment]}`.
  if type(cfgFormat[1]) == "string" then
    verifyType(cfg, cfgFormat[1], typeList, "value", address)
    return
  end
  
  -- Check for "_ipairs_" first and iterate sequential keys in cfg. We mark these as processed so they won't get picked up a second time in the following iterations.
  -- Format: `_ipairs_ = {<value type names>|<sub-config>, [2] = [default value 1], [3] = [default value 2], ...}`.
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
  
  -- Match keys in cfgFormat with ones in cfg (format fields are skipped).
  for k, v in pairs(cfgFormat) do
    if not (processedKeys[k] or formatFields[k]) then
      processedKeys[k] = true
      verifySubconfig(cfg[k], v, typeList, nextAddress(address, k))
    end
  end
  
  -- Check for "_pairs_" third and iterate remaining keys/values in cfg.
  -- Format: `_pairs_ = {<key type names>, <value type names>|<sub-config>, [default key 1] = [default value 1], ...}`.
  if cfgFormat._pairs_ then
    local keyTypes, valueTypes = cfgFormat._pairs_[1], cfgFormat._pairs_[2]
    for k, v in pairs(cfg) do
      if not processedKeys[k] then
        local address2 = nextAddress(address, k)
        processedKeys[k] = true
        verifyType(k, keyTypes, typeList, "key", address2)
        if type(valueTypes) == "string" then
          verifyType(v, valueTypes, typeList, "value", address2)
        else
          verifySubconfig(v, valueTypes, typeList, address2)
        end
      end
    end
  end
  
  -- Confirm no extra fields are defined in cfg that we didn't match previously.
  for k, v in pairs(cfg) do
    if not processedKeys[k] then
      error("at " .. nextAddress(address, k) .. ": key is undefined in configuration format.")
    end
  end
end


---@docdef
-- 
-- Checks the format of config `cfg` to make sure it matches cfgFormat. An error
-- is thrown if any inconsistencies with the format are found.
-- 
---@param cfg any
---@param cfgFormat table
---@param typeList table
function config.verify(cfg, cfgFormat, typeList)
  if type(cfgFormat) ~= "table" then
    error("at config: expected table in configuration format.")
  end
  
  if cfgFormat._pairs_ or cfgFormat._ipairs_ then
    error("at config: _pairs_ and _ipairs_ are not allowed in first level of configuration format.")
  end
  
  -- Match keys in cfgFormat with ones in cfg (format fields are skipped).
  local processedKeys = {}
  for k, v in pairs(cfgFormat) do
    if not formatFields[k] then
      if not isFreeIdentifier(k) then
        error("at " .. nextAddress("config", k) .. ": keys in first level of configuration must be non-reserved string identifiers.")
      end
      processedKeys[k] = true
      verifySubconfig(cfg[k], v, typeList, nextAddress("config", k))
    end
  end
  
  -- Confirm no extra fields are defined in cfg that we didn't match previously.
  for k, v in pairs(cfg) do
    if not processedKeys[k] then
      error("at " .. nextAddress("config", k) .. ": key is undefined in configuration format.")
    end
  end
end


-- Writes a value out to the given file. This uses `typeNames` and
-- `verifyType()` if provided to determine if the value is a custom type.
-- Includes checking when `valueName` is the string `key` to wrap the value in
-- brackets.
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
      error("at " .. address .. ": failed to convert " .. typeVerified .. " to string: " .. tostring(result))
    end
    value = result
    -- Pseudo type for strings that need to be written as a Lua chunk (and not wrapped in quotes like normal strings, the below code does this).
    valueType = "string_code"
  end
  
  -- Brackets are needed for table keys (except when the key is a string, valid identifier, and not a reserved word).
  local addBrackets = (valueName == "key")
  if addBrackets and isFreeIdentifier(value) then
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
  elseif valueType == "number" then
    -- Special cases for NaN and infinity.
    if value ~= value then
      file:write("0/0")
    elseif value == math.huge then
      file:write("math.huge")
    elseif value == -math.huge then
      file:write("-math.huge")
    else
      file:write(tostring(value))
    end
  else
    file:write(tostring(value))
  end
  
  if addBrackets then
    file:write("]", endOfLine)
  else
    file:write(endOfLine)
  end
end


-- Gets an iterator for looping over the union of keys in `a` and `b`.
-- 
---@param a table
---@param b table
---@return function iter
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


-- Creates a sequence of the union of keys in `cfg` and `cfgFormat` where the
-- keys are sorted. The sort ordering puts numeric keys first (ascending),
-- string keys second (ascending), and all other keys last. This respects
-- "_order_" meta-fields in the config format to provide custom ordering.
-- 
---@param cfg table
---@param cfgFormat table
---@return table sortedKeys
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
  
  -- Search for cfg keys that have a corresponding "_order_" field in cfgFormat. This marks an override for the ordering.
  local customOrder = setmetatable({}, {
    __index = function() return math.huge end
  })
  for _, v in ipairs(sortedKeys) do
    local formatValue = cfgFormat[v]
    if type(formatValue) == "table" and formatValue._order_ then
      customOrder[v] = formatValue._order_
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
  
  return sortedKeys
end


-- Writes a string to the file, prepending a double-dash for each line (except
-- for leading empty lines).
-- 
---@param file file*
---@param comment string
---@param spacing string
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


-- Helper function for `config.saveFile()` to write the configuration to a file.
-- 
-- NOTE: This function is fairly similar to `verifySubconfig()`, it just does
-- file I/O instead of type checking. Maybe there is an elegant way to combine
-- the two (might add extra complexity and not be worth it)?
-- 
---@param file file*
---@param cfg any
---@param cfgFormat table
---@param typeList table
---@param address string
---@param spacing string
local function writeSubconfig(file, cfg, cfgFormat, typeList, address, spacing)
  if type(cfgFormat) ~= "table" then
    error("at " .. address .. ": expected table in configuration format.")
  end
  
  -- Special case to handle first level of cfg. The first level is written to the file such that the values are not within a table.
  local endOfLine = ",\n"
  if #spacing <= 2 then
    endOfLine = "\n"
  end
  
  -- If first index in cfgFormat is a string, the table represents a value definition.
  if type(cfgFormat[1]) == "string" then
    writeValue(file, cfg, cfgFormat[1], typeList, "value", address, spacing, endOfLine)
    return
  end
  
  local newSpacing = spacing .. "  "
  if spacing ~= "" then
    file:write("{\n")
  end
  
  local sortedKeys = sortKeys(cfg, cfgFormat)
  
  -- Check for "_ipairs_" first and iterate sequential keys in cfg. We mark these as processed so they won't get picked up a second time in the following iterations.
  local processedKeys = {}
  if cfgFormat._ipairs_ then
    local valueTypes = cfgFormat._ipairs_[1]
    for i, v in ipairs(cfg) do
      processedKeys[i] = true
      file:write(spacing)
      if type(valueTypes) == "string" then
        writeValue(file, v, valueTypes, typeList, "value", nextAddress(address, i), newSpacing, ",\n")
      else
        writeSubconfig(file, v, valueTypes, typeList, nextAddress(address, i), newSpacing)
      end
    end
  end
  
  -- Match keys in cfgFormat with existing/non-existing ones in cfg second. Iterates with sortedKeys for a defined ordering.
  for i = 1, #sortedKeys do
    local k = sortedKeys[i]
    local v = cfgFormat[k]
    if not processedKeys[k] and v then
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
  
  -- Check for "_pairs_" third and iterate remaining keys/values in cfg (we already got all of the cfgFormat ones in above step). Iterates with sortedKeys for a defined ordering.
  if cfgFormat._pairs_ then
    local keyTypes, valueTypes = cfgFormat._pairs_[1], cfgFormat._pairs_[2]
    for i = 1, #sortedKeys do
      local k = sortedKeys[i]
      if not processedKeys[k] then
        local address2 = nextAddress(address, k)
        processedKeys[k] = true
        file:write(spacing)
        writeValue(file, k, keyTypes, typeList, "key", address2, newSpacing, " = ")
        if type(valueTypes) == "string" then
          writeValue(file, cfg[k], valueTypes, typeList, "value", address2, newSpacing, ",\n")
        else
          writeSubconfig(file, cfg[k], valueTypes, typeList, address2, newSpacing)
        end
      end
    end
  end
  
  if spacing ~= "" then
    file:write(string.sub(spacing, 3), "}", endOfLine)
  end
end


---@docdef
-- 
-- Saves the configuration to a file. The filename can be `-` to send the config
-- to standard output instead. This does some minor verification of `cfg` to
-- determine types and such when serializing values to strings. Errors may be
-- thrown if the config format is not met.
-- 
---@param filename string
---@param cfg any
---@param cfgFormat table
---@param typeList table
function config.saveFile(filename, cfg, cfgFormat, typeList)
  local file = (filename == "-" and io.stdout or io.open(filename, "w"))
  if not file then
    error("failed to open file \"" .. filename .. "\" for writing.")
  end
  
  writeSubconfig(file, cfg, cfgFormat, typeList, "config", "")
  
  if filename ~= "-" then
    file:close()
  end
end

return config
