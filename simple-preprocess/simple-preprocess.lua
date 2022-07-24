--------------------------------------------------------------------------------
-- Minimalistic Lua preprocessor.
-- 
-- @see file://simple-preprocess/README.md
-- @author tdepke2
--------------------------------------------------------------------------------


local fs = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")

local USAGE_STRING = [[Usage: simple-preprocess [OPTION]... [INPUT-FILE] [OUTPUT-FILE]

Options:
  -h, --help                display help message and exit
  -v, --verbose             print additional debug information to stdout
      --local-env=STRING    data to append to local environment when processing
                            input (format should use serialization library)

For more information, run: man simple-preprocess
]]


-- Check if a file was opened successfully, and raise an error if not.
local function checkFileError(filename, file, err)
  if not file then
    if fs.isDirectory(filename) then
      io.stderr:write("simple-preprocess " .. filename .. ": is a directory\n")
    else
      io.stderr:write("simple-preprocess " .. filename .. ": " .. tostring(err) .. "\n")
    end
    os.exit(2)
  end
end


local args, opts = shell.parse(...)

-- Check command line options, open files, start preprocessor, and write results
-- to output.
local function main()
  local inputFilename = (args[1] == nil and "-" or args[1])
  local outputFilename = (args[2] == nil and "-" or args[2])
  if #args > 2 or opts["h"] or opts["help"] then
    io.write(USAGE_STRING)
    os.exit(0)
  end
  local verbose = (opts["v"] or opts["verbose"])
  local appendEnv = {}
  if opts["local-env"] then
    appendEnv = serialization.unserialize(tostring(opts["local-env"]))
    if type(appendEnv) ~= "table" then
      io.stderr:write("simple-preprocess: provided --local-env argument could not be deserialized to a table value\n")
      os.exit(2)
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
  
  -- The spwrite function (simple-preprocess write) behaves very similar to
  -- print(), except that output is written to the processed file and no
  -- whitespace or tabs are inserted between arguments (besides a newline at the
  -- end). This function is available within the preprocessor environment.
  local outputLines, outputLineNum = {}, 1
  local function spwrite(...)
    outputLines[outputLineNum] = string.rep("%s", select("#", ...)):format(...) .. "\n"
    outputLineNum = outputLineNum + 1
  end
  
  -- Add a directive (code for preprocessor to run) to the output. Special case
  -- for spwrite() calls since tab alignment in the output can get a bit funky.
  local processedLines, lineNum = {}, 1
  local function addDirective(line, prefixStart, prefixSize)
    -- If the directive is a call to spwrite(), paste any leading whitespace into the first argument to preserve alignment.
    local spwriteIndexEnd = select(2, string.find(line, "^%s*spwrite%s*%(", prefixStart + prefixSize))
    local leadSpacing = string.sub(line, 1, prefixStart - 1)
    
    if spwriteIndexEnd and #leadSpacing > 0 then
      local endParenthesis = string.find(line, "^%s*%)", spwriteIndexEnd + 1)
      processedLines[lineNum] = leadSpacing .. string.sub(line, prefixStart + prefixSize, spwriteIndexEnd) .. "\"" .. leadSpacing .. (endParenthesis and "\"" or "\", ") .. string.sub(line, spwriteIndexEnd + 1) .. "\n"
    else
      processedLines[lineNum] = leadSpacing .. string.sub(line, prefixStart + prefixSize) .. "\n"
    end
  end
  
  -- Iterate each line in the file. Search for '##' or '--##' sequence that only has leading whitespace.
  local line = inputFile:read()
  while line do
    local firstNumberSigns = string.find(line, "##", 1, true)
    if firstNumberSigns and string.match(line, "^%s*##[^#]") then
      addDirective(line, firstNumberSigns, 2)
    elseif firstNumberSigns and string.match(line, "^%s*%-%-##[^#]") then
      addDirective(line, firstNumberSigns - 2, 4)
    else
      processedLines[lineNum] = string.format("spwrite(%q)\n", line)
    end
    line, lineNum = inputFile:read(), lineNum + 1
  end
  inputFile:close()
  
  if verbose then
    io.write("################# PREPARED FILE ##################\n")
    io.write(table.concat(processedLines))
    io.write("(END)\n\n")
  end
  
  -- Prepare a custom environment to use with load(), so user can define local variables in command line.
  local preprocessorEnv = {}
  for k, v in pairs(appendEnv) do
    preprocessorEnv[k] = v
  end
  preprocessorEnv.spwrite = spwrite
  setmetatable(preprocessorEnv, {
    __index = _ENV
  })
  
  if verbose then
    io.write("################## ENVIRONMENT ###################\n")
    for k, v in pairs(preprocessorEnv) do
      io.write(tostring(k), " -> ", tostring(v), "\n")
    end
    io.write("_G -> ", tostring(preprocessorEnv._G), "\n")
    io.write("\n")
  end
  
  -- Execute the processed lines as a chunk. This writes to outputLines.
  local lineNum = 0
  local fn, result = load(function() lineNum = lineNum + 1 return processedLines[lineNum] end, "=(load)", "t", preprocessorEnv)
  if not fn then
    io.stderr:write("simple-preprocess " .. inputFilename .. ": " .. tostring(result) .. "\n")
    os.exit(2)
  end
  local status, result = pcall(fn)
  if not status then
    io.stderr:write("simple-preprocess " .. inputFilename .. ": " .. tostring(result) .. "\n")
    os.exit(2)
  end
  
  if verbose then
    io.write("################## OUTPUT FILE ###################\n")
    io.write(table.concat(outputLines))
    io.write("(END)\n\n")
  end
  
  for _, line in ipairs(outputLines) do
    outputFile:write(line)
  end
  outputFile:close()
end

main()
