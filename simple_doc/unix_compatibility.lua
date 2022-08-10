--------------------------------------------------------------------------------
-- UNIX compatibility layer for Lua programs designed to run on OpenOS.
-- 
-- This is a minimal implementation for now, but may be expanded to implement
-- more of the OpenOS API in the future. If that happens it would be beneficial
-- to move the code for each OpenOS module into its own file and load these only
-- when needed.
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


local requireOverride = require


if type(_OSVERSION) ~= "string" or not string.find(_OSVERSION, "OpenOS") then
  --local utf8 = require("utf8")
  
  -- The io.open() function has some slightly different behavior on UNIX. If a directory is opened, this function still returns a file handle, but calling read() on it returns nil plus an error message.
  --io.open = function()
    
  --end
  
  local filesystem, shell, unicode = {}, {}, {}
  local openOsApis = {
    filesystem = filesystem,
    shell = shell,
    unicode = unicode,
  }
  
  function filesystem.isDirectory(path)
    assert(type(path) == "string")
    return io.popen("file -b " .. path):read() == "directory"
  end
  
  -- Copied from /lib/shell.lua
  function shell.parse(...)
    local params = table.pack(...)
    local args = {}
    local options = {}
    local doneWithOptions = false
    for i = 1, params.n do
      local param = params[i]
      if not doneWithOptions and type(param) == "string" then
        if param == "--" then
          doneWithOptions = true -- stop processing options at `--`
        elseif param:sub(1, 2) == "--" then
          local key, value = param:match("%-%-(.-)=(.*)")
          if not key then
            key, value = param:sub(3), true
          end
          options[key] = value
        elseif param:sub(1, 1) == "-" and param ~= "-" then
          for j = 2, unicode.len(param) do
            options[unicode.sub(param, j, j)] = true
          end
        else
          table.insert(args, param)
        end
      else
        table.insert(args, param)
      end
    end
    return args, options
  end
  
  function shell.resolve(path, ext)
    return path
  end
  
  function unicode.len(s)
    --return utf8.len
    return string.len(s)
  end
  
  function unicode.sub(s, i, j)
    return string.sub(s, i, j)
  end
  
  -- Modify the behavior of require() to catch any OpenOS modules and return them.
  requireOverride = function(...)
    if openOsApis[select(1, ...)] then
      return openOsApis[select(1, ...)]
    else
      return require(...)
    end
  end
end

return requireOverride
