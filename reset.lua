-- =========================================
-- LogSim (Factorio 2.0) 
-- Reset of simulation 
--
-- Version 0.2.0 first für LogSim 0.2.0
-- Version 0.2.1 reset_clear_pollution
-- Version 0.2.2 clear products_finished
-- =========================================

local M = require("config")

local R = {}
R.version = "0.2.2"

-- FIX: Added validity check for power switches
local function set_factory_power(surface, state)
  local switches = surface.find_entities_filtered{name = "power-switch"}
  for _, switch in pairs(switches) do
    if switch.valid then
      switch.power_switch_state = state
    end
  end
end

-- Check if entity is in the protected list
local function is_protected(ent)
  return ent and ent.valid and ent.unit_number
     and storage.protected
     and storage.protected[ent.unit_number] ~= nil
end

local function reset_products_finished(ent, log)
  local ok, err = pcall(function()
    ent.products_finished = 0
  end)
  if not ok and log then
    log("EV;" .. game.tick .. ";WARN;products_finished_reset_failed;name=" .. ent.name .. ";unit=" .. tostring(ent.unit_number) .. ";err=" .. tostring(err))
  end
  return ok
end

local function reset_clear_pollution(surface)
  local chunks = 0
  local removed = 0

  for chunk in surface.get_chunks() do
    local pos = { x = chunk.x * M.CHUNK_SIZE, y = chunk.y * M.CHUNK_SIZE }

    local p = surface.get_pollution(pos) or 0
    if p > 0 then
      removed = removed + p
      surface.set_pollution(pos, 0)
    end

    chunks = chunks + 1
  end

  return chunks, removed
end

local function reset_clear_chests(surface)
  local cleared = 0
  local skipped = 0

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"}
  }

  for _, ent in ipairs(chests) do
    if ent.valid then
      if is_protected(ent) then
        skipped = skipped + 1
      else
        local inv = ent.get_inventory(defines.inventory.chest)
        if inv and inv.valid then
          inv.clear()
          cleared = cleared + 1
        end
      end
    end
  end

  return cleared, skipped
end

local function reset_clear_ground_items(surface)
  local destroyed = 0

  local items = surface.find_entities_filtered{ type = "item-entity" }
  for _, e in ipairs(items) do
    if e.valid then
      e.destroy()
      destroyed = destroyed + 1
    end
  end

  return destroyed
end

local function clear_inventory(ent, inv_id)
  local inv = ent.get_inventory(inv_id)
  if inv and inv.valid then
    inv.clear()
    return true
  end
  return false
end

local function reset_clear_machine_buffers(surface, force, log)
  local cleared = 0

  -- Assembler
  local assemblers = surface.find_entities_filtered{force = force, type = "assembling-machine"}
  for _, ent in ipairs(assemblers) do
    if ent.valid and not is_protected(ent) then
      local any = false
      any = clear_inventory(ent, defines.inventory.assembling_machine_input) or any
      any = clear_inventory(ent, defines.inventory.assembling_machine_output) or any
      any = clear_inventory(ent, defines.inventory.fuel) or any
      any = clear_inventory(ent, defines.inventory.burnt_result) or any
      reset_products_finished(ent, log) 
      if any then cleared = cleared + 1 end
    end
  end

  -- Furnace
  local furnaces = surface.find_entities_filtered{force = force, type = "furnace"}
  for _, ent in ipairs(furnaces) do
    if ent.valid and not is_protected(ent) then
      local any = false
      any = clear_inventory(ent, defines.inventory.furnace_source) or any
      any = clear_inventory(ent, defines.inventory.furnace_result) or any
      any = clear_inventory(ent, defines.inventory.fuel) or any
      any = clear_inventory(ent, defines.inventory.burnt_result) or any
      if any then cleared = cleared + 1 end
    end
  end

  -- Lab
  local labs = surface.find_entities_filtered{force = force, type = "lab"}
  for _, ent in ipairs(labs) do
    if ent.valid and not is_protected(ent) then
      local any = false
      any = clear_inventory(ent, defines.inventory.lab_input) or any
      if any then cleared = cleared + 1 end
    end
  end

  return cleared
end

local function reset_clear_belts(surface, force)
  local belt_entities = surface.find_entities_filtered{
    force = force,
    type = {
      "transport-belt",
      "underground-belt",
      "splitter",
      "loader",
      "loader-1x1",
      "linked-belt"
    }
  }

  local cleared_entities = 0
  local cleared_lines = 0

  for _, ent in ipairs(belt_entities) do
    if ent.valid and not is_protected(ent) then
      local max_i = ent.get_max_transport_line_index()
      for i = 1, max_i do
        local line = ent.get_transport_line(i)
        if line and line.valid then
          line.clear()
          cleared_lines = cleared_lines + 1
        end
      end
      cleared_entities = cleared_entities + 1
    end
  end

  return cleared_entities, cleared_lines
end

local function reset_clear_inserter_hands(surface, force)
  local cleared = 0

  local inserters = surface.find_entities_filtered{
    force = force,
    type = "inserter"
  }

  for _, ent in ipairs(inserters) do
    if ent.valid and not is_protected(ent) then
      local hs = ent.held_stack
      if hs and hs.valid_for_read then
        hs.clear()
        cleared = cleared + 1
      end
    end
  end

  return cleared
end

-- Exported function
function R.do_reset_simulation(surface, force, log)
  set_factory_power(surface, false)
  
  if log then
    log(string.format("EV;%d;RESET_START", game.tick))
  end
  
  local cleared_chests, skipped = reset_clear_chests(surface)
  local ground = reset_clear_ground_items(surface)
  local cleared_machines = reset_clear_machine_buffers(surface, force, log)
  local cleared_belts, cleared_lines = reset_clear_belts(surface, force)
  local cleared_hands = reset_clear_inserter_hands(surface, force)
  local pol_chunks, pol_removed = reset_clear_pollution(surface)

  if log then
    log(string.format(
      "EV;%d;RESET_DONE;chests=%d;skipped_protected=%d;ground=%d;machines=%d;entities=%d;lines=%d;inserters=%d;pol_chunks=%d;pol_removed=%.2f",
      game.tick, cleared_chests, skipped, ground, cleared_machines, cleared_belts, cleared_lines, cleared_hands,
      pol_chunks, pol_removed
    ))
  end
  
  set_factory_power(surface, true)
end

return R