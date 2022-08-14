--------------------------------------------------------------------------------
-- Just like hexdump command in UNIX. Currently only supports canonical
-- hex+ASCII display.
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


local xprint = require("xprint")

local args = {...}

if not args[1] or args[1] == "-" then
  xprint.hexdump(io.stdin)
else
  local file = io.open(args[1], "r")
  xprint.hexdump(file)
  file:close()
end
