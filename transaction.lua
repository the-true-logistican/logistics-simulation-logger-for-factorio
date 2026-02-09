-- =========================================
-- LogSim (Factorio 2.0)
-- Transaction Module (visual inserter marks)
--
-- Goal:
--   Build a transaction list based on inserter hand movements.
--   Each physical move is represented as TWO postings:
--     1) TAKE (source decreases)
--     2) GIVE (destination increases)
--     3) OBJ_TRANSIT = "T00"   inernal transit
--     4) OBJ_SHIP    = "SHIP"  outbount shipping
--     5) OBJ_RECV    = "RECV"  inbound receive 
--     6) OBJ_WIP     = "WIP"   work in origress  
--     7) OBJ_MAN     = "MAN"   manual crafting
--
-- Rules (Martin):
--   - Full inventory snapshots remain as anchors (handled elsewhere)
--   - Between snapshots, record SAP-like postings
--   - Only *registered* objects matter (Cxx, Txx, Mxx)
--   - Inserters are NOT manually registered; they get an auto ID (Ixx)
--   - For now: no file export; events stay in memory
--   - automatic mark "participating" inserters in yellow with text Ixx
--   - Allow explicitly marking watched inserters as "active" (green)
--   - Active boundary inserters represent Shipping/Receiving interface (pink)
--
-- version 0.8.0 first complete working version
-- version 0.8.1 tx window with buttons <<  <  >  >> 
--               number of items in transactipons from/to belts corrected
--               simple filter for transactions with checkboxes
--               ring buffer M.TX_MAX_EVENTS load/save secure
-- Version 0.8.2 get global parameters from settings
-- Version 0.8.3 WIP virtual account + Shift-R toggle normal/WIP/OFF (minimal additions)
-- Version 0.8.4 transactions with the "hand" of the player
--               crafting in wirtual inventpry MAN
--
-- =========================================

local Config = require("config")
local UI = require("ui")
local Util = require("utility")  -- fly() lives here

local Transaction = {}
Transaction.version = "0.8.4"

-- forward declarations (needed because ensure_defaults() uses them)
local tx_rb_ensure
local tx_rb_resize

-- -----------------------------------------
-- Defaults / Storage
-- -----------------------------------------

local function ensure_defaults()
  Config.ensure_storage_defaults(storage)

  -- NEW: keep WIP flag map (minimal, no structural change to existing ones)
  storage.tx_wip_inserters = storage.tx_wip_inserters or {}

  -- NEW: ensure virtual account exists (migration safe even if config.lua not updated yet)
  storage.tx_virtual = storage.tx_virtual or { T00 = {}, SHIP = {}, RECV = {} }
  storage.tx_virtual.WIP = storage.tx_virtual.WIP or {}

  -- Keep TX ringbuffer settings in sync with config/settings across save/load.
  tx_rb_ensure()

  -- NEW: player "hands" as pseudo-inserters (H01, H02, ...)
  -- Minimal: provide an inserter-like list for later ledger logic.
  storage.tx_hand_by_player_index = storage.tx_hand_by_player_index or {}
  storage.tx_hand_list = storage.tx_hand_list or {}
  storage.tx_inserter_list = storage.tx_inserter_list or {}

  local desired_max =
    tonumber(storage.tx_max_events)
    or tonumber(Config.TX_MAX_EVENTS)
    or (Config.M and tonumber(Config.M.TX_MAX_EVENTS))
    or 500000

  if tonumber(storage.tx_max_events) ~= desired_max then
    tx_rb_resize(desired_max)
  end
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

  local unit = ent.unit_number
  local is_active = Transaction.is_inserter_active and Transaction.is_inserter_active(unit)
  local is_wip = storage.tx_wip_inserters and storage.tx_wip_inserters[unit] == true

  -- Cycle (Boundary-only enforced by set_inserter_active):
  -- OFF -> ACTIVE(normal) -> ACTIVE(WIP) -> OFF
  if not is_active then
    local ok, reason = Transaction.set_inserter_active(unit, true)
    if ok then
      storage.tx_wip_inserters[unit] = nil
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

  if not is_wip then
    storage.tx_wip_inserters[unit] = true
    Transaction.update_marks()
    Util.fly(player, ent, {"logistics_simulation.tx_inserter_marked_WIP"})
    return true
  else	
    storage.tx_wip_inserters[unit] = false
    Transaction.update_marks()
    Util.fly(player, ent, {"logistics_simulation.tx_inserter_marked_active"})
    return true
  end

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

  -- NEW: WIP flag should not survive when deactivated
  if storage.tx_wip_inserters then
    storage.tx_wip_inserters[ins_unit] = nil
  end

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

tx_rb_ensure = function()
  -- Ringbuffer state (O(1) push, O(1) random access in logical order)
  storage.tx_events = storage.tx_events or {}

  -- Max events can be configured (defaults to 500k)
  storage.tx_max_events = storage.tx_max_events or 500000

  -- Migration: if we already have a linear array but no rb state, initialize rb state.
  if storage.tx_head == nil or storage.tx_write == nil or storage.tx_size == nil then
    local t = storage.tx_events
    local n = #t

    storage.tx_head  = 1
    storage.tx_write = n + 1
    storage.tx_size  = n

    -- Ensure write stays in [1..max] even if table is larger than max
    local max = storage.tx_max_events
    if n > max then
      -- Keep only the last `max` events, in-place, without shifting big tables repeatedly.
      -- We rebuild into a fresh array once (migration only).
      local newt = {}
      local start = n - max + 1
      for i = 1, max do
        newt[i] = t[start + (i - 1)]
      end
      storage.tx_events = newt
      storage.tx_head  = 1
      storage.tx_write = max + 1
      storage.tx_size  = max
      t = storage.tx_events
      n = max
    end

    -- Assign monotonic IDs if missing (so Excel references remain stable across wrap-around).
    storage.tx_seq = storage.tx_seq or 0
    for i = 1, n do
      local ev = t[i]
      if ev and ev.id == nil then
        storage.tx_seq = storage.tx_seq + 1
        ev.id = storage.tx_seq
      elseif ev and type(ev.id) == "number" and ev.id > storage.tx_seq then
        storage.tx_seq = ev.id
      end
    end
  end

  -- Normalize fields
  storage.tx_seq  = storage.tx_seq  or 0
  storage.tx_head = storage.tx_head or 1
  storage.tx_size = storage.tx_size or 0
  storage.tx_write = storage.tx_write or 1

  -- Clamp indices into bounds
  local max = storage.tx_max_events
  if storage.tx_head < 1 or storage.tx_head > max then storage.tx_head = 1 end
  if storage.tx_write < 1 or storage.tx_write > max then storage.tx_write = 1 end
  if storage.tx_size < 0 then storage.tx_size = 0 end
  if storage.tx_size > max then storage.tx_size = max end
end

tx_rb_resize = function(new_max)
  tx_rb_ensure()

  new_max = tonumber(new_max) or 500000
  if new_max < 1 then new_max = 1 end

  local old_max  = storage.tx_max_events or new_max
  local old_size = storage.tx_size or 0
  local old_head = storage.tx_head or 1
  local old_ev   = storage.tx_events or {}

  -- Keep the newest events when shrinking (most useful for analysis / startup behavior).
  local keep = old_size
  if keep > new_max then keep = new_max end

  local new_ev = {}
  if keep > 0 then
    local start_logical = old_size - keep + 1  -- 1..old_size
    for j = 1, keep do
      local i = start_logical + (j - 1)
      local phys = ((old_head + (i - 1) - 1) % old_max) + 1
      new_ev[j] = old_ev[phys]
    end
  end

  storage.tx_events     = new_ev
  storage.tx_max_events = new_max
  storage.tx_head       = 1
  storage.tx_size       = keep
  storage.tx_write      = (keep % new_max) + 1

  -- If TX GUI is open, mark it dirty so it refreshes after resize.
  if Transaction.tx_mark_dirty_for_open_guis then
    Transaction.tx_mark_dirty_for_open_guis()
  end
end

local function tx_rb_get_event(i)
  -- i: 1..tx_size (logical order: oldest -> newest)
  if not i then return nil end
  local size = storage.tx_size or 0
  if i < 1 or i > size then return nil end
  local max = storage.tx_max_events or 500000
  local head = storage.tx_head or 1
  local phys = ((head + (i - 1) - 1) % max) + 1
  return storage.tx_events and storage.tx_events[phys] or nil
end

local function push_event(ev)
  tx_rb_ensure()

  -- stable, monotonic ID (do NOT derive from list index; ringbuffer wraps)
  storage.tx_seq = (storage.tx_seq or 0) + 1
  ev.id = storage.tx_seq

  local t   = storage.tx_events
  local max = storage.tx_max_events or 500000
  local w   = storage.tx_write or 1
  local size = storage.tx_size or 0

  t[w] = ev

  -- update running balances for virtual buffers (T00/SHIP/RECV/WIP)
  if ev and (ev.obj == "T00" or ev.obj == "SHIP" or ev.obj == "RECV" or ev.obj == "WIP") then
    local cnt = tonumber(ev.cnt) or 0
    if cnt ~= 0 then
      if ev.kind == "GIVE" then
        virtual_add(ev.obj, ev.item,  cnt, ev.qual)
      elseif ev.kind == "TAKE" then
        virtual_add(ev.obj, ev.item, -cnt, ev.qual)
      end
    end
  end

  -- advance ringbuffer pointers (O(1), no table shifting)
  if size < max then
    storage.tx_size = size + 1
  else
    -- buffer full: overwrite oldest, so oldest pointer advances
    local head = storage.tx_head or 1
    storage.tx_head = (head % max) + 1
  end

  storage.tx_write = (w % max) + 1

  -- If TX GUI is open, mark it dirty so it refreshes (LIVE mode follows tail).
  if Transaction.tx_mark_dirty_for_open_guis then
    Transaction.tx_mark_dirty_for_open_guis()
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
--   WIP  : Work in progress     [active boundary inserter in WIP mode]
-- -----------------------------------------

local OBJ_TRANSIT = "T00"
local OBJ_SHIP    = "SHIP"
local OBJ_RECV    = "RECV"
local OBJ_WIP     = "WIP"
local OBJ_MAN     = "MAN"

-- Player inventory pseudo objects
local function fmt_player_inv_id_from_hand_id(hand_id)
  if type(hand_id) ~= "string" then return nil end
  return (hand_id:gsub("^H", "P"))
end

-- Resolve BigBrother source/target to ledger object id
local function obj_id_for_manual_location(loc, player_index)
  if not loc then return OBJ_TRANSIT end

  -- Player inventory
  if type(loc.type) == "string" then
    local t = string.lower(loc.type)
    if string.find(t, "inventory", 1, true) or t == "player" then
      local hand = storage.tx_hand_by_player_index and storage.tx_hand_by_player_index[player_index] or nil
      local pid = hand and fmt_player_inv_id_from_hand_id(hand.id) or nil
      return pid or OBJ_TRANSIT
    end
  end

  -- Entity by unit_number (BigBrother provides id)
  local unit = tonumber(loc.id)
  if unit and storage.tx_obj_by_unit and storage.tx_obj_by_unit[unit] then
    return storage.tx_obj_by_unit[unit]
  end

	-- Manual crafting / Make / handwork location (treat as MAN instead of Transit)
	if type(loc.type) == "string" then
	  local t = string.lower(loc.type)
	  local slot = type(loc.slot_name) == "string" and string.lower(loc.slot_name) or ""

	  if string.find(t, "craft", 1, true)
		or string.find(t, "make", 1, true)
		or string.find(t, "manual", 1, true)
		or string.find(t, "hand", 1, true)
		or string.find(slot, "craft", 1, true)
		or string.find(slot, "make", 1, true)
	  then
		return OBJ_MAN
	  end
	end


  return OBJ_TRANSIT
end

-- Public: ingest manual player logistics events provided by "Big Brother"
-- le schema (as provided by control.lua):
--   le.action: "TAKE" | "GIVE"
--   le.tick
--   le.actor.player_index (or le.actor.id)
--   le.item.name, le.item.quantity, optional le.item.quality
--   le.source_or_target: {type=..., id=..., slot_name=...}
function Transaction.ingest_manual_logistics_event(le)
  ensure_defaults()
  if not le then return end

  -- Rebuild hands in case players changed (cheap)
  if Transaction.rebuild_hand_list then
    Transaction.rebuild_hand_list()
  end

  local actor = le.actor or {}
  local player_index = actor.player_index or actor.player or actor.id
  player_index = tonumber(player_index)

  local hand = (player_index and storage.tx_hand_by_player_index and storage.tx_hand_by_player_index[player_index]) or nil
  local ins_id = hand and hand.id or "H00"

  local tick = tonumber(le.tick) or game.tick
  local kind = le.action
  if kind ~= "TAKE" and kind ~= "GIVE" then return end

  local item = le.item or {}
  local name = item.name
  local qty = tonumber(item.quantity) or tonumber(item.count) or 0
  if not name or qty == 0 then return end

  local qual = item.quality or "normal"
  local loc = le.source_or_target
  local obj = obj_id_for_manual_location(loc, player_index)
  local obj_unit = tonumber(loc and loc.id) or nil

  push_event({
    tick = tick,
    ins_id = ins_id,
    ins_unit = nil,
    kind = kind,
    obj = obj,
    obj_unit = obj_unit,
    item = name,
    cnt = qty,
    qual = qual
  })
end

local function opposite_obj(ins_unit, src_obj, dst_obj)
  local is_active = Transaction.is_inserter_active and Transaction.is_inserter_active(ins_unit)

  if is_active then
    -- NEW: WIP mode overrides interface postings (still boundary)
    if storage.tx_wip_inserters and storage.tx_wip_inserters[ins_unit] == true then
      return OBJ_WIP
    end

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

-- -----------------------------------------
-- Player hands (pseudo-inserters)
--   H01, H02, ... for all players
-- -----------------------------------------

local function fmt_hand_id(n)
  return string.format("H%02d", tonumber(n) or 0)
end

function Transaction.rebuild_hand_list()
  ensure_defaults()

  local by_player = {}
  local list = {}

  local n = 1
  -- Deterministic: iterate by numeric index (game.players is a LuaCustomTable userdata; ipairs() won't work)
  for i = 1, #game.players do
    local p = game.players[i]
    if p and p.valid then
      local rec = {
        id = fmt_hand_id(n),
        kind = "hand",
        player_index = p.index,
        name = p.name
      }
      by_player[p.index] = rec
      list[#list+1] = rec
      n = n + 1
    end
  end

  storage.tx_hand_by_player_index = by_player
  storage.tx_hand_list = list
end

function Transaction.rebuild_inserter_list()
  ensure_defaults()

  -- Always refresh hands first (players can join/leave anytime)
  Transaction.rebuild_hand_list()

  local list = {}

  -- Hands at the beginning
  for _, h in ipairs(storage.tx_hand_list or {}) do
    list[#list+1] = h
  end

  -- Then watched inserters
  local units = {}
  for ins_unit, _ in pairs(storage.tx_watch or {}) do
    units[#units+1] = ins_unit
  end

  table.sort(units, function(a, b)
    -- Prefer stable inserter IDs (Ixx) if known, otherwise fallback to unit_number
    local ra = storage.tx_inserter_by_unit and storage.tx_inserter_by_unit[a] or nil
    local rb = storage.tx_inserter_by_unit and storage.tx_inserter_by_unit[b] or nil
    local ida = ra and ra.id or nil
    local idb = rb and rb.id or nil

    if ida and idb then return tostring(ida) < tostring(idb) end
    if ida and not idb then return true end
    if not ida and idb then return false end
    return tonumber(a) < tonumber(b)
  end)

  for _, ins_unit in ipairs(units) do
    local rec = get_or_create_inserter_rec(ins_unit)
    list[#list+1] = {
      id = rec.id,
      kind = "inserter",
      ins_unit = ins_unit
    }
  end

  storage.tx_inserter_list = list
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
      local WIP_COLOR = Config.TX_MARK_WIP_COLOR or { r=0, g=1, b=0, a=1 }
      local col = Config.TX_MARK_COLOR
      if active[ins_unit] then
        if storage.tx_wip_inserters and storage.tx_wip_inserters[ins_unit] == true then
          col = WIP_COLOR
        else
          col = ACTIVE_COLOR
        end
      end
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
    else
      -- update boundary cache if already watched
      local m = storage.tx_watch_meta[ins.unit_number]
      if m then
        m.boundary = boundary
      end
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

  -- NEW HARD RULE #3: WIP must not survive if no longer watched
  if storage.tx_wip_inserters then
    for ins_unit, _ in pairs(storage.tx_wip_inserters) do
      if not watch[ins_unit] then
        storage.tx_wip_inserters[ins_unit] = nil
      end
    end
  end

  -- NEW HARD RULE #4: WIP must not survive if no longer boundary
  if storage.tx_wip_inserters then
    for ins_unit, _ in pairs(storage.tx_wip_inserters) do
      if watch[ins_unit] then
        if not Transaction.is_boundary_inserter(ins_unit) then
          storage.tx_wip_inserters[ins_unit] = nil
        end
      end
    end
  end

  -- NEW: build combined inserter list (hands first, then watched inserters)
  -- Minimal: just makes Hxx available wherever we iterate inserter lists.
  Transaction.rebuild_inserter_list()

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

        -- NEW: clear WIP flag too
        if storage.tx_wip_inserters then
          storage.tx_wip_inserters[ins_unit] = nil
        end
      end
    end
  end
end

-- -----------------------------------------
-- TX Viewer helpers (for UI text-box paging)
-- -----------------------------------------

-- We intentionally keep the TX viewer "one window per page".
-- The text-box should never contain more lines than fit into the window,
-- so the built-in text-box scroll bar becomes irrelevant.
local TX_WINDOW_LINES = 24  -- measured in UI: exactly 25 lines fit

function Transaction.tx_line_count()
  ensure_defaults()
  tx_rb_ensure()
  return (storage.tx_size or 0)
end

function Transaction.tx_get_event(i)
  ensure_defaults()
  tx_rb_ensure()
  return tx_rb_get_event(i)
end

function Transaction.tx_count()
  ensure_defaults()
  tx_rb_ensure()
  return (storage.tx_size or 0)
end

function Transaction.tx_get_line(i, surface)
  ensure_defaults()
  tx_rb_ensure()

  local ev = tx_rb_get_event(i)
  if not ev then return "" end

  local tick = tonumber(ev.tick) or 0
  local ts = Util.to_excel_datetime(tick, surface)

  local item_str = fmt_item_key(ev.item)

  local kind = tostring(ev.kind or "?")
  local raw = tonumber(ev.cnt) or 0
  local cnt_num = math.abs(raw)
  if kind == "TAKE" then cnt_num = -cnt_num end

  local qual = qual_name(ev.qual)

  local base = string.format(
    "%d;ts=%s;tick=%d;ins=%s;act=%s;obj=%s;item=%s;cnt=%d",
    tonumber(ev.id) or tonumber(i) or 0,
    ts,
    tick,
    tostring(ev.ins_id or "?"),
    kind,
    tostring(ev.obj or "?"),
    tostring(item_str or "?"),
    cnt_num
  )

  -- Only include quality if it's not normal
  if qual ~= "normal" then
    return base .. ";qual=" .. qual
  end

  return base
end

local function tx_count()
  tx_rb_ensure()
  return (storage.tx_size or 0)
end

local function tx_get_filters_from_ui(player)
  -- No persistence: UI is the source of truth.
  -- Defaults match UI defaults when the dialog opens.
  local f = { inbound=true, outbound=true, transit=true, wip=true, other=false, manual=true }

  if not (player and player.valid) then return f end
  local frame = player.gui.screen[Config.GUI_TX_FRAME]
  if not (frame and frame.valid) then return f end
  local top = frame["logsim_tx_toolbar"]
  if not (top and top.valid) then return f end

  local function read_chk(name, default)
    local e = top[name]
    if e and e.valid and e.type == "checkbox" then
      return e.state == true
    end
    return default
  end

  f.inbound  = read_chk("logsim_tx_chk_inbound",  true)
  f.outbound = read_chk("logsim_tx_chk_outbound", true)
  f.transit  = read_chk("logsim_tx_chk_transit",  true)
  f.wip      = read_chk("logsim_tx_chk_wip",      true)
  f.other    = read_chk("logsim_tx_chk_other",    false)
  f.manual   = read_chk("logsim_tx_chk_manual",   true)

  return f
end

local function tx_is_manual_event(ev)
  local ins = ev and ev.ins_id or nil
  if type(ins) ~= "string" then return false end
  -- H01/H02/... are player hands; H00 is unknown hand fallback
  return ins:sub(1,1) == "H"
end

local function tx_event_class(ev)
  local obj = ev and ev.obj or nil
  if obj == OBJ_RECV then return "inbound" end
  if obj == OBJ_SHIP then return "outbound" end
  if obj == OBJ_TRANSIT then return "transit" end
  if obj == OBJ_WIP then return "wip" end
  return "other"
end

-- Build exactly one visible window (TX_WINDOW_LINES) starting from a raw event index.
-- We scan forward and only emit lines that pass the UI filters.
-- Returns: text, effective_end_idx
local function tx_get_text_window_filtered(player, start_idx, surface)
  local n = tx_count()
  if n == 0 then return "", 0 end

  start_idx = math.max(1, math.min(start_idx or 1, n))

  local flt = tx_get_filters_from_ui(player)
  local lines = {}
  local i = start_idx
  local last_scanned = start_idx - 1

  while i <= n and #lines < TX_WINDOW_LINES do
    local ev = tx_rb_get_event(i)
    if ev then
      -- Manual filter is orthogonal to the buffer/account class filters.
      -- If an event is manual (player hand Hxx), it is shown iff the manual
      -- checkbox is enabled, independent of inbound/outbound/transit/wip/other.
      if tx_is_manual_event(ev) then
        if flt.manual then
          lines[#lines + 1] = Transaction.tx_get_line(i, surface)
        end
      else
        local cls = tx_event_class(ev)
        if flt[cls] then
          lines[#lines + 1] = Transaction.tx_get_line(i, surface)
        end
      end
    end
    last_scanned = i
    i = i + 1
  end

  return table.concat(lines, "\n"), last_scanned
end

local function tx_tail_window()
  local n = tx_count()
  if n == 0 then return 1, 0 end
  local e = n
  local s = math.max(1, e - (TX_WINDOW_LINES - 1))
  return s, e
end

function Transaction.tx_ensure_view(player_index)
  ensure_defaults()
  storage.tx_view = storage.tx_view or {}

  local view = storage.tx_view[player_index]
  if not view then
    local s, e = tx_tail_window()
    view = {
      start_idx = s,
      end_idx   = e,
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

  local surface = player.surface
  local view = Transaction.tx_ensure_view(player.index)

  -- If view is uninitialized or drifted beyond range, snap to tail.
  local n = tx_count()
  if n == 0 then
    view.start_idx, view.end_idx = 1, 0
  else
    if not view.end_idx or view.end_idx > n or not view.start_idx then
      view.start_idx, view.end_idx = tx_tail_window()
    end
  end

  local need_text =
    force_text_redraw
    or view.last_start ~= view.start_idx
    or view.last_end   ~= view.end_idx

  if need_text then
    local text, eff_end = tx_get_text_window_filtered(player, view.start_idx, surface)
    view.end_idx = eff_end or view.end_idx

    local ok = pcall(function()
      if box and box.valid then
        box.text = text
      end
    end)

    if not ok then
      if storage.tx_gui_dirty then storage.tx_gui_dirty[player.index] = false end
      return
    end

    view.last_start = view.start_idx
    view.last_end   = view.end_idx
  end
end

-- Paging controls

function Transaction.tx_home(player)
  if not (player and player.valid) then return end
  ensure_defaults()

  local n = tx_count()
  local view = Transaction.tx_ensure_view(player.index)

  if n == 0 then
    view.start_idx, view.end_idx = 1, 0
  else
    local s = 1
    local e = math.min(n, TX_WINDOW_LINES)
    view.start_idx, view.end_idx = s, e
  end

  Transaction.tx_refresh_for_player(player, true)
end

function Transaction.tx_end(player)
  -- Alias: end == tail
  Transaction.tx_tail(player)
end

function Transaction.tx_tail(player)
  if not (player and player.valid) then return end
  ensure_defaults()

  local view = Transaction.tx_ensure_view(player.index)
  view.start_idx, view.end_idx = tx_tail_window()

  Transaction.tx_refresh_for_player(player, true)
end

function Transaction.tx_page_older(player)
  if not (player and player.valid) then return end
  ensure_defaults()

  local n = tx_count()
  if n == 0 then
    Transaction.tx_refresh_for_player(player, true)
    return
  end

  local view = Transaction.tx_ensure_view(player.index)

  local new_end = math.max(1, (view.start_idx or 1) - 1)
  local new_start = math.max(1, new_end - (TX_WINDOW_LINES - 1))

  view.start_idx, view.end_idx = new_start, new_end
  Transaction.tx_refresh_for_player(player, true)
end

function Transaction.tx_page_newer(player)
  if not (player and player.valid) then return end
  ensure_defaults()

  local n = tx_count()
  if n == 0 then
    Transaction.tx_refresh_for_player(player, true)
    return
  end

  local view = Transaction.tx_ensure_view(player.index)

  local new_start = math.min(n, (view.end_idx or 0) + 1)
  local new_end = math.min(n, new_start + (TX_WINDOW_LINES - 1))

  view.start_idx, view.end_idx = new_start, new_end
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
  storage.tx_virtual = { T00 = {}, SHIP = {}, RECV = {}, WIP = {} }

  -- NEW: clear WIP mode flags
  storage.tx_wip_inserters = {}

  -- Ringbuffer state reset (keep configured max, reset pointers + ids)
  storage.tx_head = 1
  storage.tx_write = 1
  storage.tx_size = 0
  storage.tx_seq = 0

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

function Transaction.tx_tick_refresh_open_guis()
  ensure_defaults()
  local any = false
  for _, v in pairs(storage.tx_gui_dirty or {}) do
    if v then any = true; break end
  end
  if not any then return end
  for _, player in pairs(game.connected_players) do
    if storage.tx_gui_dirty[player.index] then
      Transaction.tx_refresh_for_player(player, false)
      storage.tx_gui_dirty[player.index] = false
    end
  end
end

return Transaction
