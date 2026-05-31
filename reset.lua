-- =========================================
-- LogSim (Factorio 2.0)
-- Reset Module
--
-- Resets factory state in a controlled way: inventories, machine work state,
-- belts, inserter hands, pollution, statistics and roboport contents.
--
-- Version 0.8.0 first complete working version
-- Version 0.8.1 player inventory reset
-- Version 0.8.2 roboport reset and flying robot cleanup
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 independent statistics reset and machine work-state reset
-- Version 0.9.2 registered cargo-wagon and fluid-wagon reset
-- Version 0.9.3 local cleanup and shared reset helpers
--
-- =========================================

local M = require("config")

local R = {}
R.version = "0.9.3"

-- =========================================
-- Local helpers
-- =========================================

local function log_warn(log_fn, code, ent, err)
  if not log_fn then return end

  log_fn("EV;" .. game.tick .. ";WARN;" .. code
    .. ";name=" .. tostring(ent and ent.name)
    .. ";unit=" .. tostring(ent and ent.unit_number)
    .. ";err=" .. tostring(err))
end

local function is_protected(ent)
  return ent
     and ent.valid
     and ent.unit_number
     and storage.protected
     and storage.protected[ent.unit_number] ~= nil
end

local function set_factory_power(surface, state)
  if not (surface and surface.valid) then return end

  local switches = surface.find_entities_filtered{ name = "power-switch" }

  for _, switch in pairs(switches) do
    if switch.valid then
      switch.power_switch_state = state
    end
  end
end

local function clear_entity_inventory(ent, inv_id)
  if not (ent and ent.valid) then return false end

  local inv = ent.get_inventory(inv_id)
  if inv and inv.valid then
    inv.clear()
    return true
  end

  return false
end

local function clear_entity_fluids(ent, log_fn)
  if not (ent and ent.valid) then return false end

  local ok, err = pcall(function()
    ent.clear_fluid_inside()
  end)

  if ok then
    return true
  end

  log_warn(log_fn, "fluid_clear_failed", ent, err)
  return false
end

local function reset_products_finished(ent, log_fn)
  if not (ent and ent.valid) then return false end

  local ok, err = pcall(function()
    ent.products_finished = 0
  end)

  if not ok then
    log_warn(log_fn, "products_finished_reset_failed", ent, err)
  end

  return ok
end

local function reset_machine_work_state(ent, log_fn)
  if not (ent and ent.valid) then return false end

  local touched = false

  -- Factorio 2.x: only entities exposing crafting progress support this field.
  local ok_crafting, err_crafting = pcall(function()
    ent.crafting_progress = 0
  end)

  if ok_crafting then
    touched = true
  else
    log_warn(log_fn, "crafting_progress_reset_failed", ent, err_crafting)
  end

  -- Factorio 2.x: only entities exposing bonus progress support this field.
  local ok_bonus, err_bonus = pcall(function()
    ent.bonus_progress = 0
  end)

  if ok_bonus then
    touched = true
  else
    log_warn(log_fn, "bonus_progress_reset_failed", ent, err_bonus)
  end

  -- result_quality is intentionally not written. Writing nil is invalid;
  -- resetting progress is sufficient to prevent buffered completion.
  return touched
end

-- =========================================
-- Pollution reset
-- =========================================

local function reset_clear_pollution(surface)
  local chunks = 0
  local removed = 0

  for chunk in surface.get_chunks() do
    local pos = {
      x = chunk.x * M.CHUNK_SIZE,
      y = chunk.y * M.CHUNK_SIZE
    }

    local pollution = surface.get_pollution(pos) or 0
    if pollution > 0 then
      removed = removed + pollution
      surface.set_pollution(pos, 0)
    end

    chunks = chunks + 1
  end

  return chunks, removed
end

-- =========================================
-- Inventory and fluid endpoint reset
-- =========================================

local function clear_unprotected_entities(entities, clear_fn)
  local cleared = 0
  local skipped = 0

  for _, ent in ipairs(entities or {}) do
    if ent.valid then
      if is_protected(ent) then
        skipped = skipped + 1
      elseif clear_fn(ent) then
        cleared = cleared + 1
      end
    end
  end

  return cleared, skipped
end

local function clear_registered_wagons(surface, kind, clear_fn)
  local cleared = 0
  local skipped = 0

  if not storage.registry then
    return cleared, skipped
  end

  for _, rec in pairs(storage.registry) do
    if rec.kind == kind and rec.surface_index == surface.index then
      local ent = game.get_entity_by_unit_number(rec.unit_number)

      if ent and ent.valid then
        if is_protected(ent) then
          skipped = skipped + 1
        elseif clear_fn(ent) then
          cleared = cleared + 1
        end
      end
    end
  end

  return cleared, skipped
end

local function reset_clear_chests(surface)
  local cleared = 0
  local skipped = 0

  local chest_cleared, chest_skipped = clear_unprotected_entities(
    surface.find_entities_filtered{
      type = { "container", "logistic-container" }
    },
    function(ent)
      return clear_entity_inventory(ent, defines.inventory.chest)
    end
  )
  cleared = cleared + chest_cleared
  skipped = skipped + chest_skipped

  local tank_cleared, tank_skipped = clear_unprotected_entities(
    surface.find_entities_filtered{ type = "storage-tank" },
    function(ent)
      return clear_entity_fluids(ent)
    end
  )
  cleared = cleared + tank_cleared
  skipped = skipped + tank_skipped

  local cargo_cleared, cargo_skipped = clear_registered_wagons(
    surface,
    "wagon",
    function(ent)
      return clear_entity_inventory(ent, defines.inventory.cargo_wagon)
    end
  )
  cleared = cleared + cargo_cleared
  skipped = skipped + cargo_skipped

  local fluid_cleared, fluid_skipped = clear_registered_wagons(
    surface,
    "fluid-wagon",
    function(ent)
      return clear_entity_fluids(ent)
    end
  )
  cleared = cleared + fluid_cleared
  skipped = skipped + fluid_skipped

  return cleared, skipped
end

local function reset_clear_ground_items(surface)
  local destroyed = 0

  local items = surface.find_entities_filtered{ type = "item-entity" }
  for _, ent in ipairs(items) do
    if ent.valid then
      ent.destroy()
      destroyed = destroyed + 1
    end
  end

  return destroyed
end

-- =========================================
-- Machine, belt and inserter reset
-- =========================================

local function clear_machine_inventory_set(ent, inventory_ids)
  local any = false

  for _, inv_id in ipairs(inventory_ids) do
    any = clear_entity_inventory(ent, inv_id) or any
  end

  return any
end

local function reset_clear_machine_group(surface, force, entity_type, inventory_ids, log_fn, reset_work_state)
  local cleared = 0

  local entities = surface.find_entities_filtered{
    force = force,
    type = entity_type
  }

  for _, ent in ipairs(entities) do
    if ent.valid and not is_protected(ent) then
      local any = false

      if reset_work_state then
        any = reset_machine_work_state(ent, log_fn) or any
      end

      any = clear_machine_inventory_set(ent, inventory_ids) or any

      if entity_type == "assembling-machine" then
        reset_products_finished(ent, log_fn)
      end

      if any then
        cleared = cleared + 1
      end
    end
  end

  return cleared
end

local function reset_clear_machine_buffers(surface, force, log_fn)
  local cleared = 0

  cleared = cleared + reset_clear_machine_group(
    surface,
    force,
    "assembling-machine",
    {
      defines.inventory.assembling_machine_input,
      defines.inventory.assembling_machine_output,
      defines.inventory.fuel,
      defines.inventory.burnt_result
    },
    log_fn,
    true
  )

  cleared = cleared + reset_clear_machine_group(
    surface,
    force,
    "furnace",
    {
      defines.inventory.furnace_source,
      defines.inventory.furnace_result,
      defines.inventory.fuel,
      defines.inventory.burnt_result
    },
    log_fn,
    true
  )

  cleared = cleared + reset_clear_machine_group(
    surface,
    force,
    "lab",
    {
      defines.inventory.lab_input
    },
    log_fn,
    false
  )

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
      local max_index = ent.get_max_transport_line_index()

      for i = 1, max_index do
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
      local held_stack = ent.held_stack

      if held_stack and held_stack.valid_for_read then
        held_stack.clear()
        cleared = cleared + 1
      end
    end
  end

  return cleared
end

-- =========================================
-- Statistics reset
-- =========================================

function R.reset_statistics(surface, force, log_fn)
  local stats_reset = 0

  local function try_clear(label, stat)
    if stat and stat.clear then
      local ok, err = pcall(function()
        stat.clear()
      end)

      if ok then
        stats_reset = stats_reset + 1
      elseif log_fn then
        log_fn(string.format(
          "EV;%d;WARN;reset_stats_failed;%s;err=%s",
          game.tick,
          label,
          tostring(err)
        ))
      end
    end
  end

  if force and force.valid and surface and surface.valid then
    try_clear("item_prod", force.get_item_production_statistics(surface))
    try_clear("fluid_prod", force.get_fluid_production_statistics(surface))
    try_clear("kills", force.get_kill_count_statistics(surface))
    try_clear("build", force.get_entity_build_count_statistics(surface))
  end

  if surface and surface.valid then
    try_clear("electric", surface.global_electric_network_statistics)
    try_clear("pollution", surface.pollution_statistics)
  end

  if log_fn then
    log_fn(string.format("EV;%d;RESET_STATS;cleared=%d", game.tick, stats_reset))
  end

  return stats_reset
end

-- =========================================
-- Roboport reset
-- =========================================

local function reset_clear_roboports(surface, force, log_fn)
  local cleared_ports = 0
  local skipped = 0
  local cleared_robots = 0
  local cleared_mats = 0
  local destroyed_bots = 0

  local roboports = surface.find_entities_filtered{
    force = force,
    type = "roboport"
  }

  for _, roboport in ipairs(roboports) do
    if not roboport.valid then goto continue end

    if is_protected(roboport) then
      skipped = skipped + 1
      goto continue
    end

    local inv_robot = roboport.get_inventory(defines.inventory.roboport_robot)
    if inv_robot and inv_robot.valid then
      local before = #inv_robot
      inv_robot.clear()
      cleared_robots = cleared_robots + before
    end

    local inv_mat = roboport.get_inventory(defines.inventory.roboport_material)
    if inv_mat and inv_mat.valid then
      local before = #inv_mat
      inv_mat.clear()
      cleared_mats = cleared_mats + before
    end

    cleared_ports = cleared_ports + 1

    ::continue::
  end

  local flying_types = { "logistic-robot", "construction-robot" }

  for _, robot_type in ipairs(flying_types) do
    local bots = surface.find_entities_filtered{
      force = force,
      type = robot_type
    }

    for _, bot in ipairs(bots) do
      if bot.valid then
        bot.destroy()
        destroyed_bots = destroyed_bots + 1
      end
    end
  end

  if log_fn then
    log_fn(string.format(
      "EV;%d;RESET_ROBOPORTS;ports=%d;skipped_protected=%d;robots_cleared=%d;mats_cleared=%d;bots_destroyed=%d",
      game.tick,
      cleared_ports,
      skipped,
      cleared_robots,
      cleared_mats,
      destroyed_bots
    ))
  end

  return cleared_ports, skipped, cleared_robots, cleared_mats, destroyed_bots
end

-- =========================================
-- Simulation reset
-- =========================================

function R.do_reset_simulation(surface, force, log_fn)
  set_factory_power(surface, false)

  if log_fn then
    log_fn(string.format("EV;%d;RESET_START", game.tick))
  end

  local cleared_chests, skipped = reset_clear_chests(surface)
  local ground = reset_clear_ground_items(surface)
  local cleared_machines = reset_clear_machine_buffers(surface, force, log_fn)
  local cleared_belts, cleared_lines = reset_clear_belts(surface, force)
  local cleared_hands = reset_clear_inserter_hands(surface, force)
  local pol_chunks, pol_removed = reset_clear_pollution(surface)

  local cleared_ports, skipped_ports, cleared_robots, cleared_mats, destroyed_bots =
    reset_clear_roboports(surface, force, log_fn)

  if log_fn then
    log_fn(string.format(
      "EV;%d;RESET_DONE;chests=%d;skipped_protected=%d;ground=%d;machines=%d;entities=%d;lines=%d;inserters=%d;pol_chunks=%d;pol_removed=%.2f;roboports=%d;roboports_skipped=%d;robots=%d;repair_mats=%d;bots_destroyed=%d",
      game.tick,
      cleared_chests,
      skipped,
      ground,
      cleared_machines,
      cleared_belts,
      cleared_lines,
      cleared_hands,
      pol_chunks,
      pol_removed,
      cleared_ports,
      skipped_ports,
      cleared_robots,
      cleared_mats,
      destroyed_bots
    ))
  end

  set_factory_power(surface, true)
end

-- =========================================
-- Player inventory reset
-- =========================================

function R.wipe_player_inventory(player)
  if not (player and player.valid) then return end

  local inventory_ids = {
    defines.inventory.character_main,
    defines.inventory.character_trash,
    defines.inventory.character_armor,
    defines.inventory.character_guns,
    defines.inventory.character_ammo,
    defines.inventory.character_vehicle
  }

  for _, inv_id in pairs(inventory_ids) do
    local inv = player.get_inventory(inv_id)
    if inv then
      inv.clear()
    end
  end

  if player.cursor_stack and player.cursor_stack.valid_for_read then
    player.cursor_stack.clear()
  end
end

function R.wipe_all_player_inventories(players)
  if not players then return end

  for _, player in pairs(players) do
    R.wipe_player_inventory(player)
  end
end

return R