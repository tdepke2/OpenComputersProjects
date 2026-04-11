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


-- Reads a module file and extracts the source code for only the specified
-- fields (variables and functions). The module name is prepended onto each
-- field name so that the table goes away (this make the resulting code more
-- compressible). By removing the table, the fields will now be global, so the
-- prefixLocal parameter can be used to define them as locals.
-- 
-- This can be used with simple_preprocess to insert some library code directly
-- into code that will be loaded onto an EEPROM.
-- 
-- Returns an iterator that gives the next line of source code with each call.
-- 
---@param filename string
---@param moduleName string
---@param prefixLocal boolean
---@param selectedFields table
---@return function
function embedded.extractModuleSource(filename, moduleName, prefixLocal, selectedFields)
  local sourceFile = io.open(filename, "r")
  if not sourceFile then
    error("unable to open file \"" .. filename .. "\" in read mode.")
  end

  local fieldPattern1 = "^%s*" .. moduleName .. "%.([%w_]+)"
  local fieldPattern2 = "^function%s+" .. moduleName .. "%.([%w_]+)"
  local fields = {}

  local lines, lineNum = {}, 1
  local line = sourceFile:read()
  while line do
    local fieldCapture = string.match(line, fieldPattern1) or string.match(line, fieldPattern2)
    if fieldCapture then
      assert(not fields[fieldCapture])
      fields[fieldCapture] = lineNum
    end
    lines[lineNum] = line
    line, lineNum = sourceFile:read(), lineNum + 1
  end
  sourceFile:close()

  local selectedFieldIndex = 1
  local firstLine, fieldLine, lastLine

  local function iter()
    if firstLine then
      if firstLine > lastLine then
        firstLine, fieldLine, lastLine = nil, nil, nil
        return ""
      end

      local result = string.gsub(lines[firstLine], moduleName .. "%.", moduleName .. "_")
      if firstLine == fieldLine and prefixLocal then
        result = "local " .. result
      end
      firstLine = firstLine + 1
      return result
    end

    local field = selectedFields[selectedFieldIndex]
    if not field then
      return nil
    elseif not fields[field] then
      error("in file \"" .. filename .. "\": did not find a field named \"" .. field .. "\".")
    end

    -- Find the first comment line above the field.
    firstLine = fields[field]
    while firstLine > 1 and string.match(lines[firstLine - 1], "^%s*%-%-") do
      firstLine = firstLine - 1
    end

    -- Find the last line. If it's a function then assume this is where we find "end" at the beginning of a line followed by an empty line.
    fieldLine = fields[field]
    lastLine = fieldLine
    if string.match(lines[fieldLine], "^function") then
      while lines[lastLine + 1] and not (string.match(lines[lastLine], "^end%s*$") and string.match(lines[lastLine + 1], "^%s*$")) do
        lastLine = lastLine + 1
      end
    end

    selectedFieldIndex = selectedFieldIndex + 1
    return iter()
  end

  return iter
end

return embedded
