--[[

--]]

local COMMS_PORT = 0xE298

local component = require("component")
local computer = require("computer")
local event = require("event")
local gpu = component.gpu
local keyboard = require("keyboard")
local modem = component.modem
local serialization = require("serialization")
local tdebug = require("tdebug")
local term = require("term")
local text = require("text")
local thread = require("thread")
local wnet = require("wnet")

local function isPointInRectangle(xPoint, yPoint, x, y, width, height)
  return xPoint >= x and xPoint < x + width and yPoint >= y and yPoint < y + height
end

-- Hash function djb2 by Dan Bernstein for converting string to hash value.
-- http://www.cse.yorku.ca/~oz/hash.html
local function djb2StringHash(s)
  local h = 5381
  for c in string.gmatch(s, ".") do
    h = ((h << 5) + h) + string.byte(c)    -- Does h * 33 + c, apparently 33 is a magic number.
  end
  return h
end

local Gui = {}

function Gui:new(obj, storageItems, storageServerAddress)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  self.ITEM_LABEL_WIDTH = 45
  self.LEFT_COLUMN_WIDTH = 8
  self.RIGHT_COLUMN_WIDTH = 25
  self.TOP_ROW_HEIGHT = 4
  self.BOTTOM_ROW_HEIGHT = 3
  
  self.LAZY_DRAW_INTERVAL = 0.05
  
  self.drawAreaItemRequested = false
  
  self.palette = {}
  self.palette.bg = 0
  gpu.setPaletteColor(0, 0x141414)    -- Dark gray
  self.palette.bg2 = 1
  gpu.setPaletteColor(1, 0x292929)    -- Less dark gray
  self.palette.fg = 2
  gpu.setPaletteColor(2, 0xFFFFFF)
  self.palette.fg2 = 3
  gpu.setPaletteColor(3, 0xFFFFFF)
  self.palette.button = 4
  gpu.setPaletteColor(4, 0xB00B69)    -- Dark magenta
  self.palette.item1 = 5
  gpu.setPaletteColor(5, 0x323232)    -- Gray1
  self.palette.item2 = 6
  gpu.setPaletteColor(6, 0x373737)    -- Gray2
  self.palette.crafting = 7
  gpu.setPaletteColor(7, 0x1B4B47)    -- Dark teal
  
  self.palette.mod1 = 8
  gpu.setPaletteColor(8, 0xFF8080)
  self.palette.mod2 = 9
  gpu.setPaletteColor(9, 0x80FF80)
  self.palette.mod3 = 10
  gpu.setPaletteColor(10, 0x8080FF)
  self.palette.mod4 = 11
  gpu.setPaletteColor(11, 0xFFFF80)
  self.palette.mod5 = 12
  gpu.setPaletteColor(12, 0x80FFFF)
  self.palette.mod6 = 13
  gpu.setPaletteColor(13, 0xFF80FF)
  
  --[[
  0x121212
  0x1E1E1E
  0x212121
  0x242424
  0x272727
  0x2C2C2C
  0x2D2D2D
  0x323232
  0x353535
  0x373737
  
  0xBB86FC    -- Light purple
  0x3700B3    -- Dark blue
  0x251F2D    -- Dark purple
  0x03DAC5    -- Teal
  0x1B4B47    -- Dark teal
  0xCF6679    -- Light red
  0xB00020    -- Dark red
  --]]
  
  local width, height = term.getViewport()
  self.area = {}
  self.area.left = {}
  self.area.left.x = 1
  self.area.left.y = 1
  self.area.left.width = self.LEFT_COLUMN_WIDTH
  self.area.left.height = height
  
  self.area.right = {}
  self.area.right.x = width - self.RIGHT_COLUMN_WIDTH + 1
  self.area.right.y = 1
  self.area.right.width = self.RIGHT_COLUMN_WIDTH
  self.area.right.height = height
  
  self.area.top = {}
  self.area.top.x = self.area.left.x + self.area.left.width
  self.area.top.y = 1
  self.area.top.width = self.area.right.x - self.area.top.x
  self.area.top.height = self.TOP_ROW_HEIGHT
  
  self.area.bottom = {}
  self.area.bottom.x = self.area.top.x
  self.area.bottom.y = height - self.BOTTOM_ROW_HEIGHT + 1
  self.area.bottom.width = self.area.top.width
  self.area.bottom.height = self.BOTTOM_ROW_HEIGHT
  
  self.area.numItemColumns = math.floor((self.area.top.width - 2) / self.ITEM_LABEL_WIDTH)
  for i = 1, self.area.numItemColumns do
    self.area["item" .. i] = {}
    self.area["item" .. i].x = self.area.left.x + self.area.left.width + 1 + (i - 1) * (self.ITEM_LABEL_WIDTH + 1)
    self.area["item" .. i].y = self.area.top.y + self.area.top.height
    self.area["item" .. i].width = self.ITEM_LABEL_WIDTH
    self.area["item" .. i].height = self.area.bottom.y - self.area["item" .. i].y
  end
  
  self.textBox = {}
  self.textBox.x = self.area.top.x + 17
  self.textBox.y = self.area.top.y + 1
  self.textBox.width = self.area.top.x + self.area.top.width - self.textBox.x - 1
  self.textBox.selected = false
  self.textBox.cursor = 1
  self.textBox.scroll = 0
  self.textBox.contents = ""
  
  self.scrollBar = {}
  self.scrollBar.x = self.area["item" .. self.area.numItemColumns].x + self.area["item" .. self.area.numItemColumns].width + 1
  self.scrollBar.y = self.area.item1.y
  self.scrollBar.height = self.area.item1.height
  self.scrollBar.scroll = 0
  self.scrollBar.maxScroll = 0
  
  self.button = {}
  self.button.filterType = {}
  self.button.filterType.x = self.area.left.x + 1
  self.button.filterType.y = self.area.left.y + 1
  self.button.filterType.width = 6
  self.button.filterType.height = 3
  self.button.filterType.val = 1
  
  self.button.sortDir = {}
  self.button.sortDir.x = self.button.filterType.x
  self.button.sortDir.y = self.button.filterType.y + self.button.filterType.height + 1
  self.button.sortDir.width = 6
  self.button.sortDir.height = 3
  self.button.sortDir.val = 1
  
  self.button.sortType = {}
  self.button.sortType.x = self.button.sortDir.x
  self.button.sortType.y = self.button.sortDir.y + self.button.sortDir.height + 1
  self.button.sortType.width = 6
  self.button.sortType.height = 3
  self.button.sortType.val = 1
  
  self.button.labelType = {}
  self.button.labelType.x = self.button.sortType.x
  self.button.labelType.y = self.button.sortType.y + self.button.sortType.height + 1
  self.button.labelType.width = 6
  self.button.labelType.height = 3
  self.button.labelType.val = 1
  
  self:setStorageItems(storageItems)
  self.storageServerAddress = storageServerAddress
  
  return obj
end

function Gui:drawButtonFilterType()
  gpu.setBackground(self.palette.button, true)
  gpu.fill(self.button.filterType.x, self.button.filterType.y, self.button.filterType.width, self.button.filterType.height, " ")
  if self.button.filterType.val == 1 then
    gpu.set(self.button.filterType.x, self.button.filterType.y + 1, "Patter")
  else
    gpu.set(self.button.filterType.x, self.button.filterType.y + 1, "Fixed")
  end
  gpu.set(self.button.filterType.x + 1, self.button.filterType.y + 2, "[P]")
end

function Gui:drawButtonSortDir()
  gpu.setBackground(self.palette.button, true)
  gpu.fill(self.button.sortDir.x, self.button.sortDir.y, self.button.sortDir.width, self.button.sortDir.height, " ")
  if self.button.sortDir.val == 1 then
    gpu.set(self.button.sortDir.x + 2, self.button.sortDir.y + 1, "/\\")
  else
    gpu.set(self.button.sortDir.x + 2, self.button.sortDir.y + 1, "\\/")
  end
  gpu.set(self.button.sortDir.x + 1, self.button.sortDir.y + 2, "[D]")
end

function Gui:drawButtonSortType()
  gpu.setBackground(self.palette.button, true)
  gpu.fill(self.button.sortType.x, self.button.sortType.y, self.button.sortType.width, self.button.sortType.height, " ")
  if self.button.sortType.val == 1 then
    gpu.set(self.button.sortType.x + 1, self.button.sortType.y + 1, "Name")
  elseif self.button.sortType.val == 2 then
    gpu.set(self.button.sortType.x + 2, self.button.sortType.y + 1, "ID")
  else
    gpu.set(self.button.sortType.x + 1, self.button.sortType.y + 1, "Quan")
  end
  gpu.set(self.button.sortType.x + 1, self.button.sortType.y + 2, "[S]")
end

function Gui:drawButtonLabelType()
  gpu.setBackground(self.palette.button, true)
  gpu.fill(self.button.labelType.x, self.button.labelType.y, self.button.labelType.width, self.button.labelType.height, " ")
  if self.button.labelType.val == 1 then
    gpu.set(self.button.labelType.x, self.button.labelType.y + 1, "Extern")
  else
    gpu.set(self.button.labelType.x, self.button.labelType.y + 1, "Intern")
  end
  gpu.set(self.button.labelType.x + 1, self.button.labelType.y + 2, "[L]")
end

function Gui:drawAreaLeft()
  gpu.setBackground(self.palette.bg2, true)
  gpu.fill(self.area.left.x, self.area.left.y, self.area.left.width, self.area.left.height, " ")
  self:drawButtonFilterType()
  self:drawButtonSortDir()
  self:drawButtonSortType()
  self:drawButtonLabelType()
end

function Gui:drawAreaRight()
  gpu.setBackground(self.palette.crafting, true)
  gpu.fill(self.area.right.x, self.area.right.y, self.area.right.width, self.area.right.height, " ")
end

function Gui:drawTextBox()
  gpu.setBackground(0x000000)
  gpu.fill(self.textBox.x, self.textBox.y, self.textBox.width, 1, " ")
  gpu.set(self.textBox.x, self.textBox.y, string.sub(self.textBox.contents, self.textBox.scroll + 1, self.textBox.scroll + self.textBox.width))
  if self.textBox.selected then
    gpu.setBackground(0xFFFFFF)
    gpu.setForeground(0x000000)
    gpu.set(self.textBox.x + self.textBox.cursor - 1 - self.textBox.scroll, self.textBox.y, self.textBox.cursor <= #self.textBox.contents and string.sub(self.textBox.contents, self.textBox.cursor, self.textBox.cursor) or " ")
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
  end
end

function Gui:drawAreaTop()
  gpu.setBackground(self.palette.bg, true)
  gpu.fill(self.area.top.x, self.area.top.y, self.area.top.width, self.area.top.height, " ")
  gpu.set(self.area.top.x + 1, self.area.top.y + 1, "Storage Network")
  self:drawTextBox()
end

function Gui:drawAreaBottom()
  gpu.setBackground(self.palette.bg, true)
  gpu.fill(self.area.bottom.x, self.area.bottom.y, self.area.bottom.width, self.area.bottom.height, " ")
end

function Gui:drawScrollBar()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  local barLength = math.max(self.scrollBar.height - self.scrollBar.maxScroll, 1)
  local barText
  if barLength > 1 then
    barText = text.padRight(string.rep(" ", self.scrollBar.scroll) .. string.rep("\u{2588}", barLength), self.scrollBar.height)
  else
    barText = text.padRight(string.rep(" ", math.floor(self.scrollBar.scroll / (self.scrollBar.maxScroll + 1) * self.scrollBar.height)) .. "\u{2588}", self.scrollBar.height)
  end
  gpu.set(self.scrollBar.x, self.scrollBar.y, barText, true)
end

-- Drawing text in columns with alternating background colors is taxing on the
-- GPU to switch backgrounds/foregrounds so frequently. We can optimize by
-- drawing all of the text with the same color background and foreground at
-- once, then switch colors. It also helps to group text into the largest chunk
-- possible to minimize calls to gpu.set() as this call is only about twice as
-- fast as gpu.setBackground() and gpu.setForeground().
function Gui:drawTextTable(textTable)
  local bgColor = gpu.getBackground()
  local fgColor = gpu.getForeground()
  for bg, fgGroup in pairs(textTable) do
    if bg ~= bgColor then
      gpu.setBackground(bg, true)
      bgColor = bg
    end
    for fg, strGroup in pairs(fgGroup) do
      if fg ~= fgColor then
        gpu.setForeground(fg, true)
        fgColor = fg
      end
      for _, str in ipairs(strGroup) do
        gpu.set(str[1], str[2], str[3])
      end
    end
  end
  
  --[[
  Data format looks like the following.
  
  textTable: {
    <bg>: {
      <fg>: {
        1: {
          1: <x>
          2: <y>
          3: <string>
        }
        2: {
          1: <x>
          2: <y>
          3: <string>
        }
        ...
      }
      ...
    }
    ...
  }
  --]]
end

-- Draw the item table with the list of all items in the network. Depending on
-- the graphics card this may be a single column or multiple column table. This
-- uses a lazy-draw system so that this function can be called as many times as
-- necessary but will only draw as fast as the lazy interval (handled by an
-- external thread). Setting force to true overrides this behavior and the table
-- will draw immediately.
function Gui:drawAreaItem(force)
  if not force then
    self.drawAreaItemRequested = true
    return
  end
  
  
  
  local timeStart = computer.uptime()
  
  
  
  local textTable1 = {}    -- Represents the first layer (item totals and the fill area for each row).
  textTable1[self.palette.item1] = {}
  textTable1[self.palette.item2] = {}
  local textTable2 = {}    -- Represents the second layer (item external/internal names).
  textTable2[self.palette.item1] = {}
  textTable2[self.palette.item2] = {}
  -- Item index starts at first or last entry (depending on sort direction) with an offset for the scroll.
  local itemIndex = (self.button.sortDir.val == 1 and 1 or #self.filteredItems) + self.scrollBar.scroll * self.area.numItemColumns * self.button.sortDir.val
  local bgColor, fgColor
  local totalsLine = ""
  
  -- Iterate through each entry in table, corresponds to item index.
  for i = 0, self.area.numItemColumns * self.area.item1.height - 1 do
    local x = i % self.area.numItemColumns
    local y = math.floor(i / self.area.numItemColumns)
    local itemArea = self.area["item" .. x + 1]
    bgColor = (y + self.scrollBar.scroll) % 2 == 0 and self.palette.item1 or self.palette.item2
    
    -- If entry corresponds to an item (it's not a blank one near the end) then add it to textTable2 for drawing. Otherwise we just add a blank line.
    if itemIndex >= 1 and itemIndex <= #self.filteredItems then
      local itemName = self.filteredItems[itemIndex]
      local displayName = (self.button.labelType.val == 1 and self.storageItems[itemName].label .. (string.sub(itemName, #itemName) == "n" and " (+NBT)" or "") or itemName)
      fgColor = self.palette["mod" .. (djb2StringHash(string.match(itemName, "[^:]+")) % 6 + 1)]
      
      -- Append to the totalsLine with the item count and some spacing.
      local totalFormatted = self.storageItems[itemName].total < 1000000 and string.format("%5d", self.storageItems[itemName].total) or "######"
      totalsLine = totalsLine .. text.padRight(totalFormatted, x ~= self.area.numItemColumns - 1 and self.area["item" .. x + 2].x - itemArea.x or itemArea.width)
      
      -- Add item label to the text table (layer 2).
      if not textTable2[bgColor][fgColor] then textTable2[bgColor][fgColor] = {} end
      textTable2[bgColor][fgColor][#textTable2[bgColor][fgColor] + 1] = {itemArea.x + 6, itemArea.y + y, string.sub(displayName, 1, itemArea.width - 6)}
      
      itemIndex = itemIndex + self.button.sortDir.val
    else
      totalsLine = totalsLine .. string.rep(" ", x ~= self.area.numItemColumns - 1 and self.area["item" .. x + 2].x - itemArea.x or itemArea.width)
    end
    
    -- If this is the last column, we add the totalsLine to the text table (layer 1).
    if x == self.area.numItemColumns - 1 then
      fgColor = self.palette.fg
      if not textTable1[bgColor][fgColor] then textTable1[bgColor][fgColor] = {} end
      textTable1[bgColor][fgColor][#textTable1[bgColor][fgColor] + 1] = {self.area.item1.x, self.area.item1.y + y, totalsLine}
      totalsLine = ""
    end
  end
  
  -- Draw the text that was added to the tables for each layer, then draw any separators between tables.
  self:drawTextTable(textTable1)
  self:drawTextTable(textTable2)
  gpu.setBackground(self.palette.bg, true)
  for i = 1, self.area.numItemColumns - 1 do
    for j = self.area["item" .. i].x + self.area["item" .. i].width, self.area["item" .. i + 1].x - 1 do
      gpu.set(j, self.area.item1.y, string.rep(" ", self.area.item1.height), true)
    end
  end
  
  
  
  local timeEnd = computer.uptime()
  term.clearLine()
  io.write("took " .. timeEnd - timeStart .. "s")
end

function Gui:draw()
  term.clear()
  gpu.setBackground(self.palette.bg, true)
  local width, height = term.getViewport()
  gpu.fill(1, 1, width, height, " ")
  self:drawAreaLeft()
  self:drawAreaRight()
  self:drawAreaTop()
  self:drawAreaBottom()
  self:drawAreaItem()
  self:drawScrollBar()
end

function Gui:getSortingKeyName(itemName)
  if self.button.sortType.val == 1 then    -- Sort by name.
    return self.storageItems[itemName].label .. "," .. itemName
  elseif self.button.sortType.val == 2 then    -- Sort by ID.
    return itemName
  else    -- Sort by quantity.
    -- Really neat idea to sort string numbers http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua
    return string.format("%03d%s", #tostring(self.storageItems[itemName].total), tostring(self.storageItems[itemName].total)) .. "," .. itemName
  end
end

function Gui:rebuildSortingKeys()
  self.sortingKeys = {}
  for itemName, itemDetails in pairs(self.storageItems) do
    self.sortingKeys[#self.sortingKeys + 1] = self:getSortingKeyName(itemName)
  end
  self:updateSortingKeys()
end

function Gui:setStorageItems(storageItems)
  self.storageItems = storageItems
  self:rebuildSortingKeys()
end

function Gui:addSortingKey(itemName)
  self.sortingKeys[#self.sortingKeys + 1] = self:getSortingKeyName(itemName)
end

function Gui:removeSortingKey(itemName)
  local keyName = self:getSortingKeyName(itemName)
  
  -- Search for the key in sortingKeys and remove it (replace with last element).
  for i, v in ipairs(self.sortingKeys) do
    if v == keyName then
      self.sortingKeys[i] = self.sortingKeys[#self.sortingKeys]
      self.sortingKeys[#self.sortingKeys] = nil
      break
    end
  end
end

function Gui:updateSortingKeys()
  table.sort(self.sortingKeys)
  self:updateFilteredItems()
  self:drawAreaItem()
end

function Gui:updateFilteredItemsUnsafe()
  local filterString = string.lower(text.trim(self.textBox.contents))
  local useInternalName = false
  if string.sub(filterString, 1, 1) == "#" then
    filterString = string.sub(filterString, 2)
    useInternalName = true
  end
  local plainMatch = false
  if self.button.filterType.val == 2 then
    plainMatch = true
  end
  
  for _, keyName in ipairs(self.sortingKeys) do
    local itemName = string.match(keyName, "[^,]+$") or keyName
    if useInternalName then
      if string.find(string.lower(itemName), filterString, 1, plainMatch) then
        self.filteredItems[#self.filteredItems + 1] = itemName
      end
    elseif string.find(string.lower(self.storageItems[itemName].label), filterString, 1, plainMatch) then
      self.filteredItems[#self.filteredItems + 1] = itemName
    end
  end
end

function Gui:updateFilteredItems()
  -- If pattern matching in string.find() throws an exception, suppress it and continue.
  self.filteredItems = {}
  pcall(function() self:updateFilteredItemsUnsafe() end)
  self:updateScrollBar(0)
end

function Gui:clearTextBox()
  self.textBox.cursor = 1
  self.textBox.scroll = 0
  self.textBox.contents = ""
  self:drawTextBox()
end

function Gui:setTextBoxCursor(position)
  self.textBox.cursor = position
  if position <= self.textBox.scroll then
    self.textBox.scroll = position - 1
  elseif position > self.textBox.scroll + self.textBox.width then
    self.textBox.scroll = position - self.textBox.width
  end
  self:drawTextBox()
end

function Gui:updateScrollBar(direction)
  self.scrollBar.maxScroll = math.max(math.floor(math.ceil(#self.filteredItems / self.area.numItemColumns) - self.area.item1.height), 0)
  self.scrollBar.scroll = math.min(math.max(self.scrollBar.scroll - math.floor(direction), 0), self.scrollBar.maxScroll)
  self:drawScrollBar()
end

function Gui:toggleButtonFilterType()
  self.button.filterType.val = (self.button.filterType.val % 2) + 1
  self:drawButtonFilterType()
  self:updateFilteredItems()
  self:drawAreaItem()
end

function Gui:toggleButtonSortDir()
  self.button.sortDir.val = -self.button.sortDir.val
  self:drawButtonSortDir()
  self:drawAreaItem()
end

function Gui:toggleButtonSortType()
  self.button.sortType.val = (self.button.sortType.val % 3) + 1
  self:drawButtonSortType()
  self:rebuildSortingKeys()
end

function Gui:toggleButtonLabelType()
  self.button.labelType.val = (self.button.labelType.val % 2) + 1
  self:drawButtonLabelType()
  self:drawAreaItem()
end

function Gui:handleKeyDown(keyboardAddress, char, code, playerName)
  --print("handleKeyDown", keyboardAddress, char, code, playerName)
  if self.textBox.selected then
    if keyboard.isControl(char) then
      if code == keyboard.keys.back then
        if self.textBox.cursor > 1 then
          self.textBox.contents = string.sub(self.textBox.contents, 1, self.textBox.cursor - 2) .. string.sub(self.textBox.contents, self.textBox.cursor)
          self:setTextBoxCursor(self.textBox.cursor - 1)
          self:updateFilteredItems()
          self:drawAreaItem()
        end
      elseif code == keyboard.keys.delete then
        self.textBox.contents = string.sub(self.textBox.contents, 1, self.textBox.cursor - 1) .. string.sub(self.textBox.contents, self.textBox.cursor + 1)
        self:drawTextBox()
        self:updateFilteredItems()
        self:drawAreaItem()
      elseif code == keyboard.keys.enter or code == keyboard.keys.numpadenter then
        print("enter")
      elseif code == keyboard.keys.home then
        self:setTextBoxCursor(1)
      elseif code == keyboard.keys.lcontrol then
        self:clearTextBox()
        self:updateFilteredItems()
        self:drawAreaItem()
      elseif code == keyboard.keys.left then
        self:setTextBoxCursor(math.max(self.textBox.cursor - 1, 1))
      elseif code == keyboard.keys.right then
        self:setTextBoxCursor(math.min(self.textBox.cursor + 1, #self.textBox.contents + 1))
      elseif code == keyboard.keys["end"] then
        self:setTextBoxCursor(#self.textBox.contents + 1)
      elseif code == keyboard.keys.tab then
        self.textBox.selected = false
        self:drawTextBox()
      end
    else
      self.textBox.contents = string.sub(self.textBox.contents, 1, self.textBox.cursor - 1) .. string.char(char) .. string.sub(self.textBox.contents, self.textBox.cursor)
      self:setTextBoxCursor(self.textBox.cursor + 1)
      self:updateFilteredItems()
      self:drawAreaItem()
    end
  else
    if keyboard.isControl(char) then
      if code == keyboard.keys.home then
        self.scrollBar.scroll = 0
        self:drawScrollBar()
        self:drawAreaItem()
      elseif code == keyboard.keys["end"] then
        self.scrollBar.scroll = self.scrollBar.maxScroll
        self:drawScrollBar()
        self:drawAreaItem()
      elseif code == keyboard.keys.tab then
        self.textBox.selected = true
        self:drawTextBox()
      end
    elseif char == string.byte("p") then
      self:toggleButtonFilterType()
    elseif char == string.byte("d") then
      self:toggleButtonSortDir()
    elseif char == string.byte("s") then
      self:toggleButtonSortType()
    elseif char == string.byte("l") then
      self:toggleButtonLabelType()
    end
  end
end

function Gui:handleKeyUp(keyboardAddress, char, code, playerName)
  --print("handleKeyUp", keyboardAddress, char, code, playerName)
end

function Gui:handleTouch(screenAddress, x, y, button, playerName)
  --print("handleTouch", screenAddress, x, y, button, playerName)
  x = math.floor(x)
  y = math.floor(y)
  if isPointInRectangle(x, y, self.button.filterType.x, self.button.filterType.y, self.button.filterType.width, self.button.filterType.height) then
    self:toggleButtonFilterType()
  elseif isPointInRectangle(x, y, self.button.sortDir.x, self.button.sortDir.y, self.button.sortDir.width, self.button.sortDir.height) then
    self:toggleButtonSortDir()
  elseif isPointInRectangle(x, y, self.button.sortType.x, self.button.sortType.y, self.button.sortType.width, self.button.sortType.height) then
    self:toggleButtonSortType()
  elseif isPointInRectangle(x, y, self.button.labelType.x, self.button.labelType.y, self.button.labelType.width, self.button.labelType.height) then
    self:toggleButtonLabelType()
  else
    for i = 1, self.area.numItemColumns do
      local itemArea = self.area["item" .. i]
      if isPointInRectangle(x, y, itemArea.x, itemArea.y, itemArea.width, itemArea.height) then
        local itemIndex = (self.button.sortDir.val == 1 and 1 or #self.filteredItems) + self.scrollBar.scroll * self.area.numItemColumns * self.button.sortDir.val
        itemIndex = itemIndex + ((y - itemArea.y) * self.area.numItemColumns + (i - 1)) * self.button.sortDir.val
        if self.filteredItems[itemIndex] then
          wnet.send(modem, self.storageServerAddress, COMMS_PORT, "stor_extract," .. self.filteredItems[itemIndex] .. ",")
        end
      end
    end
  end
end

function Gui:handleScroll(screenAddress, x, y, direction, playerName)
  --print("handleScroll", screenAddress, x, y, direction, playerName)
  self:updateScrollBar(direction)
  self:drawAreaItem()
end

local function main()
  local threadSuccess = false
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  local storageServerAddress, storageItems, gui
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    modem.open(COMMS_PORT)
    wnet.debug = false
    
    local attemptNumber = 1
    while not storageServerAddress do
      term.clearLine()
      io.write("Trying to contact storage controller on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
      
      wnet.send(modem, nil, COMMS_PORT, "stor_discover,")
      local address, port, data = wnet.receive(2)
      if address and port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        if dataType == "craftinter_item_list" then
          storageItems = serialization.unserialize(data)
          storageServerAddress = address
        end
      end
      attemptNumber = attemptNumber + 1
    end
    io.write("\nSuccess.\n")
    
    print(" - items - ")
    tdebug.printTable(storageItems)
    
    gui = Gui:new(nil, storageItems, storageServerAddress)
    gui:draw()
    
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
              gui:removeSortingKey(itemName)
              storageItems[itemName] = nil
            elseif storageItems[itemName] then
              storageItems[itemName].total = diff.total
            else
              storageItems[itemName] = {}
              storageItems[itemName].label = diff.label
              storageItems[itemName].total = diff.total
              gui:addSortingKey(itemName)
            end
          end
          gui:updateSortingKeys()
        elseif dataType == "craftinter_stor_started" then
          -- If we get a broadcast that storage started, it must have just rebooted and we need to discover new storageItems.
          wnet.send(modem, address, COMMS_PORT, "stor_discover,")
        elseif dataType == "craftinter_item_list" then
          -- New item list, update storageItems and GUI.
          storageItems = serialization.unserialize(data)
          storageServerAddress = address
          gui:setStorageItems(storageItems)
          gui.storageServerAddress = address
        end
      end
    end
  end)
  
  -- Listens for keyboard and screen events and sends them to the GUI.
  local userInputThread = thread.create(function()
    local function filterEvents(eventName, ...)
      return eventName == "key_down" or eventName == "key_up" or eventName == "touch" or eventName == "scroll"
    end
    while true do
      local ev = {event.pullFiltered(filterEvents)}
      
      if ev[1] == "key_down" then
        gui:handleKeyDown(select(2, table.unpack(ev)))
      elseif ev[1] == "key_up" then
        gui:handleKeyUp(select(2, table.unpack(ev)))
      elseif ev[1] == "touch" then
        gui:handleTouch(select(2, table.unpack(ev)))
      elseif ev[1] == "scroll" then
        gui:handleScroll(select(2, table.unpack(ev)))
      end
    end
  end)
  
  -- Redraws parts of the GUI as set from flags. This prevents some slow drawing
  -- tasks from lagging the UI. Used to use an event-based system but it seems a
  -- lot more performant when using os.sleep() loop.
  local guiLazyDrawThread = thread.create(function()
    while true do
      os.sleep(gui.LAZY_DRAW_INTERVAL)
      if gui.drawAreaItemRequested then
        gui:drawAreaItem(true)
        gui.drawAreaItemRequested = false
      end
    end
  end)
  
  --[[
  -- Continuously get user input and send commands to storage controller.
  local commandThread = thread.create(function()
    while true do
      io.write("> ")
      local input = io.read()
      if type(input) ~= "string" then
        input = "exit"
      end
      input = text.tokenize(input)
      if input[1] == "l" then    -- List.
        io.write("Storage contents:\n")
        for itemName, itemDetails in pairs(storageItems) do
          io.write("  " .. itemDetails.total .. "  " .. itemName .. "\n")
        end
      elseif input[1] == "r" then    -- Request.
        --print("result = ", extractStorage(transposers, routing, storageItems, "output", 1, nil, input[2], tonumber(input[3])))
        input[2] = input[2] or ""
        input[3] = input[3] or ""
        wnet.send(modem, storageServerAddress, COMMS_PORT, "stor_extract," .. input[2] .. "," .. input[3])
      elseif input[1] == "a" then    -- Add.
        --print("result = ", insertStorage(transposers, routing, storageItems, "input", 1))
        wnet.send(modem, storageServerAddress, COMMS_PORT, "stor_insert,")
      elseif input[1] == "d" then
        print(" - items - ")
        tdebug.printTable(storageItems)
      elseif input[1] == "exit" then
        break
      else
        print("Enter \"l\" to list, \"r <item> <count>\" to request, \"a\" to add, or \"exit\" to quit.")
      end
    end
    threadSuccess = true
  end)
  --]]
  
  thread.waitForAny({interruptThread, modemThread, userInputThread, guiLazyDrawThread})
  if interruptThread:status() == "dead" then
    os.exit(1)
  elseif not threadSuccess then
    io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
    os.exit(1)
  end
  
  interruptThread:kill()
  modemThread:kill()
  userInputThread:kill()
  guiLazyDrawThread:kill()
end

main()
