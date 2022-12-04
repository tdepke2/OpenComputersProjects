# config.lua

Provides a flexible interface for defining a configuration structure, with the ability to save and load from a file.

Defining the configuration format is done with a single table, and optionally a list of custom data types. Strict type checking is optional and can be used to verify the configuration for user-made errors.

### Configuration format

Configuration tables are simply key-value mappings with a defined structure. When saving, loading, or verifying a config table, a format needs to be provided to define this structure (the `cfgFormat` argument in the API functions). The format is a key-value mapping that looks very similar to what the default config file would contain. The format can contain only the following types of entries:

* Table (or sub-config)

  Syntax: `<key name> = {...}`
  
  Defines an additional level in the config, any of the format entries can go in here.

* Value

  Syntax: `<key name> = {<type names>, [default value], [comment]}`
  
  Adds a value definition. The type names is a string of Lua types (like `number`, `string`, `table`, etc) and custom types (see below section) separated by vertical bars (`|`). The value must match one of these types, or an error will be thrown during verification. A default value and a string comment are optional.

* Pairs meta-field

  Syntax: `_pairs_ = {<key type names>, <value type names> | <sub-config>, [default key 1] = [default value 1], ...}`
  
  Specifies that the current table may contain any number of key-value pairs. The key and value type names are strings just like the one in the value entry. For the value, a sub-config can instead be used (just an additional level in the config). Note that in the keys for default values, index 1 and 2 are already used for the key and value type names. In order to allow 1 and 2 as keys in default values, a positive integer key will be reduced by 2 to normalize the range. Just take care to add 2 for any positive integer keys.

* Sequence meta-field

  Syntax: `_ipairs_ = {<value type names> | <sub-config>, [2] = [default value 1], [3] = [default value 2], ...}`
  
  Very similar to pairs, but requires that the keys are sequential increasing integers starting from 1. The same note about adding an offset to positive integer keys in the default values applies here, except that the offset is 1 instead of 2 in this case.

* Comment meta-field

  Syntax: `_comment_ = <comment text>`
  
  Adds inline comments above the current table when saving the config to a file. Leading empty lines can be used to add spacing between entries.

* Order meta-field

  Syntax: `_order_ = <order number>`
  
  Specifies an override for the ordering of entries when saving to file. By default, entries are ordered ascending by numbers, strings, then everything else. Anything with an order entry will get sorted to the top (in ascending order).

> **Note**
> 
> Mixing value, pairs, and sequence entries in the same table is allowed. If a key in the config would match multiple entries during verification or file saving, it is matched with this priority: sequence, value, pairs.
> 
> Pairs and sequence entries are forbidden in the top level of the config! Only non-reserved string identifiers can be used as keys in the top level (otherwise there will be errors during file load because the top-level entries become value assignments during file save, and are not within a table).

### Custom data types

In some cases, it may be desired to use enumerated types in the config format and numbers with special range and formatting rules (such as a 24 bit RGB color in hex). To do this, a table of data type definitions (the `typeList` argument in the API functions) can be created that assigns a string name for each table definition. The table definition can either be a sequence of every allowed value for the data type, or define functions `encode` and `verify` to handle type checking and serialization. If `encode` is defined, it is called when saving the config to a file and the value for the custom data type needs to be written. The function will be called with the value and is expected to return a string (this string should be executable Lua code). If `verify` is defined, it is called during verification on the value. The function is again called with the value and should throw an error if the value does not meet requirements. See the example usage for a demonstration of custom types.

### API

<!-- SIMPLE-DOC:START (FILE:../libconfig/config.lua) -->

* `config.loadFile(filename: string, cfgFormat: table, defaultIfMissing: boolean, localEnv: table|nil) -> cfg: table, loadedDefaults: boolean`
  
  Load configuration from a text file and return it. The file is expected to
  contain executable Lua code, but doesn't need to have the structure specified
  in `cfgFormat` (no verification is done). If `defaultIfMissing` is true, the
  default config is returned if the file cannot be opened. Use `localEnv` to
  provide a custom environment during file code execution. This defaults to
  `_ENV` but an empty table could be used, for example, to prevent code in the
  file from accessing external globals (make sure that `math.huge` is still
  defined if using this method).

* `config.loadDefaults(cfgFormat: table) -> cfg: table`
  
  Get the default configuration and return it. Depending on how `cfgFormat` is
  structured, the result may or may not be a valid config format.

* `config.verify(cfg: any, cfgFormat: table, typeList: table)`
  
  Checks the format of config `cfg` to make sure it matches cfgFormat. An error
  is thrown if any inconsistencies with the format are found.

* `config.saveFile(filename: string, cfg: any, cfgFormat: table, typeList: table)`
  
  Saves the configuration to a file. The filename can be `-` to send the config
  to standard output instead. This does some minor verification of `cfg` to
  determine types and such when serializing values to strings. Errors may be
  thrown if the config format is not met.
<!-- SIMPLE-DOC:END -->

### Example usage

```lua
-- Custom data types used in the config. In this case we define a 24 bit RGB color value.
local customTypes = {
  Color = {
    encode = function(v)
      return string.format("0x%06X", v)
    end,
    verify = function(v)
      assert(type(v) == "number" and math.floor(v) == v and v >= 0 and v <= 0xFFFFFF, "provided Color must be a 24 bit integer value.")
    end,
  },
}

-- The configuration format with some default values.
local cfgFormat = {
  objects = {
    _comment_ = "List of shapes to draw.",
    _order_ = 1,
    _ipairs_ = {"string",
      "circle",
    },
  },
  properties = {
    _comment_ = "\nProperties for drawing area.",
    _order_ = 2,
    bgColor = {"Color", 0x000000},
    fgColor = {"Color", 0xFFFFFF},
    windowAttributes = {"table", {
      width = 160,
      height = 50,
    }},
  },
  palette = {
    _comment_ = "\nColor palette.",
    _order_ = 3,
    _pairs_ = {"string", "Color",
      red = 0xFF0000,
      green = 0x00FF00,
      blue = 0x0000FF,
    },
  },
}

-- Load the config file, or use the default values if it doesn't exist.
local cfg = config.loadFile("my_sample_config.cfg", cfgFormat, true)
config.verify(cfg, cfgFormat, customTypes)

-- Add a new object to draw.
cfg.objects[#cfg.objects + 1] = "triangle"

-- Verify before saving the config, then write the changes to the file.
config.verify(cfg, cfgFormat, customTypes)
config.saveFile("my_sample_config.cfg", cfg, cfgFormat, customTypes)
```

### Future work

Some potential use cases might be:

* Configs with cyclic references.
* Tables as keys.
* Multiple entries in the config referencing a common table (this would make copies of the tables during load).
* Could we allow pairs/sequence meta-fields in top level of config? Might just be a simple change to file saving.

Right now these cases are not handled well, if at all.
