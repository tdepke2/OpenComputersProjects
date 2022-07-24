local include = require("include")
local first = include("include_test.first")
local x = include("include_test.x")

local fourth = {}

fourth.first = first
fourth.x = x

return fourth
