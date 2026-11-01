-- Smart Fuel
-- Keeps everything that burns fuel (furnaces, boilers, burner drills and inserters, locomotives, cars, heating
-- towers, nuclear reactors, biochambers, and modded burners) fuelled.
--
-- How it works: every burner is checked in rotation. When its fuel runs low, the mod creates an "item request"
-- for it - the same thing a blueprint makes when it asks for modules - and construction robots bring the fuel
-- from the logistic network (on space platforms, the hub throws it across). Machines that inserters keep full
-- never run low, so they are left alone.
--
-- Four kinds of burner, each with its own rule for "which fuel":
--   vehicle    (locomotive, car, tank)       the best fuel: biggest speed + acceleration bonus; swaps worse fuel out
--   stationary (furnace, boiler, drill, ...) the most plentiful basic fuel; never the fuels listed in the settings
--   reactor    (burns nuclear fuel)          a few fuel cells; used-up cells are taken away
--   nutrients  (biochamber)                  a small amount of nutrients, because they spoil
--   heater     (heating tower)               like stationary, but only when switched on (they burn ~40 MW)
--
-- The player can also pick the fuel for one machine (a panel beside its window); that fuel is then the only one used.

local VEHICLE_TYPES = {["locomotive"] = true, ["car"] = true, ["spider-vehicle"] = true}
local CHECK_INTERVAL = 60 -- each burner is checked at most once per this many ticks
local FUEL = defines.inventory.fuel
local BURNT = defines.inventory.burnt_result

local cfg = {}
local function name_set(value)
  local set = {}
  for name in string.gmatch(value, "[^%s,;]+") do set[name] = true end
  return set
end
local function read_settings()
  local s = settings.global
  cfg.fill = s["sf-fill-percent"].value / 100
  cfg.refill = s["sf-refill-percent"].value / 100
  cfg.vehicle_upgrade = s["sf-vehicle-upgrade"].value
  cfg.stationary_never = name_set(s["sf-stationary-never"].value)
  cfg.never = name_set(s["sf-never"].value)
  cfg.reactors = s["sf-reactors"].value
  cfg.reactor_keep = s["sf-reactor-keep"].value
  cfg.biochambers = s["sf-biochambers"].value
  cfg.heaters = s["sf-heating-towers"].value
  cfg.nutrient_keep = s["sf-nutrient-keep"].value
  cfg.remove_burnt = s["sf-remove-burnt"].value
  cfg.per_tick = s["sf-per-tick"].value
end

---------------------------------------------------------------------------------------------------------
-- Fuels
---------------------------------------------------------------------------------------------------------

-- A dictionary or a list of names -> a set of names (the API gives fuel categories either way).
local function as_set(t)
  local set = {}
  for k, v in pairs(t or {}) do
    if type(k) == "string" then set[k] = true elseif type(v) == "string" then set[v] = true end
  end
  return set
end

local quality_cache
local function qualities()
  if not quality_cache then
    quality_cache = {}
    for name, q in pairs(prototypes.quality) do
      if not q.hidden then table.insert(quality_cache, {name = name, level = q.level}) end
    end
    table.sort(quality_cache, function(a, b) return a.level > b.level end)
  end
  return quality_cache
end

-- Every fuel item, once: {name, categories (set), bonus (vehicle speed + acceleration), value, stack}
local fuel_cache
local function all_fuels()
  if not fuel_cache then
    fuel_cache = {}
    for name, item in pairs(prototypes.get_item_filtered{{filter = "fuel"}}) do
      table.insert(fuel_cache, {
        name = name,
        categories = as_set(item.fuel_categories),
        bonus = (item.fuel_acceleration_multiplier or 1) + (item.fuel_top_speed_multiplier or 1),
        value = item.fuel_value or 0,
        stack = item.stack_size,
      })
    end
    table.sort(fuel_cache, function(a, b) return a.name < b.name end) -- a fixed order, the same everywhere
  end
  return fuel_cache
end

-- What kind of burner is this prototype? nil = one the mod leaves alone.
local kind_cache = {}
local function kind_of(proto)
  local k = kind_cache[proto.name]
  if k ~= nil then return k or nil end
  local burner = proto.burner_prototype
  if not burner then kind_cache[proto.name] = false return nil end
  local cats = as_set(burner.fuel_categories)
  if cats["nuclear"] then k = "reactor"
  elseif cats["nutrients"] then k = "nutrients"
  elseif proto.type == "reactor" then k = "heater" -- a heating tower (a "reactor" that burns ordinary fuel)
  elseif VEHICLE_TYPES[proto.type] then k = "vehicle"
  else k = "stationary" end
  kind_cache[proto.name] = k
  return k
end

-- The fuels this burner may use, already filtered by the settings, in the order to try them.
-- Vehicles: best first. Others: basic fuels (no vehicle bonus) first, then the smallest bonus first.
local candidate_cache = {}
local function candidates_for(entity)
  local proto = entity.prototype
  local list = candidate_cache[proto.name]
  if list then return list end
  list = {}
  local kind = kind_of(proto)
  local cats = as_set(proto.burner_prototype.fuel_categories)
  for _, f in ipairs(all_fuels()) do
    local fits = false
    for c in pairs(f.categories) do if cats[c] then fits = true break end end
    if fits and not cfg.never[f.name] and not ((kind == "stationary" or kind == "heater") and cfg.stationary_never[f.name]) then
      table.insert(list, f)
    end
  end
  if kind == "vehicle" then
    table.sort(list, function(a, b)
      if a.bonus ~= b.bonus then return a.bonus > b.bonus end
      if a.value ~= b.value then return a.value > b.value end
      return a.name < b.name
    end)
  else
    table.sort(list, function(a, b)
      if a.bonus ~= b.bonus then return a.bonus < b.bonus end
      return a.name < b.name
    end)
  end
  candidate_cache[proto.name] = list
  return list
end

local function reset_caches()
  candidate_cache = {}
  fuel_cache = nil
  quality_cache = nil
end

---------------------------------------------------------------------------------------------------------
-- Where the fuel comes from
---------------------------------------------------------------------------------------------------------

local function supply_counter(entity)
  local platform = entity.surface.platform
  if platform then
    local hub = platform.hub
    if not (hub and hub.valid) then return nil end
    local inv = hub.get_inventory(defines.inventory.hub_main)
    if not inv then return nil end
    return function(name, quality) return inv.get_item_count({name = name, quality = quality}) end
  end
  local networks = entity.surface.find_logistic_networks_by_construction_area(entity.position, entity.force)
  if #networks == 0 then return nil end
  return function(name, quality)
    local best = 0
    for _, net in pairs(networks) do
      if net.valid then
        local n = net.get_item_count({name = name, quality = quality})
        if n > best then best = n end
      end
    end
    return best
  end
end

---------------------------------------------------------------------------------------------------------
-- Deciding what a burner should ask for
---------------------------------------------------------------------------------------------------------

local function first_stack(inv)
  for i = 1, #inv do
    local s = inv[i]
    if s.valid_for_read then
      return {name = s.name, quality = s.quality.name, level = s.quality.level, count = s.count, index = i - 1}
    end
  end
end

local function first_empty_slot(inv)
  for i = 1, #inv do
    if not inv[i].valid_for_read then return i - 1 end
  end
end

-- How much of this fuel to put in.
local function amount_for(kind, fuel_name)
  local stack = prototypes.item[fuel_name].stack_size
  if kind == "reactor" then return math.min(cfg.reactor_keep, stack) end
  if kind == "nutrients" then return math.min(cfg.nutrient_keep, stack) end
  return math.max(1, math.floor(stack * cfg.fill))
end

local function insert_plan(name, quality, count, slot)
  return {id = {name = name, quality = quality}, items = {in_inventory = {{inventory = FUEL, stack = slot, count = count}}}}
end
local function removal_of(stack, inventory_id)
  return {id = {name = stack.name, quality = stack.quality}, items = {in_inventory = {{inventory = inventory_id, stack = stack.index, count = stack.count}}}}
end

local function send(entity, modules, removal)
  if #modules == 0 and #removal == 0 then return end
  entity.surface.create_entity{
    name = "item-request-proxy", position = entity.position, force = entity.force, target = entity,
    modules = modules, removal_plan = (#removal > 0) and removal or nil,
  }
end

-- Is this fuel one this burner may use?
local function allowed(candidates, name)
  for _, f in ipairs(candidates) do if f.name == name then return f end end
end

-- The fuel to put in an empty slot: {name, quality, have} or nil.
local function choose(kind, candidates, available)
  if kind == "vehicle" then
    for _, f in ipairs(candidates) do
      for _, q in ipairs(qualities()) do
        local have = available(f.name, q.name)
        if have > 0 then return {name = f.name, quality = q.name, have = have} end
      end
    end
    return nil
  end
  -- stationary / reactor / nutrients: among the fuels with the smallest bonus that the network has any of,
  -- take the one it has the most of
  local best, best_bonus
  for _, f in ipairs(candidates) do
    if best and f.bonus > best_bonus then break end
    for _, q in ipairs(qualities()) do
      local have = available(f.name, q.name)
      if have > 0 and (not best or have > best.have) then
        best, best_bonus = {name = f.name, quality = q.name, have = have}, f.bonus
      end
    end
  end
  return best
end

local function service(entity)
  if entity.item_request_proxy then return end -- a delivery is already on its way
  local kind = kind_of(entity.prototype)
  if not kind then return end
  if kind == "reactor" and not cfg.reactors then return end
  if kind == "nutrients" and not cfg.biochambers then return end
  if kind == "heater" and not cfg.heaters then return end
  if kind == "vehicle" then
    local moving = entity.train and entity.train.speed ~= 0 or (not entity.train and entity.speed ~= 0)
    if moving then return end -- robots can't fuel a moving vehicle
  end
  local inv = entity.get_fuel_inventory()
  if not inv or #inv == 0 then return end
  local candidates = candidates_for(entity)
  local available = supply_counter(entity)
  if not available then return end

  local modules, removal = {}, {}

  -- used-up fuel (spent fuel cells): carry it away
  if cfg.remove_burnt then
    local burnt = entity.get_burnt_result_inventory()
    if burnt then
      for i = 1, #burnt do
        local s = burnt[i]
        if s.valid_for_read then
          table.insert(removal, removal_of({name = s.name, quality = s.quality.name, count = s.count, index = i - 1}, BURNT))
        end
      end
    end
  end

  -- the player picked a fuel for this machine: use only that
  local choice = storage.choices[entity.unit_number]
  if choice then
    local keep = amount_for(kind, choice.name)
    local total = inv.get_item_count({name = choice.name, quality = choice.quality})
    local others, slot = {}, nil
    for i = 1, #inv do
      local s = inv[i]
      if s.valid_for_read and not (s.name == choice.name and s.quality.name == choice.quality) then
        table.insert(others, {name = s.name, quality = s.quality.name, count = s.count, index = i - 1})
      elseif s.valid_for_read and slot == nil then
        slot = i - 1
      end
    end
    local have = available(choice.name, choice.quality)
    if #others > 0 and have > 0 then
      -- swap the other fuel out (vehicles are standing still here; machines can be swapped any time)
      for _, o in ipairs(others) do table.insert(removal, removal_of(o, FUEL)) end
      table.insert(modules, insert_plan(choice.name, choice.quality, math.min(keep, have), slot or others[1].index))
    elseif #others == 0 and total < math.max(1, math.floor(keep * cfg.refill)) and have > 0 then
      table.insert(modules, insert_plan(choice.name, choice.quality, math.min(keep - total, have), slot or 0))
    end
    return send(entity, modules, removal)
  end

  local loaded = first_stack(inv)
  if not loaded then
    local pick = choose(kind, candidates, available)
    if pick then
      table.insert(modules, insert_plan(pick.name, pick.quality, math.min(amount_for(kind, pick.name), pick.have), 0))
    end
    return send(entity, modules, removal)
  end

  local loaded_fuel = allowed(candidates, loaded.name)
  if not loaded_fuel then return send(entity, modules, removal) end -- fuel the player chose to put in: leave it

  -- vehicles: swap for a full load of better fuel
  if kind == "vehicle" and cfg.vehicle_upgrade then
    for _, f in ipairs(candidates) do
      for _, q in ipairs(qualities()) do
        local better = f.bonus > loaded_fuel.bonus or (f.name == loaded.name and q.level > loaded.level)
        if better then
          local keep = amount_for(kind, f.name)
          if available(f.name, q.name) >= keep then
            table.insert(removal, removal_of(loaded, FUEL))
            table.insert(modules, insert_plan(f.name, q.name, keep, loaded.index))
            return send(entity, modules, removal)
          end
        end
      end
    end
  end

  -- running low: top up with the same fuel, or put another fuel in a free slot
  local keep = amount_for(kind, loaded.name)
  local total = inv.get_item_count({name = loaded.name, quality = loaded.quality})
  if total < math.max(1, math.floor(keep * cfg.refill)) then
    local have = available(loaded.name, loaded.quality)
    if have > 0 then
      table.insert(modules, insert_plan(loaded.name, loaded.quality, math.min(keep - total, have), loaded.index))
    else
      local slot = first_empty_slot(inv)
      local pick = slot and choose(kind, candidates, available)
      if pick then
        table.insert(modules, insert_plan(pick.name, pick.quality, math.min(amount_for(kind, pick.name), pick.have), slot))
      end
    end
  end
  send(entity, modules, removal)
end

---------------------------------------------------------------------------------------------------------
-- Keeping the list of burners
---------------------------------------------------------------------------------------------------------

-- Entity types that have at least one burner prototype (for searches and event filters).
local burner_types
local function get_burner_types()
  if not burner_types then
    local set = {}
    for _, proto in pairs(prototypes.entity) do
      if proto.burner_prototype then set[proto.type] = true end
    end
    burner_types = {}
    for t in pairs(set) do table.insert(burner_types, t) end
    table.sort(burner_types)
  end
  return burner_types
end

local function add_burner(entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  if not kind_of(entity.prototype) then return end
  if storage.burners[entity.unit_number] then return end
  storage.burners[entity.unit_number] = entity
  table.insert(storage.queue, entity.unit_number)
end

local function scan_all()
  local types = get_burner_types()
  if #types == 0 then return end
  for _, surface in pairs(game.surfaces) do
    for _, e in pairs(surface.find_entities_filtered{type = types}) do add_burner(e) end
  end
end

local function init_storage()
  storage.burners = storage.burners or {}
  storage.queue = storage.queue or {}
  storage.cursor = storage.cursor or 1
  storage.choices = storage.choices or {} -- unit_number -> {name, quality}: fuel the player picked
  storage.open_entity = storage.open_entity or {} -- player index -> the machine whose window is open
end

script.on_init(function()
  init_storage()
  read_settings()
  scan_all()
end)

script.on_load(function() read_settings() end)

script.on_configuration_changed(function()
  init_storage()
  read_settings()
  reset_caches()
  kind_cache = {}
  burner_types = nil
  scan_all()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(e)
  if e.setting:sub(1, 3) == "sf-" then
    read_settings()
    reset_caches()
  end
end)

local set_choice -- defined below
local function on_built(e)
  add_burner(e.entity)
  local tag = e.tags and e.tags.sf_fuel
  if tag and e.entity and e.entity.valid then set_choice(e.entity, tag.name, tag.quality) end
end
local function register_build_events()
  local filter = {}
  for _, t in pairs(get_burner_types()) do table.insert(filter, {filter = "type", type = t}) end
  for _, ev in pairs({defines.events.on_built_entity, defines.events.on_robot_built_entity,
                      defines.events.on_space_platform_built_entity, defines.events.script_raised_built,
                      defines.events.script_raised_revive}) do
    if #filter > 0 then script.on_event(ev, on_built, filter) else script.on_event(ev, on_built) end
  end
end
register_build_events()

script.on_event(defines.events.on_tick, function()
  local queue = storage.queue
  local n = #queue
  if n == 0 then return end
  local count = math.min(cfg.per_tick, math.ceil(n / CHECK_INTERVAL))
  local i = storage.cursor
  while count > 0 and #queue > 0 do
    if i > #queue then i = 1 end
    local id = queue[i]
    local entity = storage.burners[id]
    if entity and entity.valid then
      service(entity)
      i = i + 1
    else
      storage.burners[id] = nil
      storage.choices[id] = nil
      queue[i] = queue[#queue]
      queue[#queue] = nil
    end
    count = count - 1
  end
  storage.cursor = i
end)

---------------------------------------------------------------------------------------------------------
-- Picking the fuel for one machine: a panel beside its window, copy / paste, and blueprints
---------------------------------------------------------------------------------------------------------

-- Fuels the player may pick for this machine: anything it can burn, except the "never use at all" list.
-- (A deliberate pick may use fuel the automatic rules avoid, like rocket fuel in a furnace.)
local function pickable_names(entity)
  local cats = as_set(entity.prototype.burner_prototype.fuel_categories)
  local names = {}
  for _, f in ipairs(all_fuels()) do
    local fits = false
    for c in pairs(f.categories) do if cats[c] then fits = true break end end
    if fits and not cfg.never[f.name] then table.insert(names, f.name) end
  end
  return names
end

set_choice = function(entity, name, quality)
  if not (entity and entity.valid and entity.unit_number and kind_of(entity.prototype)) then return end
  local ok = false
  if name then
    for _, n in pairs(pickable_names(entity)) do if n == name then ok = true break end end
  end
  storage.choices[entity.unit_number] = ok and {name = name, quality = quality or "normal"} or nil
end

local PANEL = "sf_panel"
local R = defines.relative_gui_type
local ANCHOR = {
  ["furnace"] = R.furnace_gui, ["boiler"] = R.boiler_gui, ["mining-drill"] = R.mining_drill_gui,
  ["inserter"] = R.inserter_gui, ["locomotive"] = R.train_gui, ["car"] = R.car_gui,
  ["reactor"] = R.reactor_gui, ["assembling-machine"] = R.assembling_machine_gui,
  ["spider-vehicle"] = R.spider_vehicle_gui, ["lab"] = R.lab_gui,
}

local function close_panel(player)
  local old = player.gui.relative[PANEL]
  if old then old.destroy() end
  storage.open_entity[player.index] = nil
end

local function status_caption(choice) return choice and {"sf-gui.locked"} or {"sf-gui.auto"} end

local function open_panel(player, entity)
  close_panel(player)
  local anchor = ANCHOR[entity.type] or R.entity_with_energy_source_gui
  local frame = player.gui.relative.add{type = "frame", name = PANEL, direction = "vertical", caption = {"sf-gui.title"},
    anchor = {gui = anchor, position = defines.relative_gui_position.right}}
  storage.open_entity[player.index] = entity
  local names = pickable_names(entity)
  if #names == 0 then
    frame.add{type = "label", caption = {"sf-gui.nothing"}}
    return
  end
  local row = frame.add{type = "flow", name = "row", direction = "horizontal"}
  row.style.vertical_align = "center"
  local choice = storage.choices[entity.unit_number]
  local picker = row.add{type = "choose-elem-button", name = "sf_pick", elem_type = "item-with-quality",
    elem_filters = {{filter = "name", name = names}}, tooltip = {"sf-gui.pick-tooltip"}}
  if choice then picker.elem_value = {name = choice.name, quality = choice.quality} end
  row.add{type = "button", name = "sf_auto", caption = {"sf-gui.auto-button"}, tooltip = {"sf-gui.auto-tooltip"}}
  local status = frame.add{type = "label", name = "sf_status", caption = status_caption(choice)}
  status.style.single_line = false
  status.style.maximal_width = 220
end

local function refresh_panel(player)
  local frame = player.gui.relative[PANEL]
  local entity = storage.open_entity[player.index]
  if not (frame and entity and entity.valid and frame.sf_status) then return end
  local choice = storage.choices[entity.unit_number]
  frame.row.sf_pick.elem_value = choice and {name = choice.name, quality = choice.quality} or nil
  frame.sf_status.caption = status_caption(choice)
end

script.on_event(defines.events.on_gui_opened, function(e)
  local player = game.get_player(e.player_index)
  local ent = e.entity
  if ent and ent.valid and ent.unit_number and kind_of(ent.prototype) then open_panel(player, ent) else close_panel(player) end
end)

script.on_event(defines.events.on_gui_closed, function(e)
  if e.entity then close_panel(game.get_player(e.player_index)) end
end)

script.on_event(defines.events.on_gui_elem_changed, function(e)
  if e.element.name ~= "sf_pick" then return end
  local player = game.get_player(e.player_index)
  local entity = storage.open_entity[player.index]
  if not (entity and entity.valid) then return end
  local v = e.element.elem_value
  if v then set_choice(entity, v.name, v.quality) else set_choice(entity, nil) end
  refresh_panel(player)
end)

script.on_event(defines.events.on_gui_click, function(e)
  if e.element.name ~= "sf_auto" then return end
  local player = game.get_player(e.player_index)
  local entity = storage.open_entity[player.index]
  if entity and entity.valid then set_choice(entity, nil) end
  refresh_panel(player)
end)

-- Shift + right-click, Shift + left-click: the fuel choice is copied too.
script.on_event(defines.events.on_entity_settings_pasted, function(e)
  local src, dst = e.source, e.destination
  if not (src.valid and dst.valid and src.unit_number and dst.unit_number) then return end
  if not (kind_of(src.prototype) and kind_of(dst.prototype)) then return end
  local c = storage.choices[src.unit_number]
  if c then set_choice(dst, c.name, c.quality) else set_choice(dst, nil) end
end)

-- Blueprints remember each machine's choice (as a tag); placing the blueprint brings it back (on_built).
script.on_event(defines.events.on_player_setup_blueprint, function(e)
  local player = game.get_player(e.player_index)
  local function usable(x)
    if not x then return false end
    local ok, result = pcall(function()
      if x.object_name == "LuaRecord" then return x.valid and x.type == "blueprint" and x.is_blueprint_setup() end
      return x.valid_for_read and x.is_blueprint and x.is_blueprint_setup()
    end)
    return ok and result
  end
  local bp
  for _, candidate in pairs({e.stack, e.record, player.blueprint_to_setup, player.cursor_stack}) do
    if usable(candidate) then bp = candidate break end
  end
  if not bp then return end
  for index, entity in pairs(e.mapping.get()) do
    local c = entity.valid and entity.unit_number and storage.choices[entity.unit_number]
    if c then bp.set_blueprint_entity_tag(index, "sf_fuel", {name = c.name, quality = c.quality}) end
  end
end)

remote.add_interface("smart-fuel", {
  -- what kind of burner the mod thinks this is: "vehicle", "stationary", "reactor", "nutrients" or nil
  kind = function(entity) return entity and entity.valid and kind_of(entity.prototype) or nil end,
  -- pick the fuel for one machine (nil name = back to automatic), or read the pick
  set_fuel = function(entity, name, quality) set_choice(entity, name, quality) end,
  get_fuel = function(entity) return entity and entity.valid and entity.unit_number and storage.choices[entity.unit_number] or nil end,
})
