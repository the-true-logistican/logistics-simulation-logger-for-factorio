-- =========================================
-- LogSim (Factorio 2.0)
-- Manages registration of chests, tanks, machines and protected entities with visual markers.
--
-- Rendering markers:
--   - Text markers are managed centrally via UI.marker_text_update/clear
--   - NO legacy marker_*_id persistence anymore
--   - Includes one-shot "purge + redraw" support for old saves
-- =========================================

local M  = require("config")
local UI = require("ui")
local Util = require("utility")

local Chests = {}
Chests.version = "0.8.0"

-- =========================================
-- ENTITY CACHE (Performance Optimization)
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
-- SUPPORTED MACHINE TYPES
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

local function is_machine(ent)
  return ent and ent.valid and SUPPORTED_MACHINE_TYPES[ent.type] == true
end


-- =========================================
-- Helper: Marker purge (handles old saves + legacy fields)
-- =========================================

local function purge_marker_handles(rec)
  if not rec then return end

  -- New system: UI-managed marker stored in rec.marker_text (render id/object)
  UI.marker_text_clear(rec)

  -- Old system (legacy fields from older saves): kill them if present
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

  -- Some older variants stored circles/objects directly
  if rec.marker_circle then
    local obj = rec.marker_circle
    if type(obj) == "number" then obj = rendering.get_object_by_id(obj) end
    if obj and obj.valid then obj:destroy() end
    rec.marker_circle = nil
  end
end

-- =========================================
-- Public: Selection check
-- =========================================

function Chests.check_selected_entity(player)
  local ent = player.selected

  if not ent or not ent.valid then
    local msg = {"logistics_simulation.no_entity_selected"}
    info_print(player, msg)
    Util.fly(player, nil, msg)
    return false
  end

  if not ent.unit_number then
    local msg = {"logistics_simulation.no_unit_number"}
    info_print(player, msg)
    Util.fly(player, nil, msg)
    return false
  end

  return true
end

-- =========================================
-- Public: Resolve entity (cache + fallbacks)
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
-- Public: Marker update (single record)
-- =========================================

function Chests.update_marker(rec, ent)
  -- If entity invalid -> clear markers
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
-- Public: Full marker refresh (purge + redraw)
--   Call once after loading old saves / migration
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
  refresh_list(storage.protected)

  storage.marker_dirty = true
end

-- =========================================
-- Public: Register selected
-- =========================================

function Chests.register_selected(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if is_chest(ent) then return Chests.register_chest(player, log) end
  if is_tank(ent)  then return Chests.register_tank(player, log)  end
  if is_machine(ent) then return Chests.register_machine(player, log) end

  local msg = {"logistics_simulation.no_reg_entity"}
  info_print(player, msg)
  Util.fly(player, ent, msg)
end

-- =========================================
-- Public: Register chest
-- =========================================

function Chests.register_chest(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if not is_chest(ent) then
    info_print(player, {"logistics_simulation.no_chest"})
    return
  end

  if storage.registry and storage.registry[ent.unit_number] then
    info_print(player, {"logistics_simulation.already_registered_chest"})
    return
  end

  local id = string.format("C%02d", storage.next_chest_id)
  storage.next_chest_id = storage.next_chest_id + 1

  local rec = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    kind = "chest",
    -- marker_text is UI-managed runtime handle (safe to exist, but will be refreshed on demand)
    marker_text = nil
  }

  storage.registry[ent.unit_number] = rec
  Chests.update_marker(rec, ent)
  storage.marker_dirty = true

  if log then
    log(string.format(
      "EV;%d;REG;id=%s;unit=%d;name=%s;x=%.1f;y=%.1f",
      game.tick, id, ent.unit_number, ent.name, ent.position.x, ent.position.y
    ))
  end

  local msg = {"logistics_simulation.registered_chest", id}
  info_print(player, msg)
  Util.fly(player, ent, msg)
  info_print(player, {"logistics_simulation.show_buffer"})
end

-- =========================================
-- Public: Register tank
-- =========================================

function Chests.register_tank(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if not is_tank(ent) then
    info_print(player, {"logistics_simulation.no_reg_entity"})
    return
  end

  if storage.registry and storage.registry[ent.unit_number] then
    info_print(player, {"logistics_simulation.already_registered_chest"})
    return
  end

  local id = string.format("T%02d", storage.next_tank_id)
  storage.next_tank_id = storage.next_tank_id + 1

  local rec = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    kind = "tank",
    marker_text = nil
  }

  storage.registry[ent.unit_number] = rec
  Chests.update_marker(rec, ent)
  storage.marker_dirty = true

  if log then
    log(string.format(
      "EV;%d;REG_TANK;id=%s;unit=%d;name=%s;x=%.1f;y=%.1f",
      game.tick, id, ent.unit_number, ent.name, ent.position.x, ent.position.y
    ))
  end

  local msg = {"logistics_simulation.registered_chest", id}
  info_print(player, msg)
  Util.fly(player, ent, msg)
  info_print(player, {"logistics_simulation.show_buffer"})
end

-- =========================================
-- Public: Register machine
-- =========================================

function Chests.register_machine(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if not is_machine(ent) then
    info_print(player, {"logistics_simulation.no_machine"})
    return
  end

  if storage.machines and storage.machines[ent.unit_number] then
    info_print(player, {"logistics_simulation.already_registered_machine"})
    return
  end

  local id = string.format("M%02d", storage.next_machine_id)
  storage.next_machine_id = storage.next_machine_id + 1

  local rec = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    type = ent.type,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    marker_text = nil
  }

  storage.machines[ent.unit_number] = rec
  Chests.update_marker(rec, ent)
  storage.marker_dirty = true

  if log then
    log(string.format(
      "EV;%d;MACH;id=%s;unit=%d;type=%s;name=%s;x=%.1f;y=%.1f",
      game.tick, id, ent.unit_number, ent.type, ent.name, ent.position.x, ent.position.y
    ))
  end

  local msg = {"logistics_simulation.registered_machine", id}
  info_print(player, msg)
  Util.fly(player, ent, msg)
  info_print(player, {"logistics_simulation.show_buffer"})
end

-- =========================================
-- Public: Register protected
-- =========================================

function Chests.register_protect(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if storage.protected and storage.protected[ent.unit_number] then
    info_print(player, {"logistics_simulation.already_protected"})
    return
  end

  local id = string.format("P%02d", storage.next_protect_id)
  storage.next_protect_id = storage.next_protect_id + 1

  local rec = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    marker_text = nil
  }

  storage.protected[ent.unit_number] = rec
  Chests.update_marker(rec, ent)
  storage.marker_dirty = true

  if log then
    log(string.format(
      "EV;%d;PROT;id=%s;unit=%d;name=%s;x=%.1f;y=%.1f",
      game.tick, id, ent.unit_number, ent.name, ent.position.x, ent.position.y
    ))
  end

  local msg = {"logistics_simulation.registered_protected", id}
  info_print(player, msg)
  Util.fly(player, ent, msg)
  info_print(player, {"logistics_simulation.show_buffer"})
end

-- =========================================
-- Public: Unregister selected
-- =========================================

function Chests.unregister_selected(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected
  local unit = ent.unit_number
  local removed_any = false

  local rec = storage.registry and storage.registry[unit]
  if rec then
    Chests.update_marker(rec, nil)
    storage.registry[unit] = nil
    removed_any = true

    if log then log(string.format("EV;%d;UNREG;%s;%d", game.tick, rec.id or "?", unit)) end
    info_print(player, {"logistics_simulation.unregistered_registry", rec.id or "?"})
  end

  local prec = storage.protected and storage.protected[unit]
  if prec then
    Chests.update_marker(prec, nil)
    storage.protected[unit] = nil
    removed_any = true

    if log then log(string.format("EV;%d;UNPROT;%s;%d", game.tick, prec.id or "?", unit)) end
    info_print(player, {"logistics_simulation.unregistered_protected", prec.id or "?"})
  end

  local mrec = storage.machines and storage.machines[unit]
  if mrec then
    Chests.update_marker(mrec, nil)
    storage.machines[unit] = nil
    removed_any = true

    if log then log(string.format("EV;%d;UNMACH;%s;%d", game.tick, mrec.id or "?", unit)) end
    info_print(player, {"logistics_simulation.unregistered_registry", mrec.id or "?"})
  end

  if removed_any then
    invalidate_cache_entry(unit)
    storage.marker_dirty = true
    return
  end

  info_print(player, {"logistics_simulation.unregistered_none"})
  if log then log(string.format("EV;%d;UNSEL;NONE;%d", game.tick, unit)) end
end

-- =========================================
-- Public: Clear markers (list)
-- =========================================

function Chests.clear_markers(list)
  if not list then return end
  for _, rec in pairs(list) do
    purge_marker_handles(rec)
  end
end

-- =========================================
-- Public: Reset list(s)
-- =========================================

function Chests.reset_list(mode)
  if not storage or not mode then return end

  if mode == "chests" then
    Chests.clear_markers(storage.registry)
    storage.registry = {}
    storage.next_chest_id = 1
    storage.next_tank_id = 1
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
  if opts.chests then Chests.reset_list("chests"); any = true end
  if opts.machines then Chests.reset_list("machines"); any = true end
  if opts.protected then Chests.reset_list("protected"); any = true end

  if any then storage.marker_dirty = true end
end

return Chests
