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
-- Version 0.6.1 - Localized CSV headers (cached on first use)
-- =========================================

local ItemCost = {}

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

return ItemCost
