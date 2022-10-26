local include = require("include")
local fourth = include("include_test.fourth")
local second = include("include_test.second")
local third = include("include_test.third")

local fifth = {}

fifth.fourth = fourth
fifth.second = second
fifth.third = third

return fifth
