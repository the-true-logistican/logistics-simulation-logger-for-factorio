-- =========================================
-- LogSim (Factorio 2.0) 
-- Main Control 
--
-- Version 0.6.0 blueprint inventory extraction with cost calculation
-- =========================================

local DEBUG = true

local M = require("config")
local Buffer = require("buffer")
local R = require("reset")
local UI = require("ui")
local Chests = require("chests")
local SimLog = require("simlog")
local ItemCost = require("itemcost")
local Blueprint = require("blueprint")

-- Blueprint inventory: session only (not persistent) - REMOVED, moved to blueprint.lua
-- bp_session moved to blueprint.lua module

-- Forward declarations
local debug_print
local ensure_storage_defaults
local sanitize_filename
local build_base_filename
local maybe_prompt_runname_for_all_players
local handle_runname_submit
local resolve_entity
local cleanup_entity_from_registries
local clear_invalid_rendering_objects

-- -----------------------------------------
-- Helper Functions
-- -----------------------------------------

resolve_entity = function(rec)
  local surface = game.get_surface(rec.surface_index)
  if not surface then return nil end
  
  local found = surface.find_entities_filtered{
    name = rec.name,
    position = rec.position,
    limit = 1
  }
  return (found and found[1]) or nil
end

handle_runname_submit = function(player)
  local frame = player.gui.screen.logsim_runname
  if not frame or not frame.valid then return end

  local name = frame.logsim_runname_text.text
  if name == "" then
    player.print({"logistics_simulation.get_sim_name"})
    return
  end

  storage.run_name = name
  storage.run_start_tick = storage.run_start_tick or game.tick
  storage.base_filename = build_base_filename(storage.run_name, storage.run_start_tick)

  if not storage.buffer_lines or #storage.buffer_lines == 0 then
    storage.buffer_lines = {}
    local header = SimLog.build_header{
      run_name   = storage.run_name,
      start_tick = storage.run_start_tick,
      surface    = player.surface and player.surface.name or nil,
      force      = player.force and player.force.name or nil
    }
    Buffer.append_multiline(header)
  end

  player.print({"logistics_simulation.show_prot_name", storage.run_name})
  player.print({"logistics_simulation.show_start_tick", tostring(storage.run_start_tick)})

  frame.destroy()

  UI.show_buffer_gui(player)
  Buffer.refresh_for_player(player)
end

debug_print = function(msg)
  if DEBUG then
    local prefix = {"logistics_simulation.chat_name"}
    if type(msg) == "table" then
      game.print({"", prefix, " ", msg})
    else
      game.print({"", prefix, " ", tostring(msg)})
    end
  end
end


info_print = function(player, msg)
  if not storage.info_mode then return end
  if not (player and player.valid) then return end
  player.print(msg)
end



ensure_storage_defaults = function()
  storage.run_name = storage.run_name or nil
  storage.run_start_tick = storage.run_start_tick or nil
  storage.base_filename = storage.base_filename or nil
  storage.sample_interval = storage.sample_interval or M.SAMPLE_INTERVAL_TICKS

  if storage.protocol_active == nil then
    storage.protocol_active = false
  end

  if storage.info_mode == nil then
    storage.info_mode = false
  end

  Buffer.ensure_defaults()

  storage.registry = storage.registry or {}
  storage.next_chest_id = storage.next_chest_id or 1
  storage.next_tank_id = storage.next_tank_id or 1

  storage.machines = storage.machines or {}
  storage.next_machine_id = storage.next_machine_id or 1

  storage.protected = storage.protected or {}
  storage.next_protect_id = storage.next_protect_id or 1

  storage.marker_dirty = storage.marker_dirty or false
  storage._needs_rendering_cleanup = storage._needs_rendering_cleanup or false
end

sanitize_filename = function(s)
  return (tostring(s):gsub("[^%w%._%-]", "_"))
end

build_base_filename = function(run_name, start_tick)
  local rn = sanitize_filename(run_name or "run")
  local ver = sanitize_filename(get_logger_version())
  local tick = start_tick or 0
  return string.format("tick%09d__%s__logsim-v%s", tick, rn, ver)
end

function get_logger_version()
  return (script.active_mods and script.active_mods["logistics_simulation"]) or "unknown"
end

maybe_prompt_runname_for_all_players = function()
  if storage.run_name and storage.run_name ~= "" then
    return
  end
  for _, player in pairs(game.players) do
    UI.show_runname_gui(player)
  end
end

clear_invalid_rendering_objects = function()
  if not storage._needs_rendering_cleanup then return end
  
  if storage.registry then
    for _, rec in pairs(storage.registry) do
      rec.marker_circle = nil
      rec.marker_text = nil
    end
  end
  if storage.machines then
    for _, rec in pairs(storage.machines) do
      rec.marker_circle = nil
      rec.marker_text = nil
    end
  end
  if storage.protected then
    for _, rec in pairs(storage.protected) do
      rec.marker_circle = nil
      rec.marker_text = nil
    end
  end
  
  storage._needs_rendering_cleanup = false
end

cleanup_entity_from_registries = function(unit_number, log_fn)
  if not unit_number then return false end
  
  local removed_any = false
  
  if storage.registry and storage.registry[unit_number] then
    local rec = storage.registry[unit_number]
    Chests.update_marker(rec, nil)
    storage.registry[unit_number] = nil
    
    if log_fn then
      log_fn(string.format("EV;%d;AUTO_UNREG;%s;%d", game.tick, rec.id or "?", unit_number))
    end
    removed_any = true
  end
  
  if storage.machines and storage.machines[unit_number] then
    local rec = storage.machines[unit_number]
    Chests.update_marker(rec, nil)
    storage.machines[unit_number] = nil
    
    if log_fn then
      log_fn(string.format("EV;%d;AUTO_UNMACH;%s;%d", game.tick, rec.id or "?", unit_number))
    end
    removed_any = true
  end
  
  if storage.protected and storage.protected[unit_number] then
    local rec = storage.protected[unit_number]
    Chests.update_marker(rec, nil)
    storage.protected[unit_number] = nil
    
    if log_fn then
      log_fn(string.format("EV;%d;AUTO_UNPROT;%s;%d", game.tick, rec.id or "?", unit_number))
    end
    removed_any = true
  end
  
  return removed_any
end

-- -----------------------------------------
-- Lifecycle Events
-- -----------------------------------------

script.on_init(function()
  ensure_storage_defaults()
  debug_print({"logistics_simulation.mod_initialised"})
  maybe_prompt_runname_for_all_players()
end)

script.on_configuration_changed(function(data)
  ensure_storage_defaults()
  
  local mod_changes = data.mod_changes and data.mod_changes["logistics_simulation"]
  if mod_changes then
    local old_version = mod_changes.old_version
    if old_version and old_version < "0.5.2" then
      debug_print({"", "Migrating from ", old_version, " to 0.5.2"})
      storage._needs_rendering_cleanup = true
    end
  end
  
  maybe_prompt_runname_for_all_players()
end)

script.on_load(function()
  -- After load, rendering IDs are invalid and need to be cleared
  -- We set a flag in on_configuration_changed and clear it in on_tick
end)

-- -----------------------------------------
-- Commands
-- -----------------------------------------

commands.add_command("gp", "Global Power Network: /gp on | /gp off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter
  
  if arg == "on" then
    player.surface.create_global_electric_network()
    player.print({"logistics_simulation.cmd_gp_on"})
  elseif arg == "off" then
    player.surface.destroy_global_electric_network()
    player.print({"logistics_simulation.cmd_gp_off"})
  else
    player.print({"logistics_simulation.cmd_gp_usage"})
  end
end)

commands.add_command("prot", "Protocol Recording: /prot on | /prot off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter
  
  if arg == "on" then
    storage.protocol_active = true
    player.print({"logistics_simulation.cmd_prot_on"})
  elseif arg == "off" then
    storage.protocol_active = false
    player.print({"logistics_simulation.cmd_prot_off"})
  else
    player.print({"logistics_simulation.cmd_prot_usage"})
  end
end)

commands.add_command("info", "Info Mode: /info on | /info off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter
  
  if arg == "on" then
    storage.info_mode = true
    player.print({"logistics_simulation.cmd_info_on"})
  elseif arg == "off" then
    storage.info_mode = false
    player.print({"logistics_simulation.cmd_info_off"})
  else
    player.print({"logistics_simulation.cmd_info_usage"})
  end
end)

-- -----------------------------------------
-- GUI Events
-- -----------------------------------------

script.on_event(defines.events.on_gui_confirmed, function(event)
  local el = event.element
  if not (el and el.valid) then return end
  if el.name ~= "logsim_runname_text" then return end

  local player = game.players[event.player_index]
  handle_runname_submit(player)
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  
  -- Close buffer window
  if element.name == M.GUI_BUFFER_FRAME then
    element.destroy()
    return
  end
  
  -- Close inventory window
  if element.name == "logsim_invwin" then
    element.destroy()
    return
  end
end)

-- -----------------------------------------
-- Entity Cleanup Events
-- -----------------------------------------

local entity_cleanup_events = {
  defines.events.on_entity_died,
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.script_raised_destroy
}

script.on_event(entity_cleanup_events, function(event)
  local ent = event.entity
  if not (ent and ent.unit_number) then return end
  
  cleanup_entity_from_registries(ent.unit_number, Buffer.append_line)
end)

-- -----------------------------------------
-- on_tick
-- -----------------------------------------

local function tick_should_log()
  if not storage.run_name then return false end
  if (game.tick % storage.sample_interval) ~= 0 then return false end
  return true
end

local function tick_update_markers()
  if storage.protected and next(storage.protected) ~= nil then
    for _, prec in pairs(storage.protected) do
      local entp = Chests.resolve_entity(prec)
      Chests.update_marker(prec, entp)
    end
  end

  if storage.machines and next(storage.machines) ~= nil then
    for _, mrec in pairs(storage.machines) do
      local entm = Chests.resolve_entity(mrec)
      Chests.update_marker(mrec, entm)
    end
  end

  if storage.registry and next(storage.registry) ~= nil then
    for _, rec in pairs(storage.registry) do
      local ent = Chests.resolve_entity(rec)
      Chests.update_marker(rec, ent)
    end
  end
end

local function tick_build_and_append_logline()
  local tick = game.tick
  
  local surfaces_used = {}
  
  for _, rec in pairs(storage.registry or {}) do
    surfaces_used[rec.surface_index] = true
  end
  for _, rec in pairs(storage.machines or {}) do
    surfaces_used[rec.surface_index] = true
  end
  
  if not next(surfaces_used) then
    surfaces_used[1] = true
  end
  
  for surf_idx, _ in pairs(surfaces_used) do
    local surface = game.get_surface(surf_idx)
    if not surface or not surface.valid then
      goto continue
    end
    
    local force = game.forces.player
    if not force or not force.valid then
      goto continue
    end
    
    local parts = SimLog.begin_telegram(tick, surface, force)
    
    local chest_str = SimLog.build_string_for_surface(
      storage.registry, 
      surf_idx,
      resolve_entity, 
      SimLog.encode_chest
    )
    if chest_str ~= "" then
      parts[#parts+1] = chest_str
    end
    
    local machine_str = SimLog.build_string_for_surface(
      storage.machines,
      surf_idx,
      resolve_entity,
      SimLog.encode_machine
    )
    if machine_str ~= "" then
      parts[#parts+1] = machine_str
    end
    
    Buffer.append_line(SimLog.end_telegram(parts))
    
    ::continue::
  end
end

script.on_event(defines.events.on_tick, function(event)
  if storage._needs_rendering_cleanup then
    clear_invalid_rendering_objects()
  end

  if (event.tick % M.CLEANUP_INTERVAL_TICKS) == 0 then
    Buffer.cleanup_disconnected_players()
  end

  if storage.marker_dirty then
    tick_update_markers()
    storage.marker_dirty = false
  end

  Buffer.tick_refresh_open_guis(event.tick)

  -- Clean up blueprint sidecars (delegated to blueprint module)
  Blueprint.tick_cleanup_sidecars()

  if not storage.protocol_active then return end
  if not tick_should_log() then return end
  tick_build_and_append_logline()
end)

-- -----------------------------------------
-- Custom Inputs (Hotkeys)
-- -----------------------------------------

local function hotkey_toggle_buffer(event)
  local player = game.players[event.player_index]
  local frame = player.gui.screen.logsim_buffer

  if frame and frame.valid then
    frame.destroy()
  else
    UI.show_buffer_gui(player)
    Buffer.refresh_for_player(player)
  end
end

local function hotkey_register_chest(event)
  local player = game.players[event.player_index]
  Chests.register_selected(player, Buffer.append_line)
end

local function hotkey_register_protect(event)
  local player = game.players[event.player_index]
  Chests.register_protect(player, Buffer.append_line)
end

local function hotkey_unregister_selected(event)
  local player = game.players[event.player_index]
  Chests.unregister_selected(player, Buffer.append_line)
end

script.on_event(
  {
    "logsim_toggle_buffer",
    "logsim_register_chest",
    "logsim_register_protect",
    "logsim_unregister_selected"
  },
  function(event)
    local name = event.input_name

    if name == "logsim_toggle_buffer" then
      hotkey_toggle_buffer(event)
    elseif name == "logsim_register_chest" then
      hotkey_register_chest(event)
    elseif name == "logsim_register_protect" then
      hotkey_register_protect(event)
    elseif name == "logsim_unregister_selected" then
      hotkey_unregister_selected(event)
    end
  end
)

-- -----------------------------------------
-- GUI Click Handlers 
-- -----------------------------------------

local function click_runname_ok(event)
  local player = game.players[event.player_index]
  handle_runname_submit(player)
end

local function click_hide_or_close(event)
  local player = game.players[event.player_index]

  local frame = player.gui.screen.logsim_buffer
  if frame and frame.valid then frame.destroy() end

  local hf = player.gui.screen[M.GUI_HELP_FRAME]
  if hf and hf.valid then hf.destroy() end
end

local function click_reset_open(event)
  local player = game.players[event.player_index]
  UI.show_reset_dialog(player)
end

local function click_reset_cancel(event)
  local player = game.players[event.player_index]
  UI.close_reset_dialog(player)
end

local function click_reset_ok(event)
  local player = game.players[event.player_index]

  local opts = UI.read_reset_dialog(player)
  UI.close_reset_dialog(player)
  if not opts then return end

  if opts.del_items then
    R.do_reset_simulation(player.surface, player.force, Buffer.append_line, opts.del_stats)
  end

  if opts.del_chests or opts.del_machines or opts.del_prot then
    Chests.reset_lists{
      chests = opts.del_chests,
      machines = opts.del_machines,
      protected = opts.del_prot
    }
  end

  if opts.del_log then
    storage.buffer_lines = {}
    storage.perline_counter = 0
    storage.buffer_view = {}
    storage.gui_dirty = {}
    
    storage.run_start_tick = game.tick

    local header = SimLog.build_header{
      mod_name = storage.mod_name,
      mod_version = storage.mod_version,
      run_name = storage.run_name or "",
      start_tick = storage.run_start_tick
    }
    Buffer.append_multiline(header)
  end

  if opts.new_name and opts.new_name ~= "" then
    storage.run_name = opts.new_name
  end

  Buffer.refresh_for_player(player)
end

local function click_buffer_nav(event, element)
  local player = game.players[event.player_index]
  local n = Buffer.count()
  if n == 0 then
    Buffer.refresh_for_player(player)
    return
  end

  local view = storage.buffer_view[player.index]
  if not view then
    local s, e = Buffer.compute_tail_window(M.TEXT_MAX)
    view = { start_line = s, end_line = e, follow = true }
    storage.buffer_view[player.index] = view
  end

  if element.name == M.GUI_BTN_TAIL and not storage.protocol_active then
    view.follow = false
    player.print({"logistics_simulation.protocol_off_static_mode"})
    Buffer.refresh_for_player(player)
    return
  end

  if element.name == M.GUI_BTN_TAIL then
    view.follow = true
    Buffer.refresh_for_player(player)
    return
  end

  local win  = math.max(1, (view.end_line - view.start_line + 1))
  local page = math.max(M.BUFFER_PAGE_LINES, win)

  if element.name == M.GUI_BTN_OLDER then
    view.follow = false

    local new_end = math.max(1, view.start_line - 1)
    local new_start = math.max(1, new_end - (page - 1))

    new_start, new_end = Buffer.fit_window_to_chars(new_end, M.TEXT_MAX)
    view.start_line, view.end_line = new_start, new_end

  else
    view.follow = false

    local new_start = math.min(n, view.end_line + 1)
    local end_limit = math.min(n, new_start + (page - 1))

    local s, e = Buffer.fit_window_forward_to_chars(new_start, end_limit, M.TEXT_MAX)
    view.start_line, view.end_line = s, e
  end

  Buffer.refresh_for_player(player)
end

local function click_copy(event)
  local player = game.players[event.player_index]
  local frame = player.gui.screen.logsim_buffer
  if not (frame and frame.valid) then return end

  local box = frame.logsim_buffer_box
  if not (box and box.valid) then return end

  box.focus()
  box.select_all()
  player.print({"logistics_simulation.msg_copied"})
end

local function click_help_toggle(event)
  local player = game.players[event.player_index]
  local hf = player.gui.screen[M.GUI_HELP_FRAME]
  if hf and hf.valid then
    hf.destroy()
  else
    UI.show_help_gui(player)
  end
end

local function click_help_close(event)
  local player = game.players[event.player_index]
  local hf = player.gui.screen[M.GUI_HELP_FRAME]
  if hf and hf.valid then hf.destroy() end
end

-- Blueprint inventory extraction with cost calculation - MOVED TO blueprint.lua
-- See Blueprint.click_bp_extract()

local function click_invwin_copy(event)
  local player = game.players[event.player_index]
  local frame = player.gui.screen["logsim_invwin"]
  if not (frame and frame.valid) then return end
  
  local box = frame["logsim_invwin_box"]
  if not (box and box.valid) then return end
  
  box.focus()
  box.select_all()
  player.print({"logistics_simulation.msg_copied"})
end

local function click_invwin_close(event)
  local player = game.players[event.player_index]
  UI.close_inventory_window(player)
end

script.on_event(defines.events.on_gui_click, function(event)
  local element = event.element
  if not (element and element.valid) then return end

  local name = element.name

  if name == "logsim_runname_ok" then
    click_runname_ok(event)
  elseif name == M.GUI_BTN_HIDE or name == M.GUI_CLOSE then
    click_hide_or_close(event)
  elseif name == M.GUI_BTN_RESET then
    click_reset_open(event)
  elseif name == M.GUI_RESET_CANCEL then
    click_reset_cancel(event)
  elseif name == M.GUI_RESET_OK then
    click_reset_ok(event)
  elseif name == M.GUI_BTN_OLDER or name == M.GUI_BTN_TAIL or name == M.GUI_BTN_NEWER then
    click_buffer_nav(event, element)
  elseif name == M.GUI_BTN_COPY then
    click_copy(event)
  elseif name == M.GUI_BTN_HELP then
    click_help_toggle(event)
  elseif name == M.GUI_HELP_CLOSE then
    click_help_close(event)
  elseif name == M.GUI_BP_EXTRACTBTN then
    Blueprint.click_bp_extract(event)
  elseif name == "logsim_invwin_copy" then
    click_invwin_copy(event)
  elseif name == "logsim_invwin_close" or name == "logsim_invwin_close_x" then
    click_invwin_close(event)
  end
end)

-- -----------------------------------------
-- Blueprint GUI opened (delegated to blueprint module)
-- -----------------------------------------

script.on_event(defines.events.on_gui_opened, Blueprint.on_gui_opened)
