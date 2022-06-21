--[[

--]]

-- OS libraries.
local component = require("component")
local computer = require("computer")
local event = require("event")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local mnet = include("mnet")
local mrpc_server = include("mrpc").newServer(123)

mrpc_server.addDeclarations(dofile("net_testing/mrpc_ocvnc.lua"))

mrpc_server.async.stor_discover("*")

mrpc_server.functions.stor_extract = function() print("ok") end

dlog.osBlockNewGlobals(false)
