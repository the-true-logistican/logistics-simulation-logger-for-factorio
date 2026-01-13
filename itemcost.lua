-- =========================================
-- LogSim (Factorio 2.0) 
-- Item Cost Calculator Module
--
-- Calculates comprehensive costs for items:
-- - Area (from selection_box)
-- - Raw materials (recursive recipe resolution)
-- - Time value (crafting time chain)
-- - Energy cost (time × machine power)
-- Version 0.6.0
-- Version 0.6.1 - Localized CSV headers (cached on first use) inopertional
-- Vertion 0.6.3 - Cost of all items in the factory
-- =========================================

local ItemCost = {}
 ItemCost.version = "0.6.3"

-- Cache for calculated costs to avoid recalculation
local cost_cache = {}

-- CSV Header cache - initialized on first use with player locale
local csv_header_cache = nil

-- Standard machine power consumption (Watts)
local MACHINE_POWER = {
  ["assembling-machine-1"] = 75000,    -- 75 kW
  ["assembling-machine-2"] = 150000,   -- 150 kW
  ["assembling-machine-3"] = 375000,   -- 375 kW
  ["electric-furnace"] = 180000,       -- 180 kW
  ["chemical-plant"] = 210000,         -- 210 kW
}

local DEFAULT_MACHINE_POWER = MACHINE_POWER["assembling-machine-3"]

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
  if not recipe_proto then return DEFAULT_MACHINE_POWER end
  
  local category = recipe_proto.category
  
  if category == "smelting" then
    return MACHINE_POWER["electric-furnace"]
  elseif category == "chemistry" then
    return MACHINE_POWER["chemical-plant"]
  else
    return DEFAULT_MACHINE_POWER
  end
end

-- =========================================
-- Recursive Material Resolution
-- =========================================

local function resolve_item_recursive(item_name, amount, force, depth, visited)
  depth = depth or 0
  visited = visited or {}
  amount = amount or 1
  
  local cache_key = item_name
  if cost_cache[cache_key] and depth == 0 then
    local cached = cost_cache[cache_key]
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
  
  if depth > 20 then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  if visited[item_name] then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  if RAW_MATERIALS[item_name] then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  local recipe = get_recipe_for_item(item_name, force)
  if not recipe then
    return {
      raw_materials = { [item_name] = amount },
      total_time = 0,
      total_energy = 0,
    }
  end
  
  local recipe_output = 1
  for _, product in pairs(recipe.products) do
    if product.name == item_name then
      recipe_output = product.amount or 1
      break
    end
  end
  
  local craft_count = math.ceil(amount / recipe_output)
  
  local crafting_time = get_crafting_time(recipe)
  local machine_power = get_machine_power_for_recipe(recipe)
  local recipe_time = crafting_time * craft_count
  local recipe_energy = recipe_time * machine_power
  
  local new_visited = {}
  for k, v in pairs(visited) do new_visited[k] = v end
  new_visited[item_name] = true
  
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
  
  if depth == 0 and amount == 1 then
    cost_cache[cache_key] = {
      raw_materials = {},
      total_time = total_time,
      total_energy = total_energy,
    }
    for mat, count in pairs(total_raw) do
      cost_cache[cache_key].raw_materials[mat] = count
    end
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



return ItemCost
