--------------------------------------------------------------------------------
-- Utilities for embedded devices (like drones and microcontrollers). Such
-- devices have very limited on-board EEPROM storage.
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


local embedded = {}


-- Gets an iterator to walk through the library dependencies for a source code
-- file. This is designed to help with sending source code over network
-- communication (useful for remote code upload to devices that use an EEPROM
-- storage and don't have enough space to store the files themselves). The
-- iterator returns source code contents starting from the leaves and working up
-- to the root of the source tree. This means each file will at most depend on
-- previous returned files or itself.
-- 
-- The sourceFilename is the path to the source code file, modPattern is a
-- pattern for the `require()` function equivalent. With the default value for
-- modPattern, the strings `require("")` and `include("")` will be scanned for
-- to find nested libraries in source code. Note that the nested libraries will
-- be searched by package name, not by file path. Also, the include module
-- itself is blacklisted from getting picked up as a dependency (to prevent some
-- complications).
-- 
-- For each call to the iterator, returns the module name (string) and contents
-- of the source file (also string). The module name will be an empty string if
-- the source file corresponds to the original sourceFilename argument. Iterator
-- returns nil after last source file has been returned.
-- 
---@param sourceFilename string
---@param modPattern string|nil
---@return function
function embedded.iterateSrcDependencies(sourceFilename, modPattern)
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

return embedded
