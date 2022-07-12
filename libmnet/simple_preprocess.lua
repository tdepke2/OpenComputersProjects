


local fs = require("filesystem")
local shell = require("shell")

local args = shell.parse(...)


local function checkFileError(filename, file, err)
  if not file then
    if fs.isDirectory(filename) then
      io.stderr:write("simple_preprocess " .. filename .. ": is a directory\n")
    else
      io.stderr:write("simple_preprocess " .. filename .. ": " .. tostring(err) .. "\n")
    end
    os.exit(1)
  end
end

local function main()
  if args[1] == nil then
    args[1] = "-"
  end
  if args[2] == nil then
    args[2] = "-"
  end
  local inputFile, outputFile, err
  
  -- Attempt to open input file (or use stdin).
  if args[1] == "-" then
    inputFile, err = io.stdin, "missing stdin"
  else
    args[1] = shell.resolve(args[1])
    inputFile, err = io.open(args[1])
  end
  checkFileError(args[1], inputFile, err)
  
  -- Attempt to open output file (or use stdout).
  if args[2] == "-" then
    outputFile, err = io.stdout, "missing stdout"
  else
    args[2] = shell.resolve(args[2])
    outputFile, err = io.open(args[2], "w")
  end
  checkFileError(args[2], outputFile, err)
  
  -- Iterate each line in the file.
  local processedLines = {}
  local line, lineNum = inputFile:read(), 1
  while line do
    outputFile:write("[" .. line .. "]\n")
    local firstNumberSign = string.find(line, "#", 1, true)
    if firstNumberSign and string.match(line, "^%s*#[^#]") then
      processedLines[lineNum] = string.sub(line, 1, firstNumberSign - 1) .. string.sub(line, firstNumberSign + 1) .. "\n"
    else
      processedLines[lineNum] = string.format("io.write(%q)\n", line .. "\n")
    end
    line, lineNum = inputFile:read(), lineNum + 1
  end
  inputFile:close()
  
  local y = true
  
  outputFile:write("RUNNING LOAD...\n")
  
  
  
  -- TODO: just got env working, need to modify so that output goes to another table that we write to the file (write one line at a time).
  -- need a function passed to the load env that can output to this table (basically a print function), then we can achieve same behavior in http://lua-users.org/wiki/SimpleLuaPreprocessor
  -- os.getenv() should be usable from within the preprocessed code (should already be working)
  
  
  
  lineNum = 0
  local fn, result = load(function()
    lineNum = lineNum + 1
    return processedLines[lineNum]
  end, "=(load)", "t", setmetatable({y=y}, {
    __index = _ENV
  }))
  if not fn then
    io.stderr:write("simple_preprocess " .. args[1] .. ": " .. tostring(result) .. "\n")
    os.exit(1)
  end
  local status, result = pcall(fn)
  if not status then
    io.stderr:write("simple_preprocess " .. args[1] .. ": " .. tostring(result) .. "\n")
    os.exit(1)
  end
  
  outputFile:close()
end

main()
