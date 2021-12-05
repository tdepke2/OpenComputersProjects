--[[
Interface server application code.


--]]

-- OS libraries.
local component = require("component")
local computer = require("computer")
local event = require("event")
local gpu = component.gpu
local keyboard = require("keyboard")
local modem = component.modem
local screen = component.screen
local serialization = require("serialization")
local term = require("term")
local text = require("text")
local thread = require("thread")

-- User libraries.
local include = require("include")
local dlog = include("dlog")
dlog.osBlockNewGlobals(true)
local packer = include("packer")
local wnet = include("wnet")

local COMMS_PORT = 0xE298
local DLOG_FILE_OUT = ""

-- Checks if given point lies within the bounds (inclusive).
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

-- Wrapper for gpu.setBackground() that prevents the direct (slow) GPU call if
-- background already set to the desired color.
local function gpuSetBackground(color, isPaletteIndex)
  isPaletteIndex = isPaletteIndex or false
  local currColor, currIsPalette = gpu.getBackground()
  if color ~= currColor or isPaletteIndex ~= currIsPalette then
    gpu.setBackground(color, isPaletteIndex)
  end
end

-- Same as gpuSetBackground() but for foreground color.
local function gpuSetForeground(color, isPaletteIndex)
  isPaletteIndex = isPaletteIndex or false
  local currColor, currIsPalette = gpu.getForeground()
  if color ~= currColor or isPaletteIndex ~= currIsPalette then
    gpu.setForeground(color, isPaletteIndex)
  end
end

local Gui = {
  ITEM_LABEL_WIDTH = 40, --45 FIXME #########################################################
  LEFT_COLUMN_WIDTH = 8,
  RIGHT_COLUMN_WIDTH = 26,
  TOP_ROW_HEIGHT = 4,
  BOTTOM_ROW_HEIGHT = 3,
  
  -- Lazy draw used to batch drawing tasks and limit draw rate for performance.
  LAZY_DRAW_INTERVAL = 0.05
}

-- Hook up errors to throw on access to nil class members (usually a programming
-- error or typo).
setmetatable(Gui, {
  __index = function(t, k)
    dlog.errorWithTraceback("Attempt to read undefined member " .. tostring(k) .. " in Gui class.")
  end
})

function Gui:new(storageItems, storageServerAddress, recipeItems, craftingServerAddress)
  self.__index = self
  self = setmetatable({}, self)
  
  -- The self.drawRequest table acts like a queue of draw calls (important to
  -- keep the draw calls in the order they arrive).
  self.drawRequest = {}
  
  -- Press alt key to show craftable items only (hide amounts).
  self.keyShowCraftingPressed = false
  
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
  
  self.area.craftingItem = {}
  self.area.craftingItem.x = self.area.right.x + 1
  self.area.craftingItem.y = self.area.item1.y
  self.area.craftingItem.width = self.area.right.width - 3
  self.area.craftingItem.height = self.area.item1.height
  
  self.textBox = {}
  self.textBox.x = self.area.top.x + 17
  self.textBox.y = self.area.top.y + 1
  self.textBox.width = self.area.top.x + self.area.top.width - self.textBox.x - 1
  self.textBox.selected = false
  self.textBox.cursor = 1
  self.textBox.scroll = 0
  self.textBox.contents = ""
  
  -- In searchMode, self.textBox.searchContents matches edits made to self.textBox.contents.
  -- Otherwise, the search contents stays how it is to allow text box to be used for other things (like entering amount of item to request).
  self.textBox.searchMode = true
  self.textBox.searchContents = ""
  self.textBox.requestedItem = ""
  self.textBox.requestedCrafting = false
  
  self.scrollBar = {}
  self.scrollBar.x = self.area["item" .. self.area.numItemColumns].x + self.area["item" .. self.area.numItemColumns].width + 1
  self.scrollBar.y = self.area.item1.y
  self.scrollBar.height = self.area.item1.height
  self.scrollBar.scroll = 0
  self.scrollBar.maxScroll = 0
  
  self.craftingScrollBar = {}
  self.craftingScrollBar.x = self.area.craftingItem.x + self.area.craftingItem.width
  self.craftingScrollBar.y = self.area.craftingItem.y
  self.craftingScrollBar.height = self.area.craftingItem.height
  self.craftingScrollBar.scroll = 0
  self.craftingScrollBar.maxScroll = 0
  
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
  
  self.button.lastPage = {}
  self.button.lastPage.x = self.area.right.x + 1
  self.button.lastPage.y = self.area.right.y + 2
  self.button.lastPage.width = 8
  self.button.lastPage.height = 1
  
  self.button.nextPage = {}
  self.button.nextPage.x = self.area.right.x + self.area.right.width - 1 - 8
  self.button.nextPage.y = self.area.right.y + 2
  self.button.nextPage.width = 8
  self.button.nextPage.height = 1
  
  self.button.start = {}
  self.button.start.x = self.area.right.x + 1
  self.button.start.y = self.area.right.y + self.area.right.height - 1 - 1
  self.button.start.width = 8
  self.button.start.height = 1
  
  self.button.cancel = {}
  self.button.cancel.x = self.area.right.x + self.area.right.width - 1 - 8
  self.button.cancel.y = self.area.right.y + self.area.right.height - 1 - 1
  self.button.cancel.width = 8
  self.button.cancel.height = 1
  
  self.crafting = {}
  self.crafting.pendingCraftRequests = {}
  self.crafting.activeCraftRequests = {}
  
  self.storageItems = storageItems
  self.storageServerAddress = storageServerAddress
  self.recipeItems = recipeItems
  self.craftingServerAddress = craftingServerAddress
  self:rebuildSortingKeys()
  
  -- Flush draw queue so that things don't draw out-of-order in the first call to Gui:draw().
  self.drawRequest = {}
  
  return self
end

-- Drawing text in columns with alternating background colors is taxing on the
-- GPU to switch backgrounds/foregrounds so frequently. We can optimize by
-- drawing all of the text with the same color background and foreground at
-- once, then switch colors. It also helps to group text into the largest chunk
-- possible to minimize calls to gpu.set() as this call is only about twice as
-- fast as gpu.setBackground() and gpu.setForeground().
function Gui:renderTextTable(textTable)
  for bg, fgGroup in pairs(textTable) do
    gpuSetBackground(bg, true)
    for fg, strGroup in pairs(fgGroup) do
      gpuSetForeground(fg, true)
      for _, str in ipairs(strGroup) do
        gpu.set(str[1], str[2], str[3])
      end
    end
  end
end
--[[
Data format for textTable looks like the following.

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

-- Queue a draw function call to self.drawRequest array. Drawable functions in
-- the GUI use this internally to enable the lazy drawing.
function Gui:addDrawRequest(drawFunc)
  for _, v in ipairs(self.drawRequest) do
    if drawFunc == v then
      return
    end
  end
  self.drawRequest[#self.drawRequest + 1] = drawFunc
end

-- Draw button for choosing pattern matching or fixed matching in search box.
function Gui:drawButtonFilterType(force)
  if not force then self:addDrawRequest(Gui.drawButtonFilterType) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.fill(self.button.filterType.x, self.button.filterType.y, self.button.filterType.width, self.button.filterType.height, " ")
  if self.button.filterType.val == 1 then
    gpu.set(self.button.filterType.x, self.button.filterType.y + 1, "Patter")
  else
    gpu.set(self.button.filterType.x, self.button.filterType.y + 1, "Fixed")
  end
  gpu.set(self.button.filterType.x + 1, self.button.filterType.y + 2, "[P]")
end

-- Draw button for choosing the sorting direction.
function Gui:drawButtonSortDir(force)
  if not force then self:addDrawRequest(Gui.drawButtonSortDir) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.fill(self.button.sortDir.x, self.button.sortDir.y, self.button.sortDir.width, self.button.sortDir.height, " ")
  if self.button.sortDir.val == 1 then
    gpu.set(self.button.sortDir.x + 2, self.button.sortDir.y + 1, "/\\")
  else
    gpu.set(self.button.sortDir.x + 2, self.button.sortDir.y + 1, "\\/")
  end
  gpu.set(self.button.sortDir.x + 1, self.button.sortDir.y + 2, "[D]")
end

-- Draw button for choosing the sorting behavior (by name, by internal ID, or by
-- quantity).
function Gui:drawButtonSortType(force)
  if not force then self:addDrawRequest(Gui.drawButtonSortType) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
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

-- Draw button for choosing the format item names will use when displayed in the
-- item list (external or internal names).
function Gui:drawButtonLabelType(force)
  if not force then self:addDrawRequest(Gui.drawButtonLabelType) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.fill(self.button.labelType.x, self.button.labelType.y, self.button.labelType.width, self.button.labelType.height, " ")
  if self.button.labelType.val == 1 then
    gpu.set(self.button.labelType.x, self.button.labelType.y + 1, "Extern")
  else
    gpu.set(self.button.labelType.x, self.button.labelType.y + 1, "Intern")
  end
  gpu.set(self.button.labelType.x + 1, self.button.labelType.y + 2, "[L]")
end

-- Draw left pane.
function Gui:drawAreaLeft(force)
  if not force then self:addDrawRequest(Gui.drawAreaLeft) return end
  gpuSetBackground(self.palette.bg2, true)
  gpu.fill(self.area.left.x, self.area.left.y, self.area.left.width, self.area.left.height, " ")
  self:drawButtonFilterType()
  self:drawButtonSortDir()
  self:drawButtonSortType()
  self:drawButtonLabelType()
end

function Gui:drawButtonLastPage(force)
  if not force then self:addDrawRequest(Gui.drawButtonLastPage) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.set(self.button.lastPage.x, self.button.lastPage.y, "   <<   ")
end

function Gui:drawButtonNextPage(force)
  if not force then self:addDrawRequest(Gui.drawButtonNextPage) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.set(self.button.nextPage.x, self.button.nextPage.y, "   >>   ")
end

function Gui:drawButtonStart(force)
  if not force then self:addDrawRequest(Gui.drawButtonStart) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.set(self.button.start.x, self.button.start.y, " Start  ")
end

function Gui:drawButtonCancel(force)
  if not force then self:addDrawRequest(Gui.drawButtonCancel) return end
  gpuSetBackground(self.palette.button, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.set(self.button.cancel.x, self.button.cancel.y, " Cancel ")
end

-- Draw item table for the crafting pane. The drawing is deferred to
-- Gui:renderTextTable() for performance reasons.
function Gui:drawAreaCraftingItem(force)
  if not force then self:addDrawRequest(Gui.drawAreaCraftingItem) return end
  
  local textTable = {}
  textTable[self.palette.item1] = {}
  textTable[self.palette.item2] = {}
  textTable[self.palette.mod1] = {}
  local itemIndex = 1 + self.craftingScrollBar.scroll
  local bgColor, fgColor
  
  local _, craftProgress = next(self.crafting.pendingCraftRequests)
  if not craftProgress then
    craftProgress = {}
  end
  
  -- The item list for a crafting operation should be relatively small, so we just rebuild the sorting keys each draw call.
  local sortingKeys = {}
  local i = 1
  for k, _ in pairs(craftProgress) do
    sortingKeys[i] = k
    i = i + 1
  end
  table.sort(sortingKeys)
  
  -- Iterate through each entry in table, corresponds to item index (except we only advance the index at odd values of i).
  local itemArea = self.area.craftingItem
  for i = 0, self.area.craftingItem.height - 1 do
    bgColor = (i + self.craftingScrollBar.scroll) % 2 == 0 and self.palette.item1 or self.palette.item2
    local textLine
    
    -- If entry corresponds to an item (it's not a blank one near the end) then set textLine for drawing. Otherwise we just add a blank line.
    if itemIndex >= 1 and itemIndex <= #sortingKeys then
      local itemName = sortingKeys[itemIndex]
      
      -- If i is even, we display only the item name with its mod color. Otherwise we display the amount required/missing/craft for the item.
      if i % 2 == 0 then
        fgColor = self.palette["mod" .. (djb2StringHash(string.match(itemName, "[^:]+")) % 6 + 1)]
        textLine = string.sub(itemName, 1, itemArea.width)
      else
        fgColor = self.palette.fg
        textLine = "-"
        local amountNeeded = craftProgress[itemName].inp - craftProgress[itemName].out
        if amountNeeded > 0 then
          textLine = textLine .. " R " .. amountNeeded
        end
        if craftProgress[itemName].out == 0 and amountNeeded > craftProgress[itemName].hav then
          bgColor = self.palette.mod1
          textLine = textLine .. " M " .. amountNeeded - craftProgress[itemName].hav
        elseif craftProgress[itemName].out > 0 then
          textLine = textLine .. " C " .. craftProgress[itemName].out
        end
        itemIndex = itemIndex + 1
      end
    else
      fgColor = self.palette.fg
      textLine = string.rep(" ", itemArea.width)
    end
    
    if not textTable[bgColor][fgColor] then textTable[bgColor][fgColor] = {} end
    textTable[bgColor][fgColor][#textTable[bgColor][fgColor] + 1] = {itemArea.x, itemArea.y + i, text.padRight(textLine, itemArea.width)}
  end
  
  -- Draw the text that was added to the table.
  self:renderTextTable(textTable)
end

-- Draw right pane.
function Gui:drawAreaRight(force)
  if not force then self:addDrawRequest(Gui.drawAreaRight) return end
  gpuSetBackground(self.palette.crafting, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.fill(self.area.right.x, self.area.right.y, self.area.right.width, self.area.right.height, " ")
  gpu.set(self.area.right.x + 1, self.area.right.y + 1, "Status and Crafting")
  self:drawButtonLastPage()
  self:drawButtonNextPage()
  self:drawButtonStart()
  self:drawButtonCancel()
  self:drawAreaCraftingItem()
  self:drawCraftingScrollBar()
end

-- Draw the search box for the main items list.
function Gui:drawTextBox(force)
  if not force then self:addDrawRequest(Gui.drawTextBox) return end
  gpuSetBackground(0x000000)
  gpuSetForeground(self.palette.fg, true)
  gpu.fill(self.textBox.x, self.textBox.y, self.textBox.width, 1, " ")
  gpu.set(self.textBox.x, self.textBox.y, string.sub(self.textBox.contents, self.textBox.scroll + 1, self.textBox.scroll + self.textBox.width))
  if self.textBox.selected then
    gpuSetBackground(self.palette.fg, true)
    gpuSetForeground(0x000000)
    gpu.set(self.textBox.x + self.textBox.cursor - 1 - self.textBox.scroll, self.textBox.y, self.textBox.cursor <= #self.textBox.contents and string.sub(self.textBox.contents, self.textBox.cursor, self.textBox.cursor) or " ")
  end
end

-- Draw top pane.
function Gui:drawAreaTop(force)
  if not force then self:addDrawRequest(Gui.drawAreaTop) return end
  gpuSetBackground(self.palette.bg, true)
  gpuSetForeground(self.palette.fg, true)
  gpu.fill(self.area.top.x, self.area.top.y, self.area.top.width, self.area.top.height, " ")
  gpu.set(self.area.top.x + 1, self.area.top.y + 1, "Storage Network")
  if not self.textBox.searchMode then
    gpu.set(self.area.top.x + 1, self.area.top.y + 2, "Enter amount for item \"" .. string.sub(self.textBox.requestedItem, 1, self.area.top.width - 27) .. "\".")
  end
  self:drawTextBox()
end

-- Draw bottom pane.
function Gui:drawAreaBottom(force)
  if not force then self:addDrawRequest(Gui.drawAreaBottom) return end
  gpuSetBackground(self.palette.bg, true)
  gpu.fill(self.area.bottom.x, self.area.bottom.y, self.area.bottom.width, self.area.bottom.height, " ")
end

-- Generic drawing for a scroll bar.
function Gui:renderScrollBar(scrollBar)
  gpuSetBackground(0x000000)
  gpuSetForeground(0xFFFFFF)
  local barLength = math.max(scrollBar.height - scrollBar.maxScroll, 1)
  local barText
  if barLength > 1 then
    barText = text.padRight(string.rep(" ", scrollBar.scroll) .. string.rep("\u{2588}", barLength), scrollBar.height)
  else
    barText = text.padRight(string.rep(" ", math.floor(scrollBar.scroll / (scrollBar.maxScroll + 1) * scrollBar.height)) .. "\u{2588}", scrollBar.height)
  end
  gpu.set(scrollBar.x, scrollBar.y, barText, true)
end

-- Draw the scroll bar for the main items list.
function Gui:drawScrollBar(force)
  if not force then self:addDrawRequest(Gui.drawScrollBar) return end
  self:renderScrollBar(self.scrollBar)
end

-- Draw the scroll bar for the crafting items (if visible).
function Gui:drawCraftingScrollBar(force)
  if not force then self:addDrawRequest(Gui.drawCraftingScrollBar) return end
  self:renderScrollBar(self.craftingScrollBar)
end

-- Draw the item table with the list of all items in the network. Depending on
-- the graphics card this may be a single column or multiple column table. This
-- uses a lazy-draw system so that this function can be called as many times as
-- necessary but will only draw as fast as the lazy interval (handled by an
-- external thread). Setting force to true overrides this behavior and the table
-- will draw immediately.
function Gui:drawAreaItem(force)
  if not force then self:addDrawRequest(Gui.drawAreaItem) return end
  
  
  
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
      -- Find the display name. Usually corresponds to a storageItems entry except if we have zero of that item and it's craftable.
      local itemName = self.filteredItems[itemIndex]
      local label, total
      if self.storageItems[itemName] then
        label = self.storageItems[itemName].label
        total = self.storageItems[itemName].total
      else
        label = self.recipeItems[itemName].label
        total = 0
      end
      local displayName = (self.button.labelType.val == 1 and label .. (string.sub(itemName, #itemName) == "n" and " (+NBT)" or "") or itemName)
      fgColor = self.palette["mod" .. (djb2StringHash(string.match(itemName, "[^:]+")) % 6 + 1)]
      
      -- Append to the totalsLine with the item count and some spacing. If the item is craftable and we have zero total or a key is held, show the "craft" symbol.
      local totalFormatted
      if total > 0 and not self.keyShowCraftingPressed then
        totalFormatted = total < 1000000 and string.format("%5d", total) or "######"
      elseif not self.recipeItems[itemName] then
        totalFormatted = "     "
      else
        totalFormatted = "Craft"
      end
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
  self:renderTextTable(textTable1)
  self:renderTextTable(textTable2)
  gpuSetBackground(self.palette.bg, true)
  for i = 1, self.area.numItemColumns - 1 do
    for j = self.area["item" .. i].x + self.area["item" .. i].width, self.area["item" .. i + 1].x - 1 do
      gpu.set(j, self.area.item1.y, string.rep(" ", self.area.item1.height), true)
    end
  end
  
  
  
  local timeEnd = computer.uptime()
  --term.clearLine()
  --io.write("took " .. timeEnd - timeStart .. "s") FIXME ####################################################################################
end

-- Draw full GUI. Only needs to be called once to clear the screen and draw all
-- components, updates to each component on the screen can be re-drawn
-- independently.
function Gui:draw()
  term.clear()
  gpuSetBackground(self.palette.bg, true)
  local width, height = term.getViewport()
  gpu.fill(1, 1, width, height, " ")
  self:drawAreaLeft()
  self:drawAreaRight()
  self:drawAreaTop()
  self:drawAreaBottom()
  self:drawAreaItem()
  self:drawScrollBar()
end

-- Find the sorting key name for given item. These are used in the
-- self.sortingKeys table to sort the item list.
function Gui:getSortingKeyName(itemName, label, total)
  if self.button.sortType.val == 1 then    -- Sort by name.
    return label .. "," .. itemName
  elseif self.button.sortType.val == 2 then    -- Sort by ID.
    return itemName
  else    -- Sort by quantity.
    -- Really neat idea to sort string numbers http://notebook.kulchenko.com/algorithms/alphanumeric-natural-sorting-for-humans-in-lua
    return string.format("%03d%s", #tostring(total), tostring(total)) .. "," .. itemName
  end
end

-- Create/replace the self.sortingKeys table with new sorting keys. Combines
-- both storage items and recipe items.
function Gui:rebuildSortingKeys()
  self.sortingKeys = {}
  for itemName, itemDetails in pairs(self.storageItems) do
    self.sortingKeys[#self.sortingKeys + 1] = self:getSortingKeyName(itemName, itemDetails.label, itemDetails.total)
  end
  for itemName, itemDetails in pairs(self.recipeItems) do
    if not self.storageItems[itemName] then
      self.sortingKeys[#self.sortingKeys + 1] = self:getSortingKeyName(itemName, itemDetails.label, 0)
    end
  end
  self:updateSortingKeys()
end

-- Assign new self.storageItems contents. Rebuilds sorting keys. It's more
-- efficient to use addedStorageItem() and removedStorageItem() if only a few
-- items changed in storage.
function Gui:setStorageItems(storageItems)
  self.storageItems = storageItems
  self:rebuildSortingKeys()
end

-- Assign new self.recipeItems contents. Rebuilds sorting keys.
function Gui:setRecipeItems(recipeItems)
  self.recipeItems = recipeItems
  self:rebuildSortingKeys()
end

-- Modify storage keys to reflect new item added to storage. Do nothing if key
-- already exists from a recipe.
function Gui:addedStorageItem(itemName)
  if not self.recipeItems[itemName] then
    self.sortingKeys[#self.sortingKeys + 1] = self:getSortingKeyName(itemName, self.storageItems[itemName].label, self.storageItems[itemName].total)
  end
end

-- Modify storage keys to reflect item going away from storage. Again, we skip
-- if a recipe exists for the item.
function Gui:removedStorageItem(itemName)
  if self.recipeItems[itemName] then
    return
  end
  local keyName = self:getSortingKeyName(itemName, self.storageItems[itemName].label, self.storageItems[itemName].total)
  
  -- Search for the key in sortingKeys and remove it (replace with last element).
  for i, v in ipairs(self.sortingKeys) do
    if v == keyName then
      self.sortingKeys[i] = self.sortingKeys[#self.sortingKeys]
      self.sortingKeys[#self.sortingKeys] = nil
      break
    end
  end
end

-- Re-sort the sorting keys and update filters.
function Gui:updateSortingKeys()
  table.sort(self.sortingKeys)
  self:updateFilteredItems()
end

-- Helper function for updateFilteredItems(). May throw exception if text box
-- contents has a malformed string pattern.
function Gui:updateFilteredItemsUnsafe()
  local filterStrings = {string.lower(text.trim(self.textBox.searchContents))}
  
  local useInternalName = false
  local useModName = false
  if string.sub(filterStrings[1], 1, 1) == "&" then
    -- If filter text is prefixed with an '&' symbol, we filter by internal name.
    filterStrings[1] = string.sub(filterStrings[1], 2)
    useInternalName = true
  elseif string.sub(filterStrings[1], 1, 1) == "@" then
    -- If filter text is prefixed with an '@' symbol, we filter the first filter text by mod name.
    filterStrings[1] = string.sub(filterStrings[1], 2)
    useModName = true
  end
  
  -- If filter type button is set to fixed, match the text exactly (no pattern matching). Otherwise we split the filter text at spaces.
  local plainMatch = false
  if self.button.filterType.val == 2 then
    plainMatch = true
  else
    filterStrings = text.tokenize(filterStrings[1])
  end
  
  -- Iterate through each sorting key and add the item name to self.filteredItems if it matches the filter.
  for _, keyName in ipairs(self.sortingKeys) do
    local itemName = string.match(keyName, "[^,]+$") or keyName
    local findString
    if useInternalName then
      findString = string.lower(itemName)
    elseif useModName then
      findString = string.lower(string.match(itemName, "[^:]+"))
    else
      findString = string.lower(self.storageItems[itemName] and self.storageItems[itemName].label or self.recipeItems[itemName].label)
    end
    
    -- For plainMatch we match the string exactly, otherwise we match against each filter string in the array.
    if plainMatch then
      if string.find(findString, filterStrings[1], 1, true) then
        self.filteredItems[#self.filteredItems + 1] = itemName
      end
    else
      local foundMatch = true
      for i, filterString in ipairs(filterStrings) do
        -- Switch back to external names if on second filter text. This matches JEI search behavior a bit better.
        if i == 2 and useModName then
          findString = string.lower(self.storageItems[itemName] and self.storageItems[itemName].label or self.recipeItems[itemName].label)
        end
        
        if not string.find(findString, filterString) then
          foundMatch = false
          break
        end
      end
      if foundMatch then
        self.filteredItems[#self.filteredItems + 1] = itemName
      end
    end
  end
end

-- Updates the self.filteredItems table in the case that the text box contents
-- changed. If the updateFilteredItemsUnsafe() call throws an exception then the
-- resulting self.filteredItems may be empty or incomplete (this is fine).
function Gui:updateFilteredItems()
  self.filteredItems = {}
  pcall(Gui.updateFilteredItemsUnsafe, self)
  self:updateScrollBar(0)
  self:drawAreaItem()
end

function Gui:updateTextBox()
  if self.textBox.searchMode then
    self.textBox.searchContents = self.textBox.contents
    self:updateFilteredItems()
  end
  self:drawTextBox()
end

function Gui:clearTextBox()
  self.textBox.cursor = 1
  self.textBox.scroll = 0
  self.textBox.contents = ""
  self:updateTextBox()
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
  self.scrollBar.maxScroll = math.max(math.floor(math.ceil(#self.filteredItems / self.area.numItemColumns) - self.scrollBar.height), 0)
  self.scrollBar.scroll = math.min(math.max(self.scrollBar.scroll - math.floor(direction), 0), self.scrollBar.maxScroll)
  self:drawScrollBar()
end

function Gui:updateCraftingScrollBar(direction)
  local numRows = 0
  for _, _ in pairs(self.crafting.pendingCraftRequests) do
    numRows = numRows + 2
  end
  self.craftingScrollBar.maxScroll = math.max(math.floor(numRows - self.craftingScrollBar.height), 0)
  self.craftingScrollBar.scroll = math.min(math.max(self.craftingScrollBar.scroll - math.floor(direction), 0), self.craftingScrollBar.maxScroll)
  self:drawCraftingScrollBar()
end

function Gui:toggleButtonFilterType()
  self.button.filterType.val = (self.button.filterType.val % 2) + 1
  self:drawButtonFilterType()
  self:updateFilteredItems()
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

function Gui:toggleButtonLastPage()
  
end

function Gui:toggleButtonNextPage()
  
end

function Gui:toggleButtonStart()
  local ticket = next(self.crafting.pendingCraftRequests)
  if ticket and string.find(ticket, "^id") then
    wnet.send(modem, self.craftingServerAddress, COMMS_PORT, packer.pack.craft_recipe_start(ticket))
    self.crafting.pendingCraftRequests[ticket] = nil
    
    self:updateCraftingScrollBar(0)
    self:drawAreaCraftingItem()
  end
end

-- Remove a pending or active craft request, and forward request to crafting
-- server if it's a real ticket (not "missing").
function Gui:cancelCraftRequest(ticket)
  if string.find(ticket, "^id") then
    wnet.send(modem, self.craftingServerAddress, COMMS_PORT, packer.pack.craft_recipe_cancel(ticket))
    self.crafting.activeCraftRequests[ticket] = nil
  end
  self.crafting.pendingCraftRequests[ticket] = nil
  self:updateCraftingScrollBar(0)
  self:drawAreaCraftingItem()
end

function Gui:toggleButtonCancel()
  local ticket = next(self.crafting.pendingCraftRequests)
  if ticket then
    self:cancelCraftRequest(ticket)
  end
end

function Gui:handleKeyDown(keyboardAddress, char, code, playerName)
  --dlog.out("event", "handleKeyDown", keyboardAddress, char, code, playerName)
  if keyboard.isControl(char) then
    if code == keyboard.keys.lmenu then
      if not self.keyShowCraftingPressed then
        self:drawAreaItem()
      end
      self.keyShowCraftingPressed = true
    elseif code == keyboard.keys.tab then
      self.textBox.selected = not self.textBox.selected
      self:drawTextBox()
    end
  end
  
  if self.textBox.selected then    -- Text box key handling.
    if keyboard.isControl(char) then
      if code == keyboard.keys.back then    -- Backspace removes characters in front of cursor.
        if self.textBox.cursor > 1 then
          self.textBox.contents = string.sub(self.textBox.contents, 1, self.textBox.cursor - 2) .. string.sub(self.textBox.contents, self.textBox.cursor)
          self:setTextBoxCursor(self.textBox.cursor - 1)
          self:updateTextBox()
        end
      elseif code == keyboard.keys.delete then    -- Delete removes characters after cursor.
        self.textBox.contents = string.sub(self.textBox.contents, 1, self.textBox.cursor - 1) .. string.sub(self.textBox.contents, self.textBox.cursor + 1)
        self:updateTextBox()
      elseif code == keyboard.keys.enter or code == keyboard.keys.numpadenter then    -- Enter submits an item request if available and restores the search mode.
        if not self.textBox.searchMode then
          local amount = tonumber(self.textBox.contents)
          if amount then
            if self.textBox.requestedCrafting then
              wnet.send(modem, self.craftingServerAddress, COMMS_PORT, packer.pack.craft_check_recipe(self.textBox.requestedItem, amount))
            else
              wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_extract(self.textBox.requestedItem, amount))
            end
          end
          
          self.textBox.contents = self.textBox.searchContents
          self.textBox.searchMode = true
          self.textBox.requestedItem = ""
          self:drawAreaTop()
          self:setTextBoxCursor(#self.textBox.contents + 1)
          self:updateTextBox()
        end
      elseif code == keyboard.keys.home then    -- Home moves cursor to beginning.
        self:setTextBoxCursor(1)
      elseif code == keyboard.keys.lcontrol then    -- Left control clears the text box.
        self:clearTextBox()
      elseif code == keyboard.keys.left then    -- Left moves cursor left.
        self:setTextBoxCursor(math.max(self.textBox.cursor - 1, 1))
      elseif code == keyboard.keys.right then    -- Right moves cursor right.
        self:setTextBoxCursor(math.min(self.textBox.cursor + 1, #self.textBox.contents + 1))
      elseif code == keyboard.keys["end"] then    -- End moves cursor to the end of text.
        self:setTextBoxCursor(#self.textBox.contents + 1)
      end
    else    -- Non-control key typed in text box, insert the character.
      self.textBox.contents = string.sub(self.textBox.contents, 1, self.textBox.cursor - 1) .. string.char(char) .. string.sub(self.textBox.contents, self.textBox.cursor)
      self:setTextBoxCursor(self.textBox.cursor + 1)
      self:updateTextBox()
    end
  else    -- Regular key handling.
    if keyboard.isControl(char) then
      if code == keyboard.keys.home then    -- Home scrolls item list to top.
        self.scrollBar.scroll = 0
        self:drawScrollBar()
        self:drawAreaItem()
      elseif code == keyboard.keys["end"] then    -- End scrolls item list to bottom.
        self.scrollBar.scroll = self.scrollBar.maxScroll
        self:drawScrollBar()
        self:drawAreaItem()
      end
    elseif char == string.byte("p") then    -- Press 'p' to toggle filter type.
      self:toggleButtonFilterType()
    elseif char == string.byte("d") then    -- Press 'd' to toggle sort direction.
      self:toggleButtonSortDir()
    elseif char == string.byte("s") then    -- Press 's' to toggle sort type.
      self:toggleButtonSortType()
    elseif char == string.byte("l") then    -- Press 'l' to toggle label type.
      self:toggleButtonLabelType()
    end
  end
end

function Gui:handleKeyUp(keyboardAddress, char, code, playerName)
  --dlog.out("event", "handleKeyUp", keyboardAddress, char, code, playerName)
  if keyboard.isControl(char) then
    if code == keyboard.keys.lmenu then
      if self.keyShowCraftingPressed then
        self:drawAreaItem()
      end
      self.keyShowCraftingPressed = false
    end
  end
end

-- Used by Gui:handleTouch() to determine the request type for the clicked item
-- in the items list. A left click will prompt for the amount and right click
-- will request one of the item. A shift left or right click requests a stack or
-- half stack respectively. This function also determines if the item will come
-- from storage or request it to be crafted.
function Gui:requestItem(itemName, button)
  local requestedCrafting = false
  if (self.keyShowCraftingPressed or not self.storageItems[itemName]) and self.recipeItems[itemName] then
    requestedCrafting = true
  end
  
  local amount
  if not keyboard.isShiftDown() then
    -- If user left clicks item without pressing shift key, we need to prompt for the desired amount in search box.
    -- A right click (or middle click, if we could actually catch that signal with the screen coords, oof) requests one item.
    if button == 0 then
      self.textBox.searchMode = false
      self.textBox.requestedItem = itemName
      self.textBox.requestedCrafting = requestedCrafting
      self.textBox.selected = true
      self:drawAreaTop()
      self:clearTextBox()
      return
    elseif button == 1 or button == 2 then
      amount = 1
    else
      return
    end
  elseif button ~= 0 and button ~= 1 then
    return
  end
  
  -- If crafting button held down or we don't have any of the item in storage, send a crafting request to crafting server. Otherwise send storage extract request.
  if requestedCrafting then
    if not amount then
      if button == 0 then
        amount = self.recipeItems[itemName].maxSize
      else
        amount = math.ceil(self.recipeItems[itemName].maxSize / 2)
      end
    end
    wnet.send(modem, self.craftingServerAddress, COMMS_PORT, packer.pack.craft_check_recipe(itemName, amount))
  else
    if not amount then
      if button == 0 then
        amount = math.min(self.storageItems[itemName].maxSize, self.storageItems[itemName].total)
      else
        amount = math.ceil(math.min(self.storageItems[itemName].maxSize, self.storageItems[itemName].total) / 2)
      end
    end
    wnet.send(modem, self.storageServerAddress, COMMS_PORT, packer.pack.stor_extract(itemName, amount))
  end
end

function Gui:handleTouch(screenAddress, x, y, button, playerName)
  --dlog.out("event", "handleTouch", screenAddress, x, y, button, playerName)
  x = math.floor(x)
  y = math.floor(y)
  button = math.floor(button)
  if isPointInRectangle(x, y, self.button.filterType.x, self.button.filterType.y, self.button.filterType.width, self.button.filterType.height) then
    self:toggleButtonFilterType()
  elseif isPointInRectangle(x, y, self.button.sortDir.x, self.button.sortDir.y, self.button.sortDir.width, self.button.sortDir.height) then
    self:toggleButtonSortDir()
  elseif isPointInRectangle(x, y, self.button.sortType.x, self.button.sortType.y, self.button.sortType.width, self.button.sortType.height) then
    self:toggleButtonSortType()
  elseif isPointInRectangle(x, y, self.button.labelType.x, self.button.labelType.y, self.button.labelType.width, self.button.labelType.height) then
    self:toggleButtonLabelType()
  elseif isPointInRectangle(x, y, self.button.lastPage.x, self.button.lastPage.y, self.button.lastPage.width, self.button.lastPage.height) then
    self:toggleButtonLastPage()
  elseif isPointInRectangle(x, y, self.button.nextPage.x, self.button.nextPage.y, self.button.nextPage.width, self.button.nextPage.height) then
    self:toggleButtonNextPage()
  elseif isPointInRectangle(x, y, self.button.start.x, self.button.start.y, self.button.start.width, self.button.start.height) then
    self:toggleButtonStart()
  elseif isPointInRectangle(x, y, self.button.cancel.x, self.button.cancel.y, self.button.cancel.width, self.button.cancel.height) then
    self:toggleButtonCancel()
  else
    for i = 1, self.area.numItemColumns do
      local itemArea = self.area["item" .. i]
      if isPointInRectangle(x, y, itemArea.x, itemArea.y, itemArea.width, itemArea.height) then
        local itemIndex = (self.button.sortDir.val == 1 and 1 or #self.filteredItems) + self.scrollBar.scroll * self.area.numItemColumns * self.button.sortDir.val
        itemIndex = itemIndex + ((y - itemArea.y) * self.area.numItemColumns + (i - 1)) * self.button.sortDir.val
        if self.filteredItems[itemIndex] then
          self:requestItem(self.filteredItems[itemIndex], button)
        end
      end
    end
  end
end

function Gui:handleScroll(screenAddress, x, y, direction, playerName)
  --dlog.out("event", "handleScroll", screenAddress, x, y, direction, playerName)
  if x < self.area.craftingItem.x then
    self:updateScrollBar(direction)
    self:drawAreaItem()
  else
    self:updateCraftingScrollBar(direction)
    self:drawAreaCraftingItem()
  end
end

function Gui:addPendingCraftRequest(ticket, craftProgress)
  -- Remove any old pending request and cancel it if applicable.
  local oldTicket = next(self.crafting.pendingCraftRequests)
  if oldTicket then
    self:cancelCraftRequest(oldTicket)
  end
  
  self.crafting.pendingCraftRequests[ticket] = craftProgress
  self:updateCraftingScrollBar(0)
  self:drawAreaCraftingItem()
end



-- FIXME still need to refactor interface and clean these up. ######################################################
local storageItems, storageServerAddress, recipeItems, craftingServerAddress, gui



-- Apply the items diff to storageItems to keep the table synced up.
local function handleStorItemDiff(_, _, _, itemsDiff)
  for itemName, diff in pairs(itemsDiff) do
    if diff.total == 0 then
      gui:removedStorageItem(itemName)
      storageItems[itemName] = nil
    elseif storageItems[itemName] then
      storageItems[itemName].total = diff.total
    else
      storageItems[itemName] = {}
      storageItems[itemName].maxSize = diff.maxSize
      storageItems[itemName].label = diff.label
      storageItems[itemName].total = diff.total
      gui:addedStorageItem(itemName)
    end
  end
  gui:updateSortingKeys()
end
packer.callbacks.stor_item_diff = handleStorItemDiff


-- If we get a broadcast that storage started, it must have just rebooted and we
-- need to discover new storageItems.
local function handleStorStarted(_, address, _)
  wnet.send(modem, address, COMMS_PORT, packer.pack.stor_discover())
end
packer.callbacks.stor_started = handleStorStarted


-- New item list, update storageItems and GUI.
local function handleStorItemList(_, address, _, items)
  storageItems = items
  storageServerAddress = address
  gui:setStorageItems(storageItems)
  gui.storageServerAddress = address
end
packer.callbacks.stor_item_list = handleStorItemList


-- 
local function handleCraftStarted(_, _, _)
  -- TODO #######################################################################################################################################################################
end
packer.callbacks.craft_started = handleCraftStarted


-- 
local function handleCraftRecipeList(_, _, _, recipeItems)
  
end
packer.callbacks.craft_recipe_list = handleCraftRecipeList


-- Got a response from crafting request, update in GUI to show required items
-- for crafting operation.
local function handleCraftRecipeConfirm(_, _, _, ticket, craftProgress)
  gui:addPendingCraftRequest(ticket, craftProgress)
end
packer.callbacks.craft_recipe_confirm = handleCraftRecipeConfirm


-- Got error response from crafting request, or failure during crafting.
local function handleCraftRecipeError(_, _, _, ticket, errMessage)
  if gui.crafting.pendingCraftRequests[ticket] or gui.crafting.activeCraftRequests[ticket] then
    gui:cancelCraftRequest(ticket)
  end
  
  io.write("Error in recipe: " .. ticket .. ", " .. errMessage .. "\n")    -- FIXME show error in gui ################################################################
  -- two options here, either display in log at bottom or clear crafting status window and display there (but then we have to keep that status window open)
end
packer.callbacks.craft_recipe_error = handleCraftRecipeError





local function main()
  local threadSuccess = false
  -- Captures the interrupt signal to stop program.
  local interruptThread = thread.create(function()
    event.pull("interrupted")
  end)
  
  -- Blocks until any of the given threads finish. If threadSuccess is still
  -- false and a thread exits, reports error and exits program.
  local function waitThreads(threads)
    thread.waitForAny(threads)
    if interruptThread:status() == "dead" then
      dlog.osBlockNewGlobals(false)
      os.exit(1)
    elseif not threadSuccess then
      io.stderr:write("Error occurred in thread, check log file \"/tmp/event.log\" for details.\n")
      dlog.osBlockNewGlobals(false)
      os.exit(1)
    end
    threadSuccess = false
  end
  
  if DLOG_FILE_OUT ~= "" then
    dlog.setFileOut(DLOG_FILE_OUT, "w")
  end
  
  -- Performs setup and initialization tasks.
  local setupThread = thread.create(function()
    modem.open(COMMS_PORT)
    screen.setPrecise(false)
    
    -- Contact the storage server.
    local attemptNumber = 1
    local lastAttemptTime = 0
    while not storageServerAddress do
      if computer.uptime() >= lastAttemptTime + 2 then
        lastAttemptTime = computer.uptime()
        term.clearLine()
        io.write("Trying to contact storage server on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
        wnet.send(modem, nil, COMMS_PORT, packer.pack.stor_discover())
        attemptNumber = attemptNumber + 1
      end
      local address, port, header, data = packer.extractPacket(wnet.receive(0.1))
      if port == COMMS_PORT and header == "stor_item_list" then
        storageItems = packer.unpack.stor_item_list(data)
        storageServerAddress = address
      end
    end
    io.write("\nSuccess.\n")
    
    -- Contact the crafting server.
    attemptNumber = 1
    lastAttemptTime = 0
    while not craftingServerAddress do
      if computer.uptime() >= lastAttemptTime + 2 then
        lastAttemptTime = computer.uptime()
        term.clearLine()
        io.write("Trying to contact crafting server on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
        wnet.send(modem, nil, COMMS_PORT, packer.pack.craft_discover())
        attemptNumber = attemptNumber + 1
      end
      local address, port, header, data = packer.extractPacket(wnet.receive(0.1))
      if port == COMMS_PORT and header == "craft_recipe_list" then
        recipeItems = packer.unpack.craft_recipe_list(data)
        craftingServerAddress = address
      end
    end
    io.write("\nSuccess.\n")
    
    dlog.out("setup", "storageItems:", storageItems)
    
    gui = Gui:new(storageItems, storageServerAddress, recipeItems, craftingServerAddress)
    gui:draw()
    
    threadSuccess = true
  end)
  
  
  waitThreads({interruptThread, setupThread})
  
  
  -- Listens for incoming packets over the network and deals with them.
  local modemThread = thread.create(function()
    while true do
      local address, port, message = wnet.receive()
      if port == COMMS_PORT then
        packer.handlePacket(nil, address, port, message)
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
      for i, v in ipairs(gui.drawRequest) do
        v(gui, true)
        gui.drawRequest[i] = nil
      end
    end
  end)
  
  
  waitThreads({interruptThread, modemThread, userInputThread, guiLazyDrawThread})
  
  
  interruptThread:kill()
  modemThread:kill()
  userInputThread:kill()
  guiLazyDrawThread:kill()
end

main()
dlog.osBlockNewGlobals(false)
