--------------------------------------------------------------------------------
-- Simple enumerations for Lua.
-- 
-- @see file://libapptools/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


-- Creates a new enumeration from a given table (matches keys to values and vice
-- versa). The given table is intended to use numeric keys and string values,
-- but doesn't have to be a sequence. An error is thrown if there are duplicate
-- values in the table.
-- Based on: https://unendli.ch/posts/2016-07-22-enumerations-in-lua.html
-- 
---@param t table
---@return table
---@nodiscard
local function enum(t)
  local result = {}
  for i, v in pairs(t) do
    if result[v] ~= nil then
      error("duplicate value \"" .. tostring(v) .. "\" defined in enum.", 2)
    end
    result[i] = v
    result[v] = i
  end
  return result
end

-- FIXME should enum protect against indexing an invalid key? maybe nah #######################################################################
-- FIXME this should replace other places in code where enum has been defined ###################
-- FIXME update README #####################################################

return enum
