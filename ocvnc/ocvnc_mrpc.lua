--[[
Function declarations for ocvnc remote procedure calls.
--]]

return {
  -- Client request to start VNC session with a server.
  connect = {
  },
  -- 
  redraw_display = {
  },
  -- 
  update_display = {
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
