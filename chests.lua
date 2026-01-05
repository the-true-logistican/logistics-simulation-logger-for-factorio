-- =========================================
-- LogSim (Factorio 2.0) 
-- Chest/Protected Registry Module with Locale
-- Version 0.3.0
-- =========================================

local M = require("config")

local Chests = {
   version = "0.5.0"
}

local SUPPORTED_MACHINE_TYPES = {
  ["assembling-machine"] = true,
  ["furnace"] = true,
  ["lab"] = true,
  ["mining-drill"] = true,
  ["rocket-silo"] = true,
}

-- ----------------------------
-- Helpers machine or chest
-- ----------------------------
local function is_chest(ent)
  return ent and ent.valid and (ent.type == "container" or ent.type == "logistic-container")
end

local function is_machine(ent)
  return ent and ent.valid and SUPPORTED_MACHINE_TYPES[ent.type] == true
end

-- ----------------------------
-- Helpers (Rendering)
-- ----------------------------
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

-- ----------------------------
-- Public: Selection check
-- ----------------------------
function Chests.check_selected_entity(player)
  local ent = player.selected

  if not ent or not ent.valid then
    player.print({"logistics_simulation.no_entity_selected"})
    return false
  end

  if not ent.unit_number then
    player.print({"logistics_simulation.no_unit_number"})
    return false
  end

  return true
end

-- ----------------------------
-- Public: Marker update
-- ----------------------------
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

-- ----------------------------
-- Public: check entity
-- ----------------------------
function Chests.register_selected(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if is_chest(ent) then
    return Chests.register_chest(player, log)
  end

  if is_machine(ent) then
    return Chests.register_machine(player, log)
  end

  player.print({"logistics_simulation.no_reg_entity"})
end

-- ----------------------------
-- Public: Resolve entity from record
-- ----------------------------
function Chests.resolve_entity(rec)
  local surface = game.get_surface(rec.surface_index)
  if not surface then return nil end

  local found = surface.find_entities_filtered{
    name = rec.name,
    position = rec.position,
    limit = 1
  }
  return (found and found[1]) or nil
end

-- ----------------------------
-- Public: Register chest/machine
-- ----------------------------
function Chests.register_chest(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected
  if ent.type ~= "container" and ent.type ~= "logistic-container" then
    player.print({"logistics_simulation.no_chest"})
    return
  end

  if storage.registry[ent.unit_number] then
    player.print({"logistics_simulation.already_registered_chest"})
    return
  end

  local id = string.format("C%02d", storage.next_chest_id)
  storage.next_chest_id = storage.next_chest_id + 1

  storage.registry[ent.unit_number] = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    marker_circle_id = nil,
    marker_text_id = nil
  }

  if log then
    log(string.format(
      "EV;%d;REG;id=%s;unit=%d;name=%s;x=%.1f;y=%.1f",
      game.tick, id, ent.unit_number, ent.name, ent.position.x, ent.position.y
    ))
  end

  player.print({"logistics_simulation.registered_chest", id})
  player.print({"logistics_simulation.show_buffer"})
end

function Chests.register_machine(player, log)
  if not Chests.check_selected_entity(player) then return end
  local ent = player.selected

  if not is_machine(ent) then
    player.print({"logistics_simulation.no_machine"})
    return
  end

  if storage.machines[ent.unit_number] then
    player.print({"logistics_simulation.already_registered_machine"})
    return
  end

  local id = string.format("M%02d", storage.next_machine_id)
  storage.next_machine_id = storage.next_machine_id + 1

  storage.machines[ent.unit_number] = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    type = ent.type,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    marker_circle = nil,
    marker_text = nil
  }

  if log then
    log(string.format(
      "EV;%d;MACH;id=%s;unit=%d;type=%s;name=%s;x=%.1f;y=%.1f",
      game.tick, id, ent.unit_number, ent.type, ent.name, ent.position.x, ent.position.y
    ))
  end

  player.print({"logistics_simulation.registered_machine", id})
  player.print({"logistics_simulation.show_buffer"})
end

-- ----------------------------
-- Public: Register protected entity
-- ----------------------------
function Chests.register_protect(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected

  if storage.protected[ent.unit_number] then
    player.print({"logistics_simulation.already_protected"})
    return
  end

  local id = string.format("P%02d", storage.next_protect_id)
  storage.next_protect_id = storage.next_protect_id + 1

  storage.protected[ent.unit_number] = {
    id = id,
    unit_number = ent.unit_number,
    name = ent.name,
    surface_index = ent.surface.index,
    position = { x = ent.position.x, y = ent.position.y },
    marker_circle = nil,
    marker_text = nil
  }

  if log then
    log(string.format(
      "EV;%d;PROT;id=%s;unit=%d;name=%s;x=%.1f;y=%.1f",
      game.tick, id, ent.unit_number, ent.name, ent.position.x, ent.position.y
    ))
  end

  player.print({"logistics_simulation.registered_protected", id})
  player.print({"logistics_simulation.show_buffer"})
end

-- ----------------------------
-- Public: Unregister selected
-- ----------------------------
function Chests.unregister_selected(player, log)
  if not Chests.check_selected_entity(player) then return end

  local ent = player.selected
  local unit = ent.unit_number
  local removed_any = false

  -- Registry
  local rec = storage.registry and storage.registry[unit]
  if rec then
    Chests.update_marker(rec, nil)

    if log then
      log(string.format("EV;%d;UNREG;%s;%d", game.tick, rec.id or "?", unit))
    end

    storage.registry[unit] = nil
    player.print({"logistics_simulation.unregistered_registry", rec.id or "?"})
    removed_any = true
  end

  -- Protected
  local prec = storage.protected and storage.protected[unit]
  if prec then
    Chests.update_marker(prec, nil)
    storage.protected[unit] = nil

    if log then
      log(string.format("EV;%d;UNPROT;%s;%d", game.tick, prec.id or "?", unit))
    end

    player.print({"logistics_simulation.unregistered_protected", prec.id or "?"})
    removed_any = true
  end
  
  -- Machines
  local mrec = storage.machines and storage.machines[unit]
  if mrec then
    Chests.update_marker(mrec, nil)
    storage.machines[unit] = nil
    
    if log then
      log(string.format("EV;%d;UNMACH;%s;%d", game.tick, mrec.id or "?", unit))
    end
    
    player.print({"logistics_simulation.unregistered_registry", mrec.id or "?"})
    removed_any = true
  end

  if not removed_any then
    player.print({"logistics_simulation.unregistered_none"})
    
    if log then
      log(string.format("EV;%d;UNSEL;NONE;%d", game.tick, unit))
    end
  end
end

-- ----------------------------
-- Public: Clear markers in a list
-- ----------------------------
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

-- ----------------------------
-- Public: Reset list helper
-- ----------------------------
function Chests.reset_list(mode)
  if not storage or not mode then return end

  if mode == "chests" then
    Chests.clear_markers(storage.registry)
    storage.registry = {}
    storage.next_chest_id = 1
    return
  end

  if mode == "machines" then
    Chests.clear_markers(storage.machines)
    storage.machines = {}
    storage.next_machine_id = 1
    return
  end

  if mode == "protected" then
    Chests.clear_markers(storage.protected)
    storage.protected = {}
    storage.next_protect_id = 1
    return
  end
end

-- ----------------------------
-- Public: Reset multiple lists
-- ----------------------------
function Chests.reset_lists(opts)
  if not opts or not storage then return end
  if opts.chests then
    Chests.reset_list("chests")
  end
  if opts.machines then
    Chests.reset_list("machines")
  end
  if opts.protected then
    Chests.reset_list("protected")
  end
end

return Chests