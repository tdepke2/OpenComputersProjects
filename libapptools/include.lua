--[[
Library loader (improved version of require() function).

Extends the functionality of require() to solve an issue with libraries getting
cached and not reloading. The include() function will reload a library if it
detects that the file has been modified. Any user libraries that need to be
loaded should use include() instead of require() for this to work properly
(except for the include module itself). Using include() for system libraries is
not necessary and may not always work. Take a look at the package.loaded
warnings here: https://ocdoc.cil.li/api:non-standard-lua-libs

In order for include() to work properly, a module must meet these requirements:
  1. It must return a table.
  2. The module must not make any reference back to itself.

Also "included" here is a source tree dependency solver. It's useful for
uploading code to a device via network or other medium. This allows the user to
send software with multiple dependencies to robots/drones/microcontrollers that
only have a small EEPROM storage.

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

-- Tracks file modified timestamps for each module that is loaded.
include.loaded = {}


-- Performs a move (copy) operation from table src into table dest, this allows
-- changing the memory address of the original table. If the dest table has a
-- metatable with the __metatable field defined, an error is raised. If the src
-- table has a reference back to itself, and error is raised as this would imply
-- that the reference was not fully moved.
local function moveTableReference(src, dest)
  -- Clear contents of dest.
  setmetatable(dest, nil)
  for k, _ in next, dest do
    dest[k] = nil
  end
  assert(next(dest) == nil and getmetatable(dest) == nil)
  
  -- Shallow copy contents over.
  for k, v in next, src do
    dest[k] = v
  end
  setmetatable(dest, getmetatable(src))
  
  -- Verify no cyclic references back to src (not perfect, does not check metatables).
  local searched = {}
  local function recursiveSearch(t)
    if searched[t] then
      return
    end
    searched[t] = true
    assert(not rawequal(t, src), "Found a reference back to source table, this is not allowed when using include() to load a module.")
    for k, v in next, t do
      if type(k) == "table" then
        recursiveSearch(k)
      end
      if type(v) == "table" then
        recursiveSearch(v)
      end
    end
  end
  recursiveSearch(dest)
end


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
  assert(libraryPath and filesystem.exists(libraryPath), "Cannot find library \"" .. libraryName .. "\" in search path.")
  local modifiedTime = filesystem.lastModified(libraryPath)
  local lib
  
  -- Attempt to reload library if it doesn't appear in package, we don't know the modification time, or modification time changed.
  if not package.loaded[libraryName] or (include.loaded[libraryName] or -1) ~= modifiedTime then
    if libraryName == "dlog" then
      io.write("Include is reloading lib dlog, was found in package = " .. tostring(package.loaded[libraryName]) .. "\n")
    end
    
    print("Reloading library " .. libraryName)
    local oldModule = package.loaded[libraryName]
    package.loaded[libraryName] = nil
    lib = require(libraryName)
    include.loaded[libraryName] = modifiedTime
    
    -- If this is not the first time the module loaded, we need to purge the newly created one and swap the contents into the previous module.
    if oldModule then
      moveTableReference(lib, oldModule)
      package.loaded[libraryName] = oldModule
    end
  else
    if libraryName == "dlog" then
      io.write("Include found lib dlog already\n")
    end
    
    print("Keeping library " .. libraryName)
    lib = package.loaded[libraryName]
  end
  
  if libraryName == "dlog" then
    io.write("dlog lib = " .. tostring(lib) .. "\n")
  end
  
  return lib
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


-- include.iterateSrcDependencies(sourceFilename: string[, libPattern: string]):
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
-- The sourceFilename is the path to the source code file, libPattern is a
-- pattern for the require() function equivalent. With the default value for
-- libPattern, the strings 'require("")' and 'include("")' will be scanned for
-- to find nested libraries in source code. Note that the nested libraries will
-- be searched by package name, not by file path. Also, the include module
-- itself is blacklisted from getting picked up as a dependency (to prevent some
-- complications).
-- 
-- For each call to the iterator, returns the library name (string) and contents
-- of the source file (also string). The library name will be an empty string if
-- the source file corresponds to the original sourceFilename argument. Iterator
-- returns nil after last source file has been returned.
function include.iterateSrcDependencies(sourceFilename, libPattern)
  libPattern = libPattern or "require%(\"([^\"]*)\"%)"
  local srcStack = {sourceFilename}
  local searchedLibs = {include=true}
  local sentLibs = {}
  
  local function srcIter()
    if not srcStack then
      return
    end
    -- Get source file on top of stack that hasn't been sent yet.
    local srcTop = srcStack[#srcStack]
    while sentLibs[srcTop] do
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
    
    -- Look for the libPattern or 'include("")' strings. Only count ones we haven't searched before (to protect against circular dependencies).
    searchedLibs[srcTop] = true
    local hasNewLibs = false
    for libName in string.gmatch(srcCode, libPattern) do
      if not searchedLibs[libName] then
        srcStack[#srcStack + 1] = libName
        hasNewLibs = true
      end
    end
    for libName in string.gmatch(srcCode, "include%(\"([^\"]*)\"%)") do
      if not searchedLibs[libName] then
        srcStack[#srcStack + 1] = libName
        hasNewLibs = true
      end
    end
    
    if hasNewLibs then
      return srcIter()
    elseif #srcStack > 1 then
      srcStack[#srcStack] = nil
      sentLibs[srcTop] = true
      return srcTop, srcCode
    else
      srcStack = nil
      return "", srcCode
    end
  end
  
  return srcIter
end


return include
