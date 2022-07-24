local include = require("include")
local x = include("include-test.x")
local y = include("include-test.y")

local first = {}

first.x = x
first.y = y

return first
