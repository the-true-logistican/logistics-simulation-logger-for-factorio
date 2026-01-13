-- =========================================
-- LogSim (Factorio 2.0) 
-- Blueprint Extraction Logic Module
-- Version 0.6.0 introduced
-- Version 0.6.3 Clculate 
-- =========================================

local UI = require("ui")
local ItemCost = require("itemcost")
local Chests = require("chests")

local Blueprint = {}
  Blueprint.version = "0.6.3"

-- Session storage (not persistent)
local bp_session = {
  sidecar_visible = {}, -- [player_index] = true
  last = {}             -- [player_index] = { tick=..., label=..., counts=..., costs=... }
}

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

-- Extrahiert Entities, Tiles und berechnet Footprint
function Blueprint.extract_counts_from_blueprint(stack)
  local counts = {}

  if not (stack and stack.valid_for_read and stack.is_blueprint and stack.is_blueprint_setup()) then
    return counts
  end

  local ents = stack.get_blueprint_entities() or {}
  
  local min_x, min_y = math.huge, math.huge
  local max_x, max_y = -math.huge, -math.huge
  local any = false

-- immer auf ganz Einheiten!
local function update_bounds_from_entity(e)
  local proto = prototypes.entity[e.name]
  if not (proto and proto.selection_box) then return end

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


  
  for _, e in pairs(ents) do
    update_bounds_from_entity(e)
    Blueprint.inv_add(counts, e.name, 1)

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
  end

  if stack.get_blueprint_tiles then
    local tiles = stack.get_blueprint_tiles()
    if tiles then
      for _, t in pairs(tiles) do
        Blueprint.inv_add(counts, "tile:" .. t.name, 1)
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

  return counts, footprint
end

-- Extrahiert alle Blueprints aus einem Buch
function Blueprint.extract_counts_from_book(book_stack)
  local counts = {}

  if not (book_stack and book_stack.valid_for_read and book_stack.is_blueprint_book) then
    return counts
  end

  local ok, inv = pcall(function()
    return book_stack.get_inventory(defines.inventory.item_main)
  end)
  
  if not ok or not inv then return counts end

  for i = 1, #inv do
    local st = inv[i]
    if st and st.valid_for_read and st.is_blueprint and st.is_blueprint_setup() then
      local c = Blueprint.extract_counts_from_blueprint(st)
      for name, amt in pairs(c) do
        Blueprint.inv_add(counts, name, amt)
      end
    end
  end

  return counts
end

-- -----------------------------------------
-- Event Handlers
-- -----------------------------------------

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
  end
end

function Blueprint.click_bp_extract(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local st = nil
  
  -- Try to get the currently opened blueprint/book
  if player.opened_gui_type == defines.gui_type.item then
    local opened = player.opened
    if opened and opened.valid_for_read and (opened.is_blueprint or opened.is_blueprint_book) then
      st = opened
    end
  end

  -- Fallback: Check cursor stack
  if not st then
    local cursor = player.cursor_stack
    if cursor and cursor.valid_for_read and (cursor.is_blueprint or cursor.is_blueprint_book) then
      st = cursor
    end
  end

  -- Verify we have a valid blueprint
  if not st or not st.is_blueprint_setup() then
    player.print({"logistics_simulation.bp_no_blueprint"})
    return
  end

  -- Extract counts and footprint
  local counts, footprint
  if st.is_blueprint_book then
    counts = Blueprint.extract_counts_from_book(st)
    footprint = nil
  else
    counts, footprint = Blueprint.extract_counts_from_blueprint(st)
  end

  -- Confirm extraction
  player.print({"logistics_simulation.bp_extracted", table_size(counts)})

  -- Calculate comprehensive costs
  local costs = ItemCost.calculate_blueprint_cost(counts, player.force)
  costs.footprint = footprint
  
  -- Fixed assets (blueprint)
  local fixed_txt = ItemCost.format_detailed_breakdown(costs, player)

  -- Working capital portfolio (unit costs, amount=1)
  local portfolio_set = ItemCost.collect_portfolio_items(storage, Chests.resolve_entity, player.force)
  local unit_costs = ItemCost.calculate_unit_costs(portfolio_set, player.force)
  local wc_txt = ItemCost.format_portfolio_unit_costs(unit_costs)

  local txt = fixed_txt .. "\n\n" .. wc_txt
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

return Blueprint
