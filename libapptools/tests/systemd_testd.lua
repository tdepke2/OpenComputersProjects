-- This file goes in `/etc/rc.d` so it can be managed by rc. It must be enabled (with rc) to start at boot.

local text = require("text")

local systemd_utils = require("systemd_utils")

local rcInterface = systemd_utils.RcInterface:new("systemd_testd", "systemd_testd.lua - Example Daemon", "/usr/lib/systemd_test_daemon.lua")

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
