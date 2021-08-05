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

local Gui = {}

function Gui:new(obj, storageItems)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  
  self.ITEM_LABEL_WIDTH = 45
  self.LEFT_COLUMN_WIDTH = 8
  self.RIGHT_COLUMN_WIDTH = 25
  self.TOP_ROW_HEIGHT = 4
  self.BOTTOM_ROW_HEIGHT = 3
  
  self.LAZY_DRAW_INTERVAL = 0.1
  
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
    self.area["item" .. i].x = self.area.left.x + self.area.left.width + 1 + (i - 1) * self.ITEM_LABEL_WIDTH
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
  self.scrollBar.scroll = 0
  
  self.button = {}
  self.button.sortDir = {}
  self.button.sortDir.x = self.area.left.x + 1
  self.button.sortDir.y = self.area.left.y + 1
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
  
  return obj
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

-- Drawing text in columns with alternating background colors is taxing on the
-- GPU to switch backgrounds/foregrounds so frequently. We can optimize by
-- drawing all of the text with the same color background at once, then switch
-- backgrounds.
function Gui:drawTextTable(textTable)
  --[[
  textTable: {
    <bg>: {
      <fg>: {
        1: {
          1: <x>
          2: <y>
          3: <s>
        }
        2: {
          1: <x>
          2: <y>
          3: <s>
        }
        ...
      }
    }
  }
  --]]
  
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
end

function Gui:drawAreaItem(force)
  if not force then
    --event.push("gui_lazy_draw", "item")    -- FIXME: we still using lazy draw? ###########################################
    --return
  end
  
  --[[
  for i = 1, self.area.numItemColumns do
    local itemArea = self.area["item" .. i]
    gpu.setBackground(i % 2 == 0 and self.palette.item1 or self.palette.item2, true)
    gpu.fill(itemArea.x, itemArea.y, itemArea.width, itemArea.height, " ")
  end
  --]]
  
  
  
  --[[
  -- Key index starts at first or last entry (depending on sort direction) with an offset for the scroll.
  local keyIndex = (self.button.sortDir.val == 1 and 1 or #self.sortingKeys) + self.scrollBar.scroll * self.area.numItemColumns * self.button.sortDir.val
  for i = 0, self.area.numItemColumns * self.area.item1.height - 1 do
    local x = i % self.area.numItemColumns
    local y = math.floor(i / self.area.numItemColumns)
    local itemArea = self.area["item" .. x + 1]
    gpu.setBackground((x + y + self.scrollBar.scroll) % 2 == 0 and self.palette.item1 or self.palette.item2, true)
    
    if keyIndex >= 1 and keyIndex <= #self.sortingKeys then
      local itemName = string.match(self.sortingKeys[keyIndex], "[^,]+$") or self.sortingKeys[keyIndex]
      local displayName = (self.button.labelType.val == 1 and self.storageItems[itemName].label .. (string.sub(itemName, #itemName) == "n" and " (+NBT)" or "") or itemName)
      displayName = string.format("%5d %s", self.storageItems[itemName].total, displayName)
      
      gpu.set(itemArea.x, itemArea.y + y, text.padRight(string.sub(displayName, 1, self.ITEM_LABEL_WIDTH), self.ITEM_LABEL_WIDTH))
      keyIndex = keyIndex + self.button.sortDir.val
    else
      gpu.fill(itemArea.x, itemArea.y + y, itemArea.width, 1, " ")
    end
  end
  --]]
  
  -- FIXME: clean this up and optimize drawTextTable() maybe. probably not gonna do colored text for item total vs item name cuz too laggy. try using a back buffer to fix flickering issue ################################################
  
  --
  -- Version 2, testing speed improvements.
  -- Key index starts at first or last entry (depending on sort direction) with an offset for the scroll.
  local textTable = {}
  local keyIndex = (self.button.sortDir.val == 1 and 1 or #self.sortingKeys) + self.scrollBar.scroll * self.area.numItemColumns * self.button.sortDir.val
  for i = 0, self.area.numItemColumns * self.area.item1.height - 1 do
    local x = i % self.area.numItemColumns
    local y = math.floor(i / self.area.numItemColumns)
    local itemArea = self.area["item" .. x + 1]
    local bgColor = (x + y + self.scrollBar.scroll) % 2 == 0 and self.palette.item1 or self.palette.item2
    local fgColor = self.palette.fg
    
    if keyIndex >= 1 and keyIndex <= #self.sortingKeys then
      local itemName = string.match(self.sortingKeys[keyIndex], "[^,]+$") or self.sortingKeys[keyIndex]
      local displayName = (self.button.labelType.val == 1 and self.storageItems[itemName].label .. (string.sub(itemName, #itemName) == "n" and " (+NBT)" or "") or itemName)
      displayName = string.format("%5d %s", self.storageItems[itemName].total, displayName)
      
      if not textTable[bgColor] then
        textTable[bgColor] = {}
      end
      if not textTable[bgColor][fgColor] then
        textTable[bgColor][fgColor] = {}
      end
      textTable[bgColor][fgColor][#textTable[bgColor][fgColor] + 1] = {itemArea.x, itemArea.y + y, text.padRight(string.sub(displayName, 1, self.ITEM_LABEL_WIDTH), itemArea.width)}
      
      keyIndex = keyIndex + self.button.sortDir.val
    else
      if not textTable[bgColor] then
        textTable[bgColor] = {}
      end
      if not textTable[bgColor][fgColor] then
        textTable[bgColor][fgColor] = {}
      end
      textTable[bgColor][fgColor][#textTable[bgColor][fgColor] + 1] = {itemArea.x, itemArea.y + y, string.rep(" ", itemArea.width)}
    end
  end
  self:drawTextTable(textTable)
  --
  
  
  
  --[[
    if i == 1 then
      --
      local j = 1
      for itemName, itemDetails in pairs(self.storageItems) do
        gpu.set(itemArea.x, itemArea.y + j - 1, itemName .. " " .. itemDetails.total)
        j = j + 1
      end
      --
      
      -- FIXME may need to rework if we want to display this over multiple columns. ##############################################################
      
      local j = (self.button.sortDir.val == 1 and 1 or #self.sortingKeys)
      for _, key in ipairs(self.sortingKeys) do
        local itemName = string.match(key, "[^,]+$") or key
        local displayName = (self.button.labelType.val == 1 and self.storageItems[itemName].label .. (string.sub(itemName, #itemName) == "n" and " (+NBT)" or "") or itemName)
        gpu.set(itemArea.x, itemArea.y + j - 1, self.storageItems[itemName].total .. " " .. displayName)
        j = j + self.button.sortDir.val
      end
    end
  end
  --]]
  gpu.setBackground(self.palette.bg, true)
end

function Gui:draw()
  term.clear()
  gpu.setBackground(self.palette.bg, true)
  local width, height = term.getViewport()
  gpu.fill(1, 1, width, height, " ")
  Gui:drawAreaLeft()
  Gui:drawAreaRight()
  Gui:drawAreaTop()
  Gui:drawAreaBottom()
  Gui:drawAreaItem()
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
  self:drawAreaItem()
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
        end
      elseif code == keyboard.keys.delete then
        self.textBox.contents = string.sub(self.textBox.contents, 1, self.textBox.cursor - 1) .. string.sub(self.textBox.contents, self.textBox.cursor + 1)
        self:drawTextBox()
      elseif code == keyboard.keys.enter or code == keyboard.keys.numpadenter then
        print("enter")
      elseif code == keyboard.keys.home then
        self:setTextBoxCursor(1)
      elseif code == keyboard.keys.lcontrol then
        self:clearTextBox()
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
    end
  else
    if keyboard.isControl(char) then
      if code == keyboard.keys.tab then
        self.textBox.selected = true
        self:drawTextBox()
      end
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
  if isPointInRectangle(x, y, self.button.sortDir.x, self.button.sortDir.y, self.button.sortDir.width, self.button.sortDir.height) then
    self:toggleButtonSortDir()
  elseif isPointInRectangle(x, y, self.button.sortType.x, self.button.sortType.y, self.button.sortType.width, self.button.sortType.height) then
    self:toggleButtonSortType()
  elseif isPointInRectangle(x, y, self.button.labelType.x, self.button.labelType.y, self.button.labelType.width, self.button.labelType.height) then
    self:toggleButtonLabelType()
  else
    for i = 1, self.area.numItemColumns do
      if isPointInRectangle(x, y, self.area["item" .. i].x, self.area["item" .. i].y, self.area["item" .. i].width, self.area["item" .. i].height) then
        
      end
    end
  end
end

function Gui:handleScroll(screenAddress, x, y, direction, playerName)
  --print("handleScroll", screenAddress, x, y, direction, playerName)
  self.scrollBar.scroll = math.max(self.scrollBar.scroll - math.floor(direction), 0)
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
    wnet.debug = true
    
    local attemptNumber = 1
    while not storageServerAddress do
      term.clearLine()
      io.write("Trying to contact storage controller on port " .. COMMS_PORT .. " (attempt " .. attemptNumber .. ")...")
      
      wnet.send(modem, nil, COMMS_PORT, "stor_discover,")
      local address, port, data = wnet.receive(2)
      if address and port == COMMS_PORT then
        local dataType = string.match(data, "[^,]*")
        data = string.sub(data, #dataType + 2)
        if dataType == "stor_item_list" then
          storageItems = serialization.unserialize(data)
          storageServerAddress = address
        end
      end
      attemptNumber = attemptNumber + 1
    end
    io.write("\nSuccess.\n")
    
    print(" - items - ")
    tdebug.printTable(storageItems)
    
    gui = Gui:new(nil, storageItems)
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
        
        if dataType == "stor_item_diff" then
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
  
  -- Redraws parts of the GUI as scheduled by events. This prevents some slow drawing tasks from lagging the UI.
  local guiLazyDrawThread = thread.create(function()
    local lastItemDraw = computer.uptime()
    local itemDrawRequested = false
    while true do
      local eventName, drawType = event.pull(gui.LAZY_DRAW_INTERVAL, "gui_lazy_draw")
      if eventName then
        itemDrawRequested = (drawType == "item" and true or itemDrawRequested)
      end
      local timeNow = computer.uptime()
      if itemDrawRequested and timeNow >= lastItemDraw + gui.LAZY_DRAW_INTERVAL then
        gui:drawAreaItem(true)
        lastItemDraw = timeNow
        itemDrawRequested = false
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
