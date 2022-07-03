--------------------------------------------------------------------------------
-- Module loader (improved version of require() function).
-- 
-- @see file://libapptools/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local filesystem = require("filesystem")

local include = {}


-- Enables include() function call as a shortcut to include.load().
setmetatable(include, {
  __call = function(func, arg)
    return include.load(arg)
  end
})

-- Private data members:
-- Tracks loaded modules, each entry is a null-character separated list. Format is: requiresReload, modulePath, modifiedTime, and dependencies.
include.loaded = {}
-- Current depth in the dependency traversal. Starts at 1 for a top-level module and increments for each level down.
include.moduleDepth = 0
-- Table of unique dependencies for each level of include.moduleDepth. Each entry is a null-character separated list.
include.moduleDependencies = nil
-- Table of unique modules that have been checked for a file change since the last top-level module.
include.scannedModules = nil


-- Recursively searches the moduleName and all dependencies for files that
-- changed. Any that changed are unloaded and the same goes for their parents
-- that are descendants of moduleName (other parents are just marked as needing
-- to reload). Modules that have already been checked since the last top-level
-- call to include.load are ignored.
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


-- include.load(moduleName: string): table
-- 
-- Loads a module just like require() does. The difference is that the module
-- will be removed from the internal cache and loaded again if the file
-- modification timestamp changes. This helps resolve the annoying problem where
-- a change is made in a module, the module is included with require() in a
-- source file, and the changes made do not show up during testing (because the
-- module has been cached). Normally you would have to either reboot the machine
-- to force the module to reload, or remove the entry in package.loaded
-- manually. The include.load() function fixes this problem.
function include.load(moduleName)
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
    assert(modulePath and filesystem.exists(modulePath), "Cannot find module \"" .. moduleName .. "\" in search path.")
    --print("Looked up path \"" .. modulePath .. "\"")
  end
  
  include.moduleDepth = include.moduleDepth + 1
  include.moduleDependencies[include.moduleDepth] = ""
  
  -- Attempt to load module if it doesn't appear in package.
  local mod
  if not package.loaded[moduleName] then
    print("Loading module \"" .. moduleName .. "\"")
    local modifiedTime = filesystem.lastModified(modulePath)
    -- Catch errors from require() at the top-level only. This lets us reset the state of traversal before application receives the error.
    if atTopLevel then
      local status
      status, mod = pcall(require, moduleName)
      if not status then
        include.moduleDepth = 0
        include.moduleDependencies = nil
        include.scannedModules = nil
        error(mod)
      end
    else
      mod = require(moduleName)
    end
    include.loaded[moduleName] = "0\0" .. modulePath .. "\0" .. tostring(modifiedTime) .. include.moduleDependencies[include.moduleDepth]
    --print("Added include.loaded entry \"" .. include.loaded[moduleName] .. "\"")
  else
    --print("Keeping module \"" .. moduleName .. "\" at " .. tostring(package.loaded[moduleName]))
    mod = package.loaded[moduleName]
  end
  
  include.moduleDependencies[include.moduleDepth] = nil
  include.moduleDepth = include.moduleDepth - 1
  
  if atTopLevel then
    -- Make sure state has been reset to expected values, and delete unnecessary tables to save some memory.
    assert(include.moduleDepth == 0, "Unexpected stack size while finding dependencies for module \"" .. moduleName .. "\".")
    assert(next(include.moduleDependencies) == nil, "Unexpected remaining dependencies while loading module \"" .. moduleName .. "\".")
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


-- include.isLoaded(moduleName: string): boolean
-- 
-- Check if a module is currently loaded (already in cache).
function include.isLoaded(moduleName)
  return package.loaded[moduleName] ~= nil
end


-- include.reload(moduleName: string): table
-- 
-- Forces a module to load/reload, regardless of the file modification
-- timestamp. Be careful not to use this with system libraries!
function include.reload(moduleName)
  include.unload(moduleName)
  return include.load(moduleName)
end


-- include.unload(moduleName: string)
-- 
-- Unloads the given module (removes it from the internal cache). Be careful not
-- to use this with system libraries!
function include.unload(moduleName)
  print("Unloading module \"" .. moduleName .. "\"")
  if include.loaded[moduleName] then
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


-- include.unloadAll()
-- 
-- Unloads all modules that have been loaded with include(), include.load(),
-- include.reload(), etc. System libraries will not be touched as long as they
-- were loaded through other means, like require().
function include.unloadAll()
  for k, v in pairs(include.loaded) do
    package.loaded[k] = nil
    include.loaded[k] = nil
  end
end


-- include.iterateSrcDependencies(sourceFilename: string[, modPattern: string]):
--   function
-- 
-- Gets an iterator to walk through the library dependencies for a source code
-- file. This is designed to help with sending source code over network
-- communication (useful for remote code upload to devices that use an EEPROM
-- storage and don't have enough space to store the files themselves). The
-- iterator returns source code contents starting from the leaves and working up
-- to the root of the source tree. This means each file will at most depend on
-- previous returned files or itself.
-- 
-- The sourceFilename is the path to the source code file, modPattern is a
-- pattern for the require() function equivalent. With the default value for
-- modPattern, the strings 'require("")' and 'include("")' will be scanned for
-- to find nested libraries in source code. Note that the nested libraries will
-- be searched by package name, not by file path. Also, the include module
-- itself is blacklisted from getting picked up as a dependency (to prevent some
-- complications).
-- 
-- For each call to the iterator, returns the module name (string) and contents
-- of the source file (also string). The module name will be an empty string if
-- the source file corresponds to the original sourceFilename argument. Iterator
-- returns nil after last source file has been returned.
function include.iterateSrcDependencies(sourceFilename, modPattern)
  modPattern = modPattern or "require%(\"([^\"]*)\"%)"
  local srcStack = {sourceFilename}
  local searchedMods = {include=true}
  local sentMods = {}
  
  local function srcIter()
    if not srcStack then
      return
    end
    -- Get source file on top of stack that hasn't been sent yet.
    local srcTop = srcStack[#srcStack]
    while sentMods[srcTop] do
      srcStack[#srcStack] = nil
      srcTop = srcStack[#srcStack]
    end
    
    -- Look up path to file, and get file contents.
    local srcPath = srcTop
    if #srcStack > 1 then
      srcPath = package.searchpath(srcTop, package.path)
    end
    assert(srcPath, "Failed searching dependencies for \"" .. sourceFilename .. "\": cannot find source file \"" .. srcTop .. "\" in search path.")
    print("Checking file " .. srcPath)
    local srcFile, errMessage = io.open(srcPath, "rb")
    assert(srcFile, "Failed searching dependencies for \"" .. sourceFilename .. "\": cannot open source file \"" .. srcTop .. "\": " .. tostring(errMessage))
    local srcCode = srcFile:read("*a")
    srcFile:close()
    
    -- Look for the modPattern or 'include("")' strings. Only count ones we haven't searched before (to protect against circular dependencies).
    searchedMods[srcTop] = true
    local hasNewMods = false
    for modName in string.gmatch(srcCode, modPattern) do
      if not searchedMods[modName] then
        srcStack[#srcStack + 1] = modName
        hasNewMods = true
      end
    end
    for modName in string.gmatch(srcCode, "include%(\"([^\"]*)\"%)") do
      if not searchedMods[modName] then
        srcStack[#srcStack + 1] = modName
        hasNewMods = true
      end
    end
    
    if hasNewMods then
      return srcIter()
    elseif #srcStack > 1 then
      srcStack[#srcStack] = nil
      sentMods[srcTop] = true
      return srcTop, srcCode
    else
      srcStack = nil
      return "", srcCode
    end
  end
  
  return srcIter
end

return include
