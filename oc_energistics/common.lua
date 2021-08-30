-- Shared library for a bunch of stuff.

local common = {}

-- Deque class (like a deck of cards). Works like a queue or a stack.
common.Deque = {}

function common.Deque:new(obj)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  self.backIndex = 1
  self.length = 0
  return obj
end

function common.Deque:empty()
  return self.length == 0
end

function common.Deque:size()
  return self.length
end

function common.Deque:front()
  return self[self.backIndex + self.length - 1]
end

function common.Deque:back()
  return self[self.backIndex]
end

function common.Deque:push_front(val)
  self[self.backIndex + self.length] = val
  self.length = self.length + 1
end

function common.Deque:push_back(val)
  self.backIndex = self.backIndex - 1
  self[self.backIndex] = val
  self.length = self.length + 1
end

function common.Deque:pop_front()
  self[self.backIndex + self.length - 1] = nil
  self.length = self.length - 1
end

function common.Deque:pop_back()
  self[self.backIndex] = nil
  self.backIndex = self.backIndex + 1
  self.length = self.length - 1
end

function common.Deque:clear()
  while self.length > 0 do
    self[self.backIndex + self.length - 1] = nil
    self.length = self.length - 1
  end
end

return common
