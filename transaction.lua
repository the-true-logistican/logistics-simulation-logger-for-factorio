-- =========================================
-- LogSim (Factorio 2.0)
-- Transaction Module
--
-- Goal:
--   Build a transaction list based on inserter hand movements.
--   Each physical move is represented as TWO postings:
--     1) TAKE (source decreases)
--     2) GIVE (destination increases)
--     3) OBJ_TRANSIT = "T00"   internal transit
--     4) OBJ_SHIP    = "SHIP"  outbound shipping
--     5) OBJ_RECV    = "RECV"  inbound receive 
--     6) OBJ_WIP     = "WIP"   work in progress
--     7) OBJ_MAN     = "MAN"   manual crafting
--
-- Rules (Martin):
--   - Full inventory snapshots remain as anchors (handled elsewhere)
--   - Between snapshots, record SAP-like postings
--   - Only *registered* objects matter (Cxx, Txx, Mxx)
--   - Inserters are NOT manually registered; they get an auto ID (Ixx)
--   - For now: no file export; events stay in memory
--   - Automatically mark participating inserters in yellow with text Ixx.
--   - Allow explicitly marking watched boundary inserters as active.
--   - Active boundary inserters represent Shipping/Receiving interfaces.
--
-- version 0.8.0 first complete working version
-- version 0.8.1 tx window with buttons <<  <  >  >> 
--               corrected item quantities in transactions from/to belts
--               simple filter for transactions with checkboxes
--               ring buffer M.TX_MAX_EVENTS load/save secure
-- Version 0.8.2 get global parameters from settings
-- Version 0.8.3 WIP virtual account + Shift-R toggle normal/WIP/OFF (minimal additions)
-- Version 0.8.4 transactions with the "hand" of the player
--               crafting in virtual inventory MAN
-- Version 0.8.5 Setup Parameters corrected
-- Version 0.8.6 Transition: filled -> filled, same item/quality, changed count
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.3 rebuild_watchlist updates wagon positions before every scan
-- Version 0.9.2 TAKE from WIP uses BOM to relieve the WIP inventory
--               TAKE from T00 (transit) is now a post-deduct inventory transaction
--               GIVE to T00 is now an assumption-based posting
--               registering chests is now transitive to machines to avoid implicit WIP
-- Version 0.9.3 resolve_entity_at finds now blocked inserter
--               transaction_refactored no change in funtionality
--
-- =========================================

local Config = require("config")
local UI     = require("ui")
local Chests = require("chests")
local Util   = require("utility")  -- fly() lives here

local Transaction = {}
Transaction.version = "0.9.3"

-- Forward declarations required by ensure_defaults().
local tx_rb_ensure
local tx_rb_resize

-- -----------------------------------------
-- Defaults / Storage
-- -----------------------------------------

local function ensure_defaults()
  Config.ensure_storage_defaults(storage)

  -- WIP mode is stored separately to preserve the existing active-inserter structure.
  storage.tx_wip_inserters = storage.tx_wip_inserters or {}

  -- Migration-safe virtual account initialization.
  storage.tx_virtual = storage.tx_virtual or { T00 = {}, SHIP = {}, RECV = {}, WIP = {}, MAN = {} }
  -- Older saves may lack WIP or MAN buckets.
  storage.tx_virtual.WIP = storage.tx_virtual.WIP or {}
  storage.tx_virtual.MAN = storage.tx_virtual.MAN or {}

  -- Keep TX ringbuffer settings in sync with config/settings across save/load.
  tx_rb_ensure()

  -- Player hands are pseudo-inserters (H01, H02, ...).
  -- The list format matches watched inserters for ledger display logic.
  storage.tx_hand_by_player_index = storage.tx_hand_by_player_index or {}
  storage.tx_hand_list = storage.tx_hand_list or {}
  storage.tx_inserter_list = storage.tx_inserter_list or {}
  storage.tx_manual_pending_takes = storage.tx_manual_pending_takes or {}

  local desired_max =
    tonumber(storage.tx_max_events)
    or Config.get_tx_max_events()

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

  -- Keep the inserter path isolated if the public helpers are unavailable.
  if not (Transaction.set_inserter_active and Transaction.is_watched_inserter) then
    return true
  end

  local unit = ent.unit_number
  local is_active = Transaction.is_inserter_active and Transaction.is_inserter_active(unit)
  local is_wip = storage.tx_wip_inserters and storage.tx_wip_inserters[unit] == true

  -- Boundary validation is enforced by set_inserter_active().
  -- Repeated SHIFT+R toggles normal active mode and WIP mode.
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
    -- Only watched inserters can become explicit boundary interfaces.
    if not (storage.tx_watch and storage.tx_watch[ins_unit] == true) then
      return false, "not_watched"
    end

    -- Boundary interfaces require exactly one registered side.
    if not Transaction.is_boundary_inserter(ins_unit) then
      storage.tx_active_inserters[ins_unit] = nil
      Transaction.update_marks()
      return false, "not_boundary"
    end

    storage.tx_active_inserters[ins_unit] = true
    Transaction.update_marks()
    return true
  end

  -- Deactivation also clears WIP mode.
  storage.tx_active_inserters[ins_unit] = nil

  -- WIP mode must not survive deactivation.
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
  -- Factorio 2.x may return a LuaQualityPrototype.
  if type(q) == "table" and q.name then return q.name end
  -- Userdata-style objects are read via pcall to avoid runtime errors.
  local ok, n = pcall(function() return q.name end)
  if ok and n then return n end
  return tostring(q)
end

-- Item key formatter: include quality only if it's not "normal"
local function fmt_item_key(k)
  if not k then return "" end

  -- Inventory keys may be strings or Factorio 2.x item-with-quality tables.
  if type(k) == "string" then
    -- Some code paths may already encode quality as "name@quality".
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

  -- Do not clamp balances; negative values are accounting signals.
  if new == 0 then
    buf[key] = nil
  else
    buf[key] = new
  end
end

-- -----------------------------------------
-- WIP retrograde consumption
--
-- TAKE from WIP is treated as production output. The output item itself is
-- never consumed from WIP, because externally supplied or separately produced
-- output stock must remain untouched. Instead, the output is resolved one
-- recipe level down and the direct ingredients are consumed from the highest
-- available WIP stage first. Only uncovered remainders are recursively
-- resolved further.
-- -----------------------------------------

local function recipe_product_amount(recipe_proto, product_name)
  if not (recipe_proto and product_name) then return nil end

  for _, product in pairs(recipe_proto.products or {}) do
    if product and product.name == product_name then
      local amount = tonumber(product.amount)
      if amount and amount > 0 then return amount end

      local amount_min = tonumber(product.amount_min)
      local amount_max = tonumber(product.amount_max)
      if amount_min and amount_max and amount_min > 0 and amount_max > 0 then
        return (amount_min + amount_max) / 2
      end

      return 1
    end
  end

  if recipe_proto.main_product and recipe_proto.main_product.name == product_name then
    return 1
  end

  return nil
end

local function find_recipe_for_product_one_level(product_name, force)
  if not product_name then return nil, nil end
  force = force or game.forces.player

  for recipe_name, recipe_proto in pairs(prototypes.recipe or {}) do
    local enabled = true
    if force and force.valid and force.recipes then
      local force_recipe = force.recipes[recipe_name]
      enabled = force_recipe and force_recipe.enabled == true
    end

    if enabled then
      local out_amount = recipe_product_amount(recipe_proto, product_name)
      if out_amount and out_amount > 0 then
        return recipe_proto, out_amount
      end
    end
  end

  return nil, nil
end

local function wip_positive_available(item, qual)
  if not (storage.tx_virtual and storage.tx_virtual.WIP) then return 0 end
  local key = vkey(item, qual)
  if not key then return 0 end

  local have = tonumber(storage.tx_virtual.WIP[key]) or 0
  if have <= 0 then return 0 end
  return have
end

local function wip_consume_direct(item, amount, qual)
  amount = tonumber(amount) or 0
  if not item or amount <= 0 then return 0 end

  local have = wip_positive_available(item, qual)
  local take = math.min(have, amount)
  if take > 0 then
    virtual_add("WIP", item, -take, qual)
  end

  return amount - take
end

local consume_wip_input

local function retrograde_ingredients_from_recipe(recipe_proto, out_amount, requested_amount, force, depth, visited)
  if not (recipe_proto and out_amount and out_amount > 0) then return false end

  local factor = (tonumber(requested_amount) or 0) / out_amount
  if factor <= 0 then return true end

  for _, ingredient in pairs(recipe_proto.ingredients or {}) do
    local ing_name = ingredient and ingredient.name
    local ing_amount = tonumber(ingredient and ingredient.amount) or 0

    if ing_name and ing_amount > 0 then
      consume_wip_input(ing_name, ing_amount * factor, "normal", force, depth + 1, visited)
    end
  end

  return true
end

consume_wip_input = function(item, amount, qual, force, depth, visited)
  amount = tonumber(amount) or 0
  if not item or amount <= 0 then return end

  depth = tonumber(depth) or 0
  local max_depth = tonumber(Config.COLLECT_DEPENDENC_DEPTH) or 30
  if depth > max_depth then
    virtual_add("WIP", item, -amount, qual)
    return
  end

  -- Inputs are allowed to consume their own WIP stock first.
  local rest = wip_consume_direct(item, amount, qual)
  if rest <= 0 then return end

  visited = visited or {}
  if visited[item] then
    virtual_add("WIP", item, -rest, qual)
    return
  end

  local next_visited = {}
  for k, v in pairs(visited) do next_visited[k] = v end
  next_visited[item] = true

  local recipe_proto, out_amount = find_recipe_for_product_one_level(item, force)
  if not recipe_proto then
    virtual_add("WIP", item, -rest, qual)
    return
  end

  retrograde_ingredients_from_recipe(recipe_proto, out_amount, rest, force, depth, next_visited)
end

local function retrograde_take_product_from_wip(product, amount, qual, force)
  amount = tonumber(amount) or 0
  if not product or amount <= 0 then return false end

  local recipe_proto, out_amount = find_recipe_for_product_one_level(product, force)
  if not recipe_proto then
    -- No recipe means the output cannot be explained; keep the residual visible.
    virtual_add("WIP", product, -amount, qual)
    return false
  end

  -- Critical rule: do NOT consume product itself from WIP here. TAKE WIP product
  -- represents an output leaving WIP; only its ingredients may be relieved.
  retrograde_ingredients_from_recipe(recipe_proto, out_amount, amount, force, 0, { [product] = true })
  return true
end

tx_rb_ensure = function()
  -- Ring buffer state: O(1) push and O(1) logical access.
  storage.tx_events = storage.tx_events or {}

  -- Maximum event count is runtime-configurable.
  storage.tx_max_events = storage.tx_max_events or Config.get_tx_max_events()

  -- _tx_rb_initialized is the single explicit migration sentinel.
  -- It is intentionally NOT set in config.lua ensure_storage_defaults;
  -- only this function may set it to true.
  -- Old saves and brand-new saves both go through this block once,
  -- regardless of which individual fields already exist.
  if not storage._tx_rb_initialized then
    local t = storage.tx_events
    local n = #t

    storage.tx_head  = 1
    storage.tx_write = n + 1
    storage.tx_size  = n

    -- Keep the write index inside the configured buffer range.
    local max = storage.tx_max_events
    if n > max then
      -- Migration keeps the newest events without repeated table shifting.
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

    storage._tx_rb_initialized = true
  end

  -- Normalize persisted ring-buffer fields.
  storage.tx_seq  = storage.tx_seq  or 0
  storage.tx_head = storage.tx_head or 1
  storage.tx_size = storage.tx_size or 0
  storage.tx_write = storage.tx_write or 1

  -- Clamp persisted indices into the configured bounds.
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
    local start_logical = old_size - keep + 1
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
  local max = storage.tx_max_events or Config.get_tx_max_events()
  local head = storage.tx_head or 1
  local phys = ((head + (i - 1) - 1) % max) + 1
  return storage.tx_events and storage.tx_events[phys] or nil
end

local function push_event(ev)
  tx_rb_ensure()

  -- Use monotonic IDs; ring-buffer indices are not stable identifiers.
  storage.tx_seq = (storage.tx_seq or 0) + 1
  ev.id = storage.tx_seq

  local t   = storage.tx_events
  local max = storage.tx_max_events or Config.get_tx_max_events()
  local w   = storage.tx_write or 1
  local size = storage.tx_size or 0

  t[w] = ev

  -- Update running balances for virtual buffers.
  if ev and (ev.obj == "T00" or ev.obj == "SHIP" or ev.obj == "RECV"
             or ev.obj == "WIP" or ev.obj == "MAN") then
    local cnt = tonumber(ev.cnt) or 0
    if cnt ~= 0 then
      if ev.kind == "GIVE" then
        virtual_add(ev.obj, ev.item,  cnt, ev.qual)
      elseif ev.kind == "TAKE" then
        if ev.obj == "WIP" then
          retrograde_take_product_from_wip(ev.item, cnt, ev.qual, game.forces.player)
        else
          virtual_add(ev.obj, ev.item, -cnt, ev.qual)
        end
      end
    end
  end

  -- Advance ring-buffer pointers without table shifting.
  if size < max then
    storage.tx_size = size + 1
  else
    -- Full buffer overwrites the oldest event.
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

  -- 1) Prefer already registered LogSim endpoints.
  -- This is the robust path for inserters with a non-empty hand:
  -- pickup_target/drop_target may be temporarily unavailable or unstable,
  -- but pickup_position/drop_position still identify the logistics side.
  local found = surface.find_entities_filtered{
    area = area
  } or {}

  for _, e in pairs(found) do
    if e
       and e.valid
       and e.unit_number
       and storage.tx_obj_by_unit
       and storage.tx_obj_by_unit[e.unit_number] then
      return e
    end
  end

  -- 2) Then known registerable inventory/fluid endpoints.
  -- Includes wagons explicitly; they were missing from the old fallback.
  found = surface.find_entities_filtered{
    area = area,
    type = {
      "container",
      "logistic-container",
      "storage-tank",
      "cargo-wagon",
      "fluid-wagon"
    },
    limit = 1
  }
  if found and found[1] then return found[1] end

  -- 3) Then common machines.
  -- Keep this path for transitive machine registration.
  found = surface.find_entities_filtered{
    area = area,
    type = {
      "assembling-machine",
      "furnace",
      "lab",
      "mining-drill",
      "rocket-silo"
    },
    limit = 1
  }
  if found and found[1] then return found[1] end

  -- 4) No generic "any entity" fallback here.
  -- Returning belts/rails/inserters is more harmful than returning nil.
  return nil
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

local function unknown_source_obj(ins_unit, src_obj, dst_obj)
  local is_active = Transaction.is_inserter_active and Transaction.is_inserter_active(ins_unit)

  if is_active then
    -- WIP mode overrides normal interface classification.
    if storage.tx_wip_inserters and storage.tx_wip_inserters[ins_unit] == true then
      return OBJ_WIP
    end

    -- Unknown source + registered destination = inbound interface.
    local meta = storage.tx_watch_meta and storage.tx_watch_meta[ins_unit]
    local b = meta and meta.boundary or nil
    if b == "recv" then return OBJ_RECV end

    if (not src_obj) and dst_obj then
      return OBJ_RECV
    end
  end

  return OBJ_TRANSIT
end

local function unknown_destination_obj(ins_unit, src_obj, dst_obj)
  local is_active = Transaction.is_inserter_active and Transaction.is_inserter_active(ins_unit)

  if is_active then
    -- WIP mode overrides normal interface classification.
    if storage.tx_wip_inserters and storage.tx_wip_inserters[ins_unit] == true then
      return OBJ_WIP
    end

    -- Registered source + unknown destination = outbound interface.
    local meta = storage.tx_watch_meta and storage.tx_watch_meta[ins_unit]
    local b = meta and meta.boundary or nil
    if b == "ship" then return OBJ_SHIP end

    if src_obj and (not dst_obj) then
      return OBJ_SHIP
    end
  end

  return OBJ_TRANSIT
end

-- -----------------------------------------
-- Deferred transit TAKE
--
-- If an inserter takes from an unregistered source, we do not book TAKE T00
-- immediately. Belt/source detection is not stable enough for accounting.
-- Instead, remember the amount in the inserter record and book TAKE T00
-- retroactively when the corresponding GIVE is observed.
-- -----------------------------------------

local function defer_transit_take(ins_rec, item, cnt, qual)
  cnt = tonumber(cnt) or 0
  if not ins_rec or not item or cnt <= 0 then return end

  qual = qual or "normal"
  local key = vkey(item, qual)
  if not key then return end

  ins_rec.deferred_transit_take = ins_rec.deferred_transit_take or {}

  local rec = ins_rec.deferred_transit_take[key]
  if not rec then
    rec = {
      item = item,
      qual = qual,
      cnt = 0
    }
    ins_rec.deferred_transit_take[key] = rec
  end

  rec.cnt = (tonumber(rec.cnt) or 0) + cnt
end

local function flush_deferred_transit_take(ins_rec, tick, ins_unit, item, cnt, qual)
  cnt = tonumber(cnt) or 0
  if not ins_rec or not item or cnt <= 0 then return 0 end

  qual = qual or "normal"
  local key = vkey(item, qual)
  if not key then return 0 end

  local pending_map = ins_rec.deferred_transit_take
  local pending = pending_map and pending_map[key]
  local available = pending and tonumber(pending.cnt) or 0

  -- No deferred unknown-source pickup exists for this item/quality.
  -- Therefore do not create a retrograde T00 clearing entry.
  if available <= 0 then
    return 0
  end

  -- Important:
  -- Use the confirmed GIVE quantity, not the previously observed pickup quantity.
  -- The pickup-side count is exactly the unstable part for belt interactions.
  local booked = cnt

  push_event({
    tick = tick,
    ins_id = ins_rec.id,
    ins_unit = ins_unit,
    kind = "TAKE",
    obj = OBJ_TRANSIT,
    obj_unit = nil,
    item = item,
    cnt = booked,
    qual = qual
  })

  -- The pending amount is only a marker/buffer, not a hard accounting limit.
  -- If GIVE exceeds the observed pickup amount, clear the marker.
  -- If only part of the pending amount was given, keep the remainder.
  pending.cnt = available - booked
  if pending.cnt <= 0 then
    pending_map[key] = nil
  end

  return booked
end


local fmt_player_inv_id_from_hand_id

-- -----------------------------------------
-- Manual player-inventory retrograde resolution
--
-- Big Brother may report a GIVE into a player inventory without a matching
-- TAKE. This can happen when another helper module creates material directly.
-- In that case the created product is explained by consuming its recipe inputs
-- from the same player inventory, using the same retrograde rule as WIP.
-- -----------------------------------------

local function is_player_inventory_obj(obj)
  return type(obj) == "string" and obj:match("^P%d+$") ~= nil
end

local function manual_pending_key(ins_id, item, qual)
  local key = vkey(item, qual or "normal")
  if not key then return nil end
  return tostring(ins_id or "H00") .. "|" .. key
end

local function cleanup_manual_pending_takes(tick)
  local pending = storage.tx_manual_pending_takes
  if not pending then return end

  local now = tonumber(tick) or game.tick
  local max_age = 600

  for key, rec in pairs(pending) do
    local rec_tick = tonumber(rec and rec.tick) or 0
    if now - rec_tick > max_age then
      pending[key] = nil
    end
  end
end

local function remember_manual_take(ins_id, item, amount, qual, tick)
  amount = tonumber(amount) or 0
  if not item or amount <= 0 then return end

  storage.tx_manual_pending_takes = storage.tx_manual_pending_takes or {}
  cleanup_manual_pending_takes(tick)

  local key = manual_pending_key(ins_id, item, qual)
  if not key then return end

  local rec = storage.tx_manual_pending_takes[key]
  if not rec then
    rec = { item = item, qual = qual or "normal", count = 0, tick = tick or game.tick }
    storage.tx_manual_pending_takes[key] = rec
  end

  rec.count = (tonumber(rec.count) or 0) + amount
  rec.tick = tick or game.tick
end

local function consume_matching_manual_take(ins_id, item, amount, qual, tick)
  amount = tonumber(amount) or 0
  if not item or amount <= 0 then return amount end

  storage.tx_manual_pending_takes = storage.tx_manual_pending_takes or {}
  cleanup_manual_pending_takes(tick)

  local key = manual_pending_key(ins_id, item, qual)
  if not key then return amount end

  local rec = storage.tx_manual_pending_takes[key]
  local available = tonumber(rec and rec.count) or 0
  if available <= 0 then return amount end

  local matched = math.min(available, amount)
  rec.count = available - matched

  if rec.count <= 0 then
    storage.tx_manual_pending_takes[key] = nil
  else
    rec.tick = tick or game.tick
  end

  return amount - matched
end

local function player_by_inventory_obj(obj)
  if not is_player_inventory_obj(obj) then return nil end

  for _, hand in ipairs(storage.tx_hand_list or {}) do
    if hand and hand.id and fmt_player_inv_id_from_hand_id(hand.id) == obj then
      return game.get_player(hand.player_index)
    end
  end

  local n = tonumber(obj:match("^P(%d+)$"))
  if not n then return nil end

  local i = 1
  for _, player in pairs(game.players) do
    if player and player.valid then
      if i == n then return player end
      i = i + 1
    end
  end

  return nil
end

local function read_player_inventory_availability(player)
  local available = {}
  if not (player and player.valid) then return available end

  local inv_ids = {
    defines.inventory.character_main,
    defines.inventory.character_trash
  }

  for _, inv_id in ipairs(inv_ids) do
    local inv = player.get_inventory(inv_id)
    if inv and inv.valid then
      local contents = inv.get_contents()
      if contents then
        for k, v in pairs(contents) do
          local item_name, count, qual

          if type(k) == "number" and type(v) == "table" then
            item_name = v.name or v.item
            qual = qual_name(v.quality or v.quality_name)
            count = tonumber(v.count or v.amount) or 0
          elseif type(k) == "string" then
            item_name = k
            qual = "normal"
            count = type(v) == "number" and v or (type(v) == "table" and (tonumber(v.count or v.amount) or 0) or 0)
          elseif type(k) == "table" then
            item_name = k.name or k.item
            qual = qual_name(k.quality or k.quality_name)
            count = type(v) == "number" and v or (type(v) == "table" and (tonumber(v.count or v.amount) or 0) or 0)
          end

          if item_name and count and count > 0 then
            local key = vkey(item_name, qual or "normal")
            if key then
              available[key] = (available[key] or 0) + count
            end
          end
        end
      end
    end
  end

  local stack = player.cursor_stack
  if stack and stack.valid_for_read and stack.name and stack.count and stack.count > 0 then
    local qual = "normal"
    local okq, q = pcall(function() return stack.quality end)
    if okq and q then qual = qual_name(q) end
    local key = vkey(stack.name, qual)
    if key then
      available[key] = (available[key] or 0) + stack.count
    end
  end

  return available
end

local function player_inventory_consume_direct(ctx, item, amount, qual)
  amount = tonumber(amount) or 0
  if not ctx or not item or amount <= 0 then return amount end

  qual = qual or "normal"
  local key = vkey(item, qual)
  if not key then return amount end

  local have = tonumber(ctx.available[key]) or 0
  local take = math.min(have, amount)

  if take > 0 then
    ctx.available[key] = have - take

    push_event({
      tick = ctx.tick,
      ins_id = ctx.ins_id,
      ins_unit = nil,
      kind = "TAKE",
      obj = ctx.obj,
      obj_unit = nil,
      item = item,
      cnt = take,
      qual = qual
    })
  end

  return amount - take
end

local consume_player_inventory_input

local function retrograde_player_ingredients_from_recipe(ctx, recipe_proto, out_amount, requested_amount, force, depth, visited)
  if not (recipe_proto and out_amount and out_amount > 0) then return false end

  local factor = (tonumber(requested_amount) or 0) / out_amount
  if factor <= 0 then return true end

  for _, ingredient in pairs(recipe_proto.ingredients or {}) do
    local ing_name = ingredient and ingredient.name
    local ing_amount = tonumber(ingredient and ingredient.amount) or 0

    if ing_name and ing_amount > 0 then
      consume_player_inventory_input(ctx, ing_name, ing_amount * factor, "normal", force, depth + 1, visited)
    end
  end

  return true
end

consume_player_inventory_input = function(ctx, item, amount, qual, force, depth, visited)
  amount = tonumber(amount) or 0
  if not ctx or not item or amount <= 0 then return end

  depth = tonumber(depth) or 0
  local max_depth = tonumber(Config.COLLECT_DEPENDENC_DEPTH) or 30
  if depth > max_depth then
    push_event({
      tick = ctx.tick,
      ins_id = ctx.ins_id,
      ins_unit = nil,
      kind = "TAKE",
      obj = ctx.obj,
      obj_unit = nil,
      item = item,
      cnt = amount,
      qual = qual or "normal"
    })
    return
  end

  local rest = player_inventory_consume_direct(ctx, item, amount, qual)
  if rest <= 0 then return end

  visited = visited or {}
  if visited[item] then
    push_event({
      tick = ctx.tick,
      ins_id = ctx.ins_id,
      ins_unit = nil,
      kind = "TAKE",
      obj = ctx.obj,
      obj_unit = nil,
      item = item,
      cnt = rest,
      qual = qual or "normal"
    })
    return
  end

  local next_visited = {}
  for k, v in pairs(visited) do next_visited[k] = v end
  next_visited[item] = true

  local recipe_proto, out_amount = find_recipe_for_product_one_level(item, force)
  if not recipe_proto then
    push_event({
      tick = ctx.tick,
      ins_id = ctx.ins_id,
      ins_unit = nil,
      kind = "TAKE",
      obj = ctx.obj,
      obj_unit = nil,
      item = item,
      cnt = rest,
      qual = qual or "normal"
    })
    return
  end

  retrograde_player_ingredients_from_recipe(ctx, recipe_proto, out_amount, rest, force, depth, next_visited)
end

local function retrograde_give_product_to_player_inventory(ins_id, obj, player, product, amount, qual, tick)
  amount = tonumber(amount) or 0
  if not (is_player_inventory_obj(obj) and player and player.valid and product and amount > 0) then return false end

  local force = player.force or game.forces.player
  local recipe_proto, out_amount = find_recipe_for_product_one_level(product, force)

  local ctx = {
    obj = obj,
    player = player,
    available = read_player_inventory_availability(player),
    tick = tick or game.tick,
    ins_id = ins_id or "H00"
  }

  if not recipe_proto then
    -- No recipe means the created item cannot be explained further.
    -- Book an explicit inventory relief entry for the same item.
    player_inventory_consume_direct(ctx, product, amount, qual)
    return false
  end

  -- Critical rule: do not consume the created product itself here.
  -- Only its inputs may explain the unmatched GIVE into the player inventory.
  retrograde_player_ingredients_from_recipe(ctx, recipe_proto, out_amount, amount, force, 0, { [product] = true })
  return true
end


-- Player inventory pseudo objects
fmt_player_inv_id_from_hand_id = function(hand_id)
  if type(hand_id) ~= "string" then return nil end
  return (hand_id:gsub("^H", "P"))
end

-- Resolve a Big Brother source/target descriptor to a ledger object id.
local function obj_id_for_manual_location(loc, player_index)
  if not loc then return OBJ_TRANSIT end

  -- Player inventories map to pseudo hand objects.
  if type(loc.type) == "string" then
    local t = string.lower(loc.type)
    if string.find(t, "inventory", 1, true) or t == "player" then
      local hand = storage.tx_hand_by_player_index and storage.tx_hand_by_player_index[player_index] or nil
      local pid = hand and fmt_player_inv_id_from_hand_id(hand.id) or nil
      return pid or OBJ_TRANSIT
    end
  end

  -- Entity locations are matched by unit_number.
  local unit = tonumber(loc.id)
  if unit and storage.tx_obj_by_unit and storage.tx_obj_by_unit[unit] then
    return storage.tx_obj_by_unit[unit]
  end

  -- Manual crafting locations use MAN instead of Transit.
  if type(loc.type) == "string" then
    local t = string.lower(loc.type)
    local slot = type(loc.slot_name) == "string" and string.lower(loc.slot_name) or ""

    if string.find(t, "craft", 1, true)
       or string.find(t, "make", 1, true)
       or string.find(t, "manual", 1, true)
       or string.find(t, "hand", 1, true)
       or string.find(slot, "craft", 1, true)
       or string.find(slot, "make", 1, true) then
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

  -- Player membership can change between manual events.
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

  if kind == "TAKE" then
    -- Only non-player sources can explain a later GIVE into the player inventory.
    -- TAKE from Pxx is an outbound movement from the player and must not offset
    -- a future unmatched inventory creation.
    if not is_player_inventory_obj(obj) then
      remember_manual_take(ins_id, name, qty, qual, tick)
    end
    return
  end

  if kind == "GIVE" and is_player_inventory_obj(obj) then
    local unmatched = consume_matching_manual_take(ins_id, name, qty, qual, tick)
    if unmatched > 0 then
      local player = player_by_inventory_obj(obj)
      retrograde_give_product_to_player_inventory(ins_id, obj, player, name, unmatched, qual, tick)
    end
  end
end

local function opposite_obj(ins_unit, src_obj, dst_obj)
  if src_obj and (not dst_obj) then
    return unknown_destination_obj(ins_unit, src_obj, dst_obj)
  end

  if (not src_obj) and dst_obj then
    return unknown_source_obj(ins_unit, src_obj, dst_obj)
  end

  return OBJ_TRANSIT
end

-- Fallback resolver for inserters when direct unit-number lookup is unavailable.
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
  -- game.players is a LuaCustomTable; numeric iteration keeps deterministic hand IDs.
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

  -- Refresh hands first because players can join or leave at any tick.
  Transaction.rebuild_hand_list()

  local list = {}

  -- Hands are displayed before physical inserters.
  for _, h in ipairs(storage.tx_hand_list or {}) do
    list[#list+1] = h
  end

  -- Physical inserters follow hands in stable order.
  local units = {}
  for ins_unit, _ in pairs(storage.tx_watch or {}) do
    units[#units+1] = ins_unit
  end

  table.sort(units, function(a, b)
    -- Prefer stable Ixx ids; fallback to unit_number for new entries.
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

  -- Boundary means exactly one side is registered.
  if (src_obj and not dst_obj) or (not src_obj and dst_obj) then
    return true
  end
  return false
end

-- -----------------------------------------
-- Rendering helpers for legacy mark cleanup.
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
-- Rebuild the map from Factorio unit_number to LogSim object id.
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

function Transaction.autoregister_machine_closure(player, log)
  ensure_defaults()

  if not (Chests and Chests.register_machine_entity and Chests.is_machine_entity) then
    return 0
  end

  local total_added = 0
  local max_passes = 100
  local pass = 0
  local scan_radius = 20

  local function scan_registered_object(rec)
    if not (rec and rec.surface_index and rec.position) then return 0 end

    local surface = game.get_surface(rec.surface_index)
    if not (surface and surface.valid) then return 0 end

    local pos = rec.position
    local area = {
      { pos.x - scan_radius, pos.y - scan_radius },
      { pos.x + scan_radius, pos.y + scan_radius }
    }

    local all = surface.find_entities_filtered{
      area = area,
      type = "inserter"
    } or {}

    local added = 0

    for _, ins in pairs(all) do
      if ins and ins.valid and ins.unit_number then
        local pick, drop = get_targets(ins)

        local src_obj = obj_id_for_entity(pick)
        local dst_obj = obj_id_for_entity(drop)

        -- Registered object feeds an unregistered machine.
        if src_obj and (not dst_obj) and Chests.is_machine_entity(drop) then
          local ok = Chests.register_machine_entity(drop, log, "closure_drop")
          if ok then added = added + 1 end
        end

        -- Unregistered machine feeds a registered object.
        if dst_obj and (not src_obj) and Chests.is_machine_entity(pick) then
          local ok = Chests.register_machine_entity(pick, log, "closure_pick")
          if ok then added = added + 1 end
        end
      end
    end

    return added
  end

  while pass < max_passes do
    pass = pass + 1

    -- Newly registered Mxx objects must be visible before the next scan pass.
    Transaction.rebuild_object_map()

    local added_this_pass = 0

    for _, rec in pairs(storage.registry or {}) do
      added_this_pass = added_this_pass + scan_registered_object(rec)
    end

    for _, rec in pairs(storage.machines or {}) do
      added_this_pass = added_this_pass + scan_registered_object(rec)
    end

    total_added = total_added + added_this_pass

    if added_this_pass == 0 then
      break
    end
  end

  if total_added > 0 then
    Transaction.rebuild_object_map()
    storage.marker_dirty = true

    if player and player.valid then
      Util.info_print(player, {"", "[LogSim] auto machines registered: ", tostring(total_added)})
    end
  end

  return total_added
end

function Transaction.is_machine_required_by_closure(machine_unit)
  ensure_defaults()

  if not machine_unit then return false end

  if not (storage.machines and storage.machines[machine_unit]) then return false end

  -- Current registry state must be reflected in tx_obj_by_unit.
  if Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end

  local scan_radius = 20

  local function scan_registered_object(rec)
    if not (rec and rec.surface_index and rec.position) then return false end

    local surface = game.get_surface(rec.surface_index)
    if not (surface and surface.valid) then return false end

    local pos = rec.position
    local area = {
      { pos.x - scan_radius, pos.y - scan_radius },
      { pos.x + scan_radius, pos.y + scan_radius }
    }

    local all = surface.find_entities_filtered{
      area = area,
      type = "inserter"
    } or {}

    for _, ins in pairs(all) do
      if ins and ins.valid and ins.unit_number then
        local pick, drop = get_targets(ins)

        local src_obj = obj_id_for_entity(pick)
        local dst_obj = obj_id_for_entity(drop)

        -- Registered object feeds exactly this machine.
        -- If this machine were unregistered, input would disappear into Transit
        -- and the later transformed output would reappear from an unknown source.
        if src_obj
           and drop
           and drop.valid
           and drop.unit_number == machine_unit then
          return true
        end

        -- Symmetric case: this machine feeds a registered object.
        -- This keeps the accounting boundary closed in both directions.
        if dst_obj
           and pick
           and pick.valid
           and pick.unit_number == machine_unit then
          return true
        end
      end
    end

    return false
  end

  -- Registered chests/tanks.
  for _, rec in pairs(storage.registry or {}) do
    if scan_registered_object(rec) then
      return true
    end
  end

  -- Registered machines, except the machine currently selected for removal.
  -- A machine must not justify its own protection.
  for unit, rec in pairs(storage.machines or {}) do
    if unit ~= machine_unit then
      if scan_registered_object(rec) then
        return true
      end
    end
  end

  return false
end

function Transaction.rebuild_watchlist()
  ensure_defaults()

  -- Wagon positions are refreshed before scanning so moving wagons use their current location.
  if storage.registry then
    for _, rec in pairs(storage.registry) do
      if rec.kind == "wagon" or rec.kind == "fluid-wagon" then
        local ent = game.get_entity_by_unit_number(rec.unit_number)
        if ent and ent.valid then
          rec.position      = { x = ent.position.x, y = ent.position.y }
          rec.surface_index = ent.surface.index
        end
      end
    end
  end

  local watch = {}
  local r = 20

  local function consider_inserter(ins)
    if not (ins and ins.valid and ins.unit_number) then return false end

    local pick, drop = get_targets(ins)
    local src_obj = obj_id_for_entity(pick)
    local dst_obj = obj_id_for_entity(drop)

    -- Cache boundary direction for robust SHIP/RECV logging.
    local boundary = nil
    if src_obj and (not dst_obj) then
      boundary = "ship"
    elseif (not src_obj) and dst_obj then
      boundary = "recv"
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
      -- Update boundary classification for existing watched inserters.
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

  -- Active mode must not survive if the inserter is no longer watched.
  if storage.tx_active_inserters then
    for ins_unit, _ in pairs(storage.tx_active_inserters) do
      if not watch[ins_unit] then
        storage.tx_active_inserters[ins_unit] = nil
      end
    end
  end

  -- Active mode must not survive if the inserter is no longer a boundary.
  if storage.tx_active_inserters then
    for ins_unit, _ in pairs(storage.tx_active_inserters) do
      if watch[ins_unit] then
        if not Transaction.is_boundary_inserter(ins_unit) then
          storage.tx_active_inserters[ins_unit] = nil
        end
      end
    end
  end

  -- WIP mode must not survive if the inserter is no longer watched.
  if storage.tx_wip_inserters then
    for ins_unit, _ in pairs(storage.tx_wip_inserters) do
      if not watch[ins_unit] then
        storage.tx_wip_inserters[ins_unit] = nil
      end
    end
  end

  -- WIP mode must not survive if the inserter is no longer a boundary.
  if storage.tx_wip_inserters then
    for ins_unit, _ in pairs(storage.tx_wip_inserters) do
      if watch[ins_unit] then
        if not Transaction.is_boundary_inserter(ins_unit) then
          storage.tx_wip_inserters[ins_unit] = nil
        end
      end
    end
  end

  -- Build a combined hand/inserter list for display and export consumers.
  Transaction.rebuild_inserter_list()

  Transaction.update_marks()
end

-- -----------------------------------------
-- Tick processing
-- -----------------------------------------

local function book_take(ev_base, obj, obj_unit, item, cnt, qual)
  push_event({
    tick = ev_base.tick,
    ins_id = ev_base.ins_id,
    ins_unit = ev_base.ins_unit,
    kind = "TAKE",
    obj = obj,
    obj_unit = obj_unit,
    item = item,
    cnt = cnt,
    qual = qual or "normal"
  })
end

local function book_give(ev_base, obj, obj_unit, item, cnt, qual)
  push_event({
    tick = ev_base.tick,
    ins_id = ev_base.ins_id,
    ins_unit = ev_base.ins_unit,
    kind = "GIVE",
    obj = obj,
    obj_unit = obj_unit,
    item = item,
    cnt = cnt,
    qual = qual or "normal"
  })
end

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
    local item = now.name
    local cnt = now.count
    local qual = now.quality or "normal"
    local ev_base = { tick = tick, ins_id = ins_rec.id, ins_unit = ins_unit }

    if src_obj then
      -- Registered source is the reliable side.
      book_take(ev_base, src_obj, pick and pick.unit_number or nil, item, cnt, qual)

      if not dst_obj then
        -- Do not wait for the physical belt drop delta.
        -- Unknown destination means transit; clear by the confirmed TAKE quantity.
        book_give(ev_base, unknown_destination_obj(ins_unit, src_obj, dst_obj), nil, item, cnt, qual)
      end
    else
      -- Do not book TAKE T00 here.
      -- Unknown source means transit; clear T00 later when a registered GIVE is confirmed.
    end

    ins_rec.last = now
    return
  end

  -- Transition: filled -> empty  => GIVE
  if last and (not now) then
    local item = last.name
    local cnt = last.count
    local qual = last.quality or "normal"
    local ev_base = { tick = tick, ins_id = ins_rec.id, ins_unit = ins_unit }

    if dst_obj then
      if not src_obj then
        -- Do not rely on the physical belt pickup delta.
        -- Unknown source means transit; clear T00 by the confirmed GIVE quantity.
        book_take(ev_base, unknown_source_obj(ins_unit, src_obj, dst_obj), nil, item, cnt, qual)
      end

      book_give(ev_base, dst_obj, drop and drop.unit_number or nil, item, cnt, qual)
    else
      -- Unknown destination means transit.
      -- If source was registered, the corresponding GIVE T00 was already booked
      -- together with the confirmed TAKE. Do not book the belt drop delta again.
      if not src_obj then
        -- Fully unknown movement; keep previous fallback behavior minimal.
        book_give(ev_base, opposite_obj(ins_unit, src_obj, dst_obj), drop and drop.unit_number or nil, item, cnt, qual)
      end
    end

    ins_rec.last = nil
    return
  end

  -- Transition: filled -> filled, same item/quality, changed count
  -- Stack inserters can increase/decrease the held amount while the hand is not empty.
  -- Book only the delta so TAKE/GIVE quantities stay balanced.
  if last and now
     and last.name == now.name
     and (last.quality or "normal") == (now.quality or "normal") then

    local delta = (tonumber(now.count) or 0) - (tonumber(last.count) or 0)

    if delta > 0 then
      local item = now.name
      local cnt = delta
      local qual = now.quality or "normal"
      local ev_base = { tick = tick, ins_id = ins_rec.id, ins_unit = ins_unit }

      if src_obj then
        -- Registered source is the reliable side.
        book_take(ev_base, src_obj, pick and pick.unit_number or nil, item, cnt, qual)

        if not dst_obj then
          -- Unknown destination means transit.
          -- Book GIVE T00 immediately with the confirmed TAKE delta.
          book_give(ev_base, unknown_destination_obj(ins_unit, src_obj, dst_obj), nil, item, cnt, qual)
        end
      else
        -- Do not book TAKE T00 here.
        -- Unknown source means transit; wait for confirmed GIVE into a registered object.
      end

      ins_rec.last = now
      return

    elseif delta < 0 then
      local item = last.name
      local cnt = -delta
      local qual = last.quality or "normal"
      local ev_base = { tick = tick, ins_id = ins_rec.id, ins_unit = ins_unit }

      if dst_obj then
        if not src_obj then
          -- Unknown source means transit.
          -- Book TAKE T00 immediately with the confirmed GIVE delta.
          book_take(ev_base, unknown_source_obj(ins_unit, src_obj, dst_obj), nil, item, cnt, qual)
        end

        book_give(ev_base, dst_obj, drop and drop.unit_number or nil, item, cnt, qual)
      else
        -- Unknown destination means transit.
        -- If the source was registered, GIVE T00 was already booked with TAKE.
        -- Do not book the observed belt-drop delta again.
        if not src_obj then
          -- Fully unknown fallback, normally irrelevant because such inserters are not watched.
          book_give(ev_base, opposite_obj(ins_unit, src_obj, dst_obj), drop and drop.unit_number or nil, item, cnt, qual)
        end
      end

      ins_rec.last = now
      return
    end
  end


  -- Any other change (rare): refresh last
  ins_rec.last = now
end

function Transaction.on_tick(tick)
  ensure_defaults()

  -- control.lua owns protocol_active; this module only processes when called.
  tick = tick or game.tick

  -- Rebuild object and watch maps periodically.
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

        -- WIP mode must be cleared when the watched inserter is removed.
        if storage.tx_wip_inserters then
          storage.tx_wip_inserters[ins_unit] = nil
        end
      end
    end
  end
end

-- -----------------------------------------
-- TX viewer helpers for UI text-box paging.
-- -----------------------------------------

-- We intentionally keep the TX viewer "one window per page".
-- The text-box should never contain more lines than fit into the window,
-- so the built-in text-box scroll bar becomes irrelevant.
local TX_WINDOW_LINES = 24  -- measured in UI: exactly 25 lines fit

-- Transaction.tx_line_count is the single public API for the event count.
-- Internal callers use the local tx_count() below (defined after the viewer helpers).
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

  -- Clear TX event log + virtual balances 
  -- Reset also clears WIP mode flags so all watched inserters start as normal.
  storage.tx_events = {}
  storage.tx_virtual = { T00 = {}, SHIP = {}, RECV = {}, WIP = {}, MAN = {} }

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

  storage.tx_view = {}
  storage.tx_gui_dirty = {}
  storage._tx_last_gui_refresh_tick = 0

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
