-- =========================================
-- LogSim (Factorio 2.0) 
-- Extracts item counts, costs and footprint data from blueprints and blueprint books.
--
-- version 0.8.0 first complete working version
-- version 0.8.1 Blueprint.ui_front_tick_handler()
-- version 0.8.2 factory stats block (Teil 3): scenario, mods, power, pollution
-- version 0.8.3 EMA Module – Exponential Moving Average über Bestände
-- version 0.8.4 extract from blueprint with tabs
--               compatibility extract from bleuprintbook
-- Version 0.9.0 Stable Ledger Operational Baseline 
--
-- =========================================

local UI = require("ui")
local ItemCost = require("itemcost")
local Chests = require("chests")
local SimLog = require("simlog")
local EMA = require("ema")


local Blueprint = {}
  Blueprint.version = "0.9.0"

-- Session storage (not persistent)
local bp_session = {
  sidecar_visible = {}, -- [player_index] = true
  last = {}             -- [player_index] = { tick=..., label=..., counts=..., costs=... }
}

-- =========================================
-- ERROR HANDLING & LOGGING
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

  local ok, err = pcall(player.print, player, payload)
  if not ok then
    player.print("[LogSim] Error displaying message")
  end
  
end

-- =========================================
-- HELPER FUNCTIONS
-- =========================================

-- Hilfsfunktion zum Hinzufügen von Items zur Zählung
function Blueprint.inv_add(dst, name, amount)
  if not name then return end

  if amount == nil then amount = 1 end

  local t = type(amount)
  if t == "number" then
    -- ok
  elseif t == "boolean" then
    amount = amount and 1 or 0
  elseif t == "string" then
    local n = tonumber(amount)
    amount = n or 0
  elseif t == "table" then
    if type(amount.count) == "number" then
      amount = amount.count
    elseif type(amount.amount) == "number" then
      amount = amount.amount
    else
      amount = 0
    end
  else
    amount = 0
  end

  if amount == 0 then return end
  dst[name] = (dst[name] or 0) + amount
end

-- =========================================
-- BLUEPRINT EXTRACTION (Error-Safe)
-- =========================================

-- Extrahiert Entities, Tiles und berechnet Footprint
function Blueprint.extract_counts_from_blueprint(stack)
  local counts = {}

  -- MASTERDATA: items produced by blueprint machine recipes
  local produced = {} -- set: [name]=true
  local function add_prod(name)
    if not name or name == '' then return end
    produced[name] = true
  end

  -- Guard: Check stack validity
  if not stack then
    safe_log("extract_counts: stack is nil")
    return counts
  end

  local ok, is_valid = pcall(function() return stack.valid_for_read end)
  if not ok or not is_valid then
    safe_log("extract_counts: stack not valid_for_read")
    return counts
  end

  local ok2, is_bp = pcall(function() return stack.is_blueprint end)
  if not ok2 or not is_bp then
    safe_log("extract_counts: stack is not a blueprint")
    return counts
  end

  local ok3, is_setup = pcall(function() return stack.is_blueprint_setup() end)
  if not ok3 or not is_setup then
    safe_log("extract_counts: blueprint not setup")
    return counts
  end

  -- Safe entity extraction
  local ents = {}
  local ok4, result = pcall(function()
    return stack.get_blueprint_entities()
  end)
  
  if ok4 and result then
    ents = result
  else
    safe_log("extract_counts: get_blueprint_entities failed - " .. tostring(result))
    return counts
  end

  local min_x, min_y = math.huge, math.huge
  local max_x, max_y = -math.huge, -math.huge
  local any = false

  -- immer auf ganz Einheiten!
  local function update_bounds_from_entity(e)
    if not e then return end
    
    local ok, proto = pcall(function()
      return prototypes.entity[e.name]
    end)
    
    if not ok or not proto then return end
    if not proto.selection_box then return end

    local box = proto.selection_box
    local lt = box.left_top
    local rb = box.right_bottom

    -- Die tatsächliche Breite/Höhe der Selection Box
    local raw_w = math.abs(rb.x - lt.x)
    local raw_h = math.abs(rb.y - lt.y)

    -- Rotation berücksichtigen (2 und 6 sind Seitwärts-Ausrichtungen)
    local dir = e.direction or 0
    if (dir % 4) == 2 then
      raw_w, raw_h = raw_h, raw_w
    end

    -- WICHTIG: Auf das nächste volle Rasterfeld aufrunden
    -- Ein Inserter (0.8x0.8) wird hier zu 1x1
    local w = math.ceil(raw_w)
    local h = math.ceil(raw_h)

    local px = e.position and e.position.x or 0
    local py = e.position and e.position.y or 0

    -- Zentrierung der aufgerundeten Box um die Position
    local left   = px - w/2
    local right  = px + w/2
    local top    = py - h/2
    local bottom = py + h/2

    if left < min_x then min_x = left end
    if top < min_y then min_y = top end
    if right > max_x then max_x = right end
    if bottom > max_y then max_y = bottom end
    any = true
  end

  -- Process entities with error handling
  for _, e in pairs(ents) do
    local ok = pcall(function()
      update_bounds_from_entity(e)
      Blueprint.inv_add(counts, e.name, 1)

      -- MASTERDATA: capture products from recipe configured on blueprint entities (e.g., assembling-machine)
      if e.recipe then
        local okr, rp = pcall(function() return prototypes.recipe[e.recipe] end)
        if okr and rp and rp.products then
          for _, p in pairs(rp.products) do
            if p and p.name then add_prod(p.name) end
          end
        end
      end

      if e.items then
        local function count_insert_plan(plan)
          local n = 0
          if type(plan) ~= "table" then return 0 end
          local pitems = plan.items
          if type(pitems) == "table" then
            if type(pitems.grid_count) == "number" then n = n + pitems.grid_count end
            if type(pitems.in_inventory) == "table" then
              for _, pos in pairs(pitems.in_inventory) do
                n = n + (type(pos) == "table" and (pos.count or 1) or 1)
              end
            end
          end
          return n
        end

        if type(e.items) == "table" and #e.items > 0 then
          for _, it in pairs(e.items) do
            if type(it) == "table" then
              if it.id and it.id.name then
                local c = count_insert_plan(it)
                if c == 0 then c = 1 end
                Blueprint.inv_add(counts, it.id.name, c)
              elseif it.name then
                Blueprint.inv_add(counts, it.name, it.count or it.amount or 1)
              end
            end
          end
        else
          for item_name, qty in pairs(e.items) do
            Blueprint.inv_add(counts, item_name, qty)
          end
        end
      end
    end)
    
    if not ok then
      safe_log("extract_counts: error processing entity " .. tostring(e.name))
    end
  end

  -- Safe tile extraction
  if stack.get_blueprint_tiles then
    local ok, tiles = pcall(function()
      return stack.get_blueprint_tiles()
    end)
    
    if ok and tiles then
      for _, t in pairs(tiles) do
        local ok2 = pcall(function()
          Blueprint.inv_add(counts, "tile:" .. t.name, 1)
        end)
        
        if not ok2 then
          safe_log("extract_counts: error processing tile " .. tostring(t.name))
        end
      end
    end
  end

  local footprint = nil
  if any then
    local gross_w = math.ceil(max_x) - math.floor(min_x)
    local gross_h = math.ceil(max_y) - math.floor(min_y)
    footprint = {
      gross_w = math.max(0, gross_w),
      gross_h = math.max(0, gross_h),
      gross_area = math.max(0, gross_w * gross_h)
    }
  end

  return counts, footprint, produced
end

-- Extrahiert alle Blueprints aus einem Buch
-- Rückgabe kompatibel zu extract_counts_from_blueprint:
--   counts, footprint, produced
--
-- Hinweis:
--   Für ein Blueprint-Book gibt es keinen eindeutigen gemeinsamen Footprint,
--   weil die enthaltenen Blueprints nicht in einem gemeinsamen Koordinatensystem
--   platziert sind. Deshalb bleibt footprint bewusst nil.
function Blueprint.extract_counts_from_book(book_stack)
  local counts = {}
  local produced = {}
  local footprint = nil

  -- Guard: Check book validity
  if not book_stack then
    safe_log("extract_book: book_stack is nil")
    return counts, footprint, produced
  end

  local ok, is_valid = pcall(function() return book_stack.valid_for_read end)
  if not ok or not is_valid then
    safe_log("extract_book: book not valid_for_read")
    return counts, footprint, produced
  end

  local ok2, is_book = pcall(function() return book_stack.is_blueprint_book end)
  if not ok2 or not is_book then
    safe_log("extract_book: not a blueprint book")
    return counts, footprint, produced
  end

  -- Safe inventory access
  local ok3, inv = pcall(function()
    return book_stack.get_inventory(defines.inventory.item_main)
  end)

  if not ok3 or not inv then
    safe_log("extract_book: failed to get inventory")
    return counts, footprint, produced
  end

  -- Process each blueprint in book
  for i = 1, #inv do
    local ok4, st = pcall(function() return inv[i] end)

    if ok4 and st then
      local ok5, valid = pcall(function() return st.valid_for_read end)
      local ok6, is_bp = pcall(function() return st.is_blueprint end)
      local ok7, is_setup = pcall(function() return st.is_blueprint_setup() end)

      if ok5 and valid and ok6 and is_bp and ok7 and is_setup then
        local ok8, c, _fp, prod = pcall(function()
          return Blueprint.extract_counts_from_blueprint(st)
        end)

        if ok8 and c then
          for name, amt in pairs(c) do
            Blueprint.inv_add(counts, name, amt)
          end

          for name, flag in pairs(prod or {}) do
            if flag then
              produced[name] = true
            end
          end
        else
          safe_log("extract_book: error extracting blueprint " .. i .. " - " .. tostring(c))
        end
      end
    end
  end

  return counts, footprint, produced
end




function Blueprint.ui_front_tick_handler()
  if not storage or not storage._ui_front_tick then return end
  for pidx, t in pairs(storage._ui_front_tick) do
    if t and game.tick >= t then
      local p = game.get_player(pidx)
      if p then UI.bring_inventory_overlay_to_front(p) end
      storage._ui_front_tick[pidx] = nil
    end
  end
end

-- =========================================
-- REPORT BLOCK BUILDERS
-- =========================================

local function build_assets_text(costs, player)
  local ok, fixed_txt = pcall(function()
    return ItemCost.format_detailed_breakdown(costs, player)
  end)

  if ok then
    return fixed_txt or "", true
  end

  safe_log("build_assets_text: format failed - " .. tostring(fixed_txt))
  return "# FIXED ASSETS ERROR: " .. tostring(fixed_txt), false
end

local function is_valid_report_item_key(name)
  if not name then return false end
  if type(name) ~= "string" then return false end
  if name:sub(1, 5) == "tile:" then return false end
  if prototypes.item and prototypes.item[name] then return true end
  if prototypes.fluid and prototypes.fluid[name] then return true end
  return false
end

local function build_costs_text(counts, produced, player)
  local master_set = {}

  -- 1) Blueprint fixed assets (counts keys)
  for name, _ in pairs(counts or {}) do
    if is_valid_report_item_key(name) then
      master_set[name] = true
    end
  end

  -- 2) Produced items from blueprint recipes
  for name, _ in pairs(produced or {}) do
    if is_valid_report_item_key(name) then
      master_set[name] = true
    end
  end

  -- 3) Current factory portfolio
  local okP, portfolio_set = pcall(function()
    return ItemCost.collect_portfolio_items(storage, Chests.resolve_entity, player.force)
  end)

  if okP and portfolio_set then
    for name, _ in pairs(portfolio_set) do
      if is_valid_report_item_key(name) then
        master_set[name] = true
      end
    end
  else
    safe_log("build_costs_text: collect_portfolio_items failed - " .. tostring(portfolio_set))
  end

  local okE, expanded = pcall(function()
    return ItemCost.expand_item_set_full(master_set, player.force)
  end)

  if not okE or not expanded then
    safe_log("build_costs_text: expand_item_set_full failed - " .. tostring(expanded))
    return "# ITEM/COSTS ERROR: " .. tostring(expanded)
  end

  if next(expanded) == nil then
    return "# ITEM/COSTS: no valid item data"
  end

  local okU, unit_costs = pcall(function()
    return ItemCost.calculate_unit_costs(expanded, player.force)
  end)

  if not okU or not unit_costs then
    safe_log("build_costs_text: calculate_unit_costs failed - " .. tostring(unit_costs))
    return "# ITEM/COSTS ERROR: " .. tostring(unit_costs)
  end

  local okF, out = pcall(function()
    return ItemCost.format_masterdata_unit_costs(unit_costs)
  end)

  if okF and out then
    return out
  end

  safe_log("build_costs_text: format_masterdata_unit_costs failed - " .. tostring(out))
  return "# ITEM/COSTS ERROR: " .. tostring(out)
end

local function build_system_text(player)
  local lines = {}

  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = "# SYSTEM/MODS (tick=" .. tostring(game.tick) .. ")"

  local ok_lvl, lvl = pcall(function()
    return script.level
  end)

  if ok_lvl and lvl then
    local sname = tostring(lvl.level_name or "unknown")
    local cname = tostring(lvl.campaign_name or "")
    local mname = tostring(lvl.mod_name or "base")

    if cname ~= "" then
      lines[#lines + 1] = "# scenario=" .. sname .. "  campaign=" .. cname .. "  provided_by=" .. mname
    else
      lines[#lines + 1] = "# scenario=" .. sname .. "  provided_by=" .. mname
    end
  else
    lines[#lines + 1] = "# scenario=NA"
  end

  local run_name = (storage and storage.run_name) or ""
  lines[#lines + 1] = "# run_name=" .. (run_name ~= "" and run_name or "(not set)")

  if player and player.valid then
    lines[#lines + 1] = "# player=" .. tostring(player.name)
    lines[#lines + 1] = "# surface=" .. tostring(player.surface and player.surface.name or "NA")
    lines[#lines + 1] = "# force=" .. tostring(player.force and player.force.name or "NA")
  end

  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = "# ACTIVE_MODS"
  lines[#lines + 1] = "# id;mod_name;version"

  local ok_mods, mods = pcall(function()
    return script.active_mods
  end)

  if ok_mods and mods then
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

    for i, e in ipairs(mod_list) do
      lines[#lines + 1] = string.format("%d;%s;%s", i, e.name, e.version)
    end
  else
    lines[#lines + 1] = "NA"
  end

  return table.concat(lines, "\n")
end

local function safe_stats_flow(stats, name, category, precision)
  local ok, v = pcall(function()
    return stats.get_flow_count{
      name            = name,
      category        = category,
      precision_index = precision,
    }
  end)
  return (ok and v) and v or 0
end

local function read_stats_flows(stats, precision)
  if not stats then return {} end
  local result = {}

  for name, _ in pairs(stats.input_counts or {}) do
    local v = safe_stats_flow(stats, name, "input", precision)
    if not result[name] then result[name] = { produced = 0, consumed = 0 } end
    result[name].produced = v
  end

  for name, _ in pairs(stats.output_counts or {}) do
    local v = safe_stats_flow(stats, name, "output", precision)
    if not result[name] then result[name] = { produced = 0, consumed = 0 } end
    result[name].consumed = v
  end

  return result
end

local function sorted_stats_pairs(tbl)
  local keys = {}
  for k in pairs(tbl or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  local i = 0
  return function()
    i = i + 1
    if keys[i] then return keys[i], tbl[keys[i]] end
  end
end

local function append_stats_block(lines, surface, force, precision, title)
  lines[#lines + 1] = "# ----"
  lines[#lines + 1] = title
  lines[#lines + 1] = "# category;name;produced;consumed;delta"

  -- Pollution: surface-based
  if surface and surface.valid and surface.pollution_statistics then
    local pol_data = read_stats_flows(surface.pollution_statistics, precision)
    local pol_prod, pol_cons = 0.0, 0.0
    for _, v in pairs(pol_data) do
      pol_prod = pol_prod + (v.produced or 0)
      pol_cons = pol_cons + (v.consumed or 0)
    end
    lines[#lines + 1] = string.format("POLLUTION;;%.2f;%.2f;%.2f", pol_prod, pol_cons, pol_prod - pol_cons)
  end

  -- Items: force + surface based, Factorio 2.x API
  if force and force.valid and surface and surface.valid then
    local ok_is, item_stats = pcall(function()
      return force.get_item_production_statistics(surface)
    end)
    if ok_is and item_stats then
      local items = read_stats_flows(item_stats, precision)
      for name, v in sorted_stats_pairs(items) do
        lines[#lines + 1] = string.format("ITEM;%s;%.1f;%.1f;%.1f", name, v.produced, v.consumed, v.produced - v.consumed)
      end
    end
  end

  -- Fluids: force + surface based, Factorio 2.x API
  if force and force.valid and surface and surface.valid then
    local ok_fs, fluid_stats = pcall(function()
      return force.get_fluid_production_statistics(surface)
    end)
    if ok_fs and fluid_stats then
      local fluids = read_stats_flows(fluid_stats, precision)
      for name, v in sorted_stats_pairs(fluids) do
        lines[#lines + 1] = string.format("FLUID;%s;%.1f;%.1f;%.1f", name, v.produced, v.consumed, v.produced - v.consumed)
      end
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

  append_stats_block(
    lines,
    player.surface,
    player.force,
    defines.flow_precision_index.ten_minutes,
    "# STATISTICS_10MIN (precision=10min)"
  )

  append_stats_block(
    lines,
    player.surface,
    player.force,
    defines.flow_precision_index.one_hour,
    "# STATISTICS_1H (precision=1h)"
  )

  return table.concat(lines, "\n")
end

local function build_working_capital_text(player)
  local ok_ema, result_ema = pcall(function()
    return EMA.format_display(game.tick, player.surface)
  end)

  local ema_count = 0
  if storage.ema then
    for k, _ in pairs(storage.ema) do
      if type(k) == "string" and k:sub(1, 1) ~= "_" then
        ema_count = ema_count + 1
      end
    end
  end

  safe_log(string.format("EMA diag: ok=%s entries=%d last_tick=%s",
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
-- EVENT HANDLERS
-- =========================================

function Blueprint.on_gui_opened(event)
  if event.gui_type ~= defines.gui_type.item then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local item = event.item
  if not (item and item.valid_for_read) then return end

  -- Show sidecar when blueprint or book is opened
  if item.is_blueprint or item.is_blueprint_book then
    bp_session.sidecar_visible[event.player_index] = true
    UI.show_blueprint_sidecar(player)
    UI.bring_inventory_overlay_to_front(player)
    -- extra: nochmal im nächsten Tick, damit wir den Z-Order "gewinnen"
    storage._ui_front_tick = storage._ui_front_tick or {}
    storage._ui_front_tick[player.index] = game.tick + 1
  end
  
end

function Blueprint.click_bp_extract(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local st = nil

  -- Try to get the currently opened blueprint/book
  if player.opened_gui_type == defines.gui_type.item then
    local ok, opened = pcall(function() return player.opened end)
    if ok and opened and opened.valid_for_read then
      if opened.is_blueprint or opened.is_blueprint_book then
        st = opened
      end
    end
  end

  -- Fallback: Check cursor stack
  if not st then
    local ok, cursor = pcall(function() return player.cursor_stack end)
    if ok and cursor and cursor.valid_for_read then
      if cursor.is_blueprint or cursor.is_blueprint_book then
        st = cursor
      end
    end
  end

  -- Verify we have a valid blueprint
  if not st then
    safe_print(player, "logistics_simulation.bp_no_blueprint")
    return
  end

  local ok, is_setup = pcall(function() return st.is_blueprint_setup() end)
  if not ok or not is_setup then
    safe_print(player, "logistics_simulation.bp_no_blueprint")
    return
  end

  -- Extract counts and footprint (with error handling)
  local counts, footprint, produced
  local ok2, result1, result2, result3 = pcall(function()
    if st.is_blueprint_book then
      return Blueprint.extract_counts_from_book(st)
    else
      return Blueprint.extract_counts_from_blueprint(st)
    end
  end)

  if not ok2 then
    safe_print(player, "logistics_simulation.bp_extraction_failed")
    safe_log("click_bp_extract: extraction failed - " .. tostring(result1))
    return
  end

  counts = result1
  footprint = result2
  produced = result3 or {}

  if not counts or table_size(counts) == 0 then
    safe_print(player, "logistics_simulation.bp_empty")
    return
  end

  -- Confirm extraction
  safe_print(player, "logistics_simulation.bp_extracted", table_size(counts))

  -- Calculate comprehensive costs (with error handling)
  local ok3, costs = pcall(function()
    return ItemCost.calculate_blueprint_cost(counts, player.force)
  end)

  if not ok3 or not costs then
    safe_print(player, "logistics_simulation.bp_cost_calculation_failed")
    safe_log("click_bp_extract: cost calculation failed - " .. tostring(costs))
    return
  end

  costs.footprint = footprint

  local assets_txt, assets_ok = build_assets_text(costs, player)
  if not assets_ok then
    safe_print(player, "logistics_simulation.bp_format_failed")
    return
  end

  local report_tabs = {
    assets = assets_txt or "",
    costs = build_costs_text(counts, produced, player),
    system = build_system_text(player),
    stats = build_stats_text(player),
    working_capital = build_working_capital_text(player)
  }

  UI.show_inventory_window(player, report_tabs)

  -- Store in session
  bp_session.last[event.player_index] = {
    tick = game.tick,
    label = st.label or "Unnamed",
    counts = counts,
    costs = costs,
    report_tabs = report_tabs
  }
end
function Blueprint.tick_cleanup_sidecars()
  for player_index, _ in pairs(bp_session.sidecar_visible) do
    local p = game.get_player(player_index)
    if not p or p.opened_gui_type ~= defines.gui_type.item then
      if p then 
        UI.hide_blueprint_sidecar(p)
        UI.close_inventory_window(p)
      end
      bp_session.sidecar_visible[player_index] = nil
    end
  end
end

-- =========================================
-- SESSION CLEANUP (prevents memory leaks)
-- =========================================

function Blueprint.cleanup_session(player_index)
  bp_session.sidecar_visible[player_index] = nil
  bp_session.last[player_index] = nil
end

function Blueprint.cleanup_all_disconnected()
  local connected = {}
  for _, p in pairs(game.connected_players) do
    connected[p.index] = true
  end
  
  for idx, _ in pairs(bp_session.sidecar_visible) do
    if not connected[idx] then
      bp_session.sidecar_visible[idx] = nil
    end
  end
  
  for idx, _ in pairs(bp_session.last) do
    if not connected[idx] then
      bp_session.last[idx] = nil
    end
  end
end

return Blueprint
