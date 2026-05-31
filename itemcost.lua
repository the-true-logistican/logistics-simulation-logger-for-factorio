-- =========================================
-- LogSim (Factorio 2.0)
-- Item Cost Calculator Module
--
-- Calculates item and blueprint costs:
--   - area from entity selection boxes
--   - raw materials through recursive recipe resolution
--   - crafting time across the dependency chain
--   - energy cost from crafting time and representative machine power
--   - portfolio unit costs and dependency closures
--
-- Version 0.8.0 first complete working version
-- Version 0.8.1 cache eviction debugging
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 local cleanup, shared formatting and Factorio 2.x inventory normalization
--
-- =========================================

local M = require("config")

local ItemCost = {}
ItemCost.version = "0.9.1"

local MAX_CACHE_SIZE = M.MAX_CACHE_SIZE or 500
local ENERGY_J_PER_KWH = 3600000
local MAX_BREAKDOWN_MATERIALS = 10
local MAX_UNIT_COST_MATERIALS = 12

local cost_cache = {}
local cache_access_order = {}
local cache_stats = {
  hits = 0,
  misses = 0,
  evictions = 0,
  total_requests = 0
}

local csv_header_cache = nil

local RAW_MATERIALS = {
  ["iron-ore"] = true,
  ["copper-ore"] = true,
  ["coal"] = true,
  ["stone"] = true,
  ["uranium-ore"] = true,
  ["wood"] = true,
  ["water"] = true,
  ["crude-oil"] = true,
  ["steam"] = true
}

-- =========================================
-- Generic table helpers
-- =========================================

local function add_amount(map, name, amount)
  amount = tonumber(amount) or 0
  if not name or name == "" or amount == 0 then return end

  map[name] = (map[name] or 0) + amount
end

local function sorted_keys(map)
  local keys = {}

  for key, _ in pairs(map or {}) do
    keys[#keys + 1] = key
  end

  table.sort(keys)

  return keys
end

local function copy_set(set)
  local out = {}

  for key, value in pairs(set or {}) do
    out[key] = value
  end

  return out
end

local function sorted_material_list(raw_materials)
  local materials = {}

  for name, count in pairs(raw_materials or {}) do
    materials[#materials + 1] = {
      name = name,
      count = tonumber(count) or 0
    }
  end

  table.sort(materials, function(a, b)
    return (a.count or 0) > (b.count or 0)
  end)

  return materials
end

local function format_materials(raw_materials, max_materials)
  if not raw_materials or next(raw_materials) == nil then return "" end

  local materials = sorted_material_list(raw_materials)
  local parts = {}
  local limit = math.min(#materials, max_materials)

  for i = 1, limit do
    local mat = materials[i]
    parts[#parts + 1] = string.format("%s=%.1f", tostring(mat.name), tonumber(mat.count) or 0)
  end

  local text = table.concat(parts, ",")
  if #materials > max_materials then
    text = text .. string.format(",...(+%d)", #materials - max_materials)
  end

  return text
end

-- =========================================
-- Power parsing
-- =========================================

local function parse_power_to_watts(value)
  if value == nil then return nil end

  if type(value) == "number" then
    if value > 0 then return value end
    return nil
  end

  if type(value) ~= "string" then return nil end

  local text = value:gsub("%s+", ""):lower()
  local number, unit = text:match("^([%d%.]+)([kmg]?w)$")
  number = tonumber(number)

  if not number or not unit then return nil end

  local multiplier = 1
  if unit == "kw" then
    multiplier = 1e3
  elseif unit == "mw" then
    multiplier = 1e6
  elseif unit == "gw" then
    multiplier = 1e9
  elseif unit == "w" then
    multiplier = 1
  else
    return nil
  end

  local watts = number * multiplier
  if watts <= 0 then return nil end

  return watts
end

local function prototype_power_w(entity_name)
  if not entity_name then return nil end

  local proto = prototypes.entity[entity_name]
  if not proto then return nil end

  local ok, energy_usage = pcall(function()
    return proto.energy_usage
  end)

  if not ok then return nil end

  return parse_power_to_watts(energy_usage)
end

local function get_machine_power_for_recipe(recipe_proto)
  local fallback = M.ITEMCOST_POWER_FALLBACK_W or 375000
  if not recipe_proto then return fallback end

  local map = M.ITEMCOST_CATEGORY_MACHINE or {}
  local category = recipe_proto.category

  local entity_name =
      (category == "smelting" and map.smelting)
   or (category == "chemistry" and map.chemistry)
   or map.default

  return prototype_power_w(entity_name) or fallback
end

-- =========================================
-- LRU cache
-- =========================================

local function cache_touch(key)
  for i, existing_key in ipairs(cache_access_order) do
    if existing_key == key then
      table.remove(cache_access_order, i)
      break
    end
  end

  cache_access_order[#cache_access_order + 1] = key
end

local function cache_get(key)
  cache_stats.total_requests = cache_stats.total_requests + 1

  local value = cost_cache[key]
  if value then
    cache_stats.hits = cache_stats.hits + 1
    cache_touch(key)
    return value
  end

  cache_stats.misses = cache_stats.misses + 1
  return nil
end

local function cache_set(key, value)
  if cost_cache[key] then
    cost_cache[key] = value
    cache_touch(key)
    return
  end

  if #cache_access_order >= MAX_CACHE_SIZE then
    local oldest_key = cache_access_order[1]
    table.remove(cache_access_order, 1)
    cost_cache[oldest_key] = nil
    cache_stats.evictions = cache_stats.evictions + 1
  end

  cost_cache[key] = value
  cache_access_order[#cache_access_order + 1] = key
end

function ItemCost.get_cache_stats()
  local hit_rate = cache_stats.total_requests > 0
    and (cache_stats.hits / cache_stats.total_requests * 100)
    or 0

  return {
    hits = cache_stats.hits,
    misses = cache_stats.misses,
    evictions = cache_stats.evictions,
    total_requests = cache_stats.total_requests,
    hit_rate = hit_rate,
    current_size = #cache_access_order,
    max_size = MAX_CACHE_SIZE
  }
end

function ItemCost.reset_cache_stats()
  cache_stats = {
    hits = 0,
    misses = 0,
    evictions = 0,
    total_requests = 0
  }
end

function ItemCost.clear_cache()
  local old_size = #cache_access_order

  cost_cache = {}
  cache_access_order = {}
  cache_stats.evictions = cache_stats.evictions + old_size
end

-- =========================================
-- CSV header
-- =========================================

local function get_csv_header(player)
  if csv_header_cache then
    return csv_header_cache
  end

  -- Text boxes require plain strings; LocalisedString translation is asynchronous.
  csv_header_cache = table.concat({
    "ID",
    "item",
    "amount",
    "area",
    "time_s",
    "energy_kWh",
    "materials"
  }, ";")

  return csv_header_cache
end

-- =========================================
-- Prototype and recipe helpers
-- =========================================

local function calculate_area(entity_name)
  local proto = prototypes.entity[entity_name]
  if not proto then return 0 end

  local box = proto.selection_box
  if not box then return 0 end

  local width = math.ceil(math.abs(box.right_bottom.x - box.left_top.x))
  local height = math.ceil(math.abs(box.right_bottom.y - box.left_top.y))

  return width * height
end

local function recipe_product_amount(recipe_proto, item_name)
  if not (recipe_proto and item_name) then return nil end

  if recipe_proto.main_product and recipe_proto.main_product.name == item_name then
    return tonumber(recipe_proto.main_product.amount) or 1
  end

  for _, product in pairs(recipe_proto.products or {}) do
    if product and product.name == item_name then
      return tonumber(product.amount) or 1
    end
  end

  return nil
end

local function find_enabled_recipe_for_item(item_name, force)
  if not item_name then return nil end

  force = force or game.forces.player

  for recipe_name, recipe_proto in pairs(prototypes.recipe) do
    local force_recipe = force.recipes[recipe_name]
    if force_recipe and force_recipe.enabled then
      if recipe_product_amount(recipe_proto, item_name) then
        return recipe_proto
      end
    end
  end

  return nil
end

local function get_crafting_time(recipe_proto)
  if not recipe_proto then return 0 end
  return recipe_proto.energy or 0.5
end

-- =========================================
-- Recursive material resolution
-- =========================================

local function terminal_result(item_name, amount)
  return {
    raw_materials = { [item_name] = amount },
    total_time = 0,
    total_energy = 0
  }
end

local function scale_cached_result(cached, amount)
  local result = {
    raw_materials = {},
    total_time = cached.total_time * amount,
    total_energy = cached.total_energy * amount
  }

  for material, count in pairs(cached.raw_materials) do
    result.raw_materials[material] = count * amount
  end

  return result
end

local function resolve_item_recursive(item_name, amount, force, depth, visited)
  depth = depth or 0
  visited = visited or {}
  amount = amount or 1

  local cache_key = item_name
  if depth == 0 then
    local cached = cache_get(cache_key)
    if cached then
      return scale_cached_result(cached, amount)
    end
  end

  if depth > 20 then
    return terminal_result(item_name, amount)
  end

  if visited[item_name] then
    return terminal_result(item_name, amount)
  end

  if RAW_MATERIALS[item_name] then
    return terminal_result(item_name, amount)
  end

  local recipe = find_enabled_recipe_for_item(item_name, force)
  if not recipe then
    return terminal_result(item_name, amount)
  end

  local recipe_output = recipe_product_amount(recipe, item_name) or 1
  local craft_count = math.ceil(amount / recipe_output)

  local recipe_time = get_crafting_time(recipe) * craft_count
  local recipe_energy = recipe_time * get_machine_power_for_recipe(recipe)

  local next_visited = copy_set(visited)
  next_visited[item_name] = true

  local total_raw = {}
  local total_time = recipe_time
  local total_energy = recipe_energy

  for _, ingredient in pairs(recipe.ingredients or {}) do
    local ingredient_name = ingredient and ingredient.name
    local ingredient_amount = (tonumber(ingredient and ingredient.amount) or 1) * craft_count

    if ingredient_name then
      local sub_result = resolve_item_recursive(
        ingredient_name,
        ingredient_amount,
        force,
        depth + 1,
        next_visited
      )

      for material, count in pairs(sub_result.raw_materials) do
        add_amount(total_raw, material, count)
      end

      total_time = total_time + sub_result.total_time
      total_energy = total_energy + sub_result.total_energy
    end
  end

  local result = {
    raw_materials = total_raw,
    total_time = total_time,
    total_energy = total_energy
  }

  if depth == 0 and amount == 1 then
    cache_set(cache_key, result)
  end

  return result
end

-- =========================================
-- Public cost calculation API
-- =========================================

function ItemCost.calculate_item_cost(item_name, amount, force)
  amount = amount or 1
  force = force or game.forces.player

  local result = {
    item_name = item_name,
    amount = amount,
    area = 0,
    raw_materials = {},
    total_time = 0,
    total_energy = 0
  }

  local item_proto = prototypes.item[item_name]
  if item_proto and item_proto.place_result then
    result.area = calculate_area(item_proto.place_result.name) * amount
  end

  local resolution = resolve_item_recursive(item_name, amount, force)
  result.raw_materials = resolution.raw_materials
  result.total_time = resolution.total_time
  result.total_energy = resolution.total_energy

  return result
end

function ItemCost.calculate_blueprint_cost(item_counts, force)
  force = force or game.forces.player

  local total = {
    area = 0,
    raw_materials = {},
    total_time = 0,
    total_energy = 0
  }

  local items = {}

  for item_name, count in pairs(item_counts or {}) do
    local item_cost = ItemCost.calculate_item_cost(item_name, count, force)
    items[item_name] = item_cost

    total.area = total.area + item_cost.area
    total.total_time = total.total_time + item_cost.total_time
    total.total_energy = total.total_energy + item_cost.total_energy

    for material, material_count in pairs(item_cost.raw_materials) do
      add_amount(total.raw_materials, material, material_count)
    end
  end

  return {
    total = total,
    items = items
  }
end

-- =========================================
-- Fixed-asset breakdown formatting
-- =========================================

function ItemCost.format_detailed_breakdown(costs_result, player)
  local lines = {}

  lines[#lines + 1] = get_csv_header(player)

  local sorted_items = {}
  for item_name, item_cost in pairs((costs_result and costs_result.items) or {}) do
    if (item_cost.amount or 0) > 0 then
      sorted_items[#sorted_items + 1] = {
        name = item_name,
        cost = item_cost
      }
    end
  end

  table.sort(sorted_items, function(a, b)
    return a.name < b.name
  end)

  local sum_amount = 0
  local sum_area = 0
  local sum_time = 0
  local sum_energy_kwh = 0
  local id = 0

  for _, item_data in ipairs(sorted_items) do
    id = id + 1

    local item_name = item_data.name
    local cost = item_data.cost or {}

    local amount = cost.amount or 0
    local area = cost.area or 0
    local time_sec = cost.total_time or 0
    local energy_kwh = (cost.total_energy or 0) / ENERGY_J_PER_KWH
    local materials = format_materials(cost.raw_materials, MAX_BREAKDOWN_MATERIALS)

    sum_amount = sum_amount + amount
    sum_area = sum_area + area
    sum_time = sum_time + time_sec
    sum_energy_kwh = sum_energy_kwh + energy_kwh

    lines[#lines + 1] = string.format(
      "%d;%s;%d;%.2f;%.1f;%.2f;%s",
      id,
      item_name,
      amount,
      area,
      time_sec,
      energy_kwh,
      materials
    )
  end

  lines[#lines + 1] = string.format(
    ";%s;%d;%.2f;%.1f;%.2f;",
    "TOTAL",
    sum_amount,
    sum_area,
    sum_time,
    sum_energy_kwh
  )

  local footprint = costs_result and costs_result.footprint
  if footprint then
    lines[#lines + 1] = string.format(
      "%s;width=%d;height=%d;area=%d;;",
      "FOOTPRINT",
      footprint.gross_w,
      footprint.gross_h,
      footprint.gross_area
    )
  end

  return table.concat(lines, "\n")
end

-- =========================================
-- Portfolio item collection
-- =========================================

local function normalize_inventory_content_entry(k, v)
  local name

  if type(k) == "number" and type(v) == "table" then
    name = v.name or v.item
  elseif type(k) == "string" then
    name = k
  elseif type(k) == "table" then
    name = k.name or k.item
  end

  return name
end

local function add_item(set, name)
  if not name or name == "" then return end

  name = tostring(name)
  local base = name:match("^(.-)@.+$") or name
  set[base] = true
end

local function add_contents_items(set, contents)
  if not contents then return end

  for k, v in pairs(contents) do
    add_item(set, normalize_inventory_content_entry(k, v))
  end
end

local function scan_inventory(set, ent, inv_id)
  if not (ent and ent.valid and inv_id) then return end

  local ok_inv, inv = pcall(function()
    return ent.get_inventory(inv_id)
  end)

  if not ok_inv or not (inv and inv.valid) then return end

  local ok_contents, contents = pcall(function()
    return inv.get_contents()
  end)

  if ok_contents and contents then
    add_contents_items(set, contents)
  end
end

local function scan_fluids(set, ent)
  if not (ent and ent.valid) then return end

  local ok, fluids = pcall(function()
    return ent.get_fluid_contents()
  end)

  if not (ok and fluids) then return end

  for fluid_name, _ in pairs(fluids) do
    add_item(set, fluid_name)
  end
end

local function scan_machine_products(set, ent)
  if not (ent and ent.valid) then return end

  if ent.get_recipe then
    local ok, recipe = pcall(function()
      return ent.get_recipe()
    end)

    if ok and recipe and recipe.valid and recipe.products then
      for _, product in pairs(recipe.products) do
        if product and product.name then
          add_item(set, product.name)
        end
      end
      return
    end
  end

  if ent.type == "mining-drill" then
    local target = ent.mining_target
    if target and target.valid and target.prototype and target.prototype.mineable_properties then
      local products = target.prototype.mineable_properties.products
      for _, product in pairs(products or {}) do
        if product and product.name then
          add_item(set, product.name)
        end
      end
    end
  end
end

local function scan_machine_buffers(set, ent)
  local entity_type = ent.type

  if entity_type == "assembling-machine" then
    scan_inventory(set, ent, defines.inventory.assembling_machine_input)
    scan_inventory(set, ent, defines.inventory.assembling_machine_output)
    scan_inventory(set, ent, defines.inventory.fuel)
    scan_inventory(set, ent, defines.inventory.burnt_result)

  elseif entity_type == "furnace" then
    scan_inventory(set, ent, defines.inventory.furnace_source)
    scan_inventory(set, ent, defines.inventory.furnace_result)
    scan_inventory(set, ent, defines.inventory.fuel)
    scan_inventory(set, ent, defines.inventory.burnt_result)

  elseif entity_type == "lab" then
    scan_inventory(set, ent, defines.inventory.lab_input)

  elseif entity_type == "mining-drill" then
    scan_inventory(set, ent, defines.inventory.mining_drill_output)
    scan_inventory(set, ent, defines.inventory.fuel)
    scan_inventory(set, ent, defines.inventory.burnt_result)

  elseif entity_type == "rocket-silo" then
    scan_inventory(set, ent, defines.inventory.rocket_silo_input)
    scan_inventory(set, ent, defines.inventory.rocket_silo_output)
    scan_inventory(set, ent, defines.inventory.rocket_silo_result)
  end
end

function ItemCost.collect_portfolio_items(storage_table, resolve_entity_fn, force)
  local set = {}

  storage_table = storage_table or {}

  for _, rec in pairs(storage_table.registry or {}) do
    local ent = resolve_entity_fn and resolve_entity_fn(rec) or nil

    if ent and ent.valid then
      if ent.type == "container" or ent.type == "logistic-container" then
        scan_inventory(set, ent, defines.inventory.chest)
      elseif ent.type == "cargo-wagon" then
        scan_inventory(set, ent, defines.inventory.cargo_wagon)
      elseif ent.type == "storage-tank" or ent.type == "fluid-wagon" then
        scan_fluids(set, ent)
      end
    end
  end

  for _, rec in pairs(storage_table.machines or {}) do
    local ent = resolve_entity_fn and resolve_entity_fn(rec) or nil

    if ent and ent.valid then
      scan_machine_products(set, ent)
      scan_machine_buffers(set, ent)
    end
  end

  return set
end

-- =========================================
-- Unit-cost calculation and formatting
-- =========================================

function ItemCost.calculate_unit_costs(item_set, force)
  force = force or game.forces.player

  local out = {}
  if not item_set then return out end

  for name, _ in pairs(item_set) do
    local cost = ItemCost.calculate_item_cost(name, 1, force)

    if cost then
      cost.area = 0
      cost.amount = 1
      out[name] = cost
    end
  end

  return out
end

local function format_unit_cost_table(unit_costs, title)
  local lines = {}

  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = "# " .. title
  lines[#lines + 1] = "id;item;time_s;energy_kWh;materials"

  if not unit_costs or next(unit_costs) == nil then
    lines[#lines + 1] = "NONE;0;0;"
    return table.concat(lines, "\n")
  end

  local id = 0

  for _, name in ipairs(sorted_keys(unit_costs)) do
    local cost = unit_costs[name] or {}
    local time_s = tonumber(cost.total_time or 0) or 0
    local energy_kwh = (tonumber(cost.total_energy or 0) or 0) / ENERGY_J_PER_KWH
    local materials = format_materials(cost.raw_materials, MAX_UNIT_COST_MATERIALS)

    id = id + 1

    lines[#lines + 1] = string.format(
      "%d;%s;%.1f;%.3f;%s",
      id,
      name,
      time_s,
      energy_kwh,
      materials
    )
  end

  return table.concat(lines, "\n")
end

function ItemCost.format_portfolio_unit_costs(unit_costs)
  return format_unit_cost_table(
    unit_costs,
    "WORKING_CAPITAL_PORTFOLIO (unit costs, amount=1)"
  )
end

function ItemCost.format_masterdata_unit_costs(unit_costs)
  return format_unit_cost_table(
    unit_costs,
    "MASTERDATA_UNIT_COSTS (amount=1)"
  )
end

-- =========================================
-- Dependency closure
-- =========================================

function ItemCost.collect_dependency_items(item_name, out_set, force, depth, visited)
  out_set = out_set or {}
  force = force or game.forces.player
  depth = depth or 0
  visited = visited or {}

  if not item_name or item_name == "" then return out_set end
  if visited[item_name] then return out_set end
  if depth > M.COLLECT_DEPENDENC_DEPTH then return out_set end

  visited[item_name] = true

  local recipe = find_enabled_recipe_for_item(item_name, force)
  if not recipe or not recipe.ingredients then
    return out_set
  end

  for _, ingredient in pairs(recipe.ingredients) do
    local ingredient_name = ingredient and ingredient.name

    if ingredient_name and ingredient_name ~= "" then
      out_set[ingredient_name] = true
      ItemCost.collect_dependency_items(
        ingredient_name,
        out_set,
        force,
        depth + 1,
        visited
      )
    end
  end

  return out_set
end

function ItemCost.expand_item_set_full(seed_set, force)
  force = force or game.forces.player

  local out = {}
  if not seed_set then return out end

  for name, _ in pairs(seed_set) do
    if name and name ~= "" then
      out[name] = true
    end
  end

  for name, _ in pairs(seed_set) do
    if name and name ~= "" then
      local dependencies = ItemCost.collect_dependency_items(name, {}, force)

      for dependency, _ in pairs(dependencies) do
        out[dependency] = true
      end
    end
  end

  return out
end

return ItemCost