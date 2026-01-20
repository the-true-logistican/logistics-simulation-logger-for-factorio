-- =========================================
-- LogSim (Factorio 2.0) 
-- Item Cost Calculator Module
--
-- Calculates comprehensive costs for items:
-- - Area (from selection_box)
-- - Raw materials (recursive recipe resolution)
-- - Time value (crafting time chain)
-- - Energy cost (time × machine power)
-- - fixed assets, unit costs and dependency closures for items and blueprints.
-- =========================================

local ItemCost = {}

local M = require("config")

 ItemCost.version = "0.8.0"

-- Cache for calculated costs to avoid recalculation
-- =========================================
-- BOUNDED LRU CACHE (Memory Safety)
-- =========================================

local MAX_CACHE_SIZE = M.MAX_CACHE_SIZE   -- Limit cache to prevent memory bloat
local cost_cache = {}
local cache_access_order = {}  -- Track access order for LRU eviction
local cache_stats = {
  hits = 0,
  misses = 0,
  evictions = 0,
  total_requests = 0
}

local function parse_power_to_watts(v)
  if v == nil then return nil end

  -- Sometimes mods/prototypes may provide numbers (rare). Treat as W.
  if type(v) == "number" then
    if v > 0 then return v end
    return nil
  end

  if type(v) ~= "string" then return nil end

  -- normalize: "150kW" / "150 kW" / "1.2MW"
  local s = v:gsub("%s+", ""):lower()
  local num, unit = s:match("^([%d%.]+)([kmg]?w)$")
  num = tonumber(num)
  if not num or not unit then return nil end

  local mul = 1
  if unit == "kw" then mul = 1e3
  elseif unit == "mw" then mul = 1e6
  elseif unit == "gw" then mul = 1e9
  elseif unit == "w" then mul = 1
  else return nil end

  local w = num * mul
  if w <= 0 then return nil end
  return w
end

local function prototype_power_w(entity_name)
  if not entity_name then return nil end
  local proto = prototypes.entity[entity_name]
  if not proto then return nil end

  -- energy_usage is typically a string like "150kW"
  local ok, eu = pcall(function() return proto.energy_usage end)
  if not ok then return nil end

  return parse_power_to_watts(eu)
end

-- Get item from cache (updates LRU order)
local function cache_get(key)
  cache_stats.total_requests = cache_stats.total_requests + 1
  
  local value = cost_cache[key]
  if value then
    cache_stats.hits = cache_stats.hits + 1
    
    -- Update LRU: move to end
    for i, k in ipairs(cache_access_order) do
      if k == key then
        table.remove(cache_access_order, i)
        break
      end
    end
    cache_access_order[#cache_access_order + 1] = key
    
    return value
  end
  
  cache_stats.misses = cache_stats.misses + 1
  return nil
end

-- Add item to cache (with LRU eviction if full)
local function cache_set(key, value)
  -- If already exists, update it
  if cost_cache[key] then
    cost_cache[key] = value
    -- Move to end of LRU
    for i, k in ipairs(cache_access_order) do
      if k == key then
        table.remove(cache_access_order, i)
        break
      end
    end
    cache_access_order[#cache_access_order + 1] = key
    return
  end
  
  -- Check if cache is full
  if #cache_access_order >= MAX_CACHE_SIZE then
    -- Evict oldest (least recently used)
    local oldest_key = cache_access_order[1]
    table.remove(cache_access_order, 1)
    cost_cache[oldest_key] = nil
    cache_stats.evictions = cache_stats.evictions + 1
  end
  
  -- Add new entry
  cost_cache[key] = value
  cache_access_order[#cache_access_order + 1] = key
end

-- Get cache statistics (for debugging/monitoring)
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

-- Reset cache statistics
function ItemCost.reset_cache_stats()
  cache_stats = {
    hits = 0,
    misses = 0,
    evictions = 0,
    total_requests = 0
  }
end

-- CSV Header cache - initialized on first use with player locale
local csv_header_cache = nil

-- Raw materials list (items with no recipe)
local RAW_MATERIALS = {
  ["iron-ore"] = true,
  ["copper-ore"] = true,
  ["coal"] = true,
  ["stone"] = true,
  ["uranium-ore"] = true,
  ["wood"] = true,
  ["water"] = true,
  ["crude-oil"] = true,
  ["steam"] = true,
}

-- =========================================
-- CSV Header Cache
-- =========================================

-- Function to initialize/get CSV header (cached)
local function get_csv_header(player)
  if csv_header_cache then
    return csv_header_cache
  end
   -- NOTE: Translating LocalisedString into plain strings is async in Factorio (request_translation/on_string_translated).
  -- This report is shown in a text-box, which only accepts plain strings, so we use stable English headers here.
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
-- Helper Functions
-- =========================================

-- Calculate area from selection_box (rounded to full tiles)
local function calculate_area(entity_name)
  local proto = prototypes.entity[entity_name]
  if not proto then return 0 end
  
  local box = proto.selection_box
  if not box then return 0 end
  
  local width = math.ceil(math.abs(box.right_bottom.x - box.left_top.x))
  local height = math.ceil(math.abs(box.right_bottom.y - box.left_top.y))
  
  return width * height
end

-- Get recipe that produces an item
local function get_recipe_for_item(item_name, force)
  force = force or game.forces.player
  
  for recipe_name, recipe_proto in pairs(prototypes.recipe) do
    local recipe = force.recipes[recipe_name]
    if recipe and recipe.enabled then
      if recipe_proto.main_product and recipe_proto.main_product.name == item_name then
        return recipe_proto
      end
      
      for _, product in pairs(recipe_proto.products) do
        if product.name == item_name then
          return recipe_proto
        end
      end
    end
  end
  
  return nil
end

-- Get crafting time in seconds
local function get_crafting_time(recipe_proto)
  if not recipe_proto then return 0 end
  return recipe_proto.energy or 0.5
end

-- Get machine power for recipe category
local function get_machine_power_for_recipe(recipe_proto)
  local fallback = M.ITEMCOST_POWER_FALLBACK_W or 375000

  if not recipe_proto then return fallback end

  local cat = recipe_proto.category

  -- Category -> representative machine prototype name (from config)
  local map = M.ITEMCOST_CATEGORY_MACHINE or {}
  local ent_name =
      (cat == "smelting" and map.smelting)
   or (cat == "chemistry" and map.chemistry)
   or map.default

  local w = prototype_power_w(ent_name)
  if w then return w end

  -- Last resort
  return fallback
end

-- =========================================
-- Recursive Material Resolution
-- =========================================

local function resolve_item_recursive(item_name, amount, force, depth, visited)
  depth = depth or 0
  visited = visited or {}
  amount = amount or 1
  
  -- PATCH: Cache-Lookup am Anfang (nur bei depth=0, amount=1)
  local cache_key = item_name
  if depth == 0 then
    local cached = cache_get(cache_key)
    if cached then
      -- Cache hit! Skaliere Ergebnis mit amount
      local result = {
        raw_materials = {},
        total_time = cached.total_time * amount,
        total_energy = cached.total_energy * amount,
      }
      for mat, count in pairs(cached.raw_materials) do
        result.raw_materials[mat] = count * amount
      end
      return result
    end
  end
  
  -- Recursion depth limit
  if depth > 20 then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  -- Circular dependency check
  if visited[item_name] then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  -- Raw materials haben keine Recipe
  if RAW_MATERIALS[item_name] then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  -- Recipe lookup
  local recipe = get_recipe_for_item(item_name, force)
  if not recipe then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  -- Calculate how many times we need to craft
  local recipe_output = 1
  for _, product in pairs(recipe.products) do
    if product.name == item_name then
      recipe_output = product.amount or 1
      break
    end
  end
  
  local craft_count = math.ceil(amount / recipe_output)
  
  -- Calculate time & energy for this recipe
  local crafting_time = get_crafting_time(recipe)
  local machine_power = get_machine_power_for_recipe(recipe)
  local recipe_time = crafting_time * craft_count
  local recipe_energy = recipe_time * machine_power
  
  -- Mark as visited for circular dependency check
  local new_visited = {}
  for k, v in pairs(visited) do new_visited[k] = v end
  new_visited[item_name] = true
  
  -- Recursive resolution of ingredients
  local total_raw = {}
  local total_time = recipe_time
  local total_energy = recipe_energy
  
  for _, ingredient in pairs(recipe.ingredients) do
    local ing_name = ingredient.name
    local ing_amount = (ingredient.amount or 1) * craft_count
    
    local sub_result = resolve_item_recursive(
      ing_name, 
      ing_amount, 
      force, 
      depth + 1, 
      new_visited
    )
    
    for mat, count in pairs(sub_result.raw_materials) do
      total_raw[mat] = (total_raw[mat] or 0) + count
    end
    
    total_time = total_time + sub_result.total_time
    total_energy = total_energy + sub_result.total_energy
  end
  
  local result = {
    raw_materials = total_raw,
    total_time = total_time,
    total_energy = total_energy,
  }
  
  -- PATCH: Cache-Speicherung am Ende (nur bei depth=0, amount=1)
  if depth == 0 and amount == 1 then
    cache_set(cache_key, result)
  end
  
  return result
end

-- =========================================
-- Public API
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
    total_energy = 0,
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
    total_energy = 0,
  }
  
  local items = {}
  
  for item_name, count in pairs(item_counts) do
    local item_cost = ItemCost.calculate_item_cost(item_name, count, force)
    items[item_name] = item_cost
    
    total.area = total.area + item_cost.area
    total.total_time = total.total_time + item_cost.total_time
    total.total_energy = total.total_energy + item_cost.total_energy
    
    for mat, mat_count in pairs(item_cost.raw_materials) do
      total.raw_materials[mat] = (total.raw_materials[mat] or 0) + mat_count
    end
  end
  
  return {
    total = total,
    items = items,
  }
end

function ItemCost.clear_cache()
  cost_cache = {}
  cache_access_order = {}
  cache_stats.evictions = cache_stats.evictions + #cache_access_order
  
end

-- Format detailed per-item breakdown as semicolon table
-- Version 0.6.1 - Fully localized headers (cached on first call)
function ItemCost.format_detailed_breakdown(costs_result, player)
  local lines = {}

  -- Header row - use cached localized header
  lines[#lines+1] = get_csv_header(player)

  -- Collect + sort items alphabetically
  local sorted_items = {}
  for item_name, item_cost in pairs(costs_result.items) do
    if (item_cost.amount or 0) > 0 then
      table.insert(sorted_items, { name = item_name, cost = item_cost })
    end  
  end
  
  table.sort(sorted_items, function(a, b)
    return a.name < b.name
  end)  

  local sum_amount = 0
  local sum_area = 0
  local sum_time = 0
  local sum_energy_kwh = 0
  
  -- Data rows
  local id = 0
  for _, item_data in ipairs(sorted_items) do
    id = id + 1
    local item_name = item_data.name
    local c = item_data.cost or {}

    local amount = c.amount or 0
    local area = c.area or 0
    local time_sec = c.total_time or 0
    local energy_kwh = (c.total_energy or 0) / 3600000

    -- Materials as compact comma list
    local mats_str = ""
    if c.raw_materials and next(c.raw_materials) then
      local mats = {}
      for mat, cnt in pairs(c.raw_materials) do
        table.insert(mats, { name = mat, count = cnt })
      end
      table.sort(mats, function(a, b) return a.count > b.count end)

      local max_mats = 10
      local parts = {}
      for i, m in ipairs(mats) do
        if i > max_mats then break end
        parts[#parts+1] = string.format("%s=%.1f", m.name, m.count)
      end
      mats_str = table.concat(parts, ",")
      if #mats > max_mats then
        mats_str = mats_str .. string.format(",...(+%d)", #mats - max_mats)
      end
    end

    sum_amount = sum_amount + amount
    sum_area = sum_area + area
    sum_time = sum_time + time_sec
    sum_energy_kwh = sum_energy_kwh + energy_kwh

    lines[#lines+1] = string.format(
      "%d;%s;%d;%.2f;%.1f;%.2f;%s",
      id, item_name, amount, area, time_sec, energy_kwh, mats_str
    )
  end

  -- Total row (localized)
  local total_label = "TOTAL"
  lines[#lines+1] = string.format(
    ";%s;%d;%.2f;%.1f;%.2f;",
    total_label, sum_amount, sum_area, sum_time, sum_energy_kwh
  )

  -- Footprint (localized)
  local fp = costs_result.footprint
  if fp then
    local footprint_label = "FOOTPRINT"
    lines[#lines+1] = string.format(
      "%s;width=%d;height=%d;area=%d;;",
      footprint_label, fp.gross_w, fp.gross_h, fp.gross_area
    )
  end
  
  return table.concat(lines, "\n")
end

-- =========================================
-- Working Capital / Portfolio Unit Costs
-- (No quantities; only item universe + unit costs)
-- =========================================

-- Normalize "item key" (handles string, item-with-quality table keys)
local function normalize_item_key(k)
  if type(k) == "string" then
    return k
  elseif type(k) == "table" then
    -- Factorio can use {name=..., quality=...} style keys
    return k.name or k.item or nil
  else
    return nil
  end
end

local function add_item(set, name)
  if not name or name == "" then return end
  -- Ignore quality suffixes like "name@rare" if they ever show up as strings
  -- (Your protocol may log quality, but unit costs remain per base item.)
  name = tostring(name)
  local base = name:match("^(.-)@.+$") or name
  set[base] = true
end

local function add_contents_keys(set, contents)
  if not contents then return end
  for k, _ in pairs(contents) do
    local name = normalize_item_key(k)
    add_item(set, name)
  end
end

local function scan_inventory(set, ent, inv_id)
  if not (ent and ent.valid) then return end
  if not inv_id then return end

  local ok, inv = pcall(function() return ent.get_inventory(inv_id) end)
  if not ok or not (inv and inv.valid) then return end

  local ok2, contents = pcall(function() return inv.get_contents() end)
  if ok2 and contents then
    add_contents_keys(set, contents)
  end
end

-- Portfolio products: recipe products or mining target products
local function scan_machine_products(set, ent)
  if not (ent and ent.valid) then return end

  -- 1) Try recipe products (safe: some entity types throw on get_recipe)
  if ent.get_recipe then
    local ok, recipe = pcall(function() return ent.get_recipe() end)
    if ok and recipe and recipe.valid and recipe.products then
      for _, p in pairs(recipe.products) do
        if p and p.name then add_item(set, p.name) end
      end
      return
    end
  end

  -- 2) Mining drill products via mining_target
  if ent.type == "mining-drill" then
    local tgt = ent.mining_target
    if tgt and tgt.valid and tgt.prototype and tgt.prototype.mineable_properties then
      local prods = tgt.prototype.mineable_properties.products
      if prods then
        for _, p in pairs(prods) do
          if p and p.name then add_item(set, p.name) end
        end
      end
    end
  end
end

-- Collect all items that "exist or can exist" in the factory:
-- - registered chests: contents keys
-- - registered tanks: fluid keys
-- - registered machines:
--   - recipe/mining products (portfolio mode: regardless of products_finished)
--   - input/output/fuel/burnt buffers (because you might buy intermediate parts)
--
-- storage: global storage table
-- resolve_entity_fn(rec): returns LuaEntity (e.g. Chests.resolve_entity)
-- force: LuaForce (used later for recipe resolution in calculate_item_cost)
function ItemCost.collect_portfolio_items(storage, resolve_entity_fn, force)
  local set = {}

  storage = storage or {}
  local reg = storage.registry or {}
  local machines = storage.machines or {}

  -- 1) Registered chests + tanks
  for _, rec in pairs(reg) do
    local ent = resolve_entity_fn and resolve_entity_fn(rec) or nil
    if ent and ent.valid then
      if ent.type == "container" or ent.type == "logistic-container" then
        scan_inventory(set, ent, defines.inventory.chest)
      elseif ent.type == "storage-tank" then
        local ok, fluids = pcall(function() return ent.get_fluid_contents() end)
        if ok and fluids then
          for fname, _ in pairs(fluids) do
            add_item(set, fname)
          end
        end
      end
    end
  end

  -- 2) Registered machines: products + buffers
  for _, rec in pairs(machines) do
    local ent = resolve_entity_fn and resolve_entity_fn(rec) or nil
    if ent and ent.valid then
      -- Portfolio products (what the machine is configured to produce)
      scan_machine_products(set, ent)

      -- Buffers: input/output/fuel/burnt etc.
      local t = ent.type

      if t == "assembling-machine" then
        scan_inventory(set, ent, defines.inventory.assembling_machine_input)
        scan_inventory(set, ent, defines.inventory.assembling_machine_output)
        scan_inventory(set, ent, defines.inventory.fuel)
        scan_inventory(set, ent, defines.inventory.burnt_result)

      elseif t == "furnace" then
        scan_inventory(set, ent, defines.inventory.furnace_source)
        scan_inventory(set, ent, defines.inventory.furnace_result)
        scan_inventory(set, ent, defines.inventory.fuel)
        scan_inventory(set, ent, defines.inventory.burnt_result)

      elseif t == "lab" then
        scan_inventory(set, ent, defines.inventory.lab_input)

      elseif t == "mining-drill" then
        -- Output exists for drills; fuel may exist for burner drills
        scan_inventory(set, ent, defines.inventory.mining_drill_output)
        scan_inventory(set, ent, defines.inventory.fuel)
        scan_inventory(set, ent, defines.inventory.burnt_result)

      elseif t == "rocket-silo" then
        -- Safe calls; if an inventory id doesn't exist, scan_inventory will just skip.
        scan_inventory(set, ent, defines.inventory.rocket_silo_input)
        scan_inventory(set, ent, defines.inventory.rocket_silo_output)
        scan_inventory(set, ent, defines.inventory.rocket_silo_result)
      end
    end
  end

  return set
end

-- Calculate unit costs (amount=1) for each item key in the set.
-- Returns map: name -> { total_time, total_energy, raw_materials }
function ItemCost.calculate_unit_costs(item_set, force)
  force = force or game.forces.player
  local out = {}

  if not item_set then return out end

  for name, _ in pairs(item_set) do
    -- Only unit cost (amount = 1); area is irrelevant for working capital
    local c = ItemCost.calculate_item_cost(name, 1, force)
    if c then
      c.area = 0
      c.amount = 1
      out[name] = c
    end
  end

  return out
end

-- Format unit costs as semicolon table for the inventory window.
function ItemCost.format_portfolio_unit_costs(unit_costs)
  local lines = {}
  lines[#lines+1] = "# ----"
  lines[#lines+1] = "# WORKING_CAPITAL_PORTFOLIO (unit costs, amount=1)"
  lines[#lines+1] = "id;item;time_s;energy_kWh;materials"

  if not unit_costs or next(unit_costs) == nil then
    lines[#lines+1] = "NONE;0;0;"
    return table.concat(lines, "\n")
  end

  local names = {}
  for name, _ in pairs(unit_costs) do names[#names+1] = name end
  table.sort(names)

  local id = 0 
  for _, name in ipairs(names) do
    local c = unit_costs[name] or {}
    local time_s = tonumber(c.total_time or 0) or 0
    local energy_kwh = (tonumber(c.total_energy or 0) or 0) / 3600000

    local mats_str = ""
    if c.raw_materials and next(c.raw_materials) then
      local mats = {}
      for mat, cnt in pairs(c.raw_materials) do
        mats[#mats+1] = { name = mat, count = cnt }
      end
      table.sort(mats, function(a, b) return (a.count or 0) > (b.count or 0) end)

      local parts = {}
      local max_mats = 12
      for i = 1, math.min(#mats, max_mats) do
        local m = mats[i]
        parts[#parts+1] = string.format("%s=%.1f", tostring(m.name), tonumber(m.count) or 0)
      end
      mats_str = table.concat(parts, ",")
      if #mats > max_mats then
        mats_str = mats_str .. string.format(",...(+%d)", #mats - max_mats)
      end
    end

    id = id + 1
    lines[#lines+1] = string.format("%d;%s;%.1f;%.3f;%s",
    id, name, time_s, energy_kwh, mats_str)
  end

  return table.concat(lines, "\n")
end





-- Format unit costs as semicolon table for MASTERDATA (blueprint + produced + portfolio)
function ItemCost.format_masterdata_unit_costs(unit_costs)
  local lines = {}
  lines[#lines+1] = "# ----"
  lines[#lines+1] = "# MASTERDATA_UNIT_COSTS (amount=1)"
  lines[#lines+1] = "id;item;time_s;energy_kWh;materials"

  if not unit_costs or next(unit_costs) == nil then
    lines[#lines+1] = "NONE;0;0;"
    return table.concat(lines, "\n")
  end

  local names = {}
  for name, _ in pairs(unit_costs) do names[#names+1] = name end
  table.sort(names)

  local id = 0
  for _, name in ipairs(names) do
    local c = unit_costs[name] or {}
    local time_s = tonumber(c.total_time or 0) or 0
    local energy_kwh = (tonumber(c.total_energy or 0) or 0) / 3600000

    local mats_str = ""
    if c.raw_materials and next(c.raw_materials) then
      local mats = {}
      for mat, cnt in pairs(c.raw_materials) do
        mats[#mats+1] = { name = mat, count = cnt }
      end
      table.sort(mats, function(a, b) return (a.count or 0) > (b.count or 0) end)

      local parts = {}
      local max_mats = 12
      for i = 1, math.min(#mats, max_mats) do
        local m = mats[i]
        parts[#parts+1] = string.format("%s=%.1f", tostring(m.name), tonumber(m.count) or 0)
      end
      mats_str = table.concat(parts, ",")
      if #mats > max_mats then
        mats_str = mats_str .. string.format(",...(+%d)", #mats - max_mats)
      end
    end

    id = id + 1
    lines[#lines+1] = string.format("%d;%s;%.1f;%.3f;%s",
      id, name, time_s, energy_kwh, mats_str)
  end

  return table.concat(lines, "\n")
end

-- Find an enabled recipe that produces item_name (same idea as calculate_item_cost)
local function find_recipe_for_item(item_name, force)
  force = force or game.forces.player

  for recipe_name, recipe_proto in pairs(prototypes.recipe) do
    local r = force.recipes[recipe_name]
    if r and r.enabled then
      if recipe_proto.main_product and recipe_proto.main_product.name == item_name then
        return recipe_proto
      end
      for _, product in pairs(recipe_proto.products or {}) do
        if product and product.name == item_name then
          return recipe_proto
        end
      end
    end
  end
  return nil
end

-- Collect full dependency closure (all intermediates + terminals), by ingredient graph.
-- This does NOT collapse into raw_materials; it keeps everything that appears on the path.
function ItemCost.collect_dependency_items(item_name, out_set, force, depth, visited)
  out_set = out_set or {}
  force = force or game.forces.player
  depth = depth or 0
  visited = visited or {}

  if not item_name or item_name == "" then return out_set end
  if visited[item_name] then return out_set end
  visited[item_name] = true

  if depth > M.COLLECT_DEPENDENC_DEPTH then return out_set end

  local recipe = find_recipe_for_item(item_name, force)
  if not recipe or not recipe.ingredients then
    return out_set
  end

  for _, ing in pairs(recipe.ingredients) do
    local ing_name = ing and ing.name
    if ing_name and ing_name ~= "" then
      out_set[ing_name] = true
      ItemCost.collect_dependency_items(ing_name, out_set, force, depth + 1, visited)
    end
  end

  return out_set
end

-- Expand a whole seed set into full closure up to terminals.
function ItemCost.expand_item_set_full(seed_set, force)
  force = force or game.forces.player
  local out = {}

  if not seed_set then return out end

  -- keep seeds
  for name, _ in pairs(seed_set) do
    if name and name ~= "" then out[name] = true end
  end

  -- expand all seeds
  for name, _ in pairs(seed_set) do
    if name and name ~= "" then
      local deps = ItemCost.collect_dependency_items(name, {}, force)
      for dep, _ in pairs(deps) do
        out[dep] = true
      end
    end
  end

  return out
end

return ItemCost
