local include = require("include")
local x = include("include_test.x")
local first = include("include_test.first")

local third = {}

third.x = x
third.first = first

return third
