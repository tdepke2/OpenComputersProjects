--------------------------------------------------------------------------------
-- Lua documentation generator.
-- 
-- @see file://simple_doc/README.md
-- @author tdepke2
--------------------------------------------------------------------------------

-- Check for optional dependency unix_compatibility. This is needed only when running simple_doc outside of OpenOS.
do
  pcall(function() require = require("unix_compatibility") end)
end
local fs = require("filesystem")
local shell = require("shell")

local USAGE_STRING = [[Usage: simple_doc [OPTION]... [INPUT-FILE] [OUTPUT-FILE]

Options:
  -h, --help                   display help message and exit
  -B, --boilerplate=NUMBER     ignore first N comments in file (boilerplate comments)
  -C, --context                include next line in file after each comment block
      --insert-start=STRING    insert output text in file starting at the given string
      --insert-end=STRING      same as insert-start for the ending position
      --ocdoc                  add bullet points and indent like the OpenComputers docs

For more information, run: man simple_doc
]]

local args, opts = shell.parse(...)


---@docstr
-- 
-- Wrapper for `io.open()` to check if the file was opened successfully, and
-- raise an error if not.
-- 
---@param filename string
---@param mode? openmode
---@return file*
---@nodiscard
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


---@docstr
-- 
-- Searches for annotations in the docSection (patterns beginning with the `@`
-- symbol). Most of these are replaced with empty lines to hide them from
-- documentation, but a few (`@docstr`, `@param`, and `@return`) are used to add
-- function/variable definitions with named parameter types and return values.
-- 
---@param contextLine string
---@param docSection table
local function formatAnnotations(contextLine, docSection)
  -- Tables for tracking function/variable definition lines, named parameters, and potentially named return values.
  local funcs, params, returns
  
  -- Step through each line in docSection to find lines that begin with "@".
  for i = 1, docSection.n do
    local annotation, arguments = string.match(docSection[i], "^%s*@(%S+)%s*(.*)")
    if annotation then
      docSection[i] = ""
      if annotation == "docstr" then
        -- The "@docstr [function/variable definition]" annotation was found. If no definition is provided, guess it from the contextLine.
        if arguments == "" then
          docSection[i] = string.match(contextLine, "function%s+(.*)") or contextLine
          docSection[i] = "`" .. docSection[i] .. "`"
        else
          docSection[i] = arguments
        end
        funcs = funcs or {}
        funcs[#funcs + 1] = i
      elseif annotation == "param" then
        -- The "@param <name[?]> <type[|type...]> [description]" annotation was found. We ignore the description if provided.
        local paramName, paramTypes, paramDesc = string.match(arguments, "(%S+)%s+(%S+)%s*(.*)")
        if paramName then
          params = params or {}
          params[paramName] = paramTypes
        end
      elseif annotation == "return" then
        -- The "@return <type> [<name> [comment] | [name] #<comment>]" annotation was found. We ignore the comment if provided.
        local returnTypes, returnName, returnDesc = string.match(arguments, "(%S+)%s*(%S*)%s*(.*)")
        if returnTypes then
          returns = returns or {}
          returns[#returns + 1] = {returnTypes, returnName}
        end
      end
    end
  end
  
  -- If some function/variable definitions were found, try to add types to parameters and return values for each definition.
  if funcs then
    for _, index in ipairs(funcs) do
      -- Substitute function parameter names with the annotated version where applicable.
      if params then
        local funcParams = string.match(docSection[index], "%(.*%)")
        if funcParams then
          local annotatedParams = ""
          for p in string.gmatch(funcParams, "[%w_%.]+") do
            if params[p] then
              p = p .. ": " .. params[p]
            elseif params[p .. "?"] then
              p = p .. "?: " .. params[p .. "?"]
            end
            annotatedParams = annotatedParams .. p .. ", "
          end
          docSection[index] = string.gsub(docSection[index], funcParams, string.sub(annotatedParams, 1, -3), 1)
        end
      end
      
      -- Add on the list of annotated return values if provided.
      local annotatedReturns = ""
      for _, returnTypeNamePair in ipairs(returns or {}) do
        annotatedReturns = annotatedReturns .. (returnTypeNamePair[2] ~= "" and returnTypeNamePair[2] .. ": " or "") .. returnTypeNamePair[1] .. ", "
      end
      if annotatedReturns ~= "" then
        local trailingChars = string.match(docSection[index], "^.*%)(.+)$")
        if trailingChars then
          docSection[index] = string.sub(docSection[index], 1, -1 - #trailingChars)
        else
          trailingChars = ""
        end
        docSection[index] = docSection[index] .. " -> " .. string.sub(annotatedReturns, 1, -3) .. trailingChars
      end
    end
  end
end


---@docstr
-- 
-- Write a documentation comment block to the output file. Skips any blocks that
-- are considered boilerplate code, adds a newline to separate blocks, and trims
-- trailing empty lines.
-- 
---@param outputFile file*
---@param docSection table
local function writeSection(outputFile, docSection)
  local contextLine = docSection[docSection.n]
  if docSection.n > 0 and not opts["C"] then
    docSection[docSection.n] = nil
    docSection.n = docSection.n - 1
  end
  formatAnnotations(contextLine, docSection)
  
  -- Trim trailing lines that are only whitespace. Return early if docSection is empty.
  for i = docSection.n, 1, -1 do
    if string.find(docSection[i], "%S") then
      break
    end
    docSection[i] = nil
    docSection.n = docSection.n - 1
  end
  if docSection.n == 0 then
    docSection.sectionNumber = docSection.sectionNumber + 1
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
    
    if opts["ocdoc"] and docSection[1] and string.find(docSection[1], "^%s*`") then
      -- The ocdoc format adds a bullet point to the first line (if it begins with a backtick) and indents the rest of the block.
      outputFile:write("* ", docSection[1], "\n")
      for i = 2, #docSection do
        outputFile:write("  ", docSection[i], "\n")
        docSection[i] = nil
      end
      docSection[1] = nil
    else
      -- Add remaining lines to output.
      for i, v in ipairs(docSection) do
        outputFile:write(v, "\n")
        docSection[i] = nil
      end
    end
  end
  docSection.sectionNumber = docSection.sectionNumber + 1
  docSection.n = 0
end


---@docstr
-- 
-- Reads the given input file to look for comment blocks formatted as
-- documentation. These are appended to the output file.
-- 
---@param inputFile file*
---@param outputFile file*
local function buildDoc(inputFile, outputFile)
  local state = 0
  local docSection = {sectionNumber = 1, n = 0}
  
  local line, lineNum = inputFile:read(), 1
  while line do
    if state == 1 then
      -- Within comment block (line type).
      local docText = string.match(line, "^%s*%-%-+%s?(.*)")
      if docText then
        docSection.n = docSection.n + 1
        docSection[docSection.n] = docText
      else
        docSection.n = docSection.n + 1
        docSection[docSection.n] = line
        state = 0
        writeSection(outputFile, docSection)
      end
    elseif state == 2 then
      -- Within comment block (multi-line type).
      if not string.find(line, "%]%]") then
        docSection.n = docSection.n + 1
        docSection[docSection.n] = line
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
    if state == 0 and string.find(line, "^%s*%-%-") then
      local docText = string.match(line, "^%s*%-%-%-+%s?(.*)")
      if docText then
        state = 1
      else
        docText = string.match(line, "^%s*%-%-%[%[%-%-+%s?(.*)")
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


---@docstr
-- 
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
