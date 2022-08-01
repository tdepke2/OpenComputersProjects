--------------------------------------------------------------------------------
-- Simple daemon for setting hostname at boot. This lets computers with a shared
-- filesystem individually set their hostname (the hostname usually lives in
-- /etc/hostname).
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


local computer = require("computer")

local hosts = {
  ["1315ba5c-c95c-4f7f-ab3f-80fd65d3a9a4"] = "my_host"
}


function start()
  local hostname = hosts[computer.address()]
  if hostname then
    os.setenv("HOSTNAME_SEPARATOR", hostname and #hostname > 0 and ":" or "")
    os.setenv("HOSTNAME", hostname)
  end
end
