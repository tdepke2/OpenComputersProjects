local include = require("include")
local x = include("include_test.x")
local y = include("include_test.y")

local first = {}

first.x = x
first.y = y

return first
