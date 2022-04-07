local matrix = {}

function matrix.new(rows, cols, data)
  rows = math.floor(rows)
  cols = math.floor(cols)
  assert(rows > 0 and cols > 0, "rows and cols must be positive integers.")
  data = data or {}
  data.r = rows
  data.c = cols
  return data
end
