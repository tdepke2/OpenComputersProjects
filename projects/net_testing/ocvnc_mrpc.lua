--[[
Function declarations for ocvnc remote procedure calls.
--]]

return {
  -- Request storage server address.
  stor_discover = {
  },
  -- Request storage to insert items into storage network.
  stor_insert = {
  },
  -- Request storage to extract items from storage network.
  stor_extract = {
    {
      "itemName", "string,nil",
      "amount", "number",
    }, {
      "something", "string",
    },
  },
  -- Request storage to reserve items in network for crafting operation.
  stor_recipe_reserve = {
    {
      "ticket", "string",
      "itemInputs", "table",
    },
  },
}
