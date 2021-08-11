
local component = require("component")
local computer = require("computer")
local event = require("event")
local modem = component.modem
local serialization = require("serialization")
local sides = require("sides")
local tdebug = require("tdebug")
local term = require("term")
local text = require("text")
local thread = require("thread")
local wnet = require("wnet")

local COMMS_PORT = 0xE298

-- Verify string has item name format "<mod name>:<item name>/<damage>[n]".
-- Allows skipping the damage value (which then defaults to zero).
local function stringToItemName(s)
  s = string.lower(s)
  if not string.find(s, "/") then
    s = s .. "/0"
  end
  assert(string.match(s, "[%w_]+:[%w_]+/%d+n?") == s, "Item name does not have valid format.")
  return s
end

-- Verify string has integer format (no decimals). If minVal is provided then
-- this is the lower bound for the integer.
local function stringToInteger(s, minVal)
  minVal = minVal or math.mininteger
  local x = tonumber(s)
  assert(not string.find(s, "[^%d-]") and x, "Invalid format for integer value.")
  assert(x >= minVal, "Integer must be greater than or equal to " .. minVal .. ".")
  return x
end

local function loadRecipes(stations, recipes, filename)
  checkArg(1, stations, "table", 2, recipes, "tables", 3, filename, "string")
  
  -- Parses one line of the file, checks for errors and syntax, and adds new data to the tables.
  local parseState = ""
  local stationEntry, stationName, recipeEntry
  local function loadRecipesParser(line, lineNum)
    local tokens = text.tokenize(line)
    if parseState == "re_inp" then    -- Within recipe inputs definition.
      if not (next(tokens) == nil or string.byte(tokens[1], #tokens[1]) == string.byte(":", 1) or tokens[1] == "station") then
        if stationName == "craft" then    -- <item name> <slot index 1> <slot index 2> ...
          assert(tokens[2], "Expected \"<item name> <slot index 1> <slot index 2> ...\".")
          recipeEntry.inp[#recipeEntry.inp + 1] = {stringToItemName(tokens[1])}
          local recipeInputEntry = recipeEntry.inp[#recipeEntry.inp]
          for i = 2, #tokens do
            recipeInputEntry[#recipeInputEntry + 1] = stringToInteger(tokens[i], 1)
          end
        else    -- <count> <item name>
          assert(not tokens[3], "Expected \"<count> <item name>\".")
          recipeEntry.inp[#recipeEntry.inp + 1] = {stringToItemName(tokens[2]), stringToInteger(tokens[1], 1)}
        end
        return
      end
    end
    
    if parseState == "re_out" then    -- Within recipe outputs definition.
      if tokens[1] == "with" then
        assert(not tokens[2], "Unexpected data after \"with\".")
        parseState = "re_inp"
      else    -- <count> <item name> "<item label>"
        local itemLabel = string.match(line, "\"(.*)\"")
        assert(itemLabel, "Expected \'<count> <item name> \"<item label>\"\'.")
        assert(not recipeEntry.out[stringToItemName(tokens[2])], "Duplicate output item name.")
        recipeEntry.out[stringToItemName(tokens[2])] = stringToInteger(tokens[1], 1)
        recipes[stringToItemName(tokens[2])] = recipes[stringToItemName(tokens[2])] or {}
        local itemNameEntry = recipes[stringToItemName(tokens[2])]
        itemNameEntry.label = itemLabel
        itemNameEntry[#itemNameEntry + 1] = #recipes
      end
    elseif parseState == "st" then    -- Within station definition.
      if tokens[1] == "in" then    -- in <x> <y> <z> <down|up|north|south|west|east>
        assert(sides[tokens[5]] and not tokens[6], "Expected \"in <x> <y> <z> <down|up|north|south|west|east>\" with integer coords.")
        assert(not stationEntry.inp, "Station must have only one input.")
        stationEntry.inp = {stringToInteger(tokens[2]), stringToInteger(tokens[3]), stringToInteger(tokens[4]), sides[tokens[5]]}
      elseif tokens[1] == "out" then    -- out <x> <y> <z> <down/up/north/south/west/east>
        assert(sides[tokens[5]] and not tokens[6], "Expected \"out <x> <y> <z> <down|up|north|south|west|east>\" with integer coords.")
        assert(not stationEntry.out, "Station must have only one output.")
        stationEntry.out = {stringToInteger(tokens[2]), stringToInteger(tokens[3]), stringToInteger(tokens[4]), sides[tokens[5]]}
      elseif tokens[1] == "path" then    -- path<n> <x> <y> <z>
        
      elseif tokens[1] == "time" then    -- time <average seconds for 1 unit>
        
      elseif tokens[1] == "type" then    -- type default|sequential|bulk
        
      elseif tokens[1] == "end" then    -- end
        assert(not tokens[2], "Unexpected data after \"end\".")
        assert(stationEntry.inp, "No input provided for station.")
        stationEntry.out = stationEntry.out or stationEntry.inp
        parseState = ""
      else
        assert(false, "Unexpected data \"" .. tokens[1] .. "\".")
      end
    elseif string.byte(tokens[1], #tokens[1]) == string.byte(":", 1) then    -- <station name>:
      assert(#tokens[1] > 1 and string.find(tokens[1], "[^%w_]") == #tokens[1] and not tokens[2], "Station name must contain only alphanumeric characters and underscores (with a colon at end).")
      stationName = string.sub(tokens[1], 1, #tokens[1] - 1)
      recipes[#recipes + 1] = {}
      recipeEntry = recipes[#recipes]
      recipeEntry.out = {}
      recipeEntry.inp = {}
      if stationName ~= "craft" then
        recipeEntry.station = stationName
      end
      parseState = "re_out"
    elseif tokens[1] == "station" then    -- station <station name>
      assert(not (string.find(tokens[2], "[^%w_]") or tokens[3]), "Station name must contain only alphanumeric characters and underscores.")
      local n = 1
      while stations[tokens[2] .. n] do
        n = n + 1
      end
      stations[tokens[2] .. n] = {}
      stationEntry = stations[tokens[2] .. n]
      parseState = "st"
    else
      assert(false, "Unexpected data \"" .. tokens[1] .. "\".")
    end
  end
  
  -- Open file and for each line trim whitespace, skip empty lines, and lines beginning with comment symbol '#'. Parse the rest.
  local file = io.open(filename, "r")
  local lineNum = 1
  
  local status, msg = pcall(function()
    for line in file:lines() do
      line = text.trim(line)
      if line ~= "" and string.byte(line, 1) ~= string.byte("#", 1) then
        loadRecipesParser(line, lineNum)
      end
      lineNum = lineNum + 1
    end
  end)
  if not status then
    assert(false, "In file \"" .. filename .. "\" at line " .. lineNum .. ": " .. msg)
  end
  
  file:close()
end

--[[

stations: {
  <station name><num>: {
    inp: {<x>, <y>, <z>, <down/up/north/south/west/east>}
    [out: {<x>, <y>, <z>, <down/up/north/south/west/east>}]
    [path1: {<x>, <y>, <z>}]
    time: <average seconds for 1 unit, 0 if not provided>
    type: <nil/sequential/bulk>
  }
  craft1: {
    inp: {<x>, <y>, <z>, <down/up/north/south/west/east>}
    [out: {<x>, <y>, <z>, <down/up/north/south/west/east>}]
    [path1: {<x>, <y>, <z>}]                                 -- may not need most of these if we do the robot-adjacent-to-drone-inventory idea.
    time: <average seconds for 1 unit, 0 if not provided>    -- do we need this for crafting??
  }
  ...
}

recipes: {
  1: {    -- Processing recipe.
    out: {
      <item name>: amount
      ...
    }
    inp: {
      1: {<item name>, amount}
      2: {<item name>, amount}
      ...
    }
    station: <station name>
  }
  2: {    -- Crafting recipe.
    out: {
      <item name>: amount
      ...
    }
    inp: {
      1: {<item name>, <slot num>}
      2: {<item name>, <slot num>, <slot num>}
      ...
    }
  }
  ...
  <item name>: {
    label: <item label>
    1: <recipe index>
    ...
  }
  ...
}

--]]

-- Called once after each recipe file has been scanned in. Confirms that for
-- each recipe, its corresponding station has been defined.
local function verifyRecipes(stations, recipes)
  checkArg(1, stations, "table", 2, recipes, "tables")
  for i, recipe in ipairs(recipes) do
    if recipe.station and not stations[recipe.station .. "1"] then
      assert(false, "Recipe " .. i .. " for " .. next(recipe.out) .. " requires station " .. recipe.station .. ", but station not found.")
    end
  end
end

local function main()
  local threadSuccess = false
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  local stations, recipes, storageServerAddress, storageItems, interfaceServerAddresses
  local netLog = ""
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    modem.open(COMMS_PORT)
    wnet.debug = true
    interfaceServerAddresses = {}
    
    io.write("Loading recipes...\n")
    stations = {}
    recipes = {}
    loadRecipes(stations, recipes, "recipes/torches.craft")
    loadRecipes(stations, recipes, "recipes/plates.proc")
    verifyRecipes(stations, recipes)
    
    tdebug.printTable(stations)
    tdebug.printTable(recipes)
    
    -- Contact the storage server.
    local attemptNumber = 1
    local lastAttemptTime = 0
    while not storageServerAddress do
      if computer.uptime() >= lastAttemptTime + 2 then
        lastAttemptTime = computer.uptime()
        term.clearLine()
        io.write("Trying to contact storage server on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
        wnet.send(modem, nil, COMMS_PORT, "stor_discover,")
        attemptNumber = attemptNumber + 1
      end
      local address, port, data = wnet.receive(0.1)
      if port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        if dataType == "craftinter_item_list" then
          storageItems = serialization.unserialize(data)
          storageServerAddress = address
        end
      end
    end
    io.write("\nSuccess.\n")
    
    threadSuccess = true
  end)
  
  thread.waitForAny({interruptThread, setupThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  threadSuccess = false
  
  -- Listens for incoming packets over the network and deals with them.
  local modemThread = thread.create(function()
    while true do
      local address, port, data = wnet.receive()
      if port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        
        if dataType == "craftinter_item_diff" then
          -- Apply the items diff to storageItems to keep the table synced up.
          local itemsDiff = serialization.unserialize(data)
          for itemName, diff in pairs(itemsDiff) do
            if diff.total == 0 then
              storageItems[itemName] = nil
            elseif storageItems[itemName] then
              storageItems[itemName].total = diff.total
            else
              storageItems[itemName] = {}
              storageItems[itemName].label = diff.label
              storageItems[itemName].total = diff.total
            end
          end
        elseif dataType == "craftinter_stor_started" then
          -- If we get a broadcast that storage started, it must have just rebooted and we need to discover new storageItems.
          wnet.send(modem, address, COMMS_PORT, "stor_discover,")
        elseif dataType == "craftinter_item_list" then
          -- New item list, update storageItems.
          storageItems = serialization.unserialize(data)
          storageServerAddress = address
        elseif dataType == "craft_discover" then
          -- Interface is searching for this crafting server, respond with list of recipes.
          interfaceServerAddresses[address] = true
          local recipeItems = {}
          for k, v in pairs(recipes) do
            if type(k) == "string" then
              recipeItems[k] = v.label
            end
          end
          wnet.send(modem, address, COMMS_PORT, "inter_recipe_list," .. serialization.serialize(recipeItems))
        end
      end
    end
  end)
  
  --[[
  local listenThread = thread.create(function()
    while true do
      local address, port, data = wnet.receive()
      if address then
        netLog = netLog .. "Packet from " .. string.sub(address, 1, 5) .. ":" .. port .. " <- " .. string.format("%q", data) .. "\n"
      end
    end
  end)
  --]]
  
  local commandThread = thread.create(function()
    while true do
      io.write("> ")
      local input = io.read()
      input = text.tokenize(input)
      if input[1] == "up" then
        local file = io.open("drone_up.lua")
        local sourceCode = file:read(10000000)
        io.write("Uploading \"drone_up.lua\"...\n")
        wnet.send(modem, nil, COMMS_PORT, "drone_upload," .. sourceCode)
      elseif input[1] == "exit" then
        threadSuccess = true
        break
      elseif input[1] == "log" then
        io.write(netLog)
      else
        io.write("Enter \"up\" to upload, or \"exit\" to quit.\n")
      end
    end
  end)
  
  thread.waitForAny({interruptThread, modemThread, commandThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  
  interruptThread:kill()
  modemThread:kill()
  commandThread:kill()
end

main()
