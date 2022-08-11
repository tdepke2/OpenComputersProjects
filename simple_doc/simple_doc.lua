--------------------------------------------------------------------------------
-- Lua documentation generator.
-- 
-- @see file://simple_doc/README.md
-- @author tdepke2
--------------------------------------------------------------------------------

require = require("unix_compatibility")
local fs = require("filesystem")
local shell = require("shell")

local USAGE_STRING = [[Usage: simple_doc [OPTION]... [INPUT-FILE] [OUTPUT-FILE]

Options:
  -h, --help                   display help message and exit
  -B, --boilerplate=NUMBER     ignore first N comments in file (boilerplate comments)
  -C, --context                include next line in file after each comment block
      --insert-start=STRING    insert output text in file starting at the given string
      --insert-end=STRING      same as insert-start for the ending position

For more information, run: man simple_doc
]]

local args, opts = shell.parse(...)


-- Wrapper for io.open() to check if the file was opened successfully, and raise
-- an error if not.
local function ioOpenSafe(filename, mode)
  if fs.isDirectory(filename) then
    io.stderr:write("simple_doc " .. filename .. ": is a directory\n")
    os.exit(2)
  end
  local file, err = io.open(filename, mode)
  if not file then
    io.stderr:write("simple_doc " .. filename .. ": " .. tostring(err) .. "\n")
    os.exit(2)
  end
  return file
end


-- Write a documentation comment block to the output file. Skips any blocks that
-- are considered boilerplate code, adds a newline to separate blocks, and trims
-- trailing empty lines.
local function writeSection(outputFile, docSection)
  if docSection.n == 0 then
    return
  end
  if opts["B"] and docSection.sectionNumber <= opts["B"] then
    -- Ignore the boilerplate comment.
    for i, v in ipairs(docSection) do
      docSection[i] = nil
    end
  else
    if opts["B"] then
      if docSection.sectionNumber > opts["B"] + 1 then
        outputFile:write("\n")
      end
    elseif docSection.sectionNumber ~= 1 then
      outputFile:write("\n")
    end
    -- Trim trailing lines that are only whitespace.
    for i = docSection.n, 1, -1 do
      if string.find(docSection[i], "%S") then
        break
      end
      docSection[i] = nil
    end
    -- Add remaining lines to output.
    for i, v in ipairs(docSection) do
      outputFile:write(v, "\n")
      docSection[i] = nil
    end
  end
  docSection.sectionNumber = docSection.sectionNumber + 1
  docSection.n = 0
end


-- Reads the given input file to look for comment blocks formatted as
-- documentation. These are appended to the output file.
local function buildDoc(inputFile, outputFile)
  local state = 0
  local docSection = {sectionNumber = 1, n = 0}
  
  local line, lineNum = inputFile:read(), 1
  while line do
    if state == 1 then
      -- Within comment block (line type).
      local docText = string.match(line, "%s*%-%-+%s?(.*)")
      if docText then
        docSection.n = docSection.n + 1
        docSection[docSection.n] = docText
      else
        if opts["C"] then
          docSection.n = docSection.n + 1
          docSection[docSection.n] = line
        end
        state = 0
        writeSection(outputFile, docSection)
      end
    elseif state == 2 then
      -- Within comment block (multi-line type).
      if not string.find(line, "%]%]") then
        docSection.n = docSection.n + 1
        docSection[docSection.n] = line
      elseif not opts["C"] then
        state = 0
        writeSection(outputFile, docSection)
      else
        state = 3
      end
    elseif state == 3 then
      -- At line after a multi-line comment block.
      docSection.n = docSection.n + 1
      docSection[docSection.n] = line
      state = 0
      writeSection(outputFile, docSection)
    end
    
    -- Default state, check for comment prefix that could indicate doc comment.
    if state == 0 and string.find(line, "%s*%-%-") then
      local docText = string.match(line, "%s*%-%-%-+%s?(.*)")
      if docText then
        state = 1
      else
        docText = string.match(line, "%s*%-%-%[%[%-%-+%s?(.*)")
        if docText then
          state = 2
        end
      end
      if docText and #docText > 0 then
        docSection.n = docSection.n + 1
        docSection[docSection.n] = docText
      end
    end
    line, lineNum = inputFile:read(), lineNum + 1
  end
  writeSection(outputFile, docSection)
end


-- Check command line options, open files, generate documentation, and write
-- results to output.
local function main()
  local inputFilename = (args[1] == nil and "-" or args[1])
  local outputFilename = (args[2] == nil and "-" or args[2])
  if #args > 2 or opts["h"] or opts["help"] then
    io.write(USAGE_STRING)
    os.exit(0)
  end
  
  if opts["boilerplate"] then
    opts["B"] = opts["boilerplate"]
  end
  if opts["B"] then
    opts["B"] = math.max(tonumber(opts["B"]) or 1, 0)
  end
  
  if opts["context"] then
    opts["C"] = true
  end
  
  if opts["insert-start"] or opts["insert-end"] then
    if type(opts["insert-start"]) ~= "string" or type(opts["insert-end"]) ~= "string" then
      io.stderr:write("simple_doc: must provide both --insert-start and --insert-end with string values, or skip them both\n")
      os.exit(2)
    end
  end
  
  local inputFile, outputFile
  local outputFileContents
  
  -- Attempt to open input file (or use stdin).
  if inputFilename == "-" then
    inputFile = io.stdin
  else
    inputFilename = shell.resolve(inputFilename)
    inputFile = ioOpenSafe(inputFilename)
  end
  
  -- Attempt to open output file (or use stdout).
  if outputFilename == "-" then
    outputFile = io.stdout
  else
    outputFilename = shell.resolve(outputFilename)
    
    -- If insert-start/insert-end options are provided, read the output file first and look for the start/end strings.
    if opts["insert-start"] then
      outputFile = ioOpenSafe(outputFilename)
      
      local startFound, endFound
      outputFileContents = {n = 0, insertIndex = 0}
      local line = outputFile:read()
      while line do
        if not startFound then
          if line == opts["insert-start"] then
            startFound = true
            outputFileContents.insertIndex = outputFileContents.n + 1
          end
          outputFileContents.n = outputFileContents.n + 1
          outputFileContents[outputFileContents.n] = line
        elseif not endFound then
          if line == opts["insert-end"] then
            endFound = true
            outputFileContents.n = outputFileContents.n + 1
            outputFileContents[outputFileContents.n] = line
          end
        else
          outputFileContents.n = outputFileContents.n + 1
          outputFileContents[outputFileContents.n] = line
        end
        line = outputFile:read()
      end
      
      if not startFound then
        io.stderr:write("simple_doc " .. outputFilename .. ": failed to find insert-start string \"" .. opts["insert-start"] .. "\" in file\n")
        os.exit(2)
      end
      if not endFound then
        io.stderr:write("simple_doc " .. outputFilename .. ": failed to find insert-end string \"" .. opts["insert-end"] .. "\" in file\n")
        os.exit(2)
      end
      outputFile:close()
    end
    outputFile = ioOpenSafe(outputFilename, "w")
  end
  
  if outputFileContents then
    -- Paste contents of outputFile back in until the start string.
    for i = 1, outputFileContents.insertIndex do
      outputFile:write(outputFileContents[i], "\n")
    end
  end
  
  buildDoc(inputFile, outputFile)
  inputFile:close()
  
  if outputFileContents then
    -- Paste remainder of outputFile back in after the end string.
    for i = outputFileContents.insertIndex + 1, outputFileContents.n do
      outputFile:write(outputFileContents[i], "\n")
    end
  end
  outputFile:close()
end

main()
