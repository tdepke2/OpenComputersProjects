--------------------------------------------------------------------------------
-- Minimalistic Lua preprocessor.
-- 
-- simple_preprocess [input file] [output file] [-h] [--help] [--local-env={}]
-- 
-- @author tdepke2
--------------------------------------------------------------------------------


-- FIXME do we want a man page? #############################################################
-- need to explain format of # lines, the special spwrite function, and example code.
-- If an input or output filename is unspecified or replaced with a dash, it will default to stdin or stdout respectively.



local fs = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")

local args, opts = shell.parse(...)


local function printUsage()
  io.write([[Usage: simple_preprocess [OPTION]... [INPUT-FILE] [OUTPUT-FILE]

Options:
  -h, --help                display help message and exit
  -v, --verbose             print additional debug information to stdout
      --local-env=STRING    data to append to local environment when processing
                            input (format should use serialization library)

For more information, run: man simple_preprocess
]])
end

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
  local inputFilename = (args[1] == nil and "-" or args[1])
  local outputFilename = (args[2] == nil and "-" or args[2])
  if #args > 2 or opts["h"] or opts["help"] then
    printUsage()
    os.exit(0)
  end
  local verbose = (opts["v"] or opts["verbose"])
  local appendEnv
  if opts["local-env"] then
    appendEnv = serialization.unserialize(tostring(opts["local-env"]))
    if type(appendEnv) ~= "table" then
      io.stderr:write("simple_preprocess: provided --local-env argument could not be deserialized to a table value\n")
      os.exit(1)
    end
  end
  
  local inputFile, outputFile, err
  
  -- Attempt to open input file (or use stdin).
  if inputFilename == "-" then
    inputFile, err = io.stdin, "missing stdin"
  else
    inputFilename = shell.resolve(inputFilename)
    inputFile, err = io.open(inputFilename)
  end
  checkFileError(inputFilename, inputFile, err)
  
  -- Attempt to open output file (or use stdout).
  if outputFilename == "-" then
    outputFile, err = io.stdout, "missing stdout"
  else
    outputFilename = shell.resolve(outputFilename)
    outputFile, err = io.open(outputFilename, "w")
  end
  checkFileError(outputFilename, outputFile, err)
  
  -- 
  local outputLines, outputLineNum = {}, 1
  local function spwrite(...)
    outputLines[outputLineNum] = string.rep("%s", select("#", ...)):format(...) .. "\n"
    outputLineNum = outputLineNum + 1
  end
  
  -- Iterate each line in the file. Search for '##' sequence that only has leading whitespace.
  local processedLines, lineNum = {}, 1
  local line = inputFile:read()
  while line do
    local firstNumberSigns = string.find(line, "##", 1, true)
    if firstNumberSigns and string.match(line, "^%s*##[^#]") then
      -- Found a preprocessor directive, if it's a call to spwrite() then paste any leading whitespace into the first argument to preserve alignment.
      local spwriteIndexEnd = select(2, string.find(line, "^%s*spwrite%s*%(", firstNumberSigns + 2))
      local leadSpacing = string.sub(line, 1, firstNumberSigns - 1)
      
      if spwriteIndexEnd and #leadSpacing > 0 then
        local endParenthesis = string.find(line, "^%s*%)", spwriteIndexEnd + 1)
        processedLines[lineNum] = leadSpacing .. string.sub(line, firstNumberSigns + 2, spwriteIndexEnd) .. "\"" .. leadSpacing .. (endParenthesis and "\"" or "\", ") .. string.sub(line, spwriteIndexEnd + 1) .. "\n"
      else
        processedLines[lineNum] = leadSpacing .. string.sub(line, firstNumberSigns + 2) .. "\n"
      end
    else
      processedLines[lineNum] = string.format("spwrite(%q)\n", line)
    end
    line, lineNum = inputFile:read(), lineNum + 1
  end
  inputFile:close()
  
  local y = true
  
  if verbose then
    io.write("################# PREPARED FILE ##################\n")
    io.write(table.concat(processedLines))
    io.write("(END)\n")
  end
  
  
  -- TODO: just got env working, need to modify so that output goes to another table that we write to the file (write one line at a time).
  -- need a function passed to the load env that can output to this table (basically a print function), then we can achieve same behavior in http://lua-users.org/wiki/SimpleLuaPreprocessor
  -- os.getenv() should be usable from within the preprocessed code (should already be working)
  
  
  
  lineNum = 0
  local fn, result = load(function()
    lineNum = lineNum + 1
    return processedLines[lineNum]
  end, "=(load)", "t", setmetatable({spwrite=spwrite, y=y}, {
    __index = _ENV
  }))
  if not fn then
    io.stderr:write("simple_preprocess " .. inputFilename .. ": " .. tostring(result) .. "\n")
    os.exit(1)
  end
  local status, result = pcall(fn)
  if not status then
    io.stderr:write("simple_preprocess " .. inputFilename .. ": " .. tostring(result) .. "\n")
    os.exit(1)
  end
  
  if verbose then
    io.write("\n################## OUTPUT FILE ###################\n")
    io.write(table.concat(outputLines))
    io.write("(END)\n")
  end
  
  for _, line in ipairs(outputLines) do
    outputFile:write(line)
  end
  
  outputFile:close()
end

main()
