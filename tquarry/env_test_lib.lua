local myLib = {}

----[[
function myLibGlobalFunc()
  return true
end
--]]

function myLib.sampleFunc()
  return "hi"
end

local function shallowTablePrint(t)
  if type(t) ~= "table" then
    return tostring(t) .. "\n"
  end
  local str = tostring(t) .. " {\n"
  for k, v in pairs(t) do
    str = str .. "  " .. tostring(k) .. ": " .. tostring(v) .. "\n"
  end
  return str .. "}\n"
end

--[[
local envLevel = _ENV
local i = 1
while envLevel do
  io.write("_ENV __index ^ " .. (i - 1) .. " is:\n" .. shallowTablePrint(envLevel))
  envLevel = getmetatable(envLevel)
  if envLevel then
    io.write("_ENV meta ^ " .. i .. " is:\n" .. shallowTablePrint(envLevel))
    envLevel = rawget(envLevel, "__index")
  else
    io.write("_ENV meta ^ " .. i .. " is:\nnil\n")
  end
  io.write("\n")
  i = i + 1
end
--]]

return myLib
