-- =========================================
-- LogSim (Factorio 2.0)
-- Transaction Module (visual inserter marks)
--
-- Goal:
--   Build a transaction list based on inserter hand movements.
--   Each physical move is represented as TWO postings:
--     1) TAKE (source decreases)
--     2) GIVE (destination increases)
--     3) OBJ_TRANSIT    = "T00"
--     4) OBJ_SHIP       = "SHIP"
--     5) local OBJ_RECV = "RECV"
--
-- Rules (Martin):
--   - Full inventory snapshots remain as anchors (handled elsewhere)
--   - Between snapshots, record SAP-like postings
--   - Only *registered* objects matter (Cxx, Txx, Mxx)
--   - Inserters are NOT manually registered; they get an auto ID (Ixx)
--   - For now: no file export; events stay in memory
--   - Optional: mark "participating" inserters in yellow with text Ixx
--   - Allow explicitly marking watched inserters as "active" (green)
--   - Active boundary inserters represent Shipping/Receiving interface
-- =========================================

local Config = require("config")
local UI = require("ui")
local Util = require("utility")  -- fly() lives here

local Transaction = {}
Transaction.version = "0.8.0"

-- -----------------------------------------
-- Defaults / Storage
-- -----------------------------------------

local function ensure_defaults()
  Config.ensure_storage_defaults(storage)
end

Transaction.ensure_defaults = ensure_defaults

-- -----------------------------------------
-- Hotkey handler (called by control.lua)
-- -----------------------------------------

-- Returns true if it handled the event (inserter path), false if caller should continue default behavior.
function Transaction.handle_register_hotkey(player, ent)
  ensure_defaults()

  if not (player and player.valid) then return true end
  if not (ent and ent.valid and ent.type == "inserter" and ent.unit_number) then
    return false
  end

  -- API guard
  if not (Transaction.set_inserter_active and Transaction.is_watched_inserter) then
    return true
  end

  local ok, reason = Transaction.set_inserter_active(ent.unit_number, true)

  if ok then
    Util.fly(player, ent, {"logistics_simulation.tx_inserter_marked_active"})
  else
    if reason == "not_watched" then
      Util.fly(player, ent, {"logistics_simulation.tx_inserter_not_watched"})
    elseif reason == "not_boundary" then
      Util.fly(player, ent, {"logistics_simulation.tx_inserter_not_boundary"})
    else
      Util.fly(player, ent, {"logistics_simulation.tx_inserter_mark_failed"})
    end
  end

  return true
end

-- -----------------------------------------
-- Public helpers for control.lua (NO speculation)
-- -----------------------------------------

function Transaction.is_watched_inserter(ins_unit)
  ensure_defaults()
  return storage.tx_watch and storage.tx_watch[ins_unit] == true
end

function Transaction.set_inserter_active(ins_unit, is_active)
  ensure_defaults()
  if not ins_unit then return false, "bad_unit" end

  storage.tx_active_inserters = storage.tx_active_inserters or {}

  if is_active then
    -- must be watched
    if not (storage.tx_watch and storage.tx_watch[ins_unit] == true) then
      return false, "not_watched"
    end

    -- must be a boundary inserter (exactly one side registered)
    if not Transaction.is_boundary_inserter(ins_unit) then
      storage.tx_active_inserters[ins_unit] = nil
      Transaction.update_marks()
      return false, "not_boundary"
    end

    storage.tx_active_inserters[ins_unit] = true
    Transaction.update_marks()
    return true
  end

  -- deactivate
  storage.tx_active_inserters[ins_unit] = nil
  Transaction.update_marks()
  return true
end

function Transaction.is_inserter_active(ins_unit)
  ensure_defaults()
  return storage.tx_active_inserters and storage.tx_active_inserters[ins_unit] == true
end

-- -----------------------------------------
-- Helpers
-- -----------------------------------------

local function qual_name(q)
  if q == nil then return "normal" end
  if type(q) == "string" then return q end
  -- Factorio 2.x: LuaQualityPrototype (or similar)
  if type(q) == "table" and q.name then return q.name end
  -- userdata/object: try .name safely
  local ok, n = pcall(function() return q.name end)
  if ok and n then return n end
  return tostring(q)  -- fallback (should not happen)
end

-- Item key formatter: include quality only if it's not "normal"
local function fmt_item_key(k)
  if not k then return "" end

  -- Factorio can represent inventory keys as:
  -- 1) string "iron-plate"
  -- 2) table {name="iron-plate", quality="normal"} (Factorio 2.x quality)
  if type(k) == "string" then
    -- Some codepaths may already embed quality as "name@quality"
    local base, q = k:match("^(.-)@(.+)$")
    if base and q then
      if q == "normal" then return base end
      return base .. "@" .. q
    end
    return k
  end

  if type(k) == "table" then
    local name = k.name or k.item or ""
    local q = k.quality
    if not q or q == "normal" then
      return name
    end
    return name .. "@" .. tostring(q)
  end

  return tostring(k)
end

local function fmt_inserter_id(n)
  return string.format("I%02d", n)
end

local function get_or_create_inserter_rec(ins_unit)
  local rec = storage.tx_inserter_by_unit[ins_unit]
  if rec then return rec end

  local id = fmt_inserter_id(storage.tx_next_inserter_id)
  storage.tx_next_inserter_id = storage.tx_next_inserter_id + 1

  rec = { id = id, last = nil }
  storage.tx_inserter_by_unit[ins_unit] = rec
  return rec
end

local function stack_to_tbl(st)
  if not (st and st.valid_for_read) then return nil end

  local name = st.name
  if not name then return nil end

  local cnt = st.count
  if type(cnt) ~= "number" then cnt = 1 end

  -- Quality exists in 2.0; keep robust
  local qual = "normal"
  local okq, q = pcall(function() return st.quality end)
  if okq and q then qual = qual_name(q) end

  return { name = name, count = cnt, quality = qual }
end

local function same_stack(a, b)
  if a == nil and b == nil then return true end
  if (a == nil) ~= (b == nil) then return false end
  return a.name == b.name
     and a.count == b.count
     and (a.quality or "normal") == (b.quality or "normal")
end

local function vkey(item, qual)
  if not item then return nil end
  if qual and qual ~= "normal" then
    return tostring(item) .. "@" .. tostring(qual)
  end
  return tostring(item)
end

local function virtual_add(obj, item, delta, qual)
  if not obj or not item or not delta or delta == 0 then return end
  if not storage.tx_virtual then return end
  local buf = storage.tx_virtual[obj]
  if not buf then return end

  local key = vkey(item, qual)
  if not key then return end

  local new = (buf[key] or 0) + delta

  -- NO CLAMPING. Keep true accounting signal.
  if new == 0 then
    buf[key] = nil      -- optional: keep storage small + logs clean
  else
    buf[key] = new      -- can be positive OR negative
  end
end

local function push_event(ev)
  local t = storage.tx_events
  t[#t + 1] = ev

  -- update running balances for virtual buffers (T00/SHIP/RECV)
  if ev and (ev.obj == "T00" or ev.obj == "SHIP" or ev.obj == "RECV") then
    local cnt = tonumber(ev.cnt) or 0
    if cnt ~= 0 then
      if ev.kind == "GIVE" then
        virtual_add(ev.obj, ev.item,  cnt, ev.qual)
      elseif ev.kind == "TAKE" then
        virtual_add(ev.obj, ev.item, -cnt, ev.qual)
      end
    end
  end
  
  -- If TX GUI is open, mark it dirty so it refreshes (LIVE mode follows tail).
  if Transaction.tx_mark_dirty_for_open_guis then
    Transaction.tx_mark_dirty_for_open_guis()
  end

  local max = storage.tx_max_events or 500000
  if #t > max then
    local overflow = #t - max
    for _ = 1, overflow do
      table.remove(t, 1)
    end
  end
end

local function safe_get(field_fn)
  local ok, v = pcall(field_fn)
  if ok then return v end
  return nil
end

local function resolve_entity_at(surface, pos)
  if not (surface and surface.valid and pos) then return nil end

  local r = 1.6
  local area = { {pos.x - r, pos.y - r}, {pos.x + r, pos.y + r} }

  -- 1) Prefer containers/tanks
  local found = surface.find_entities_filtered{
    area = area,
    type = {"container", "logistic-container", "storage-tank"},
    limit = 1
  }
  if found and found[1] then return found[1] end

  -- 2) Then common machines
  found = surface.find_entities_filtered{
    area = area,
    type = {"assembling-machine", "furnace", "lab", "mining-drill"},
    limit = 1
  }
  if found and found[1] then return found[1] end

  -- 3) Fallback: any entity
  found = surface.find_entities_filtered{
    area = area,
    limit = 1
  }
  return found and found[1] or nil
end

local function get_targets(ins)
  local pick = safe_get(function() return ins.pickup_target end)
  local drop = safe_get(function() return ins.drop_target end)

  if (not pick) and ins.pickup_position then
    local ppos = safe_get(function() return ins.pickup_position end)
    if ppos then pick = resolve_entity_at(ins.surface, ppos) end
  end

  if (not drop) and ins.drop_position then
    local dpos = safe_get(function() return ins.drop_position end)
    if dpos then drop = resolve_entity_at(ins.surface, dpos) end
  end

  return pick, drop
end

local function obj_id_for_entity(ent)
  if not (ent and ent.valid and ent.unit_number) then return nil end
  return storage.tx_obj_by_unit[ent.unit_number]
end

-- -----------------------------------------
-- Pseudo objects (SAP-like)
--   T00  : Transit (belts / uncontrolled flow)
--   SHIP : Shipping (outbound)  [active boundary inserter]
--   RECV : Receiving (inbound)  [active boundary inserter]
-- -----------------------------------------

local OBJ_TRANSIT = "T00"
local OBJ_SHIP    = "SHIP"
local OBJ_RECV    = "RECV"

local function opposite_obj(ins_unit, src_obj, dst_obj)
  local is_active = Transaction.is_inserter_active and Transaction.is_inserter_active(ins_unit)

  if is_active then
    -- Prefer cached boundary direction (robust against transient target resolution)
    local meta = storage.tx_watch_meta and storage.tx_watch_meta[ins_unit]
    local b = meta and meta.boundary or nil
    if b == "ship" then return OBJ_SHIP end
    if b == "recv" then return OBJ_RECV end

    -- Fallback: infer from current resolved sides
    if src_obj and (not dst_obj) then
      return OBJ_SHIP
    elseif (not src_obj) and dst_obj then
      return OBJ_RECV
    end
  end

  return OBJ_TRANSIT
end

-- Fallback resolver for inserters when get_entity_by_unit_number is unreliable
local function resolve_inserter_by_meta(unit)
  local meta = storage.tx_watch_meta and storage.tx_watch_meta[unit]
  if not meta then return nil end

  local surface = game.get_surface(meta.surface_index)
  if not (surface and surface.valid and meta.position) then return nil end

  local found = surface.find_entities_filtered{
    position = meta.position,
    radius = 1.0,
    type = "inserter"
  } or {}

  for _, e in pairs(found) do
    if e and e.valid and e.unit_number == unit then
      return e
    end
  end

  return nil
end

function Transaction.is_boundary_inserter(ins_unit)
  ensure_defaults()
  if not ins_unit then return false end

  local ins = game.get_entity_by_unit_number(ins_unit)
  if not (ins and ins.valid) then
    ins = resolve_inserter_by_meta(ins_unit)
  end
  if not (ins and ins.valid) then return false end

  local pick, drop = get_targets(ins)
  local src_obj = obj_id_for_entity(pick)
  local dst_obj = obj_id_for_entity(drop)
  
  local boundary = nil
  if src_obj and (not dst_obj) then boundary = "ship"
  elseif (not src_obj) and dst_obj then boundary = "recv"
  end  

  -- XOR: exactly one side registered
  if (src_obj and not dst_obj) or (not src_obj and dst_obj) then
    return true
  end
  return false
end

-- -----------------------------------------
-- Rendering helpers (optional visual marks)
-- -----------------------------------------

local function rendering_is_valid(id)
  if not id then return false end
  local ok, v = pcall(function() return rendering.is_valid(id) end)
  return ok and v or false
end

local function destroy_mark(ins_unit)
  local rid = storage.tx_mark_render_ids and storage.tx_mark_render_ids[ins_unit]
  if rid and rendering_is_valid(rid) then
    pcall(function() rendering.destroy(rid) end)
  end
  if storage.tx_mark_render_ids then
    storage.tx_mark_render_ids[ins_unit] = nil
  end
end

function Transaction.update_marks()
  ensure_defaults()

  if not (Config.TX_MARK_INSERTERS == true) then
    for ins_unit, rec in pairs(storage.tx_inserter_by_unit or {}) do
      UI.marker_text_update(rec, nil, "", nil)
    end
    return
  end

  local watch = storage.tx_watch or {}
  local active = storage.tx_active_inserters or {}

  local ACTIVE_COLOR = Config.TX_MARK_ACTIVE_COLOR or { r=0, g=1, b=0, a=1 }

  for ins_unit, rec in pairs(storage.tx_inserter_by_unit or {}) do
    if rec and rec.marker_text and not watch[ins_unit] then
      UI.marker_text_update(rec, nil, "", nil)
    end
  end

  for ins_unit, _ in pairs(watch) do
    local ins = game.get_entity_by_unit_number(ins_unit)
    if not (ins and ins.valid) then
      ins = resolve_inserter_by_meta(ins_unit)
    end

    local rec = get_or_create_inserter_rec(ins_unit)

    if not (ins and ins.valid) then
      UI.marker_text_update(rec, nil, "", nil)
    else
      local col = active[ins_unit] and ACTIVE_COLOR or Config.TX_MARK_COLOR

      UI.marker_text_update(rec, ins, rec.id, {
        color  = col,
        offset = Config.TX_MARK_OFFSET,
        scale  = Config.TX_MARK_SCALE
      })
    end
  end
end

-- -----------------------------------------
-- Object map rebuild (registered objects only)
-- -----------------------------------------

function Transaction.rebuild_object_map()
  ensure_defaults()

  local map = {}

  for unit, rec in pairs(storage.registry or {}) do
    if unit and rec and rec.id then
      map[unit] = rec.id
    end
  end

  for unit, rec in pairs(storage.machines or {}) do
    if unit and rec and rec.id then
      map[unit] = rec.id
    end
  end

  storage.tx_obj_by_unit = map
end

-- -----------------------------------------
-- Watchlist rebuild
-- -----------------------------------------

function Transaction.rebuild_watchlist()
  ensure_defaults()

  local watch = {}
  local r = 20

  local function consider_inserter(ins)
    if not (ins and ins.valid and ins.unit_number) then return false end

    local pick, drop = get_targets(ins)
    local src_obj = obj_id_for_entity(pick)
    local dst_obj = obj_id_for_entity(drop)

    -- Cache boundary direction for robust SHIP/RECV logging
    -- ship: registered source -> unregistered dest
    -- recv: unregistered source -> registered dest
    local boundary = nil
    if src_obj and (not dst_obj) then boundary = 'ship'
    elseif (not src_obj) and dst_obj then boundary = 'recv'
    end

    if not src_obj and not dst_obj then
      return false
    end

    if not watch[ins.unit_number] then
      watch[ins.unit_number] = true
      get_or_create_inserter_rec(ins.unit_number)

      local m = storage.tx_watch_meta[ins.unit_number] or {}
      m.surface_index = ins.surface.index
      m.position = { x = ins.position.x, y = ins.position.y }
      m.misses = 0
      m.boundary = boundary
      storage.tx_watch_meta[ins.unit_number] = m
    end

    return true
  end

  local function scan(surface_index, pos)
    local surface = game.get_surface(surface_index)
    if not (surface and surface.valid and pos) then return 0 end

    local area = { {pos.x - r, pos.y - r}, {pos.x + r, pos.y + r} }
    local all = surface.find_entities_filtered{ area = area } or {}

    local kept = 0
    for _, e in pairs(all) do
      if e and e.valid and e.type == "inserter" then
        if consider_inserter(e) then
          kept = kept + 1
        end
      end
    end
    return kept
  end

  local total_kept = 0
  local scanned = 0

  for _, rec in pairs(storage.registry or {}) do
    if rec and rec.surface_index and rec.position then
      total_kept = total_kept + scan(rec.surface_index, rec.position)
      scanned = scanned + 1
    end
  end

  for _, rec in pairs(storage.machines or {}) do
    if rec and rec.surface_index and rec.position then
      total_kept = total_kept + scan(rec.surface_index, rec.position)
      scanned = scanned + 1
    end
  end

  storage.tx_watch = watch
  storage.tx_dbg_watch = { scanned = scanned, kept = total_kept, watch_size = table_size(watch), r = r, tick = game.tick }

  -- HARD RULE: Active must not survive if no longer watched
  if storage.tx_active_inserters then
    for ins_unit, _ in pairs(storage.tx_active_inserters) do
      if not watch[ins_unit] then
        storage.tx_active_inserters[ins_unit] = nil
      end
    end
  end

  -- HARD RULE #2: Active must not survive if no longer boundary
  if storage.tx_active_inserters then
    for ins_unit, _ in pairs(storage.tx_active_inserters) do
      if watch[ins_unit] then
        if not Transaction.is_boundary_inserter(ins_unit) then
          storage.tx_active_inserters[ins_unit] = nil
        end
      end
    end
  end

  Transaction.update_marks()
end

-- -----------------------------------------
-- Tick processing
-- -----------------------------------------

local function process_inserter(ins, tick)
  if not (ins and ins.valid and ins.unit_number) then return end

  local ins_unit = ins.unit_number
  local ins_rec = get_or_create_inserter_rec(ins_unit)

  local now = stack_to_tbl(ins.held_stack)
  local last = ins_rec.last

  if same_stack(now, last) then
    return
  end

  local pick, drop = get_targets(ins)
  local src_obj = obj_id_for_entity(pick)
  local dst_obj = obj_id_for_entity(drop)

  -- Transition: empty -> filled  => TAKE
  if (not last) and now then
    local src = src_obj or opposite_obj(ins_unit, src_obj, dst_obj)

    push_event({
      tick = tick,
      ins_id = ins_rec.id,
      ins_unit = ins_unit,
      kind = "TAKE",
      obj = src,
      obj_unit = pick and pick.unit_number or nil,
      item = now.name,
      cnt = now.count,
      qual = now.quality or "normal"
    })

    ins_rec.last = now
    return
  end

  -- Transition: filled -> empty  => GIVE
  if last and (not now) then
    local dst = dst_obj or opposite_obj(ins_unit, src_obj, dst_obj)

    push_event({
      tick = tick,
      ins_id = ins_rec.id,
      ins_unit = ins_unit,
      kind = "GIVE",
      obj = dst,
      obj_unit = drop and drop.unit_number or nil,
      item = last.name,
      cnt = last.count,
      qual = last.quality or "normal"
    })

    ins_rec.last = nil
    return
  end

  -- Any other change (rare): refresh last
  ins_rec.last = now
end

function Transaction.on_tick(tick)
  ensure_defaults()

  if not storage.tx_active then return end

  tick = tick or game.tick

  -- periodic rebuild
  local interval = storage.tx_rebuild_interval or 60
  if (tick - (storage.tx_last_rebuild_tick or 0)) >= interval then
    Transaction.rebuild_object_map()
    Transaction.rebuild_watchlist()
    storage.tx_last_rebuild_tick = tick
  end

  if not storage.tx_watch or next(storage.tx_watch) == nil then return end

  for ins_unit, _ in pairs(storage.tx_watch) do
    local ins = game.get_entity_by_unit_number(ins_unit)
    if not (ins and ins.valid) then
      ins = resolve_inserter_by_meta(ins_unit)
    end

    if ins and ins.valid then
      local m = storage.tx_watch_meta and storage.tx_watch_meta[ins_unit]
      if m then m.misses = 0 end

      process_inserter(ins, tick)
    else
      local m = storage.tx_watch_meta and storage.tx_watch_meta[ins_unit]
      if not m then
        m = { misses = 0 }
        storage.tx_watch_meta[ins_unit] = m
      end
      m.misses = (m.misses or 0) + 1

      if m.misses > 300 then
        storage.tx_watch[ins_unit] = nil
        storage.tx_watch_meta[ins_unit] = nil
        storage.tx_inserter_by_unit[ins_unit] = nil
        destroy_mark(ins_unit)

        if storage.tx_active_inserters then
          storage.tx_active_inserters[ins_unit] = nil
        end
      end
    end
  end
end

-- -----------------------------------------
-- TX Viewer helpers (for UI text-box paging)
-- -----------------------------------------

function Transaction.tx_line_count()
  ensure_defaults()
  local n = (storage.tx_events and #storage.tx_events) or 0
  return n + 2
end

-- Item key formatter: include quality only if it's not "normal"
local function fmt_item_key(k)
  if not k then return "" end

  if type(k) == "string" then
    local base, q = k:match("^(.-)@(.+)$")
    if base and q then
      if q == "normal" then return base end
      return base .. "@" .. q
    end
    return k
  end

  if type(k) == "table" then
    local name = k.name or k.item or ""
    local q = k.quality
    if not q or q == "normal" then
      return name
    end
    return name .. "@" .. tostring(q)
  end

  return tostring(k)
end

function Transaction.tx_get_line(i, surface)
  ensure_defaults()
  if i == 1 then return "# TX" end
  if i == 2 then return "# id;ts;tick;ins;act;obj;item;cnt" end  -- qual removed from header (default)

  local ev = storage.tx_events and storage.tx_events[i - 2]
  if not ev then return "" end

  local tick = tonumber(ev.tick) or 0
  local ts = Util.to_excel_datetime(tick, surface)

  local item_str = fmt_item_key(ev.item)
  local cnt = tostring(ev.cnt or 0)
  local qual = qual_name(ev.qual)
  
  local base = string.format(
    "%d;ts=%s;tick=%d;ins=%s;act=%s;obj=%s;item=%s;cnt=%s",
    (i - 2),
    ts,
    tick,
    tostring(ev.ins_id or "?"),
    tostring(ev.kind or "?"),
    tostring(ev.obj or "?"),
    tostring(item_str or "?"),
    cnt
  )

  -- Only include quality if it's not normal
  if qual ~= "normal" then
    return base .. ";qual=" .. qual
  end

  return base
end

-- -----------------------------------------
-- TX Viewer (GUI paging + refresh)
--   Mirrors Buffer module behavior, but uses tx_events.
-- -----------------------------------------

local function tx_count()
  return (storage.tx_events and #storage.tx_events) or 0
end

local function tx_total_lines()
  -- +2 header lines
  return tx_count() + 2
end

local function tx_get_line_len(i, surface)
  local line = Transaction.tx_get_line(i, surface) or ""
  return #line
end

local function tx_get_text_range(start_line, end_line, surface)
  local n = tx_total_lines()
  if n <= 0 then return "" end

  start_line = math.max(1, math.min(start_line, n))
  end_line   = math.max(1, math.min(end_line, n))
  if end_line < start_line then return "" end

  local t = {}
  for i = start_line, end_line do
    t[#t+1] = Transaction.tx_get_line(i, surface)
  end
  return table.concat(t, "\n") .. "\n"
end

local function tx_compute_tail_window(max_chars, surface)
  local n = tx_total_lines()
  if n == 0 then return 1, 0 end

  local chars = 1
  local start = n
  while start > 1 do
    local add = tx_get_line_len(start-1, surface) + 1
    if chars + add > max_chars then break end
    chars = chars + add
    start = start - 1
  end
  return start, n
end

local function tx_fit_window_to_chars(end_line, max_chars, surface)
  local n = tx_total_lines()
  if n == 0 then return 1, 0 end

  end_line = math.max(1, math.min(end_line, n))

  local chars = 1
  local start = end_line
  while start > 1 do
    local add = tx_get_line_len(start-1, surface) + 1
    if chars + add > max_chars then break end
    chars = chars + add
    start = start - 1
  end

  return start, end_line
end

local function tx_fit_window_forward_to_chars(start_line, end_limit, max_chars, surface)
  local n = tx_total_lines()
  if n == 0 then return 1, 0 end

  start_line = math.max(1, math.min(start_line, n))
  end_limit  = math.max(start_line, math.min(end_limit or n, n))

  local chars = 1
  local e = start_line
  while e < end_limit and e < n do
    local add = tx_get_line_len(e + 1, surface) + 1
    if chars + add > max_chars then break end
    chars = chars + add
    e = e + 1
  end

  return start_line, e
end

function Transaction.tx_ensure_view(player_index, surface)
  ensure_defaults()
  storage.tx_view = storage.tx_view or {}

  local view = storage.tx_view[player_index]
  if not view then
    local s, e = tx_compute_tail_window(Config.TEXT_MAX or 1500000, surface)
    view = {
      start_line = s,
      end_line   = e,
      follow     = true,
      last_start = nil,
      last_end   = nil,
    }
    storage.tx_view[player_index] = view
  end

  return view
end

function Transaction.tx_mark_dirty_for_open_guis()
  ensure_defaults()
  storage.tx_gui_dirty = storage.tx_gui_dirty or {}

  for _, player in pairs(game.connected_players) do
    local frame = player.gui.screen[Config.GUI_TX_FRAME]
    if frame and frame.valid then
      storage.tx_gui_dirty[player.index] = true
    end
  end
end

function Transaction.tx_refresh_for_player(player, force_text_redraw)
  if not (player and player.valid) then return end
  ensure_defaults()

  local frame = player.gui.screen[Config.GUI_TX_FRAME]
  if not (frame and frame.valid) then
    if storage.tx_view then storage.tx_view[player.index] = nil end
    if storage.tx_gui_dirty then storage.tx_gui_dirty[player.index] = false end
    return
  end

  local box = frame[Config.GUI_TX_BOX]
  if not (box and box.valid) then
    if storage.tx_view then storage.tx_view[player.index] = nil end
    if storage.tx_gui_dirty then storage.tx_gui_dirty[player.index] = false end
    return
  end

  local toolbar = frame.logsim_tx_toolbar
  if not (toolbar and toolbar.valid) then return end

  local surface = player.surface
  local view = Transaction.tx_ensure_view(player.index, surface)

  local prot_on = (storage.protocol_active == true)
  if not prot_on then
    view.follow = false
  end

  if view.follow then
    local s, e = tx_compute_tail_window(Config.TEXT_MAX or 1500000, surface)
    view.start_line, view.end_line = s, e
  end

  local need_text =
    force_text_redraw
    or view.follow
    or view.last_start ~= view.start_line
    or view.last_end   ~= view.end_line

  if need_text then
    local prefix = ""
    if view.start_line > 1 then
      prefix = "...(truncated)\n"
    end

    local text = prefix .. tx_get_text_range(view.start_line, view.end_line, surface)

    local ok = pcall(function()
      if box and box.valid then
        box.text = text
      end
    end)

    if not ok then
      if storage.tx_gui_dirty then storage.tx_gui_dirty[player.index] = false end
      return
    end

    view.last_start = view.start_line
    view.last_end   = view.end_line
  end

  -- Update LIVE button style/state
  local live = toolbar[Config.GUI_TX_BTN_TAIL]
  if live and live.valid and live.type == "button" then
    if not prot_on then
      live.enabled = false
      live.style = "button"
      live.caption = {"logistics_simulation.tx_static"}
      live.tooltip = {"logistics_simulation.tx_static_tooltip"}
    else
      live.enabled = true
      if view.follow then
        live.style = "confirm_button"
        live.caption = {"logistics_simulation.tx_live"}
        live.tooltip = {"logistics_simulation.tx_live_tooltip"}
      else
        live.style = "button"
        live.caption = {"logistics_simulation.tx_live"}
        live.tooltip = {"logistics_simulation.tx_paused_tooltip"}
      end
    end
  end
end

function Transaction.tx_tick_refresh_open_guis(tick)
  ensure_defaults()
  tick = tick or game.tick

  if (tick - (storage._tx_last_gui_refresh_tick or 0)) < (Config.GUI_REFRESH_TICKS or 10) then
    return
  end

  local any = false
  for _, v in pairs(storage.tx_gui_dirty or {}) do
    if v then any = true; break end
  end

  if not any then
    storage._tx_last_gui_refresh_tick = tick
    return
  end

  for _, player in pairs(game.connected_players) do
    if storage.tx_gui_dirty[player.index] then
      Transaction.tx_refresh_for_player(player, false)
      storage.tx_gui_dirty[player.index] = false
    end
  end

  storage._tx_last_gui_refresh_tick = tick
end

-- Paging controls
function Transaction.tx_tail(player)
  if not (player and player.valid) then return end
  ensure_defaults()
  local view = Transaction.tx_ensure_view(player.index, player.surface)
  view.follow = true
  Transaction.tx_refresh_for_player(player, true)
end

function Transaction.tx_page_older(player)
  if not (player and player.valid) then return end
  ensure_defaults()

  local n = tx_total_lines()
  if n == 0 then
    Transaction.tx_refresh_for_player(player, true)
    return
  end

  local view = Transaction.tx_ensure_view(player.index, player.surface)
  view.follow = false

  local win  = math.max(1, (view.end_line - view.start_line + 1))
  local page = math.max(Config.BUFFER_PAGE_LINES or 200, win)

  local new_end = math.max(1, view.start_line - 1)
  local new_start = math.max(1, new_end - (page - 1))

  new_start, new_end = tx_fit_window_to_chars(new_end, Config.TEXT_MAX or 1500000, player.surface)
  view.start_line, view.end_line = new_start, new_end

  Transaction.tx_refresh_for_player(player, true)
end

function Transaction.tx_page_newer(player)
  if not (player and player.valid) then return end
  ensure_defaults()

  local n = tx_total_lines()
  if n == 0 then
    Transaction.tx_refresh_for_player(player, true)
    return
  end

  local view = Transaction.tx_ensure_view(player.index, player.surface)
  view.follow = false

  local win  = math.max(1, (view.end_line - view.start_line + 1))
  local page = math.max(Config.BUFFER_PAGE_LINES or 200, win)

  local new_start = math.min(n, view.end_line + 1)
  local end_limit = math.min(n, new_start + (page - 1))

  local s, e = tx_fit_window_forward_to_chars(new_start, end_limit, Config.TEXT_MAX or 1500000, player.surface)
  view.start_line, view.end_line = s, e

  Transaction.tx_refresh_for_player(player, true)
end

function Transaction.tx_copy_to_clipboard(player)
  if not (player and player.valid) then return end
  ensure_defaults()

  local frame = player.gui.screen[Config.GUI_TX_FRAME]
  if not (frame and frame.valid) then return end

  local box = frame[Config.GUI_TX_BOX]
  if not (box and box.valid) then return end

  box.focus()
  box.select_all()
  player.print({"logistics_simulation.msg_copied"})
end


function Transaction.reset_tx_log()
  ensure_defaults()

  -- Clear only the TX event log + viewer state.
  -- IMPORTANT: keep active inserter markings (green) and inserter IDs stable.
  storage.tx_events = {}
  storage.tx_virtual = { T00 = {}, SHIP = {}, RECV = {} }

  -- Force a rebuild of object map/watchlist after reset
  storage.tx_watch = {}
  storage.tx_watch_meta = {}
  storage.tx_obj_by_unit = {}

  storage.tx_dbg_watch = nil
  storage.tx_last_rebuild_tick = 0
  
  -- Viewer state
  storage.tx_view = {}
  storage.tx_gui_dirty = {}
  storage._tx_last_gui_refresh_tick = 0

  -- Rebuild immediately so marks/colors come back without waiting
  if Transaction.rebuild_object_map then Transaction.rebuild_object_map() end
  if Transaction.rebuild_watchlist then Transaction.rebuild_watchlist() end
  Transaction.update_marks()
end

return Transaction