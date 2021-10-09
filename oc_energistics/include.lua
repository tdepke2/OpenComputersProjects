--[[
Library loader (improved version of require() function).

Extends the functionality of require() to solve an issue with libraries getting
cached and not reloading. The include() function will reload a library if it
detects that the file has been modified. Any user libraries that need to be
loaded should use include() instead of require() for this to work properly
(except for the include module itself). Using include() for system libraries is
not necessary and may not always work. Take a look at the package.loaded
warnings here: https://ocdoc.cil.li/api:non-standard-lua-libs

Right now this has been only tested with individual modules, but should work
with a complete library too if include is used properly.

Example usage:
-- OS libraries (just use require() for these).
local component = require("component")
local robot = require("robot")
local transposer = component.transposer

-- User libraries (must require() include first).
local include = require("include")
local packer = include("packer")
local wnet = include("wnet")
--]]

local filesystem = require("filesystem")

local include = {}

-- Enables include() function call as a shortcut to include.load().
setmetatable(include, {
  __call = function(func, arg)
    return include.load(arg)
  end
})

include.loaded = {}


-- include.load(libraryName: string): table
-- 
-- Loads a library just like require() does. The difference is that the library
-- will be removed from the internal cache and loaded again if the file modified
-- time changes. This helps resolve the annoying problem where a change is made
-- in a library, the library is included with require() in a source file, and
-- the changes made do not show up during testing (because library has been
-- cached). Normally you would have to either reboot the machine to force the
-- library to reload, or remove the entry in package.loaded manually. The
-- include.load() function fixes this problem.
function include.load(libraryName)
  local libraryPath = package.searchpath(libraryName, package.path)
  assert(filesystem.exists(libraryPath), "Cannot find library \"" .. libraryName .. "\" in search path.")
  local modifiedTime = filesystem.lastModified(libraryPath)
  local mod
  
  -- Attempt to reload library if it doesn't appear in package, we don't know the modification time, or modification time changed.
  if not package.loaded[libraryName] or (include.loaded[libraryName] or -1) ~= modifiedTime then
    print("Reloading library " .. libraryName)
    package.loaded[libraryName] = nil
    mod = require(libraryName)
    include.loaded[libraryName] = modifiedTime
  else
    print("Keeping library " .. libraryName)
    mod = package.loaded[libraryName]
  end
  return mod
end


-- include.isLoaded(libraryName: string): boolean
-- 
-- Check if a library is currently loaded (already in cache).
function include.isLoaded(libraryName)
  return package.loaded[libraryName] ~= nil
end


-- include.reload(libraryName: string): table
-- 
-- Forces a library to load/reload, regardless of the file modification time. Be
-- careful not to use this with system libraries!
function include.reload(libraryName)
  package.loaded[libraryName] = nil
  return include.load(libraryName)
end


-- include.unload(libraryName: string)
-- 
-- Unloads the given library (removes it from the internal cache). Be careful
-- not to use this with system libraries!
function include.unload(libraryName)
  package.loaded[libraryName] = nil
end


-- include.unloadAll()
-- 
-- Unloads all libraries that have been loaded with include(), include.load(),
-- include.reload(), etc. System libraries will not be touched as long as they
-- were loaded through other means, like require().
function include.unloadAll()
  for k, v in pairs(include.loaded) do
    package.loaded[k] = nil
    include.loaded[k] = nil
  end
end


return include
