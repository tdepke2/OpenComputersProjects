--[[
Robot automation for miniaturization field projector recipes (from compact
machines mod with recipes from CompactClaustrophobia).

Version 1.0
Using Lua 5.3

How it works:
  Robot periodically scans inventory below it for items. If the item combination
  matches one of the stored recipes then it pulls what it needs and starts
  building. Crafting result is output to another inventory when done (can
  optionally emit a redstone signal when this happens).
  Robot shows a green status when running, yellow if problem (not enough
  energy), and red when stopped.

Requirements:
  - Computer Case (Tier 2)
  - CPU, Memory x2, Graphics Card, Hard Disk Drive, EEPROM (Lua BIOS), Screen, Keyboard, Disk Drive
  - Inventory Upgrade
  - Inventory Controller Upgrade
  - Redstone Card (needed for building hoppers)
  - Angel Upgrade (optional, only needed for some recipes)

Setup:
  All blocks shown in diagram are 1 block above ground level.
  FP = Field Projector
  RO = Robot (facing working area, with input chest underneath the robot).
  CH = Chest (for output).
  Numbers in middle represent working area, just air blocks.
  .------------------.
  |        FP        |
  |                  |
  |                  |
  |      9.6.3.      |
  |FP    8.5.2.    FP|
  |      7.4.1.      |
  |                  |
  |          RO      |
  |        FPCH      |
  '------------------'
--]]

-- Amount of time to wait for while idle.
local SLEEP_DELAY_SECONDS = 2

-- Whether the robot should send a redstone pulse when crafting completes.
-- Intended for usage with refined storage crafter in "restone pulse inserts
-- next set" mode.
local REDSTONE_PULSE_ON_SUCCESS = true
local REDSTONE_PULSE_SIDE = require("sides").left



local component = require("component")
local computer = require("computer")
local event = require("event")
local ic = component.inventory_controller
local robot = require("robot")
local rs = component.redstone
local sides = require("sides")
local term = require("term")
local text = require("text")

-- Get next string in text and index after trailing space.
function parseNextStr(line, idx)
  idx = idx or 1
  local n1, n2 = string.find(line, "%s+", idx)
  if n1 then
    return string.sub(line, idx, n1 - 1), n2 + 1
  else
    return string.sub(line, idx), nil
  end
end

function parseNextNum(line, idx)
  local str
  str, idx = parseNextStr(line, idx)
  return tonumber(str), idx
end

-- Loads structure recipes from file and returns table.
-- Table format is:
-- recipes = {
--   index, {areaSize, result, resultNum, material, materialNum, block1,
--           block1Num, block2, block2Num, ..., blockMax, pos}
-- }
-- 
-- Example for ender pearl:
--   areaSize is 3, result is pearl, material is redstone dust, block1 and
--   block2 are obsidian and redstone blocks. The pos is numbered consecutively
--   from 1 to 27 in the order shown in the setup diagram (starting at bottom
--   layer and going up).
-- 
-- [file format]
-- recipe:
-- areaSize <n>
-- <result> <count>
-- <material> <count>
-- <block1>
-- <block2>
-- ...
-- blocks:
-- 111 111 111
-- 111 121 111
-- 111 111 111
function loadRecipes(filename)
  local recipes = {}
  local co
  
  -- We use a coroutine to load the file, could also be done with state machine
  -- but I thought coroutines would be fun.
  local function loadRecipesParser(line, lineNum)
    if co == nil or coroutine.status(co) == "dead" then
      co = coroutine.create(function(line)
        table.insert(recipes, {})
        local recipe = recipes[#recipes]
        local str, num, idx
        -- Line "recipe:"
        assert(line == "recipe:", "expected \"recipe:\"")
        line = coroutine.yield()
        -- Line "areaSize <n>"
        str, idx = parseNextStr(line)
        num, idx = parseNextNum(line, idx)
        assert(str == "areaSize", "expected \"areaSize <n>\"")
        recipe.areaSize = num
        line = coroutine.yield()
        -- Line "<result> <count>"
        str, idx = parseNextStr(line)
        num, idx = parseNextNum(line, idx)
        recipe.result = str
        recipe.resultNum = num
        line = coroutine.yield()
        -- Line "<material> <count>"
        str, idx = parseNextStr(line)
        num, idx = parseNextNum(line, idx)
        recipe.material = str
        recipe.materialNum = num
        line = coroutine.yield()
        local numBlocks = 0
        while line ~= "blocks:" do
          -- Line "<input n> <count>"
          numBlocks = numBlocks + 1
          str, idx = parseNextStr(line)
          recipe["block" .. numBlocks] = str
          recipe["block" .. numBlocks .. "Num"] = 0
          line = coroutine.yield()
        end
        -- Line "blocks:"
        assert(line == "blocks:", "expected \"blocks:\"")
        recipe.blockMax = numBlocks
        recipe.pos = ""
        for i = 1, recipe.areaSize do
          line = coroutine.yield()
          -- Line "<position data>"
          recipe.pos = recipe.pos .. string.gsub(line, "%s+", "")
        end
        -- Count up the number of blocks for each type in recipe.pos
        for i = 1, #recipe.pos do
          local c = string.sub(recipe.pos, i, i)
          if c ~= "0" then
            local b = "block" .. c .. "Num"
            recipe[b] = recipe[b] + 1
          end
        end
        return
      end)
    end
    local status, msg = coroutine.resume(co, line)
    if not status then
      assert(false, string.format("%s at line %d", msg, lineNum))
    end
  end
  
  -- Step through file line-by-line and parse it.
  local file = io.open(filename, "r")
  local lineNum = 1
  for line in file:lines() do
    if line ~= "" then
      loadRecipesParser(line, lineNum)
    end
    lineNum = lineNum + 1
  end
  file:close()
  return recipes
end

-- Similar to recipe list but just has recipe inputs and total amount needed.
function getRecipeInputTotals(recipes)
  local recipeInputTotals = {}
  for i, recipe in ipairs(recipes) do
    recipeInputTotals[i] = {}
    local recipeTotal = recipeInputTotals[i]
    recipeTotal[recipe.material] = recipe.materialNum + (recipeTotal[recipe.material] or 0)
    for n = 1, recipe.blockMax do
      recipeTotal[recipe["block" .. n]] = recipe["block" .. n .. "Num"] + (recipeTotal[recipe["block" .. n]] or 0)
    end
  end
  return recipeInputTotals
end

-- Loads a file that keeps track of item crafting totals and returns table.
function loadCraftedItems(filename)
  local craftedItems = {}
  
  -- Step through file line-by-line and parse it.
  local file = io.open(filename, "r")
  if file == nil then
    return craftedItems
  end
  for line in file:lines() do
    if line ~= "" then
      local str, num, idx
      str, idx = parseNextStr(line)
      num, idx = parseNextNum(line, idx)
      craftedItems[str] = num
    end
  end
  file:close()
  
  return craftedItems
end

-- Saves data to file for loadCraftedItems().
function saveCraftedItems(filename, craftedItems)
  local file = io.open(filename, "w")
  
  for item, count in pairs(craftedItems) do
    file:write(string.format("%s %d\n", item, count))
  end
  
  file:close()
end

-- Look through the inventory at specified side, and return table with item
-- totals and details of where each item is.
function searchInventory(side)
  local itemTotals = {}
  local itemDetails = {}
  local invSize = ic.getInventorySize(side)
  if invSize == nil then
    return nil
  end
  for i = 1, invSize do
    local item = ic.getStackInSlot(side, i)
    if item ~= nil then
      local fullName = item.name .. "/" .. math.floor(item.damage)
      itemTotals[fullName] = item.size + (itemTotals[fullName] or 0)
      itemDetails[i] = {}
      itemDetails[i].name = item.name
      itemDetails[i].damage = item.damage
      itemDetails[i].size = item.size
      itemDetails[i].maxSize = item.maxSize
    end
  end
  return itemTotals, itemDetails
end

-- Grab items required for recipe from inventory. Returns a slotMap that maps
-- each block<n> to the slot it starts at (with material at end).
function prepareRecipe(recipe, itemDetails, side)
  local function grabItems(item, count)
    for i, itemDetail in pairs(itemDetails) do
      if item == (itemDetail.name .. "/" .. math.floor(itemDetail.damage)) then
        local transferAmount = math.min(count, itemDetail.size)
        assert(ic.suckFromSlot(side, i, transferAmount))
        count = count - transferAmount
        if count == 0 then
          break
        end
        
        -- Skip full slots.
        while robot.space() == 0 do
          robot.select(robot.select() + 1)
        end
      end
    end
    assert(count == 0)
  end
  
  local slotMap = {}
  robot.select(1)
  
  for n = 1, recipe.blockMax do
    while robot.count() ~= 0 do
      robot.select(robot.select() + 1)
    end
    slotMap[n] = robot.select()
    grabItems(recipe["block" .. n], recipe["block" .. n .. "Num"])
  end
  
  while robot.count() ~= 0 do
    robot.select(robot.select() + 1)
  end
  slotMap[#slotMap + 1] = robot.select()
  grabItems(recipe.material, recipe.materialNum)
  
  return slotMap
end

-- Craft a recipe loaded from loadRecipes()
function craftRecipe(recipe, slotMap)
  local idx = 0
  
  local function buildBlock()
    -- Find the actual slot where the item is.
    local slotNum = string.byte(recipe.pos, idx) - string.byte("0")
    if slotNum == 0 then
      return
    end
    slotNum = slotMap[slotNum]
    robot.select(slotNum)
    while robot.count() == 0 do
      robot.select(robot.select() + 1)
    end
    
    robot.placeDown()
  end
  
  local function buildStrip(idxDelta)
    idx = idx + idxDelta
    buildBlock()
    for i = 1, recipe.areaSize - 1 do
      robot.forward()
      idx = idx + idxDelta
      buildBlock()
    end
  end
  
  local function buildLayer(layerDelta)
    local idxDelta = layerDelta
    buildStrip(idxDelta)
    for i = 1, recipe.areaSize - 1 do
      if i % 2 == 1 then
        robot.turnLeft()
        robot.forward()
        robot.turnLeft()
      else
        robot.turnRight()
        robot.forward()
        robot.turnRight()
      end
      idx = idx + layerDelta * recipe.areaSize + idxDelta
      idxDelta = -idxDelta
      buildStrip(idxDelta)
    end
  end
  
  local function buildCube()
    local layerDelta = 1
    buildLayer(layerDelta)
    for i = 1, recipe.areaSize - 1 do
      robot.turnRight()
      robot.turnRight()
      robot.up()
      idx = idx + recipe.areaSize * recipe.areaSize + layerDelta
      layerDelta = -layerDelta
      buildLayer(layerDelta)
    end
  end
  
  robot.forward()
  robot.forward()
  -- Enable redstone signal on bottom to lock any hoppers robot travels over.
  rs.setOutput(sides.bottom, 1)
  buildCube()
  robot.up()
  robot.turnRight()
  rs.setOutput(sides.bottom, 0)
  -- Get to middle edge.
  for i = 1, recipe.areaSize // 2 do
    robot.forward()
  end
  robot.turnRight()
  robot.select(slotMap[#slotMap])
  robot.dropDown(recipe.materialNum)
  -- Get to opposite edge and go to ground.
  for i = 1, recipe.areaSize do
    robot.forward()
  end
  for i = 1, recipe.areaSize + 1 do
    robot.down()
  end
  robot.turnRight()
  robot.turnRight()
  -- Get to block before middle.
  for i = 1, recipe.areaSize // 2 do
    robot.forward()
  end
  while not robot.suck() do
    os.sleep(0.5)
  end
  -- Return home.
  robot.turnRight()
  for i = 1, recipe.areaSize // 2 do
    robot.forward()
  end
  robot.turnRight()
  robot.up()
  robot.forward()
  robot.forward()
  local selectedItem = ic.getStackInInternalSlot()
  local itemMatches = (selectedItem.name .. "/" .. math.floor(selectedItem.damage) == recipe.result and selectedItem.size == recipe.resultNum)
  if itemMatches then
    robot.drop()
    if REDSTONE_PULSE_ON_SUCCESS then
      rs.setOutput(REDSTONE_PULSE_SIDE, 15)
      os.sleep(0.1)
      rs.setOutput(REDSTONE_PULSE_SIDE, 0)
    end
  end
  robot.turnRight()
  robot.turnRight()
  
  -- Verify that we got the right item crafted and inventory empty.
  assert(itemMatches, string.format("Crafting result did not match, expected %d of %s", recipe.resultNum, recipe.result))
  for i = 1, robot.inventorySize() do
    assert(robot.count(i) == 0, string.format("Expected empty inventory at slot %d", i))
  end
end

-- Display updated list of crafted items.
function updateTerm(craftedItems)
  local _, r = term.getCursor()
  while r > 4 do
    term.setCursor(1, r - 1)
    term.clearLine()
    _, r = term.getCursor()
  end
  local maxCols, maxRows = term.getViewport()
  for item, count in pairs(craftedItems) do
    print(item .. text.padLeft(tostring(count), maxCols - #item))
    _, r = term.getCursor()
    if r == maxRows - 1 then
      print("...")
      break
    end
  end
end



local recipes = loadRecipes("recipes")
local recipeInputTotals = getRecipeInputTotals(recipes)
local craftedItems = loadCraftedItems("craftedItems")

term.clear()
print("Mini-builder running, (press ctrl+c to quit)")
print()
print("Items crafted:")
updateTerm(craftedItems)
component.robot.setLightColor(0x00ff00) -- Green
local running = true
local justCraftedItem = false

-- Main function.
function mainFunction()
  -- Require at least 20% energy to do stuff.
  if computer.energy() / computer.maxEnergy() < 0.2 then
    component.robot.setLightColor(0xffff00) -- Yellow
    return
  else
    component.robot.setLightColor(0x00ff00) -- Green
  end
  
  local itemTotals, itemDetails = searchInventory(sides.bottom)
  
  -- If found items in inventory, iterate through available recipes and pick best one.
  if itemTotals then
    local bestRecipe, bestRecipeItemCount, bestRecipeTypeCount
    
    for i, recipeTotal in ipairs(recipeInputTotals) do
      -- For each number of items in recipe, verify that we have at least the amount required.
      local recipeFound = true
      local recipeItemCount, recipeTypeCount = 0, 0
      for item, count in pairs(recipeTotal) do
        if itemTotals[item] == nil or count > itemTotals[item] then
          recipeFound = false
          break
        end
        recipeItemCount = recipeItemCount + count
        recipeTypeCount = recipeTypeCount + 1
      end
      
      -- Check if new best recipe. Item type count takes precedence over total number of items.
      if recipeFound then
        if bestRecipe == nil or recipeTypeCount > bestRecipeTypeCount or (recipeTypeCount == bestRecipeTypeCount and recipeItemCount > bestRecipeItemCount) then
          bestRecipe = recipes[i]
          bestRecipeItemCount = recipeItemCount
          bestRecipeTypeCount = recipeTypeCount
        end
      end
    end
    
    if bestRecipe then
      local slotMap = prepareRecipe(bestRecipe, itemDetails, sides.bottom)
      craftRecipe(bestRecipe, slotMap)
      craftedItems[bestRecipe.result] = bestRecipe.resultNum + (craftedItems[bestRecipe.result] or 0)
      updateTerm(craftedItems)
      justCraftedItem = true
    end
  end
end

-- Main loop.
while running do
  status, err = pcall(mainFunction)
  if not status then
    print("Error:", err)
    break
  end
  
  -- Stay idle for a bit and process any interrupt signals. Idle for only short time if we just crafted something.
  repeat
    local e
    if justCraftedItem then
      e = event.pull(0.01)
    else
      e = event.pull(SLEEP_DELAY_SECONDS)
    end
    if e == "interrupted" then
      running = false
      break
    end
  until (e == nil)
  justCraftedItem = false
end

component.robot.setLightColor(0xff0000) -- Red
saveCraftedItems("craftedItems", craftedItems)
print("Mini-builder stopped.")
