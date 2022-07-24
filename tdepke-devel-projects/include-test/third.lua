local include = require("include")
local x = include("include-test.x")
local first = include("include-test.first")

local third = {}

third.x = x
third.first = first

return third
