

local matrix = {}

-- FIXME this should probably be fixed in other stuff #######################
xassert = function(v, ...)
  if not v then
    assert(false, string.rep("%s", select("#", ...)):format(...))
  end
end

local matrixRowMeta = {
  __index = function(t, k)
    if type(k) == "number" then
      return 0
    end
  end
}

local matrixMeta = {
  type = "matrix"
}

function matrixMeta.__index(t, k)
  if type(k) == "number" then
    t[k] = setmetatable({}, matrixRowMeta)
    return t[k]
  end
  return matrixMeta[k]
end

setmetatable(matrixMeta, {
  __index = function(t, k)
    xassert(false, "attempt to read undefined member \"", k, "\" in matrix.")
  end
})

-- matrix.new(data: table)
-- matrix.new(rows: number, columns: number[, data: table|any])
function matrix.new(rows, columns, data)
  if type(rows) == "table" then
    xassert(type(rows[1]) == "table", "provided matrix data must be a 2-dimensional table structure.")
    for _, rowData in pairs(rows) do
      setmetatable(rowData, matrixRowMeta)
    end
    rows.r = #rows
    rows.c = #rows[1]
    return setmetatable(rows, matrixMeta)
  elseif rows == nil then
    return setmetatable({r = 0, c = 0}, matrixMeta)
  end
  xassert(rows == math.floor(rows) and rows >= 0 and columns == math.floor(columns) and columns >= 0, "matrix rows/columns must be non-negative integers.")
  local mat
  if type(data) == "table" then
    -- Check if provided data is a 1D table (vector). If so, we convert it to a row vector or column vector.
    if next(data) ~= nil and type(select(2, next(data))) ~= "table" then
      mat = {}
      if rows == 1 then
        mat[1] = {}
        for i = 1, columns do
          mat[1][i] = data[i]
        end
        setmetatable(mat[1], matrixRowMeta)
      elseif columns == 1 then
        for i = 1, rows do
          mat[i] = setmetatable({data[i]}, matrixRowMeta)
        end
      else
        xassert(false, "provided vector data cannot be converted to ", rows, " by ", columns, " matrix.")
      end
    else
      mat = data
      for _, rowData in pairs(mat) do
        setmetatable(rowData, matrixRowMeta)
      end
    end
  elseif data == nil then
    mat = {}
  else
    mat = {}
    for r = 1, rows do
      mat[r] = {}
      for c = 1, columns do
        mat[r][c] = data
      end
      setmetatable(mat[r], matrixRowMeta)
    end
  end
  mat.r = rows
  mat.c = columns
  return setmetatable(mat, matrixMeta)
end

-- matrix.identity(rows: number)
function matrix.identity(rows)
  xassert(rows == math.floor(rows) and rows >= 0, "matrix rows must be non-negative integer.")
  local mat = {}
  for r = 1, rows do
    mat[r] = {}
    for c = 1, rows do
      mat[r][c] = (r ~= c and 0 or 1)
    end
    setmetatable(mat[r], matrixRowMeta)
  end
  mat.r = rows
  mat.c = rows
  return setmetatable(mat, matrixMeta)
end

--[[
xprint({}, matrix.new())
xprint({}, matrix.new({{1, 2, 3}}))
xprint({}, matrix.new(1, 3, {6, 7, 8, 9}))
xprint({}, matrix.new({{1, 2, 3}, {4, 5, 6}}))
xprint({}, matrix.new({{1, 2, 3}, {4, 5, 6}}))
--]]

local m = matrix.new(4, 5)
xprint({}, m)
m[3][2] = 7
xprint({}, m)
xprint({}, m[3][19])
xprint({}, m[3][2])
xprint({}, m[11][6])
xprint({}, m)
