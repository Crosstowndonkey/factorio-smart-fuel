-- Test harness for Smart Fuel (not part of the mod). Builds a base with every kind of burner, lets the game
-- run, then checks each one and prints PASS / FAIL lines.

local function fuel_of(e)
  local inv = e.get_fuel_inventory()
  for i = 1, #inv do
    if inv[i].valid_for_read then return inv[i].name, inv[i].quality.name, inv[i].count end
  end
  return nil, nil, 0
end
local function fuel_text(e)
  local inv = e.get_fuel_inventory()
  local parts = {}
  for i = 1, #inv do
    if inv[i].valid_for_read then table.insert(parts, inv[i].name .. "x" .. inv[i].count) end
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

script.on_init(function()
  local f = game.forces.player
  f.research_all_technologies()
  local s = game.surfaces.nauvis
  s.always_day = true
  s.peaceful_mode = true
  game.map_settings.enemy_expansion.enabled = false
  local area = {{-50, -50}, {50, 50}}
  for _, e in pairs(s.find_entities_filtered{area = area}) do if e.type ~= "character" then e.destroy() end end
  for _, e in pairs(s.find_entities_filtered{force = "enemy"}) do e.destroy() end
  local tiles = {}
  for x = -50, 50 do for y = -50, 50 do table.insert(tiles, {name = "concrete", position = {x, y}}) end end
  s.set_tiles(tiles)

  local eei = s.create_entity{name = "electric-energy-interface", position = {-6, -6}, force = f}
  eei.power_production = 1e9 / 60
  eei.electric_buffer_size = 1e10
  s.create_entity{name = "substation", position = {-3, -3}, force = f}
  local rp = s.create_entity{name = "roboport", position = {0, 0}, force = f}
  rp.insert{name = "construction-robot", count = 150}
  rp.energy = 1e8

  local function chest(pos, items)
    local c = s.create_entity{name = "storage-chest", position = pos, force = f}
    for _, it in pairs(items) do c.insert(it) end
    return c
  end
  storage.chest = chest({3, -3}, {
    {name = "coal", count = 400}, {name = "wood", count = 300}, {name = "solid-fuel", count = 100},
    {name = "rocket-fuel", count = 40}, {name = "nuclear-fuel", count = 2},
  })
  chest({4, -3}, {{name = "uranium-fuel-cell", count = 20}, {name = "nutrients", count = 100}})

  local T = {}
  local function place(key, name, pos, extra)
    local args = {name = name, position = pos, force = f}
    for k, v in pairs(extra or {}) do args[k] = v end
    T[key] = s.create_entity(args)
    if not T[key] then print("STA setup: could not place " .. key) end
  end
  place("furnace", "stone-furnace", {10, 10})
  place("boiler", "boiler", {16, 10})
  T.boiler.insert{name = "wood", count = 5}             -- low on wood: topped up with wood, not changed to coal
  place("drill", "burner-mining-drill", {22, 10})
  place("rocket_furnace", "steel-furnace", {28, 10})
  T.rocket_furnace.insert{name = "rocket-fuel", count = 1} -- put in by hand: left alone
  place("inserter", "burner-inserter", {10, 16})
  place("reactor", "nuclear-reactor", {-14, 14})
  T.reactor.get_burnt_result_inventory().insert{name = "depleted-uranium-fuel-cell", count = 3}
  place("heating", "heating-tower", {-14, -14})
  place("biochamber", "biochamber", {16, 18})
  place("car", "car", {-8, 22})
  for y = -24, 24, 2 do s.create_entity{name = "straight-rail", position = {35, y}, force = f} end
  place("loco", "locomotive", {35, 0})
  if T.loco then T.loco.insert{name = "coal", count = 5} end -- coal, upgraded to the best fuel there is
  -- picked fuels
  place("locked_boiler", "boiler", {16, 26})
  T.locked_boiler.insert{name = "wood", count = 10}
  place("locked_furnace", "steel-furnace", {28, 18})
  -- a stone furnace built by robots from a blueprint whose tag says "wood"
  s.create_entity{name = "entity-ghost", inner_name = "stone-furnace", position = {22, 26}, force = f,
    tags = {sf_fuel = {name = "wood", quality = "normal"}}}
  storage.chest.insert{name = "stone-furnace", count = 1}
  storage.T = T
  for _, e in pairs(T) do script.raise_script_built{entity = e} end
  remote.call("smart-fuel", "set_fuel", T.locked_boiler, "solid-fuel", "normal")
  remote.call("smart-fuel", "set_fuel", T.locked_furnace, "rocket-fuel", "normal")
end)

local function check(name, ok, detail)
  print(string.format("STA %s %s (%s)", ok and "PASS" or "FAIL", name, detail))
  if not ok then storage.failed = (storage.failed or 0) + 1 end
end

script.on_event(defines.events.on_tick, function(e)
  if e.tick ~= 4000 then return end
  local T = storage.T
  local n, q, c

  local kinds = {}
  for key, ent in pairs(T) do kinds[key] = remote.call("smart-fuel", "kind", ent) end
  check("kinds: furnace/boiler/drill/inserter are stationary, heating tower is a heater",
    kinds.furnace == "stationary" and kinds.boiler == "stationary" and kinds.drill == "stationary" and kinds.inserter == "stationary" and kinds.heating == "heater",
    serpent.line(kinds))
  check("kinds: car/locomotive are vehicles, reactor is reactor, biochamber is nutrients",
    kinds.car == "vehicle" and kinds.loco == "vehicle" and kinds.reactor == "reactor" and kinds.biochamber == "nutrients", serpent.line(kinds))

  n, q, c = fuel_of(T.furnace)
  check("empty furnace gets the most plentiful basic fuel (coal), a full stack", n == "coal" and c == 50, fuel_text(T.furnace))
  n, q, c = fuel_of(T.boiler)
  check("boiler low on wood is topped up with wood", n == "wood" and c == 100, fuel_text(T.boiler))
  n, q, c = fuel_of(T.drill)
  check("burner drill gets coal", n == "coal" and c == 50, fuel_text(T.drill))
  n, q, c = fuel_of(T.inserter)
  check("burner inserter gets coal", n == "coal", fuel_text(T.inserter))
  n, q, c = fuel_of(T.heating)
  check("heating tower is left alone (off by default)", n == nil and T.heating.item_request_proxy == nil, fuel_text(T.heating))
  n, q, c = fuel_of(T.rocket_furnace)
  check("rocket fuel put in a furnace by hand is left alone (and not topped up)", n == "rocket-fuel" and c <= 1, fuel_text(T.rocket_furnace))

  local stationary_bad = false
  for _, key in pairs({"furnace", "boiler", "drill", "inserter"}) do
    local inv = T[key].get_fuel_inventory()
    if inv.get_item_count("rocket-fuel") > 0 or inv.get_item_count("nuclear-fuel") > 0 then stationary_bad = true end
  end
  check("no machine was given rocket fuel or nuclear fuel", not stationary_bad, "")

  n, q, c = fuel_of(T.reactor)
  check("nuclear reactor gets 2 fuel cells (one may already be burning)", n == "uranium-fuel-cell" and (c == 1 or c == 2) and T.reactor.burner.currently_burning ~= nil, fuel_text(T.reactor) .. " burning " .. tostring(T.reactor.burner.currently_burning and T.reactor.burner.currently_burning.name.name))
  local burnt = T.reactor.get_burnt_result_inventory().get_item_count("depleted-uranium-fuel-cell")
  check("the reactor's used-up fuel cells were taken away", burnt == 0, burnt .. " left")
  n, q, c = fuel_of(T.biochamber)
  check("biochamber gets 20 nutrients", n == "nutrients" and c == 20, fuel_text(T.biochamber))

  local function premium(ent) local n2 = fuel_of(ent) return n2 == "nuclear-fuel" or n2 == "rocket-fuel" end
  if T.loco then
    n, q, c = fuel_of(T.loco)
    check("locomotive's coal is swapped for the best fuel (nuclear or rocket)", premium(T.loco) and T.loco.get_fuel_inventory().get_item_count("coal") == 0, fuel_text(T.loco))
  else
    check("locomotive could be placed", false, "no locomotive")
  end
  n, q, c = fuel_of(T.car)
  check("car gets the best fuel (nuclear or rocket)", premium(T.car), fuel_text(T.car))
  n, q, c = fuel_of(T.locked_boiler)
  check("a boiler locked to solid fuel has its wood swapped for solid fuel", n == "solid-fuel" and T.locked_boiler.get_fuel_inventory().get_item_count("wood") == 0, fuel_text(T.locked_boiler))
  n, q, c = fuel_of(T.locked_furnace)
  check("a furnace locked to rocket fuel gets rocket fuel (a manual pick may)", n == "rocket-fuel" and c == 20, fuel_text(T.locked_furnace))
  local bp = game.surfaces.nauvis.find_entities_filtered{name = "stone-furnace", position = {22, 26}, radius = 1}[1]
  if bp then
    n, q, c = fuel_of(bp)
    check("a furnace built from a blueprint tagged 'wood' gets wood", n == "wood" and c == 100, fuel_text(bp))
  else
    check("the blueprint ghost was built by robots", false, "no furnace there")
  end
  print("STA DONE failures=" .. (storage.failed or 0))
end)
