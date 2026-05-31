-- =========================================
-- LogSim (Factorio 2.0)
-- Logistics Object Registry Module
--
-- Historical note:
--   This module is still named "chests.lua" because the first versions only
--   handled registered chests. The scope has grown over time, but the filename
--   is kept unchanged to avoid unnecessary require-path and architecture changes.
--
-- Purpose:
--   Central registry for all manually registered logistics objects used by
--   LogSim. These objects form the stable reference points for inventory
--   snapshots, transaction accounting, reset protection and visual markers.
--
-- Managed object classes:
--   Cxx = registered chest
--     - Factorio entity types:
--       "container"
--       "logistic-container"
--
--   Txx = registered storage tank
--     - Factorio entity type:
--       "storage-tank"
--
--   Mxx = registered machine
--     - supported Factorio entity types:
--       "assembling-machine"
--       "furnace"
--       "lab"
--       "mining-drill"
--       "rocket-silo"
--
--   Rxx = registered roboport
--     - Factorio entity type:
--       "roboport"
--
--   Pxx = protected entity
--     - entities explicitly protected from reset/cleanup operations
--
-- Operating model:
--   Players register relevant logistics objects manually.
--   Registered objects receive stable LogSim ids such as C01, T01, M01 or P01.
--   The stored registry records contain unit_number, prototype name, surface,
--   position and object kind. These records are used later by the logger,
--   transaction module, reset logic, blueprint/accounting views and GUI.
--
-- Hotkey operation:
--   SHIFT + R:
--     Register the selected object if it is a supported chest, tank, roboport or machine.
--     The same hotkey is intercepted by transaction.lua when the selected
--     entity is an inserter, so inserter interface states are handled there.
--
--   SHIFT + U:
--     Unregister the selected registered object.
--     If the selected entity is an inserter, transaction.lua handles the
--     inserter state reset instead.
--
--   SHIFT + P:
--     Register the selected entity as protected.
--
-- Visual markers:
--   Registered logistics objects:
--     Cxx/Txx/Mxx/Rxx text marker in REG_MARK_COLOR
--     default: green  { r=0, g=1, b=0, a=1 }
--
--   Protected objects:
--     Pxx text marker in PROT_MARK_COLOR
--     default: orange { r=1, g=0.5, b=0, a=1 }
--
-- Marker implementation:
--   Marker rendering is delegated to UI.marker_text_update().
--   This module decides which id, color, scale and offset are used.
--   It also clears invalid markers and removes legacy marker fields from
--   older saves.
--
-- Entity resolution:
--   Registered objects are resolved back to live LuaEntity instances by:
--     1) cached unit_number lookup
--     2) game.get_entity_by_unit_number()
--     3) surface/name/position fallback search
--
-- Cache:
--   A small runtime entity cache is used to avoid repeated expensive surface
--   lookups. Cache entries are invalidated when entities are removed or when
--   a full cache reset is required.
--
-- Relationship to transaction.lua:
--   This module defines the registered logistics objects.
--   transaction.lua uses those objects as accounting endpoints and then
--   discovers relevant inserters around them automatically.
--
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 registering chests is now transitiv to machines to avoid implicit WIP
-- Version 0.9.2 roboport, cargo-wagon and fluid-wagon registration
--               marker refresh moved into chests.lua
-- Version 0.9.3 local cleanup and shared registration/removal helpers
--
-- =========================================

local M = require("config")
local UI = require("ui")
local Util = require("utility")

local Chests = {}
Chests.version = "0.9.3"

-- =========================================
-- Entity cache
-- =========================================

local entity_cache = {}
local cache_stats = {
  hits = 0,
  misses = 0,
  invalidations = 0
}

local function invalidate_cache_entry(unit_number)
  if entity_cache[unit_number] then
    entity_cache[unit_number] = nil
    cache_stats.invalidations = cache_stats.invalidations + 1
  end
end

function Chests.clear_entity_cache()
  local count = table_size(entity_cache)
  entity_cache = {}
  cache_stats.invalidations = cache_stats.invalidations + count
end

function Chests.get_cache_stats()
  local total = cache_stats.hits + cache_stats.misses
  local hit_rate = total > 0 and (cache_stats.hits / total * 100) or 0

  return {
    hits = cache_stats.hits,
    misses = cache_stats.misses,
    invalidations = cache_stats.invalidations,
    hit_rate = hit_rate,
    cached_entities = table_size(entity_cache)
  }
end

function Chests.reset_cache_stats()
  cache_stats = { hits = 0, misses = 0, invalidations = 0 }
end

Chests.invalidate_cache_entry = invalidate_cache_entry

-- =========================================
-- Supported entity classifiers
-- =========================================

local SUPPORTED_MACHINE_TYPES = {
  ["assembling-machine"] = true,
  ["furnace"]            = true,
  ["lab"]                = true,
  ["mining-drill"]       = true,
  ["rocket-silo"]        = true,
}

local function is_chest(ent)
  return ent and ent.valid and (ent.type == "container" or ent.type == "logistic-container")
end

local function is_tank(ent)
  return ent and ent.valid and ent.type == "storage-tank"
end

local function is_roboport(ent)
  return ent and ent.valid and ent.type == "roboport"
end

local function is_machine(ent)
  return ent and ent.valid and SUPPORTED_MACHINE_TYPES[ent.type] == true
end

local function is_cargo_wagon(ent)
  return ent and ent.valid and ent.type == "cargo-wagon"
end

local function is_fluid_wagon(ent)
  return ent and ent.valid and ent.type == "fluid-wagon"
end


-- =========================================
-- Marker cleanup
-- =========================================

local function purge_marker_handles(rec)
  if not rec then return end

  -- UI-managed marker stored in rec.marker_text.
  UI.marker_text_clear(rec)

  -- Remove legacy render ids from older saves.
  if rec.marker_text_id then
    local obj = rendering.get_object_by_id(rec.marker_text_id)
    if obj and obj.valid then obj:destroy() end
    rec.marker_text_id = nil
  end
  if rec.marker_circle_id then
    local obj = rendering.get_object_by_id(rec.marker_circle_id)
    if obj and obj.valid then obj:destroy() end
    rec.marker_circle_id = nil
  end

  -- Remove legacy direct render objects from older saves.
  if rec.marker_circle then
    local obj = rec.marker_circle
    if type(obj) == "number" then obj = rendering.get_object_by_id(obj) end
    if obj and obj.valid then obj:destroy() end
    rec.marker_circle = nil
  end
end

-- =========================================
-- Selection validation
-- =========================================

function Chests.check_selected_entity(player)
  local ent = player.selected

  if not ent or not ent.valid then
    local msg = {"logistics_simulation.no_entity_selected"}
    Util.info_print(player, msg)
    Util.fly(player, nil, msg)
    return false
  end

  if not ent.unit_number then
    local msg = {"logistics_simulation.no_unit_number"}
    Util.info_print(player, msg)
    Util.fly(player, nil, msg)
    return false
  end

  return true
end

-- =========================================
-- Entity resolution
-- =========================================

function Chests.resolve_entity(rec)
  if not rec then return nil end

  -- 1) cache fast path
  if rec.unit_number and entity_cache[rec.unit_number] then
    local cached = entity_cache[rec.unit_number]
    if cached.valid then
      cache_stats.hits = cache_stats.hits + 1
      return cached
    else
      entity_cache[rec.unit_number] = nil
    end
  end

  cache_stats.misses = cache_stats.misses + 1

  -- 2) fast lookup by unit_number
  if rec.unit_number then
    local e = game.get_entity_by_unit_number(rec.unit_number)
    if e and e.valid then
      entity_cache[rec.unit_number] = e
      return e
    end
  end

  -- 3) fallback: surface lookup
  local surface = rec.surface_index and game.get_surface(rec.surface_index)
  if surface and surface.valid and rec.name and rec.position then
    local e = surface.find_entity(rec.name, rec.position)
    if e and e.valid then
      if (not rec.unit_number) or (e.unit_number == rec.unit_number) then
        if e.unit_number then entity_cache[e.unit_number] = e end
        return e
      end
    end

    local found = surface.find_entities_filtered{
      name = rec.name,
      position = rec.position,
      radius = 0.5,
      limit = 1
    }
    e = found and found[1]
    if e and e.valid then
      if (not rec.unit_number) or (e.unit_number == rec.unit_number) then
        if e.unit_number then entity_cache[e.unit_number] = e end
        return e
      end
    end
  end

  return nil
end

-- =========================================
-- Marker update
-- =========================================

function Chests.update_marker(rec, ent)
  -- Invalid entities clear marker handles.
  if (not ent) or (not ent.valid) then
    purge_marker_handles(rec)
    return
  end

  local is_prot = (type(rec.id) == "string") and (string.sub(rec.id, 1, 1) == "P")

  local color  = (is_prot and M.PROT_MARK_COLOR)  or M.REG_MARK_COLOR  or { r=0, g=1, b=0, a=1 }
  local scale  = (is_prot and M.PROT_MARK_SCALE)  or M.REG_MARK_SCALE  or 1.0
  local offset = (is_prot and M.PROT_MARK_OFFSET) or M.REG_MARK_OFFSET or { x=0, y=-1.0 }

  UI.marker_text_update(rec, ent, rec.id or "", {
    color  = color,
    offset = offset,
    scale  = scale
  })
end

-- =========================================
-- Full marker refresh
-- =========================================

function Chests.refresh_all_markers()
  if not storage then return end

  local function refresh_list(list)
    if not list then return end
    for _, rec in pairs(list) do
      purge_marker_handles(rec)
      local ent = Chests.resolve_entity(rec)
      if ent and ent.valid then
        Chests.update_marker(rec, ent)
      end
    end
  end

  refresh_list(storage.registry)
  refresh_list(storage.machines)
  refresh_list(storage.roboports)
  refresh_list(storage.protected)

  storage.marker_dirty = true
end

-- =========================================
-- Registration dispatch
-- =========================================

function Chests.register_selected(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if is_chest(ent)       then return Chests.register_chest(player, log)        end
  if is_tank(ent)        then return Chests.register_tank(player, log)          end
  if is_cargo_wagon(ent) then return Chests.register_cargo_wagon(player, log)   end
  if is_fluid_wagon(ent) then return Chests.register_fluid_wagon(player, log)   end
  if is_roboport(ent)    then return Chests.register_roboport(player, log)      end
  if is_machine(ent)     then return Chests.register_machine(player, log)       end

  local msg = {"logistics_simulation.no_reg_entity"}
  Util.info_print(player, msg)
  Util.fly(player, ent, msg)
end

-- =========================================
-- Shared registration helpers
-- =========================================

local function make_entity_record(ent, id, kind, include_type)
  local rec = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    marker_text = nil
  }

  if kind then
    rec.kind = kind
  end

  if include_type then
    rec.type = ent.type
  end

  return rec
end

local function mark_registered(list_key, ent, rec)
  storage[list_key] = storage[list_key] or {}
  storage[list_key][ent.unit_number] = rec
  Chests.update_marker(rec, ent)
  storage.marker_dirty = true
end

local function schedule_wagon_rescan()
  storage.wagon_rescan_pending = storage.wagon_rescan_pending or {}
  storage.wagon_rescan_pending[game.tick + 30] = true
end

local function print_registered(player, ent, msg)
  Util.info_print(player, msg)
  Util.fly(player, ent, msg)
  Util.info_print(player, {"logistics_simulation.show_buffer"})
end

local function register_selected_entity(player, log, def)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected

  if not def.predicate(ent) then
    Util.info_print(player, def.invalid_msg)
    return
  end

  storage[def.list_key] = storage[def.list_key] or {}

  if storage[def.list_key][ent.unit_number] then
    Util.info_print(player, def.already_msg)
    return
  end

  local id = string.format(def.id_format, storage[def.counter_key])
  storage[def.counter_key] = storage[def.counter_key] + 1

  local rec = make_entity_record(ent, id, def.kind, def.include_type)
  mark_registered(def.list_key, ent, rec)

  if log then
    if def.include_type then
      log(string.format(
        "EV;%d;%s;id=%s;unit=%d;type=%s;name=%s;x=%.1f;y=%.1f",
        game.tick,
        def.event,
        id,
        ent.unit_number,
        ent.type,
        ent.name,
        ent.position.x,
        ent.position.y
      ))
    else
      log(string.format(
        "EV;%d;%s;id=%s;unit=%d;name=%s;x=%.1f;y=%.1f",
        game.tick,
        def.event,
        id,
        ent.unit_number,
        ent.name,
        ent.position.x,
        ent.position.y
      ))
    end
  end

  print_registered(player, ent, def.success_msg(id))

  if def.schedule_rescan then
    schedule_wagon_rescan()
  end
end

-- =========================================
-- Public: Register chest
-- =========================================

function Chests.register_chest(player, log)
  register_selected_entity(player, log, {
    predicate = is_chest,
    invalid_msg = {"logistics_simulation.no_chest"},
    already_msg = {"logistics_simulation.already_registered_chest"},
    list_key = "registry",
    counter_key = "next_chest_id",
    id_format = "C%02d",
    kind = "chest",
    event = "REG",
    include_type = false,
    success_msg = function(id) return {"logistics_simulation.registered_chest", id} end
  })
end

-- =========================================
-- Public: Register tank
-- =========================================

function Chests.register_tank(player, log)
  register_selected_entity(player, log, {
    predicate = is_tank,
    invalid_msg = {"logistics_simulation.no_reg_entity"},
    already_msg = {"logistics_simulation.already_registered_chest"},
    list_key = "registry",
    counter_key = "next_tank_id",
    id_format = "T%02d",
    kind = "tank",
    event = "REG_TANK",
    include_type = false,
    success_msg = function(id) return {"logistics_simulation.registered_chest", id} end
  })
end

-- =========================================
-- Public: Register cargo wagon
-- =========================================

function Chests.register_cargo_wagon(player, log)
  register_selected_entity(player, log, {
    predicate = is_cargo_wagon,
    invalid_msg = {"logistics_simulation.no_reg_entity"},
    already_msg = {"logistics_simulation.already_registered_chest"},
    list_key = "registry",
    counter_key = "next_wagon_id",
    id_format = "W%02d",
    kind = "wagon",
    event = "REG_WAGON",
    include_type = false,
    schedule_rescan = true,
    success_msg = function(id) return {"logistics_simulation.registered_chest", id} end
  })
end

-- =========================================
-- Public: Register fluid wagon
-- =========================================

function Chests.register_fluid_wagon(player, log)
  register_selected_entity(player, log, {
    predicate = is_fluid_wagon,
    invalid_msg = {"logistics_simulation.no_reg_entity"},
    already_msg = {"logistics_simulation.already_registered_chest"},
    list_key = "registry",
    counter_key = "next_fluid_wagon_id",
    id_format = "F%02d",
    kind = "fluid-wagon",
    event = "REG_FLUID_WAGON",
    include_type = false,
    schedule_rescan = true,
    success_msg = function(id) return {"logistics_simulation.registered_chest", id} end
  })
end

-- =========================================
-- Public: Register roboport
-- =========================================

function Chests.register_roboport(player, log)
  storage.next_roboport_id = storage.next_roboport_id or 1

  register_selected_entity(player, log, {
    predicate = is_roboport,
    invalid_msg = {"logistics_simulation.no_reg_entity"},
    already_msg = {"", "[LogSim] Roboport already registered"},
    list_key = "roboports",
    counter_key = "next_roboport_id",
    id_format = "R%02d",
    kind = "roboport",
    event = "REG_ROBOPORT",
    include_type = true,
    success_msg = function(id) return {"", "[LogSim] Registered roboport ", id} end
  })
end

-- =========================================
-- Public: Register machine
-- =========================================

function Chests.is_machine_entity(ent)
  return is_machine(ent)
end

function Chests.register_machine_entity(ent, log, reason)
  if not (ent and ent.valid and ent.unit_number) then
    return false, nil
  end

  if not is_machine(ent) then
    return false, nil
  end

  storage.machines = storage.machines or {}

  if storage.machines[ent.unit_number] then
    return false, storage.machines[ent.unit_number].id
  end

  local id = string.format("M%02d", storage.next_machine_id)
  storage.next_machine_id = storage.next_machine_id + 1

  local rec = make_entity_record(ent, id, nil, true)
  mark_registered("machines", ent, rec)

  if log then
    log(string.format(
      "EV;%d;AUTO_MACH;id=%s;unit=%d;type=%s;name=%s;x=%.1f;y=%.1f;reason=%s",
      game.tick,
      id,
      ent.unit_number,
      ent.type,
      ent.name,
      ent.position.x,
      ent.position.y,
      tostring(reason or "closure")
    ))
  end

  return true, id
end

function Chests.register_machine(player, log)
  register_selected_entity(player, log, {
    predicate = is_machine,
    invalid_msg = {"logistics_simulation.no_machine"},
    already_msg = {"logistics_simulation.already_registered_machine"},
    list_key = "machines",
    counter_key = "next_machine_id",
    id_format = "M%02d",
    kind = nil,
    event = "MACH",
    include_type = true,
    success_msg = function(id) return {"logistics_simulation.registered_machine", id} end
  })
end

-- =========================================
-- Public: Register protected
-- =========================================

function Chests.register_protect(player, log)
  register_selected_entity(player, log, {
    predicate = function(ent) return ent and ent.valid and ent.unit_number end,
    invalid_msg = {"logistics_simulation.no_reg_entity"},
    already_msg = {"logistics_simulation.already_protected"},
    list_key = "protected",
    counter_key = "next_protect_id",
    id_format = "P%02d",
    kind = nil,
    event = "PROT",
    include_type = false,
    success_msg = function(id) return {"logistics_simulation.registered_protected", id} end
  })
end

-- =========================================
-- Public: Unregister selected
-- =========================================

local function remove_unit_from_list(list_key, unit, log_event, log_fn, player, message_key)
  local list = storage[list_key]
  local rec = list and list[unit]
  if not rec then return false end

  Chests.update_marker(rec, nil)
  list[unit] = nil

  if log_fn then
    log_fn(string.format("EV;%d;%s;%s;%d", game.tick, log_event, rec.id or "?", unit))
  end

  if player and message_key then
    Util.info_print(player, {message_key, rec.id or "?"})
  end

  return true
end

-- =========================================
-- Public: Unregister selected
-- =========================================

function Chests.unregister_selected(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected
  local unit = ent.unit_number
  local removed_any = false

  removed_any = remove_unit_from_list("registry", unit, "UNREG", log, player, "logistics_simulation.unregistered_registry") or removed_any
  removed_any = remove_unit_from_list("protected", unit, "UNPROT", log, player, "logistics_simulation.unregistered_protected") or removed_any
  removed_any = remove_unit_from_list("machines", unit, "UNMACH", log, player, "logistics_simulation.unregistered_registry") or removed_any
  removed_any = remove_unit_from_list("roboports", unit, "UNROBO", log, player, "logistics_simulation.unregistered_registry") or removed_any

  if removed_any then
    invalidate_cache_entry(unit)
    storage.marker_dirty = true
    return
  end

  Util.info_print(player, {"logistics_simulation.unregistered_none"})
  if log then
    log(string.format("EV;%d;UNSEL;NONE;%d", game.tick, unit))
  end
end

-- =========================================
-- Public: Cleanup removed entities from all registries
-- =========================================

function Chests.cleanup_entity_from_registries(unit_number, log_fn)
  if not unit_number then return false end

  invalidate_cache_entry(unit_number)

  local removed_any = false

  removed_any = remove_unit_from_list("registry", unit_number, "AUTO_UNREG", log_fn) or removed_any
  removed_any = remove_unit_from_list("machines", unit_number, "AUTO_UNMACH", log_fn) or removed_any
  removed_any = remove_unit_from_list("roboports", unit_number, "AUTO_UNROBO", log_fn) or removed_any
  removed_any = remove_unit_from_list("protected", unit_number, "AUTO_UNPROT", log_fn) or removed_any

  if removed_any then
    storage.marker_dirty = true
  end

  return removed_any
end

-- =========================================
-- Marker refresh
-- =========================================

function Chests.update_all_registered_markers()
  local function update_list(list)
    if not list or next(list) == nil then return end
    for _, rec in pairs(list) do
      local ent = Chests.resolve_entity(rec)
      Chests.update_marker(rec, ent)
    end
  end

  update_list(storage.protected)
  update_list(storage.roboports)
  update_list(storage.machines)
  update_list(storage.registry)
end

function Chests.tick_marker_refresh()
  if not storage.marker_dirty then return end
  Chests.update_all_registered_markers()
  storage.marker_dirty = false
end

-- =========================================
-- Marker clearing
-- =========================================

function Chests.clear_markers(list)
  if not list then return end
  for _, rec in pairs(list) do
    purge_marker_handles(rec)
  end
end

-- =========================================
-- Registry reset
-- =========================================

function Chests.reset_list(mode)
  if not storage or not mode then return end

  if mode == "chests" then
    Chests.clear_markers(storage.registry)
    storage.registry = {}
    storage.next_chest_id = 1
    storage.next_tank_id = 1
    storage.next_wagon_id = 1
    storage.next_fluid_wagon_id = 1
    storage.marker_dirty = true
    return
  end

  if mode == "machines" then
    Chests.clear_markers(storage.machines)
    storage.machines = {}
    storage.next_machine_id = 1
    storage.marker_dirty = true
    return
  end

  if mode == "roboports" then
    Chests.clear_markers(storage.roboports)
    storage.roboports = {}
    storage.next_roboport_id = 1
    storage.marker_dirty = true
    return
  end

  if mode == "protected" then
    Chests.clear_markers(storage.protected)
    storage.protected = {}
    storage.next_protect_id = 1
    storage.marker_dirty = true
    return
  end
end

function Chests.reset_lists(opts)
  if not opts or not storage then return end

  local any = false

  if opts.chests then
    Chests.reset_list("chests")
    Chests.reset_list("roboports")
    any = true
  end

  if opts.machines then
    Chests.reset_list("machines")
    any = true
  end

  if opts.protected then
    Chests.reset_list("protected")
    any = true
  end

  if any then storage.marker_dirty = true end
end

return Chests
