local include = require("include")
local dlog = include("dlog")
dlog.mode("debug")
dlog.osBlockNewGlobals(true)
local config = include("config")
local dstucts = include("dstructs")
local xprint = include("xprint")


-- Simple type checking.
local function test1()
  print("test1")
  local cfgFormat1 = {
    my_number = {"number"}
  }
  local cfg1_1 = {}
  assert(not pcall(config.verify, cfg1_1, cfgFormat1, {}))
  local cfg1_2 = {
    my_number = "number"
  }
  assert(not pcall(config.verify, cfg1_2, cfgFormat1, {}))
  local cfg1_3 = {
    my_number = {
      12.34
    }
  }
  assert(not pcall(config.verify, cfg1_3, cfgFormat1, {}))
  local cfg1_4 = {
    my_number = 99.99
  }
  config.verify(cfg1_4, cfgFormat1, {})
end

-- Invalid keys in first level.
local function test2()
  print("test2")
  local cfgFormat2 = {
    ["1number"] = {"number"}
  }
  local cfg2_1 = {
    ["1number"] = 99.99
  }
  assert(not pcall(config.verify, cfg2_1, cfgFormat2, {}))
end

-- Usage of _pairs_ in first level.
local function test3()
  print("test3")
  local cfgFormat3 = {
    _pairs_ = {"string", "number"}
  }
  local cfg3_1 = {
    something = 123
  }
  assert(not pcall(config.verify, cfg3_1, cfgFormat3, {}))
end

-- Usage of _pairs_, _ipairs_, and optional data.
local function test4()
  print("test4")
  local cfgFormat4 = {
    test = {
      _pairs_ = {"string", "number"}
    },
    test2 = {
      _ipairs_ = {"boolean"}
    },
    optional = {"string|nil"},
  }
  local cfg4_1 = {
    test = {},
    test2 = {},
  }
  config.verify(cfg4_1, cfgFormat4, {})
  local cfg4_2 = {
    test = {
      first = 6,
      second = 7,
    },
    test2 = {
      true,
      false,
      true,
    },
    optional = "hello",
  }
  config.verify(cfg4_2, cfgFormat4, {})
  local cfg4_3 = {
    test = {
      [6] = 6,
      second = 7,
    },
    test2 = {},
    optional = "hello",
  }
  assert(not pcall(config.verify, cfg4_3, cfgFormat4, {}))
  local cfg4_4 = {
    test = {
      second = "7",
    },
    test2 = {},
    optional = "hello",
  }
  assert(not pcall(config.verify, cfg4_4, cfgFormat4, {}))
  local cfg4_5 = {
    test = {
      second = 7,
    },
    test2 = {
      true,
      false,
      true,
      [5] = false,
    },
    optional = "hello",
  }
  assert(not pcall(config.verify, cfg4_5, cfgFormat4, {}))
  
  -- Extra keys and missing keys.
  local cfg4_6 = {
    test = {
      ["for"] = 7,
    },
    optional = "hello",
  }
  assert(not pcall(config.verify, cfg4_6, cfgFormat4, {}))
  local cfg4_7 = {
    test = {
      ["while"] = math.huge,
    },
    test2 = {
      [1] = true,
    },
    optional = "hello",
    unknown = "hello2",
  }
  assert(not pcall(config.verify, cfg4_7, cfgFormat4, {}))
end

-- Usage of _order_ field for custom ordering.
local function test5()
  print("test5")
  local cfg
  
  local cfgFormat1 = {
    dat = {
      stuff = {"string", "abc"},
      properties = {"string", "def"},
      foobar = {"number", 3.14},
      [0] = {"boolean", true},
      [1] = {"table", {"tab"}},
      [2] = {"nil|string|number", "cool"},
      [-3] = {"number", math.huge},
    }
  }
  cfg = config.loadFile("nonexistent file", cfgFormat1, true)
  config.verify(cfg, cfgFormat1, {})
  print("cfgFormat1 defaults:")
  config.saveFile("-", cfg, cfgFormat1, {})
  
  local cfgFormat2 = {
    dat = {
      stuff = {"string", "abc", _order_ = 3},
      properties = {"string", "def", _order_ = 1},
      foobar = {"number", 3.14, _order_ = 6},
      [0] = {"boolean", true, _order_ = 4},
      [1] = {"table", {"tab"}, _order_ = 7},
      [2] = {"nil|string|number", "cool", _order_ = 2},
      [-3] = {"number", math.huge, _order_ = 5},
    }
  }
  cfg = config.loadFile("nonexistent file", cfgFormat2, true)
  config.verify(cfg, cfgFormat2, {})
  print("cfgFormat2 defaults:")
  config.saveFile("-", cfg, cfgFormat2, {})
end

-- Default configuration.
local function test6()
  print("test6")
  local cfgFormat1 = {
    stuff = {"string", "abc"},
    my_tab = {"any", {
      shopping = {
        "eggs",
        "bacon",
      },
      [2] = 9001,
      [math.huge] = 0/0,
      [-math.huge] = "very smol number",
    }},
    list_of_things = {
      _pairs_ = {"number", "string",
        [0] = "zero",
        [3] = "one",
        [4] = "two",
        [5.25] = "five and a quarter",
      },
    },
    another_list = {
      _ipairs_ = {"number",
        0.1,
        0.2,
        0.3,
      },
    },
  }
  local cfg = config.loadDefaults(cfgFormat1)
  --xprint({}, cfg)
  config.verify(cfg, cfgFormat1, {})
end

-- Configuration saving with exotic values.
local function test7()
  print("test7")
  local typeList = {
    Fruits = {
      "apple", "banana", "cherry"
    },
    Color = {
      encode = function(v)
        return string.format("0x%06X", v)
      end,
      verify = function(v)
        assert(type(v) == "number" and math.floor(v) == v and v >= 0 and v <= 0xFFFFFF, "provided Color must be a 24 bit integer value.")
      end,
    },
    Float2 = {
      encode = function(v)
        return string.format("%.2f", v)
      end,
      verify = function(v)
        assert(type(v) == "number", "provided Float2 must be a number.")
      end
    },
  }
  
  local cfgFormat1 = {
    stuff = {"string", "abc"},
    my_fruit = {"Fruits", "cherry"},
    my_tab = {"table", {
      shopping = {
        "eggs",
        "bacon",
      },
      [2] = 9001,
      [math.huge] = 0/0,
      [-math.huge] = "very smol number",
    }},
    list_of_things = {
      _pairs_ = {"number", "Color|string",
        [0] = "zero",
        [3] = "one",
        [4] = "two",
        [5] = 0x112233,
        [5.25] = "five and a quarter",
      },
    },
    another_list = {
      _ipairs_ = {"Float2",
        0.10,
        22.20,
        0.303,
      },
    },
    wildcard_value = {"any"},
    bool = {"boolean", true},
  }
  local cfg = config.loadDefaults(cfgFormat1)
  config.verify(cfg, cfgFormat1, typeList)
  config.saveFile("test7.cfg", cfg, cfgFormat1, typeList)
  
  local cfgReference = {
    stuff = "abc",
    my_fruit = "cherry",
    my_tab = {
      shopping = {
        "eggs",
        "bacon",
      },
      [2] = 9001,
      [math.huge] = 0/0,
      [-math.huge] = "very smol number",
    },
    list_of_things = {
      [0] = "zero",
      [1] = "one",
      [2] = "two",
      [3] = 0x112233,
      [5.25] = "five and a quarter",
    },
    another_list = {
      0.10,
      22.20,
      0.30,
    },
    wildcard_value = nil,
    bool = true,
  }
  local cfg2 = config.loadFile("test7.cfg", cfgFormat1, false)
  --xprint({}, cfg2)
  config.verify(cfg2, cfgFormat1, typeList)
  
  -- Need to compare the two tables, but NaN is not equal to itself so this hack is used.
  cfg2.my_tab[math.huge] = "0/0"
  cfgReference.my_tab[math.huge] = "0/0"
  
  assert(dstucts.rawObjectsEqual(cfgReference, cfg2))
end

-- Comprehensive test with large config format.
local function test8()
  print("test8")
  local typeList = {
    Fruits = {
      "apple", "banana", "cherry"
    },
    DataTypes = {
      "number", "string", "table"
    },
    Color = {
      encode = function(v)
        return string.format("0x%06X", v)
      end,
      --decode = function(v)
        --return v
      --end,
      verify = function(v)
        assert(type(v) == "number" and math.floor(v) == v and v >= 0 and v <= 0xFFFFFF, "provided Color must be a 24 bit integer value.")
      end,
    },
    Float2 = {
      encode = function(v)
        return string.format("%.2f", v)
      end,
      verify = function(v)
        assert(type(v) == "number", "provided Float2 must be a number.")
      end
    },
  }
  
  local propList = {
    {"boolean"},
    {"string"},
    {"Float2"},
  }
  
  local cfgFormat = {
    stuff = {
      _comment_ = "My sample config file",
      _order_ = 1,
      foo = {
        enumVal = {"Fruits", "apple", "\ncan be one of: apple, banana, or cherry"},
        _pairs_ = {"DataTypes", "string",
          ["number"]   = "number  ",
          ["string"]   = "string  ",
        },
      },
      bar = {
        _ipairs_ = {"string|number",
          "set",
          "test",
          "first",
          123,
        },
      },
      baz = {
        _comment_ = "\nidk what this is...\nmust be at least 3 items",
        --_iter_ = {"number", "any",
          
          -- not finished yet, would this even be useful?
          -- I think we should skip this, complex iteration checking should be done outside of the config.
          
        --},
        _ipairs_ = {"string"}
      },
      mixedPairs = {
        _ipairs_ = {"string",
          "a",
          "b",
        },
        _pairs_ = {"string", "string",
          another = "c",
          even_more = "d",
        },
      },
    },
    properties = {
      _order_ = 2,
      color1 = {"Color", 0xAABBCC},
      color2 = {"Color", 0x000000},
      useColors = {"boolean", true},
      _ipairs_ = {propList,
        {
          true,
          "height",
          4.67,
        },
        {
          false,
          "length",
          2.89,
        },
        {
          true,
          "width",
          3.00,
        },
      },
    },
    ["while2"] = {"table|nil", {"bam", "boozled", 1234, {["for"] = true}}},
    --_ipairs_ = {"string"},
  }
  
  local cfg = config.loadFile("nonexistent file", cfgFormat, true)
  --xprint.print({}, cfg)
  print("verify cfg")
  config.verify(cfg, cfgFormat, typeList)
  
  local cfg2 = {
    -- My sample config file
    stuff = {
      bar = {
        "set",
        "test",
        "first",
        123,
      },
      -- idk what this is...
      -- must be at least 3 items
      baz = {
        --[0] = "z",
        [1] = "o",
        [2] = "t",
      },
      foo = {
        
        -- can be one of: apple, banana, or cherry
        enumVal = "apple",
        ["number"]   = "number  ",
        ["string"]   = "string  ",
      },
      mixedPairs = {
        [1] = "a",
        [2] = "b",
        another = "c",
        even_more = "d",
      },
    },
    properties = {
      [1] = {
        true,
        "height",
        4.67,
      },
      [2] = {
        false,
        "length",
        2.89,
      },
      [3] = {
        true,
        "width",
        3.00,
      },
      color1 = 0xAABBCC,
      color2 = 0x000000,
      useColors = true,
    },
    ["while2"] = {
      "bam",
      "boozled",
      1234,
      {
        ["for"] = true,
      },
    },
    --[1] = "-1.234",
    --[2] = "cool",
  }
  
  print("verify cfg2")
  config.verify(cfg2, cfgFormat, typeList)
  config.saveFile("test8.cfg", cfg2, cfgFormat, typeList)
  
  local cfg3 = config.loadFile("test8.cfg", cfgFormat, false)
  --xprint.print({}, cfg3)
  
  assert(dstucts.rawObjectsEqual(cfg2, cfg3))
end

local function main()
  test1()
  test2()
  test3()
  test4()
  test5()
  test6()
  test7()
  test8()
  print("all tests passing!")
end
dlog.handleError(xpcall(main, debug.traceback, ...))
dlog.osBlockNewGlobals(false)
