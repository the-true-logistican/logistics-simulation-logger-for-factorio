-- =========================================
-- LogSim (Factorio 2.0) 
-- Chest/Protected Registry Module with Locale
--
-- Version 0.3.0 first for LogSim 0.3.0
-- Version 0.5.0 locale support
-- Version 0.5.4 flying text feedback, optimized entity resolution, info_print
-- =========================================

local M = require("config")

local Chests = {}
Chests.version = "0.5.4"

local SUPPORTED_MACHINE_TYPES = {
  ["assembling-machine"] = true,
  ["furnace"] = true,
  ["lab"] = true,
  ["mining-drill"] = true,
  ["rocket-silo"] = true,
}

-- -----------------------------------------
-- Helper: Entity Type Check
-- -----------------------------------------

local function is_chest(ent)
  return ent and ent.valid and (ent.type == "container" or ent.type == "logistic-container")
end

local function is_machine(ent)
  return ent and ent.valid and SUPPORTED_MACHINE_TYPES[ent.type] == true
end

-- -----------------------------------------
-- Helper: Rendering
-- -----------------------------------------

local function as_render_object(x)
  if not x then return nil end
  if type(x) == "number" then
    return rendering.get_object_by_id(x)
  end
  return x
end

local function destroy_render(x)
  local obj = as_render_object(x)
  if obj and obj.valid then
    obj:destroy()
  end
end

-- -----------------------------------------
-- Helper: Flying Text
-- -----------------------------------------

local function fly(player, entity, msg, cursor_pos)
  if not (player and player.valid and msg) then return end

  local pos = nil

  if entity and entity.valid and entity.position then
    pos = entity.position
  elseif cursor_pos then
    pos = cursor_pos
  else
    pos = player.position
  end

  player.create_local_flying_text{
    text = msg,
    position = pos,
    color = {r=1, g=1, b=1}
  }
end

-- -----------------------------------------
-- Public: Selection Check
-- -----------------------------------------

function Chests.check_selected_entity(player)
  local ent = player.selected

  if not ent or not ent.valid then
    local msg = {"logistics_simulation.no_entity_selected"}
    info_print(player, msg)
    fly(player, nil, msg)
    return false
  end

  if not ent.unit_number then
    local msg = {"logistics_simulation.no_unit_number"}
    info_print(player, msg)
    fly(player, nil, msg)
    return false
  end

  return true
end

-- -----------------------------------------
-- Public: Marker Update
-- -----------------------------------------

function Chests.update_marker(rec, ent)
  if not ent or not ent.valid then
    destroy_render(rec.marker_circle)
    rec.marker_circle = nil
    destroy_render(rec.marker_text)
    rec.marker_text = nil
    return
  end

  local t = as_render_object(rec.marker_text)
  if not t or not t.valid then
    rec.marker_text = rendering.draw_text{
      text = rec.id,
      color = {r=0, g=1, b=0, a=1},
      target = ent,
      surface = ent.surface,
      target_offset = {0, -1.0},
      alignment = "center",
      scale = 1.0
    }
    t = as_render_object(rec.marker_text)
  else
    t.target = ent
    t.text = rec.id
  end
end

-- -----------------------------------------
-- Public: Register Selected
-- -----------------------------------------

function Chests.register_selected(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if is_chest(ent) then
    return Chests.register_chest(player, log)
  end

  if is_machine(ent) then
    return Chests.register_machine(player, log)
  end

  local msg = {"logistics_simulation.no_reg_entity"}
  info_print(player, msg)
  fly(player, ent, msg)
end

-- -----------------------------------------
-- Public: Resolve Entity (Optimized)
-- -----------------------------------------

function Chests.resolve_entity(rec)
  if not rec then return nil end

  if rec.unit_number then
    local e = game.get_entity_by_unit_number(rec.unit_number)
    if e and e.valid then
      return e
    end
  end

  local surface = rec.surface_index and game.get_surface(rec.surface_index)
  if surface and surface.valid and rec.name and rec.position then
    local e = surface.find_entity(rec.name, rec.position)
    if e and e.valid then
      if (not rec.unit_number) or (e.unit_number == rec.unit_number) then
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
        return e
      end
    end
  end

  return nil
end

-- -----------------------------------------
-- Public: Register Chest
-- -----------------------------------------

function Chests.register_chest(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected
  if ent.type ~= "container" and ent.type ~= "logistic-container" then
    info_print(player, {"logistics_simulation.no_chest"})
    return
  end

  if storage.registry[ent.unit_number] then
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
    marker_circle_id = nil,
    marker_text_id = nil
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
  fly(player, ent, msg)
  info_print(player, {"logistics_simulation.show_buffer"})
end

-- -----------------------------------------
-- Public: Register Machine
-- -----------------------------------------

function Chests.register_machine(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if not is_machine(ent) then
    info_print(player, {"logistics_simulation.no_machine"})
    return
  end

  if storage.machines[ent.unit_number] then
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
    marker_circle = nil,
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
  fly(player, ent, msg)
  info_print(player, {"logistics_simulation.show_buffer"})
end

-- -----------------------------------------
-- Public: Register Protected
-- -----------------------------------------

function Chests.register_protect(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected

  if storage.protected[ent.unit_number] then
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
    marker_circle = nil,
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
  fly(player, ent, msg)
  info_print(player, {"logistics_simulation.show_buffer"})
end

-- -----------------------------------------
-- Public: Unregister Selected
-- -----------------------------------------

function Chests.unregister_selected(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected
  local unit = ent.unit_number
  local removed_any = false

  local rec = storage.registry and storage.registry[unit]
  if rec then
    Chests.update_marker(rec, nil)

    if log then
      log(string.format("EV;%d;UNREG;%s;%d", game.tick, rec.id or "?", unit))
    end

    storage.registry[unit] = nil
    info_print(player, {"logistics_simulation.unregistered_registry", rec.id or "?"})
    removed_any = true
  end

  local prec = storage.protected and storage.protected[unit]
  if prec then
    Chests.update_marker(prec, nil)
    storage.protected[unit] = nil

    if log then
      log(string.format("EV;%d;UNPROT;%s;%d", game.tick, prec.id or "?", unit))
    end

    info_print(player, {"logistics_simulation.unregistered_protected", prec.id or "?"})
    removed_any = true
  end

  local mrec = storage.machines and storage.machines[unit]
  if mrec then
    Chests.update_marker(mrec, nil)
    storage.machines[unit] = nil

    if log then
      log(string.format("EV;%d;UNMACH;%s;%d", game.tick, mrec.id or "?", unit))
    end

    info_print(player, {"logistics_simulation.unregistered_registry", mrec.id or "?"})
    removed_any = true
  end

  if removed_any then
    storage.marker_dirty = true
    return
  end

  info_print(player, {"logistics_simulation.unregistered_none"})

  if log then
    log(string.format("EV;%d;UNSEL;NONE;%d", game.tick, unit))
  end
end

-- -----------------------------------------
-- Public: Clear Markers
-- -----------------------------------------

function Chests.clear_markers(list)
  if not list then return end
  for _, rec in pairs(list) do
    Chests.update_marker(rec, nil)

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
  end
end

-- -----------------------------------------
-- Public: Reset List
-- -----------------------------------------

function Chests.reset_list(mode)
  if not storage or not mode then return end

  if mode == "chests" then
    Chests.clear_markers(storage.registry)
    storage.registry = {}
    storage.next_chest_id = 1
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

-- -----------------------------------------
-- Public: Reset Multiple Lists
-- -----------------------------------------

function Chests.reset_lists(opts)
  if not opts or not storage then return end

  local any = false

  if opts.chests then
    Chests.reset_list("chests")
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

  if any then
    storage.marker_dirty = true
  end
end

return Chests
