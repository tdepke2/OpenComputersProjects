

-- OS libraries.
local text = require("text")

-- User libraries.
local include = require("include")
local systemd_utils = include("systemd_utils")

local rcInterface = systemd_utils.RcInterface:new(
  "warpd",
  "warpd.lua - Teleportation Network Daemon",
  "/usr/lib/warp_daemon.lua"
)

-- Called by rc for "start" and "restart" commands, and during boot if enabled.
-- Initializes and starts the daemon.
function start(...)
  if select("#", ...) > 0 then
    rcInterface:startAfterBootFinished(...)
  else
    rcInterface:startAfterBootFinished(table.unpack(text.tokenize(args or "")))
  end
end

-- Called by rc for "stop" and "restart" commands. Shuts down the daemon.
function stop()
  rcInterface:requestStop()
end

-- Called by rc for "status" command. Displays status much like the UNIX
-- systemctl program does.
function status()
  rcInterface:status()
end
