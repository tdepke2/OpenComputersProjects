--[[
Create symlinks from a Git repository to their install locations on the machine.


--]]

local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")
local text = require("text")

-- Time in seconds to pause if a warning shows up and not running in silent mode.
local WARNING_PAUSE_TIME = 2

local numWarnings = 0

-- Read the configuration file used by OPPM. This is based on the same process
-- OPPM uses to load in this file. Note that this is currently only used to grab
-- the default install path, any additional repos defined in the config are
-- ignored.
local function readOppmConfig()
  local filename = "/etc/oppm.cfg"
  if not fs.exists(filename) then
    filename = fs.concat(fs.path(shell.resolve(os.getenv("_"))), "/etc/oppm.cfg")
  end
  if not fs.exists(filename) then
    return {-1}
  end
  local file, errMessage = io.open(filename, "rb")
  assert(file, "failed to open file \"" .. filename .. "\": " .. tostring(errMessage))
  local cfgTable = serialization.unserialize(file:read("*a"))
  file:close()
  return cfgTable or {-1}
end

-- Creates a symbolic link from srcPath to destPath. Additionally does some
-- error checking to make sure we don't create any broken links and the
-- directories all exist.
local function addLink(options, srcPath, destPath)
  assert(fs.exists(srcPath), "file at \"" .. srcPath .. "\" not found")
  local destFilename = fs.concat(destPath, fs.name(srcPath))
  if fs.exists(destFilename) then
    if fs.isLink(destFilename) or options.force then
      assert(fs.remove(destFilename))
    else
      assert(false, "file at \"" .. destFilename .. "\" already exists (use \'-f\' flag to remove it)")
    end
  elseif not fs.exists(destPath) then
    assert(options.force, "path to \"" .. destPath .. "\" does not exist (use \'-f\' flag to create it)")
    if not options.silent then
      io.write("Creating directory \"", destPath, "\".\n")
    end
    assert(fs.makeDirectory(destPath))
  end
  if not options.silent then
    io.write("Linking \"", srcPath, "\" to \"", destFilename, "\".\n")
  end
  assert(fs.link(srcPath, destFilename))
end

-- Read the contents of the programs.cfg file for the repository at repoPath,
-- and add symlinks to all the specified files. If a repository doesn't have a
-- programs.cfg file we send a warning and move on.
local function readPackageConfig(options, repoPath, installPath)
  local filename = fs.concat(repoPath, "/programs.cfg")
  if not fs.exists(filename) then
    if not options.silent then
      io.write("\27[33mWarning: missing package definitions at \"", filename, "\"\27[0m\n")
      numWarnings = numWarnings + 1
    end
    return
  end
  local file, errMessage = io.open(filename, "rb")
  assert(file, "failed to open file \"" .. filename .. "\": " .. tostring(errMessage))
  
  local pkgTable = serialization.unserialize(file:read("*a"))
  file:close()
  assert(pkgTable, "failed to deserialize programs list \"" .. filename .. "\"")
  
  -- The programs.cfg file just gives a table with package names, where each one defines files in the repo and their install path.
  for pkgName, pkgDat in pairs(pkgTable) do
    -- Special case since the oppm_linker files need to be persistent on the system and we don't want to try to create symlinks to replace them.
    if pkgName == "oppm_linker" then
      pkgDat.files = nil
    end
    for srcPath, destPath in pairs(pkgDat.files or {}) do
      -- A colon at start of srcPath means all of the contents in that directory. A question mark has another meaning at start of srcPath but we ignore it.
      local addContents = string.find(srcPath, "^:")
      srcPath = fs.concat(repoPath, string.match(srcPath, "[^:?](/.*)"))
      
      -- Double slash at start of destPath indicates an absolute path, otherwise we use the installPath.
      if string.find(destPath, "^//") then
        destPath = string.sub(destPath, 2)
      else
        destPath = fs.concat(installPath, destPath)
      end
      
      if addContents then
        local pathIter, errMessage = fs.list(srcPath)
        assert(pathIter, "failed to list directory \"" .. srcPath .. "\": " .. tostring(errMessage))
        for filename in pathIter do
          addLink(options, fs.concat(srcPath, filename), destPath)
        end
      else
        addLink(options, srcPath, destPath)
      end
    end
  end
end

-- Search for all of the repositories in "/repository" and process the OPPM
-- packages file in each one.
local function main(options)
  local installPath = readOppmConfig().path or "/usr"
  
  local pathIter, errMessage = fs.list("/repository")
  if not pathIter then
    if not options.silent then
      io.write("\27[33mWarning: failed to list directory \"/repository\": ", tostring(errMessage), "\27[0m\n")
      numWarnings = numWarnings + 1
    end
    return
  end
  for filename in pathIter do
    readPackageConfig(options, fs.concat("/repository", filename), installPath)
  end
end

function start(...)
  -- Parse arguments from the rc config if during startup, or from the function arguments if user invoked the start function.
  local arguments, options
  local isStarting = (computer.runlevel() == "S")
  if isStarting then
    arguments, options = shell.parse(table.unpack(text.tokenize(args or "")))
  else
    arguments, options = shell.parse(...)
  end
  options = {
    force = options.f,
    silent = options.s
  }
  
  if not options.silent then
    require("term").clear()
  end
  
  -- Run main function in a protected call. Pause system and print errors if something went wrong.
  local status, err = pcall(main, options)
  if not status then
    if options.silent then
      require("term").clear()
    end
    io.write("\27[31mERROR: failed to run oppm_linker\n")
    io.write(tostring(err), "\n")
    if isStarting then
      io.write("\27[0m\n(press enter to continue)\n")
      io.read()
    end
  elseif isStarting and numWarnings > 0 and WARNING_PAUSE_TIME > 0 then
    os.sleep(WARNING_PAUSE_TIME)
  end
end
