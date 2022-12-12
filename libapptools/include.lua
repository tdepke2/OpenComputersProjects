--------------------------------------------------------------------------------
-- Module loader (improved version of require() function).
-- 
-- @see file://libapptools/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local filesystem = require("filesystem")

local include = {}


-- FIXME there are some places in code where require() has been used instead of include(), need to fix! ########################################################


-- Enables include() function call as a shortcut to include.load().
setmetatable(include, {
  __call = function(func, ...)
    return include.load(...)
  end
})

-- Private data members:
-- When enabled, status messages are printed to standard output.
local includeVerboseOutput = true
-- When enabled, file timestamp checking and dependency tracking are disabled for performance.
local includeOptimizeMode = false
-- Tracks loaded module metadata, each entry is a null-character separated list. Format is: requiresReload, modulePath, modifiedTime, and dependencies.
include.loaded = {}
-- Current depth in the dependency traversal. Starts at 1 while loading a top-level module and increments for each level down.
include.moduleDepth = 0
-- Table of unique dependencies for each level of include.moduleDepth. Each entry is a null-character separated list.
include.moduleDependencies = nil
-- Table of unique modules that have been checked for a file change since the last top-level module.
include.scannedModules = nil
-- Tracks references to modules loaded with include. This was just used for debugging to confirm there are no dangling references after a module is unloaded and garbage collection kills it.
--include.weakModuleReferences = setmetatable({}, {__mode = "k"})


---@docdef
-- 
-- Configure mode of operation for include. Usually the mode can be left as is,
-- but other modes allow silencing output and disabling some features for
-- performance. If newMode is provided, the mode is set to this value. The valid
-- modes are:
-- 
-- * `debug` (default mode, timestamp checking and status messages are enabled)
-- * `release` (timestamp checking enabled, status messages disabled)
-- * `optimize1` (timestamp checking disabled)
-- 
-- Using `optimize1` will basically make `include.load()` function the same as
-- `include.requireWithMemCheck()`. After setting the mode, the current mode is
-- returned.
-- 
---@param newMode string|nil
---@return string
function include.mode(newMode)
  local modes = {"debug", "release", "optimize1"}
  if not newMode then
    return modes[(includeVerboseOutput and 0 or 1) + (includeOptimizeMode and 1 or 0) + 1]
  end
  
  if newMode == modes[1] then
    includeVerboseOutput = true
    includeOptimizeMode = false
  elseif newMode == modes[2] then
    includeVerboseOutput = false
    includeOptimizeMode = false
  elseif newMode == modes[3] then
    includeVerboseOutput = false
    includeOptimizeMode = true
  else
    error("specified mode \"" .. tostring(newMode) .. "\" is not a valid mode.")
  end
  return newMode
end


---@docdef
-- 
-- Simple wrapper for the `require()` function that suppresses errors about
-- memory allocation while loading a module. Memory allocation errors can happen
-- occasionally even if a given system has sufficient RAM. Up to three attempts
-- are made, then the error is just passed along.
-- 
---@param moduleName string
---@return any module
function include.requireWithMemCheck(moduleName)
  local status, result
  local attempts = 1
  while attempts <= 3 do
    if includeVerboseOutput then
      print("Loading module \"" .. tostring(moduleName) .. "\"")
    end
    status, result = pcall(require, moduleName)
    if status then
      --include.weakModuleReferences[result] = moduleName
      return result
    elseif not string.find(result, "not enough memory", 1, true) then
      error(result)
    end
    if includeVerboseOutput then
      print("\27[31mFailed to allocate enough memory, retrying...\27[0m")
    end
    attempts = attempts + 1
  end
  error(result)
end


-- Recursively searches the moduleName and all dependencies for files that
-- changed. Any that changed are unloaded and the same goes for their parents
-- that are descendants of moduleName (other parents are just marked as needing
-- to reload). Modules that have already been checked since the last top-level
-- call to include.load are ignored.
-- 
---@param moduleName string
local function unloadChangedModules(moduleName)
  --print("unloadChangedModules for \"" .. moduleName .. "\"")
  if not include.loaded[moduleName] or include.scannedModules[moduleName] then
    --print("Module notLoaded = " .. tostring(not include.loaded[moduleName]) .. ", scanned = " .. tostring(include.scannedModules[moduleName]))
    return
  end
  include.scannedModules[moduleName] = true
  
  -- Step through each field in include.loaded for this module. Check if the module needs to reload, then do recursive calls for children.
  local modulePath
  local i = 1
  for x in string.gmatch(include.loaded[moduleName], "[^\0]+") do
    if i == 1 then
    elseif i == 2 then
      modulePath = x
    elseif i == 3 then
      if tostring(filesystem.lastModified(modulePath)) ~= x then
        include.unload(moduleName)
      end
    else
      unloadChangedModules(x)
    end
    i = i + 1
  end
  
  -- After recursion finished, a child may have marked parent as requiring a reload.
  if include.loaded[moduleName] and string.sub(include.loaded[moduleName], 1, 1) == "1" then
    --print("The parent \"" .. moduleName .. "\" still needs to unload")
    include.unload(moduleName)
  end
end


---@docdef
-- 
-- Loads a module just like `require()` does. The difference is that the module
-- will be removed from the internal cache and loaded again if the file
-- modification timestamp changes. This helps resolve the annoying problem where
-- a change is made in a module, the module is included with `require()` in a
-- source file, and the changes made do not show up during testing (because the
-- module has been cached). Normally you would have to either reboot the machine
-- to force the module to reload, or remove the entry in `package.loaded`
-- manually. The `include.load()` function fixes this problem.
-- 
-- The properties argument can be a comma-separated string of values. Currently
-- only the string `optional` is supported which allows this function to return
-- nil if the module is not found in the search path.
-- 
---@param moduleName string
---@param properties string|nil
---@return any module
function include.load(moduleName, properties)
  if includeOptimizeMode then
    -- If running in optimized mode, bypass all of the timestamp and dependency checking behavior.
    if not package.loaded[moduleName] then
      local modulePath = package.searchpath(moduleName, package.path)
      if not (modulePath and filesystem.exists(modulePath)) then
        assert(properties and string.find(properties, "optional"), "cannot find module \"" .. moduleName .. "\" in search path.")
        return nil
      end
      local mod = include.requireWithMemCheck(moduleName)
      include.loaded[moduleName] = "0\0" .. modulePath .. "\0" .. "0"
      return mod
    else
      return package.loaded[moduleName]
    end
  end
  
  local atTopLevel = (include.moduleDepth == 0)
  if atTopLevel then
    include.moduleDependencies = {}
    include.scannedModules = {}
  end
  unloadChangedModules(moduleName)
  
  -- Find file path to the module using a cached value or by using package.searchpath().
  local modulePath
  if include.loaded[moduleName] then
    modulePath = string.match(include.loaded[moduleName], ".\0([^\0]+)")
    --print("Found cached path \"" .. modulePath .. "\"")
  end
  if not modulePath or not filesystem.exists(modulePath) then
    modulePath = package.searchpath(moduleName, package.path)
    if not (modulePath and filesystem.exists(modulePath)) then
      assert(properties and string.find(properties, "optional"), "cannot find module \"" .. moduleName .. "\" in search path.")
      return nil
    end
    --print("Looked up path \"" .. modulePath .. "\"")
  end
  
  include.moduleDepth = include.moduleDepth + 1
  include.moduleDependencies[include.moduleDepth] = ""
  
  -- Attempt to load module if it doesn't appear in package.
  local mod
  if not package.loaded[moduleName] then
    if include.loaded[moduleName] and includeVerboseOutput then
      print("\27[33mWarning: module \"" .. moduleName .. "\" was forcibly removed from package.loaded\27[0m")
    end
    local modifiedTime = filesystem.lastModified(modulePath)
    -- Catch errors from require() at the top-level only. This lets us reset the state of traversal before application receives the error.
    if atTopLevel then
      local status
      status, mod = pcall(include.requireWithMemCheck, moduleName)
      if not status then
        include.moduleDepth = 0
        include.moduleDependencies = nil
        include.scannedModules = nil
        error(mod)
      end
    else
      mod = include.requireWithMemCheck(moduleName)
    end
    include.loaded[moduleName] = "0\0" .. modulePath .. "\0" .. tostring(modifiedTime) .. include.moduleDependencies[include.moduleDepth]
    --print("Added include.loaded entry \"" .. include.loaded[moduleName] .. "\"")
  else
    --print("Keeping module \"" .. moduleName .. "\" at " .. tostring(package.loaded[moduleName]))
    mod = package.loaded[moduleName]
    if not include.loaded[moduleName] and includeVerboseOutput then
      print("\27[33mWarning: module \"" .. moduleName .. "\" already exists in package.loaded\27[0m")
    end
  end
  
  include.moduleDependencies[include.moduleDepth] = nil
  include.moduleDepth = include.moduleDepth - 1
  
  if atTopLevel then
    -- Make sure state has been reset to expected values, and delete unnecessary tables to save some memory.
    assert(include.moduleDepth == 0, "unexpected moduleDepth size while finding dependencies for module \"" .. moduleName .. "\".")
    assert(next(include.moduleDependencies) == nil, "unexpected remaining dependencies while loading module \"" .. moduleName .. "\".")
    include.moduleDependencies = nil
    include.scannedModules = nil
  else
    -- Confirm the module is not listed in the dependencies already before adding it.
    if not string.find(include.moduleDependencies[include.moduleDepth] .. "\0", "\0" .. moduleName .. "\0", 1, true) then
      include.moduleDependencies[include.moduleDepth] = include.moduleDependencies[include.moduleDepth] .. "\0" .. moduleName
    end
  end
  
  return mod
end


---@docdef
-- 
-- Check if a module is currently loaded (already in cache).
-- 
---@param moduleName string
---@return boolean
function include.isLoaded(moduleName)
  return package.loaded[moduleName] ~= nil
end


---@docdef
-- 
-- Forces a module to load/reload, regardless of the file modification
-- timestamp. Be careful not to use this with system libraries!
-- 
---@param moduleName string
---@return any module
function include.reload(moduleName)
  include.unload(moduleName)
  return include.load(moduleName)
end


---@docdef
-- 
-- Unloads the given module (removes it from the internal cache). Be careful not
-- to use this with system libraries!
-- 
---@param moduleName string
function include.unload(moduleName)
  if includeVerboseOutput then
    print("Unloading module \"" .. moduleName .. "\"")
  end
  if not includeOptimizeMode and include.loaded[moduleName] then
    -- Set all immediate dependents as requiring a reload.
    for k, v in pairs(include.loaded) do
      if string.find(v .. "\0", "\0" .. moduleName .. "\0", 1, true) then
        --print("  Marking \"" .. k .. "\" as requiring reload")
        include.loaded[k] = "1" .. string.sub(include.loaded[k], 2)
      end
    end
  end
  package.loaded[moduleName] = nil
  include.loaded[moduleName] = nil
end


---@docdef
-- 
-- Unloads all modules that have been loaded with `include()`, `include.load()`,
-- `include.reload()`, etc. System libraries will not be touched as long as they
-- were loaded through other means, like `require()`.
function include.unloadAll()
  for k, v in pairs(include.loaded) do
    package.loaded[k] = nil
    include.loaded[k] = nil
  end
end

return include
