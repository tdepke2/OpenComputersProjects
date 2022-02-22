local geo = component.geolyzer
local holo = component.hologram


holo.clear()
holo.setScale(0.3)
local i = 1
for y = 1, 8 do
  local dat = geo.scan(0, 0, y, 8, 8, 1)
  local j = 1
  for z = 1, 8 do
    for x = 1, 8 do
      local c = math.min(math.max(math.floor(dat[j] + 0.9), 0), 3)
      if c > 0 then
        holo.set(x, y, z, c)
      end
      i = i + 1
      j = j + 1
    end
  end
end