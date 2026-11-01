-- Map settings (runtime-global): shared by everyone in a multiplayer game, changeable mid-game.
local function int(name, default, min, max, order)
  return {type = "int-setting", name = name, setting_type = "runtime-global", default_value = default,
          minimum_value = min, maximum_value = max, order = order}
end
local function bool(name, default, order)
  return {type = "bool-setting", name = name, setting_type = "runtime-global", default_value = default, order = order}
end
local function text(name, default, order)
  return {type = "string-setting", name = name, setting_type = "runtime-global", default_value = default,
          allow_blank = true, order = order}
end

data:extend({
  int("sf-fill-percent", 100, 1, 100, "a"),
  int("sf-refill-percent", 25, 1, 100, "b"),
  bool("sf-vehicle-upgrade", true, "c"),
  text("sf-stationary-never", "rocket-fuel, nuclear-fuel", "d"),
  text("sf-never", "", "e"),
  bool("sf-reactors", true, "f"),
  int("sf-reactor-keep", 2, 1, 50, "g"),
  bool("sf-biochambers", true, "h"),
  int("sf-nutrient-keep", 20, 1, 200, "i"),
  bool("sf-heating-towers", false, "i2"),
  bool("sf-remove-burnt", true, "j"),
  int("sf-per-tick", 20, 1, 500, "k"),
})
