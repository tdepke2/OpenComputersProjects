--[[
Cross dimensional player teleportation using AE2.

One enderchest slot per destination, need to support multiple ender chests.
Can update config by placing a named item like `de:d3="mars;suit,oxyge` and `cfg:n,thermal"` into any consecutive slots.
  Item names are too short, in above case the name is broken up into multiple items for the config entry.
  Use `se:` to change a setting, or `de:` to change a destination. The `de:` format looks like `de:slotId="name;requirements"` which is different from the config format. Assign the value nil to clear a destination.
Still need to copy the config file onto a new teleporter instance before hand.
Make sure to test config before leaving (teleport to the current teleporter should say you are already here)!
Spatial chamber size should have equal x and z dimensions, otherwise it will be directional.

Some slots are special:
  * Fuel slot (optional)
  * Empty fuel slot (optional)

Warp process:
  1. Put fuel item into destination slot.
  2. Once it's gone, after a short delay redstone pulse the IO port.
    a. If it didn't go away, move it into fuel return slot and error.
  3. Put cell into destination slot.
    a. If my cell doesn't come back to my slot, put it into IO port and pulse, error.
    b. If my cell does come back to my slot, put it into IO port.

Warpd process:
  1. If fuel item in my slot, move it into return slot.
  2. If cell in my slot, 


Cells are stored in the ender chests, each slot corresponds to a destination and cells are named with that slot.
Taking a cell "locks" that destination allowing the sender to put their cell in the destination slot.
We cannot take cells out of the spatial IO port input slot if there is a problem (the user can do this instead).

Warp process:
  1. At warp, if my cell in my slot and dest cell in dest slot then put my cell in IO port, create lock file with computer uptime, then pulse after a moment.
    a. Do not wait if conditions not fulfilled, someone could be in transit to this destination.
    b. If this location same as dest, inform user and exit.
    c. If my cell not in my slot, someone is in transit to this destination. If dest cell not in dest slot, destination is busy.
    d. If any cell in IO port, we also have a problem.
  2. Put dest cell at dest slot into my slot (warpd sees lock file and knows this isn't a warp request).
    a. Wait for the cell if not there, if it takes too long spit the player back out (alert anyone nearby of the arrival).
  3. Put my cell into destination slot (try once, if failure go to step a). Expect my cell to come back in my slot.
    a. If my cell stays in dest slot too long, put my cell into IO port and pulse (alert anyone nearby of the arrival), put dest cell back (assert), put my cell back (assert).
  4. Delete lock file.

Warpd process:
  1. Init: assert no cell in IO port. Check sides once for generator and ender chests, if any destination not available then warn.
  2. If fuel slots defined, generator available, and has empty fuel, put all empty fuel in return slot (try once) and put one fuel in first slot (try once).
  3. If we see a config entry, update the config and save it if it's a new value and it's a valid form.
    a. If it's new, check sides again. If it corresponds to a destination we don't have available then warn.   FIXME: forgot about this, should we actually do this though?
    b. If it's not a valid form then warn.
  4. If remote cell in my slot and no lock file (or lock file is stale), put remote cell in IO port, alert anyone nearby of the arrival, then pulse after a moment.
    a. If lock file was stale, remove it and warn.
  5. Put my cell back in my slot (retry a few times if failure, then warn), put remote cell in remote slot (try forever until it works or cell taken out of IO port by user, error each time it fails).

]]
