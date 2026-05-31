-- =========================================
-- LogSim (Factorio 2.0)
-- Blueprint Module
--
-- Extracts item counts, costs, footprint data and report tabs from blueprints
-- and blueprint books.
--
-- Version 0.8.0 first complete working version
-- Version 0.8.1 UI front tick handler
-- Version 0.8.2 factory statistics report
-- Version 0.8.3 EMA report integration
-- Version 0.8.4 blueprint-book compatibility and report tabs
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 system report uses storage.current_daytime_text
-- Version 0.9.2 registered roboport robots counted as infrastructure
-- Version 0.9.3 local cleanup and shared extraction helpers
--
-- =========================================

local UI       = require("ui")
local ItemCost = require("itemcost")
local Chests   = require("chests")
local EMA      = require("ema")

local Blueprint = {}
Blueprint.version = "0.9.3"

local bp_session = {
  sidecar_visible = {},
  last = {}
}

local STATS_WINDOWS = {
  {
    title = "# STATISTICS_10MIN (precision=10min)",
    precision = defines.flow_precision_index.ten_minutes
  },
  {
    title = "# STATISTICS_1H (precision=1h)",
    precision = defines.flow_precision_index.one_hour
  }
}

-- =========================================
-- Safe logging and output
-- =========================================

local function safe_log(msg)
  if msg then
    log("[LogSim Blueprint] " .. tostring(msg))
  end
end

local function safe_print(player, msg_key, ...)
  if not (player and player.valid) then return end

  local payload
  if type(msg_key) == "table" then
    payload = msg_key
  else
    payload = { msg_key, ... }
  end

  local ok = pcall(player.print, player, payload)
  if not ok then
    player.print("[LogSim] Error displaying message")
  end
end

local function safe_call(label, fn)
  local ok, result1, result2, result3 = pcall(fn)
  if ok then
    return true, result1, result2, result3
  end

  safe_log(label .. " failed - " .. tostring(result1))
  return false, result1, result2, result3
end

-- =========================================
-- Generic helpers
-- =========================================

local function add_set(set, name)
  if not name or name == "" then return end
  set[name] = true
end

local function add_table_counts(dst, src)
  for name, amount in pairs(src or {}) do
    Blueprint.inv_add(dst, name, amount)
  end
end

local function merge_set(dst, src)
  for name, flag in pairs(src or {}) do
    if flag then
      dst[name] = true
    end
  end
end

local function normalize_amount(amount)
  if amount == nil then return 1 end

  local amount_type = type(amount)

  if amount_type == "number" then
    return amount
  end

  if amount_type == "boolean" then
    return amount and 1 or 0
  end

  if amount_type == "string" then
    return tonumber(amount) or 0
  end

  if amount_type == "table" then
    if type(amount.count) == "number" then
      return amount.count
    end
    if type(amount.amount) == "number" then
      return amount.amount
    end
  end

  return 0
end

function Blueprint.inv_add(dst, name, amount)
  if not name then return end

  amount = normalize_amount(amount)
  if amount == 0 then return end

  dst[name] = (dst[name] or 0) + amount
end

-- =========================================
-- Stack validation
-- =========================================

local function stack_valid_for_read(stack)
  if not stack then return false end

  local ok, valid = pcall(function()
    return stack.valid_for_read
  end)

  return ok and valid == true
end

local function stack_is_blueprint(stack)
  if not stack_valid_for_read(stack) then return false end

  local ok, is_blueprint = pcall(function()
    return stack.is_blueprint
  end)

  return ok and is_blueprint == true
end

local function stack_is_blueprint_book(stack)
  if not stack_valid_for_read(stack) then return false end

  local ok, is_book = pcall(function()
    return stack.is_blueprint_book
  end)

  return ok and is_book == true
end

local function stack_is_setup(stack)
  if not stack_valid_for_read(stack) then return false end

  local ok, is_setup = pcall(function()
    return stack.is_blueprint_setup()
  end)

  return ok and is_setup == true
end

-- =========================================
-- Blueprint item extraction helpers
-- =========================================

local function add_recipe_products(produced, recipe_name)
  if not recipe_name then return end

  local ok, recipe_proto = pcall(function()
    return prototypes.recipe[recipe_name]
  end)

  if not (ok and recipe_proto and recipe_proto.products) then return end

  for _, product in pairs(recipe_proto.products) do
    if product and product.name then
      add_set(produced, product.name)
    end
  end
end

local function count_insert_plan(plan)
  if type(plan) ~= "table" then return 0 end

  local count = 0
  local items = plan.items

  if type(items) == "table" then
    if type(items.grid_count) == "number" then
      count = count + items.grid_count
    end

    if type(items.in_inventory) == "table" then
      for _, pos in pairs(items.in_inventory) do
        count = count + (type(pos) == "table" and (pos.count or 1) or 1)
      end
    end
  end

  return count
end

local function add_blueprint_entity_items(counts, entity)
  if not entity.items then return end

  if type(entity.items) == "table" and #entity.items > 0 then
    for _, item in pairs(entity.items) do
      if type(item) == "table" then
        if item.id and item.id.name then
          local count = count_insert_plan(item)
          if count == 0 then count = 1 end
          Blueprint.inv_add(counts, item.id.name, count)
        elseif item.name then
          Blueprint.inv_add(counts, item.name, item.count or item.amount or 1)
        end
      end
    end
    return
  end

  for item_name, quantity in pairs(entity.items) do
    Blueprint.inv_add(counts, item_name, quantity)
  end
end

-- =========================================
-- Footprint helpers
-- =========================================

local function new_bounds()
  return {
    min_x = math.huge,
    min_y = math.huge,
    max_x = -math.huge,
    max_y = -math.huge,
    any = false
  }
end

local function update_bounds_from_entity(bounds, entity)
  if not entity then return end

  local ok, proto = pcall(function()
    return prototypes.entity[entity.name]
  end)

  if not (ok and proto and proto.selection_box) then return end

  local box = proto.selection_box
  local left_top = box.left_top
  local right_bottom = box.right_bottom

  local raw_w = math.abs(right_bottom.x - left_top.x)
  local raw_h = math.abs(right_bottom.y - left_top.y)

  -- Sideways directions swap width and height.
  local direction = entity.direction or 0
  if (direction % 4) == 2 then
    raw_w, raw_h = raw_h, raw_w
  end

  -- Round to whole tiles so small entities still consume one layout cell.
  local width = math.ceil(raw_w)
  local height = math.ceil(raw_h)

  local px = entity.position and entity.position.x or 0
  local py = entity.position and entity.position.y or 0

  local left = px - width / 2
  local right = px + width / 2
  local top = py - height / 2
  local bottom = py + height / 2

  if left < bounds.min_x then bounds.min_x = left end
  if top < bounds.min_y then bounds.min_y = top end
  if right > bounds.max_x then bounds.max_x = right end
  if bottom > bounds.max_y then bounds.max_y = bottom end

  bounds.any = true
end

local function build_footprint(bounds)
  if not bounds.any then return nil end

  local gross_w = math.ceil(bounds.max_x) - math.floor(bounds.min_x)
  local gross_h = math.ceil(bounds.max_y) - math.floor(bounds.min_y)

  return {
    gross_w = math.max(0, gross_w),
    gross_h = math.max(0, gross_h),
    gross_area = math.max(0, gross_w * gross_h)
  }
end

-- =========================================
-- Blueprint extraction
-- =========================================

function Blueprint.extract_counts_from_blueprint(stack)
  local counts = {}
  local produced = {}

  if not stack then
    safe_log("extract_counts: stack is nil")
    return counts
  end

  if not stack_valid_for_read(stack) then
    safe_log("extract_counts: stack not valid_for_read")
    return counts
  end

  if not stack_is_blueprint(stack) then
    safe_log("extract_counts: stack is not a blueprint")
    return counts
  end

  if not stack_is_setup(stack) then
    safe_log("extract_counts: blueprint not setup")
    return counts
  end

  local ok_entities, entities = safe_call("extract_counts: get_blueprint_entities", function()
    return stack.get_blueprint_entities()
  end)

  if not (ok_entities and entities) then
    return counts
  end

  local bounds = new_bounds()

  for _, entity in pairs(entities) do
    local ok = pcall(function()
      update_bounds_from_entity(bounds, entity)
      Blueprint.inv_add(counts, entity.name, 1)
      add_recipe_products(produced, entity.recipe)
      add_blueprint_entity_items(counts, entity)
    end)

    if not ok then
      safe_log("extract_counts: error processing entity " .. tostring(entity and entity.name))
    end
  end

  if stack.get_blueprint_tiles then
    local ok_tiles, tiles = safe_call("extract_counts: get_blueprint_tiles", function()
      return stack.get_blueprint_tiles()
    end)

    if ok_tiles and tiles then
      for _, tile in pairs(tiles) do
        local ok = pcall(function()
          Blueprint.inv_add(counts, "tile:" .. tile.name, 1)
        end)

        if not ok then
          safe_log("extract_counts: error processing tile " .. tostring(tile and tile.name))
        end
      end
    end
  end

  return counts, build_footprint(bounds), produced
end

function Blueprint.extract_counts_from_book(book_stack)
  local counts = {}
  local produced = {}
  local footprint = nil

  if not book_stack then
    safe_log("extract_book: book_stack is nil")
    return counts, footprint, produced
  end

  if not stack_valid_for_read(book_stack) then
    safe_log("extract_book: book not valid_for_read")
    return counts, footprint, produced
  end

  if not stack_is_blueprint_book(book_stack) then
    safe_log("extract_book: not a blueprint book")
    return counts, footprint, produced
  end

  local ok_inventory, inventory = safe_call("extract_book: get_inventory", function()
    return book_stack.get_inventory(defines.inventory.item_main)
  end)

  if not (ok_inventory and inventory) then
    return counts, footprint, produced
  end

  for i = 1, #inventory do
    local ok_stack, stack = pcall(function()
      return inventory[i]
    end)

    if ok_stack and stack and stack_is_blueprint(stack) and stack_is_setup(stack) then
      local ok_extract, child_counts, _child_footprint, child_produced = pcall(function()
        return Blueprint.extract_counts_from_blueprint(stack)
      end)

      if ok_extract and child_counts then
        add_table_counts(counts, child_counts)
        merge_set(produced, child_produced)
      else
        safe_log("extract_book: error extracting blueprint " .. tostring(i) .. " - " .. tostring(child_counts))
      end
    end
  end

  -- A blueprint book has no single meaningful footprint because contained
  -- blueprints do not share one coordinate system.
  return counts, footprint, produced
end

-- =========================================
-- UI front-order helper
-- =========================================

function Blueprint.ui_front_tick_handler()
  if not storage or not storage._ui_front_tick then return end

  for player_index, tick in pairs(storage._ui_front_tick) do
    if tick and game.tick >= tick then
      local player = game.get_player(player_index)
      if player then
        UI.bring_inventory_overlay_to_front(player)
      end
      storage._ui_front_tick[player_index] = nil
    end
  end
end

-- =========================================
-- Report builders
-- =========================================

local function build_assets_text(costs, player)
  local ok, fixed_text = pcall(function()
    return ItemCost.format_detailed_breakdown(costs, player)
  end)

  if ok then
    return fixed_text or "", true
  end

  safe_log("build_assets_text: format failed - " .. tostring(fixed_text))
  return "# FIXED ASSETS ERROR: " .. tostring(fixed_text), false
end

local function is_valid_report_item_key(name)
  if type(name) ~= "string" then return false end
  if name:sub(1, 5) == "tile:" then return false end
  if prototypes.item and prototypes.item[name] then return true end
  if prototypes.fluid and prototypes.fluid[name] then return true end

  return false
end

local function add_valid_items_to_set(target, source)
  for name, _ in pairs(source or {}) do
    if is_valid_report_item_key(name) then
      target[name] = true
    end
  end
end

local function build_costs_text(counts, produced, player)
  local master_set = {}

  add_valid_items_to_set(master_set, counts)
  add_valid_items_to_set(master_set, produced)

  local ok_portfolio, portfolio_set = pcall(function()
    return ItemCost.collect_portfolio_items(storage, Chests.resolve_entity, player.force)
  end)

  if ok_portfolio and portfolio_set then
    add_valid_items_to_set(master_set, portfolio_set)
  else
    safe_log("build_costs_text: collect_portfolio_items failed - " .. tostring(portfolio_set))
  end

  local ok_expanded, expanded = pcall(function()
    return ItemCost.expand_item_set_full(master_set, player.force)
  end)

  if not ok_expanded or not expanded then
    safe_log("build_costs_text: expand_item_set_full failed - " .. tostring(expanded))
    return "# ITEM/COSTS ERROR: " .. tostring(expanded)
  end

  if next(expanded) == nil then
    return "# ITEM/COSTS: no valid item data"
  end

  local ok_unit_costs, unit_costs = pcall(function()
    return ItemCost.calculate_unit_costs(expanded, player.force)
  end)

  if not ok_unit_costs or not unit_costs then
    safe_log("build_costs_text: calculate_unit_costs failed - " .. tostring(unit_costs))
    return "# ITEM/COSTS ERROR: " .. tostring(unit_costs)
  end

  local ok_format, output = pcall(function()
    return ItemCost.format_masterdata_unit_costs(unit_costs)
  end)

  if ok_format and output then
    return output
  end

  safe_log("build_costs_text: format_masterdata_unit_costs failed - " .. tostring(output))
  return "# ITEM/COSTS ERROR: " .. tostring(output)
end

local function append_system_scenario(lines)
  local ok_level, level = pcall(function()
    return script.level
  end)

  if not (ok_level and level) then
    lines[#lines + 1] = "# scenario=NA"
    return
  end

  local scenario_name = tostring(level.level_name or "unknown")
  local campaign_name = tostring(level.campaign_name or "")
  local mod_name = tostring(level.mod_name or "base")

  if campaign_name ~= "" then
    lines[#lines + 1] = "# scenario=" .. scenario_name .. "  campaign=" .. campaign_name .. "  provided_by=" .. mod_name
  else
    lines[#lines + 1] = "# scenario=" .. scenario_name .. "  provided_by=" .. mod_name
  end
end

local function append_active_mods(lines)
  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = "# ACTIVE_MODS"
  lines[#lines + 1] = "# id;mod_name;version"

  local ok_mods, mods = pcall(function()
    return script.active_mods
  end)

  if not (ok_mods and mods) then
    lines[#lines + 1] = "NA"
    return
  end

  local mod_list = {}
  for name, version in pairs(mods) do
    mod_list[#mod_list + 1] = {
      name = name,
      version = tostring(version)
    }
  end

  table.sort(mod_list, function(a, b)
    return a.name < b.name
  end)

  for i, entry in ipairs(mod_list) do
    lines[#lines + 1] = string.format("%d;%s;%s", i, entry.name, entry.version)
  end
end

local function build_system_text(player)
  local lines = {}

  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = "# SYSTEM/MODS (tick=" .. tostring(game.tick) .. ")"
  lines[#lines + 1] = "# factorio_time=" .. tostring(storage.current_daytime_text or "NA")

  append_system_scenario(lines)

  local run_name = (storage and storage.run_name) or ""
  lines[#lines + 1] = "# run_name=" .. (run_name ~= "" and run_name or "(not set)")

  if player and player.valid then
    lines[#lines + 1] = "# player=" .. tostring(player.name)
    lines[#lines + 1] = "# surface=" .. tostring(player.surface and player.surface.name or "NA")
    lines[#lines + 1] = "# force=" .. tostring(player.force and player.force.name or "NA")
  end

  append_active_mods(lines)

  return table.concat(lines, "\n")
end

-- =========================================
-- Statistics report
-- =========================================

local function safe_stats_flow(stats, name, category, precision)
  local ok, value = pcall(function()
    return stats.get_flow_count{
      name = name,
      category = category,
      precision_index = precision
    }
  end)

  return (ok and value) and value or 0
end

local function read_stats_flows(stats, precision)
  if not stats then return {} end

  local result = {}

  for name, _ in pairs(stats.input_counts or {}) do
    local value = safe_stats_flow(stats, name, "input", precision)
    result[name] = result[name] or { produced = 0, consumed = 0 }
    result[name].produced = value
  end

  for name, _ in pairs(stats.output_counts or {}) do
    local value = safe_stats_flow(stats, name, "output", precision)
    result[name] = result[name] or { produced = 0, consumed = 0 }
    result[name].consumed = value
  end

  return result
end

local function sorted_stats_pairs(tbl)
  local keys = {}

  for key in pairs(tbl or {}) do
    keys[#keys + 1] = key
  end

  table.sort(keys)

  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], tbl[keys[i]]
    end
  end
end

local function append_flow_rows(lines, category, stats_table)
  for name, value in sorted_stats_pairs(stats_table) do
    lines[#lines + 1] = string.format(
      "%s;%s;%.1f;%.1f;%.1f",
      category,
      name,
      value.produced,
      value.consumed,
      value.produced - value.consumed
    )
  end
end

local function append_stats_block(lines, surface, force, precision, title)
  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = title
  lines[#lines + 1] = "# category;name;produced;consumed;delta"

  if surface and surface.valid and surface.pollution_statistics then
    local pollution_data = read_stats_flows(surface.pollution_statistics, precision)
    local pollution_produced = 0.0
    local pollution_consumed = 0.0

    for _, value in pairs(pollution_data) do
      pollution_produced = pollution_produced + (value.produced or 0)
      pollution_consumed = pollution_consumed + (value.consumed or 0)
    end

    lines[#lines + 1] = string.format(
      "POLLUTION;;%.2f;%.2f;%.2f",
      pollution_produced,
      pollution_consumed,
      pollution_produced - pollution_consumed
    )
  end

  if force and force.valid and surface and surface.valid then
    local ok_items, item_stats = pcall(function()
      return force.get_item_production_statistics(surface)
    end)

    if ok_items and item_stats then
      append_flow_rows(lines, "ITEM", read_stats_flows(item_stats, precision))
    end
  end

  if force and force.valid and surface and surface.valid then
    local ok_fluids, fluid_stats = pcall(function()
      return force.get_fluid_production_statistics(surface)
    end)

    if ok_fluids and fluid_stats then
      append_flow_rows(lines, "FLUID", read_stats_flows(fluid_stats, precision))
    end
  end
end

local function build_stats_text(player)
  local lines = {}

  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = "# STATISTICS (tick=" .. tostring(game.tick) .. ")"

  if not (player and player.valid and player.surface and player.surface.valid) then
    lines[#lines + 1] = "# (no valid player/surface)"
    return table.concat(lines, "\n")
  end

  for _, window in ipairs(STATS_WINDOWS) do
    append_stats_block(lines, player.surface, player.force, window.precision, window.title)
  end

  return table.concat(lines, "\n")
end

-- =========================================
-- Working-capital report
-- =========================================

local function build_working_capital_text(player)
  local ok_ema, result_ema = pcall(function()
    return EMA.format_display(game.tick, player.surface)
  end)

  local ema_count = 0
  if storage.ema then
    for key, _ in pairs(storage.ema) do
      if type(key) == "string" and key:sub(1, 1) ~= "_" then
        ema_count = ema_count + 1
      end
    end
  end

  safe_log(string.format(
    "EMA diag: ok=%s entries=%d last_tick=%s",
    tostring(ok_ema),
    ema_count,
    tostring(storage.ema and storage.ema._last_tick or "nil")
  ))

  if ok_ema and result_ema and result_ema ~= "" then
    return result_ema
  end

  if not ok_ema then
    safe_log("build_working_capital_text: EMA.format_display failed - " .. tostring(result_ema))
    return "# EMA ERROR: " .. tostring(result_ema)
  end

  return "# EMA: (no data yet - waiting for first sample tick)"
end

-- =========================================
-- Live robot infrastructure add-on
-- =========================================

local function normalize_inventory_content(k, v)
  local item_name
  local count = 0

  -- Factorio 2.x inventory contents normally use array entries.
  if type(k) == "number" and type(v) == "table" then
    item_name = v.name or v.item
    count = tonumber(v.count or v.amount) or 0
  elseif type(k) == "string" then
    item_name = k
    if type(v) == "number" then
      count = v
    elseif type(v) == "table" then
      count = tonumber(v.count or v.amount) or 0
    end
  elseif type(k) == "table" then
    item_name = k.name or k.item
    if type(v) == "number" then
      count = v
    elseif type(v) == "table" then
      count = tonumber(v.count or v.amount) or 0
    end
  end

  return item_name, tonumber(count) or 0
end

local function count_inventory_items(inv, out)
  if not (inv and inv.valid and out) then return end

  local ok, contents = pcall(function()
    return inv.get_contents()
  end)

  if not (ok and contents) then return end

  for k, v in pairs(contents) do
    local item_name, count = normalize_inventory_content(k, v)
    if item_name and count > 0 then
      out[item_name] = (out[item_name] or 0) + count
    end
  end
end

local function add_registered_roboport_robot_assets(player, counts)
  if not (player and player.valid and counts) then return 0 end
  if not storage.roboports then return 0 end

  local added = 0

  for _, rec in pairs(storage.roboports) do
    if (not rec.surface_index) or (player.surface and rec.surface_index == player.surface.index) then
      local ent = Chests.resolve_entity(rec)

      if ent and ent.valid and ent.type == "roboport" then
        if (not player.force) or (not ent.force) or ent.force == player.force then
          local inventory_counts = {}
          local ok_inventory, robot_inventory = pcall(function()
            return ent.get_inventory(defines.inventory.roboport_robot)
          end)

          if ok_inventory then
            count_inventory_items(robot_inventory, inventory_counts)
          end

          for name, count in pairs(inventory_counts) do
            if name == "construction-robot" or name == "logistic-robot" then
              Blueprint.inv_add(counts, name, count)
              added = added + count
            end
          end
        end
      end
    end
  end

  return added
end

local function add_flying_robot_assets(player, counts)
  if not (player and player.valid and player.surface and player.surface.valid and counts) then
    return 0
  end

  local added = 0
  local robots = player.surface.find_entities_filtered{
    force = player.force,
    type = { "construction-robot", "logistic-robot" }
  }

  for _, ent in pairs(robots or {}) do
    if ent and ent.valid then
      Blueprint.inv_add(counts, ent.name, 1)
      added = added + 1
    end
  end

  return added
end

function Blueprint.add_live_robot_assets(player, counts)
  local stored = add_registered_roboport_robot_assets(player, counts)
  local flying = add_flying_robot_assets(player, counts)

  safe_log(string.format(
    "robot assets added: stored=%d flying=%d",
    tonumber(stored) or 0,
    tonumber(flying) or 0
  ))

  return stored + flying
end

-- =========================================
-- GUI event handlers
-- =========================================

function Blueprint.on_gui_opened(event)
  if event.gui_type ~= defines.gui_type.item then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local item = event.item
  if not stack_valid_for_read(item) then return end

  if item.is_blueprint or item.is_blueprint_book then
    bp_session.sidecar_visible[event.player_index] = true
    UI.show_blueprint_sidecar(player)
    UI.bring_inventory_overlay_to_front(player)

    storage._ui_front_tick = storage._ui_front_tick or {}
    storage._ui_front_tick[player.index] = game.tick + 1
  end
end

local function get_current_blueprint_stack(player)
  if player.opened_gui_type == defines.gui_type.item then
    local ok, opened = pcall(function()
      return player.opened
    end)

    if ok and stack_valid_for_read(opened) then
      if opened.is_blueprint or opened.is_blueprint_book then
        return opened
      end
    end
  end

  local ok_cursor, cursor = pcall(function()
    return player.cursor_stack
  end)

  if ok_cursor and stack_valid_for_read(cursor) then
    if cursor.is_blueprint or cursor.is_blueprint_book then
      return cursor
    end
  end

  return nil
end

function Blueprint.click_bp_extract(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local stack = get_current_blueprint_stack(player)
  if not stack then
    safe_print(player, "logistics_simulation.bp_no_blueprint")
    return
  end

  if not stack_is_setup(stack) then
    safe_print(player, "logistics_simulation.bp_no_blueprint")
    return
  end

  local ok_extract, counts, footprint, produced = pcall(function()
    if stack.is_blueprint_book then
      return Blueprint.extract_counts_from_book(stack)
    end

    return Blueprint.extract_counts_from_blueprint(stack)
  end)

  if not ok_extract then
    safe_print(player, "logistics_simulation.bp_extraction_failed")
    safe_log("click_bp_extract: extraction failed - " .. tostring(counts))
    return
  end

  counts = counts or {}
  produced = produced or {}

  Blueprint.add_live_robot_assets(player, counts)

  if table_size(counts) == 0 then
    safe_print(player, "logistics_simulation.bp_empty")
    return
  end

  safe_print(player, "logistics_simulation.bp_extracted", table_size(counts))

  local ok_costs, costs = pcall(function()
    return ItemCost.calculate_blueprint_cost(counts, player.force)
  end)

  if not ok_costs or not costs then
    safe_print(player, "logistics_simulation.bp_cost_calculation_failed")
    safe_log("click_bp_extract: cost calculation failed - " .. tostring(costs))
    return
  end

  costs.footprint = footprint

  local assets_text, assets_ok = build_assets_text(costs, player)
  if not assets_ok then
    safe_print(player, "logistics_simulation.bp_format_failed")
    return
  end

  local report_tabs = {
    assets = assets_text or "",
    costs = build_costs_text(counts, produced, player),
    system = build_system_text(player),
    stats = build_stats_text(player),
    working_capital = build_working_capital_text(player)
  }

  UI.show_inventory_window(player, report_tabs)

  bp_session.last[event.player_index] = {
    tick = game.tick,
    label = stack.label or "Unnamed",
    counts = counts,
    costs = costs,
    report_tabs = report_tabs
  }
end

function Blueprint.tick_cleanup_sidecars()
  for player_index, _ in pairs(bp_session.sidecar_visible) do
    local player = game.get_player(player_index)

    if not player or player.opened_gui_type ~= defines.gui_type.item then
      if player then
        UI.hide_blueprint_sidecar(player)
        UI.close_inventory_window(player)
      end

      bp_session.sidecar_visible[player_index] = nil
    end
  end
end

-- =========================================
-- Session cleanup
-- =========================================

function Blueprint.cleanup_session(player_index)
  bp_session.sidecar_visible[player_index] = nil
  bp_session.last[player_index] = nil
end

function Blueprint.cleanup_all_disconnected()
  local connected = {}

  for _, player in pairs(game.connected_players) do
    connected[player.index] = true
  end

  for player_index, _ in pairs(bp_session.sidecar_visible) do
    if not connected[player_index] then
      bp_session.sidecar_visible[player_index] = nil
    end
  end

  for player_index, _ in pairs(bp_session.last) do
    if not connected[player_index] then
      bp_session.last[player_index] = nil
    end
  end
end

return Blueprint
