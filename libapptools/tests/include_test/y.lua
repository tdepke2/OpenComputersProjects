local include = require("include")
--local fifth = include("include_test.fifth")  -- Recursive dependency, doesn't work.

local y = {}

function y.thing()
  return "oof"
end
--y.fifth = fifth

return y
