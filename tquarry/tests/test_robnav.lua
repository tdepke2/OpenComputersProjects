local component = require("component")
local sides = require("sides")

local robnav = require("robnav")

local function testRobnav()
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  -- Test robnav.turn()
  --[[
  os.sleep(0.5)
  print("robnav.turn(true)")
  assert(robnav.turn(true))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  --print("robnav.turn(true)")
  assert(robnav.turn(true))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  --print("robnav.turn(true)")
  assert(robnav.turn(true))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  --print("robnav.turn(true)")
  assert(robnav.turn(true))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  print("robnav.turn(false)")
  assert(robnav.turn(false))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  --print("robnav.turn(false)")
  assert(robnav.turn(false))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  --print("robnav.turn(false)")
  assert(robnav.turn(false))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  --print("robnav.turn(false)")
  assert(robnav.turn(false))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  --]]
  
  -- Test robnav.turnTo()
  --[[
  os.sleep(0.5)
  print("robnav.turnTo(sides.right)")
  assert(robnav.turnTo(sides.right))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  print("robnav.turnTo(sides.front)")
  assert(robnav.turnTo(sides.front))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  print("robnav.turnTo(sides.left)")
  assert(robnav.turnTo(sides.left))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  print("robnav.turnTo(sides.right)")
  assert(robnav.turnTo(sides.right))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  
  os.sleep(0.5)
  print("robnav.turnTo(sides.back)")
  assert(robnav.turnTo(sides.back))
  print("xyzr = ", robnav.x, robnav.y, robnav.z, sides[robnav.r])
  --]]
  
  -- Test robnav.move()
  --[[
  os.sleep(0.5)
  print("robnav.move(sides.top)")
  assert(robnav.move(sides.top))
  assert(robnav.x == 0 and robnav.y == 1 and robnav.z == 0 and robnav.r == sides.front)
  
  os.sleep(0.5)
  print("robnav.move(sides.bottom)")
  assert(robnav.move(sides.bottom))
  assert(robnav.x == 0 and robnav.y == 0 and robnav.z == 0 and robnav.r == sides.front)
  
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == 0 and robnav.y == 0 and robnav.z == 1 and robnav.r == sides.front)
  assert(robnav.turn(true))
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == -1 and robnav.y == 0 and robnav.z == 1 and robnav.r == sides.right)
  assert(robnav.turn(true))
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == -1 and robnav.y == 0 and robnav.z == 0 and robnav.r == sides.back)
  assert(robnav.turn(true))
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == 0 and robnav.y == 0 and robnav.z == 0 and robnav.r == sides.left)
  assert(robnav.turn(true))
  
  
  os.sleep(0.5)
  print("robnav.move(sides.back)")
  assert(robnav.move(sides.back))
  assert(robnav.x == 0 and robnav.y == 0 and robnav.z == -1 and robnav.r == sides.front)
  assert(robnav.turn(false))
  
  os.sleep(0.5)
  print("robnav.move(sides.back)")
  assert(robnav.move(sides.back))
  assert(robnav.x == -1 and robnav.y == 0 and robnav.z == -1 and robnav.r == sides.left)
  assert(robnav.turn(false))
  
  os.sleep(0.5)
  print("robnav.move(sides.back)")
  assert(robnav.move(sides.back))
  assert(robnav.x == -1 and robnav.y == 0 and robnav.z == 0 and robnav.r == sides.back)
  assert(robnav.turn(false))
  
  os.sleep(0.5)
  print("robnav.move(sides.back)")
  assert(robnav.move(sides.back))
  assert(robnav.x == 0 and robnav.y == 0 and robnav.z == 0 and robnav.r == sides.right)
  assert(robnav.turn(false))
  
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == 0 and robnav.y == 0 and robnav.z == 1 and robnav.r == sides.front)
  assert(robnav.turn(false))
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == 1 and robnav.y == 0 and robnav.z == 1 and robnav.r == sides.left)
  assert(robnav.turn(false))
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == 1 and robnav.y == 0 and robnav.z == 0 and robnav.r == sides.back)
  assert(robnav.turn(false))
  
  os.sleep(0.5)
  print("robnav.move(sides.front)")
  assert(robnav.move(sides.front))
  assert(robnav.x == 0 and robnav.y == 0 and robnav.z == 0 and robnav.r == sides.right)
  assert(robnav.turn(false))
  --]]
  
end

testRobnav()
