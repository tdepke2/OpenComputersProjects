-- Generic module for common stuff
local tdebug = {}

-- Print table (supports nesting).
function tdebug.printTable(t)
  local function printTableHelper(t, spacing)
    for k, v in pairs(t) do
      if type(v) == "table" then
        print(string.format("%s%s: {", spacing, k))
        printTableHelper(v, spacing .. "  ")
        print(string.format("%s}", spacing))
      else
        print(string.format("%s%s: %s", spacing, k, v))
      end
    end
  end
  
  print(t)
  printTableHelper(t, "")
end

return tdebug