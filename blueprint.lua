-- =========================================
-- LogSim (Factorio 2.0) 
-- Extracts item counts, costs and footprint data from blueprints and blueprint books.
--
-- version 0.8.0 first complete working version
-- version 0.8.1 Blueprint.ui_front_tick_handler()
--
-- =========================================

local UI = require("ui")
local ItemCost = require("itemcost")
local Chests = require("chests")

local Blueprint = {}
  Blueprint.version = "0.8.1"

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
function Blueprint.extract_counts_from_book(book_stack)
  local counts = {}

  -- Guard: Check book validity
  if not book_stack then
    safe_log("extract_book: book_stack is nil")
    return counts
  end

  local ok, is_valid = pcall(function() return book_stack.valid_for_read end)
  if not ok or not is_valid then
    safe_log("extract_book: book not valid_for_read")
    return counts
  end

  local ok2, is_book = pcall(function() return book_stack.is_blueprint_book end)
  if not ok2 or not is_book then
    safe_log("extract_book: not a blueprint book")
    return counts
  end

  -- Safe inventory access
  local ok3, inv = pcall(function()
    return book_stack.get_inventory(defines.inventory.item_main)
  end)
  
  if not ok3 or not inv then
    safe_log("extract_book: failed to get inventory")
    return counts
  end

  -- Process each blueprint in book
  for i = 1, #inv do
    local ok4, st = pcall(function() return inv[i] end)
    
    if ok4 and st then
      local ok5, valid = pcall(function() return st.valid_for_read end)
      local ok6, is_bp = pcall(function() return st.is_blueprint end)
      local ok7, is_setup = pcall(function() return st.is_blueprint_setup() end)
      
      if ok5 and valid and ok6 and is_bp and ok7 and is_setup then
        local ok8, c = pcall(function()
          return Blueprint.extract_counts_from_blueprint(st)
        end)
        
        if ok8 and c then
          for name, amt in pairs(c) do
            Blueprint.inv_add(counts, name, amt)
          end
        else
          safe_log("extract_book: error extracting blueprint " .. i .. " - " .. tostring(c))
        end
      end
    end
  end

  return counts
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
      return Blueprint.extract_counts_from_book(st), nil
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
  
  -- Fixed assets (blueprint)
  local ok4, fixed_txt = pcall(function()
    return ItemCost.format_detailed_breakdown(costs, player)
  end)

  if not ok4 then
    safe_print(player, "logistics_simulation.bp_format_failed")
    safe_log("click_bp_extract: format failed - " .. tostring(fixed_txt))
    return
  end

  -- =========================================
  -- MASTERDATA (Unit costs): blueprint items + produced items + factory portfolio (optional)
  -- =========================================
  -- =========================================
  -- MASTERDATA (Unit costs): FULL closure to terminal raws
  -- =========================================

  local function is_valid_item_key(name)
    if not name then return false end
    if type(name) ~= 'string' then return false end
    if name:sub(1,5) == 'tile:' then return false end
    if prototypes.item and prototypes.item[name] then return true end
    if prototypes.fluid and prototypes.fluid[name] then return true end
    return false
  end

  local master_set = {}

  -- 1) Blueprint fixed assets (counts keys)
  for name, _ in pairs(counts or {}) do
    if is_valid_item_key(name) then
      master_set[name] = true
    end
  end

  -- 2) Produced items from blueprint recipes
  for name, _ in pairs(produced or {}) do
    if is_valid_item_key(name) then
      master_set[name] = true
    end
  end

  -- 3) OPTIONAL: include current factory portfolio
  local okP, portfolio_set = pcall(function()
    return ItemCost.collect_portfolio_items(storage, Chests.resolve_entity, player.force)
  end)
  if okP and portfolio_set then
    for name, _ in pairs(portfolio_set) do
      if is_valid_item_key(name) then
        master_set[name] = true
      end
    end
  end

  -- Expand to full dependency closure (intermediates + terminals)
  local expanded = ItemCost.expand_item_set_full(master_set, player.force)

  local md_txt = ""
  if next(expanded) ~= nil then
    local okU, unit_costs = pcall(function()
      return ItemCost.calculate_unit_costs(expanded, player.force)
    end)

    if okU and unit_costs then
      local okF, out = pcall(function()
        return ItemCost.format_masterdata_unit_costs(unit_costs)
      end)
      if okF and out then
        md_txt = out
      end
    end
  end

  local txt = fixed_txt
  if md_txt ~= '' then
    txt = txt .. '\n\n' .. md_txt
  end

  UI.show_inventory_window(player, txt)
  
  -- Store in session
  bp_session.last[event.player_index] = {
    tick = game.tick,
    label = st.label or "Unnamed",
    counts = counts,
    costs = costs
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