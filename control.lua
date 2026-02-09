-- =========================================
-- LogSim (Factorio 2.0) 
-- Main runtime controller: wires events, ticks, hotkeys and GUI actions together.
--
-- Version 0.1.0 first für LogSim 
-- Version 0.2.0 first modularisation
-- Version 0.3.0 machines too
-- Version 0.4.0 power, pollution, help etc.
-- Version 0.4.1 code optimisation
-- Version 0.4.2 flexible buffer display
-- Version 0.4.3 reorganise code
-- Version 0.5.0 locale de/en; buffer module
-- Version 0.5.2 multiplayer & multi-surface stability (on_load fix)
-- Version 0.5.3 statistics reset support, localized STATIC mode
-- Version 0.5.4 commands (/gp, /prot, /info), flying text, performance optimization
-- Version 0.6.0 blueprint inventory extraction with cost calculation
-- Version 0.6.1 locale de/en; debugging
-- Version 0.6.2 export to file csv/json
-- Version 0.6.3 stabilising of the mod
-- Version 0.7.x transaction based on inserter action 
-- version 0.8.0 first complete working version
--               complete accounting with export
-- version 0.8.1 tx window with buttons <<  <  >  >> 
-- Version 0.8.2 get global parameters from settings
-- Version 0.8.3 new virtal location WIP / settings added
-- Version 0.8.4 close export Dialog, if owner ist closed
--                 Blueprint.ui_front_tick_handler()
-- Version 0.8.5 manual transactions traced with mod "BIG Brother 1984"
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
local Export = require("export")
local Transaction = require("transaction")
local Util = require("utility")

local _needs_marker_refresh_after_load = false
local PROVIDER_API = "logistics_events_api"
local client_event_id = nil

-- Forward declarations
local debug_print
local ensure_storage_defaults
local maybe_prompt_runname_for_all_players
local handle_runname_submit
local resolve_entity
local cleanup_entity_from_registries
local clear_invalid_rendering_objects


-- Funktion, die die Daten vom Provider verarbeitet
local function handle_logistics_event(event)
    local le = event.logistics_event
    if not le then return end

    -- Feed manual actions into transaction log (player hand behaves like pseudo-inserter Hxx)
    if Transaction and Transaction.ingest_manual_logistics_event then
        Transaction.ingest_manual_logistics_event(le)
    end

    -- Gleiche Ausgabe wie im Big Brother, markiert als [CLIENT]
    local location_str = le.source_or_target.type .. " [ID:" .. le.source_or_target.id .. "] Slot:" .. le.source_or_target.slot_name
    
--    if le.action == "TAKE" then
--        game.print("[CLIENT] TAKE | Tick:" .. le.tick .. " | Actor:" .. le.actor.type .. " | Item:" .. le.item.name .. " | Qty:" .. le.item.quantity)
--    else
--        game.print("[CLIENT] GIVE | Tick:" .. le.tick .. " | Actor:" .. le.actor.type .. " | Target:" .. location_str .. " | Item:" .. le.item.name)
--    end
end

-- Funktion zur Registrierung des Events
local function try_register_at_provider()
    -- Prüfen, ob das Interface des Big Brother existiert
    if remote.interfaces[PROVIDER_API] then
        local event_id = remote.call(PROVIDER_API, "get_event_id")
        
        if event_id then
            client_event_id = event_id
            -- Das Event dynamisch abonnieren
            script.on_event(client_event_id, handle_logistics_event)
            game.print("[Logistics-Client] Erfolgreich beim Big Brother registriert. Event-ID: " .. tostring(event_id))
        end
    end
end

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
  M.ensure_storage_defaults(storage)
end

local function init_storage()
  storage = storage or {}
  M.ensure_storage_defaults(storage)
end

build_base_filename = function(run_name, start_tick)
  local rn = Util.sanitize_filename(run_name or "run")
  local ver = Util.sanitize_filename(get_logger_version())
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

local function on_runtime_mod_setting_changed(event)
  if not (event and event.setting_type == "runtime-global") then return end
  if not storage then return end

  local s = event.setting
  if s ~= "logsim_sample_interval_ticks"
     and s ~= "logsim_buffer_max_lines"
     and s ~= "logsim_tx_max_events" then
    return
  end

  -- Re-read settings into storage (with fallback to config.lua)
  M.ensure_storage_defaults(storage)

  -- Force ringbuffer systems to react immediately
  if Buffer and Buffer.ensure_defaults then
    Buffer.ensure_defaults()
  end
  if Transaction and Transaction.ensure_defaults then
    Transaction.ensure_defaults()
  end
end

-- -----------------------------------------
-- Lifecycle Events
-- -----------------------------------------

script.on_init(function()
  try_register_at_provider()
  init_storage()
  debug_print({"logistics_simulation.mod_initialised"})
  -- Transactions: build initial maps/watchlist (in-memory only)
  if Transaction and Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end
  if Transaction and Transaction.rebuild_watchlist then
    Transaction.rebuild_watchlist()
  end
  maybe_prompt_runname_for_all_players()
end)

script.on_configuration_changed(function(data)
  try_register_at_provider()
  init_storage()
  local mod_changes = data.mod_changes and data.mod_changes["logistics_simulation"]
  if mod_changes then
    local old_version = mod_changes.old_version
    if old_version and old_version < "0.5.2" then
      debug_print({"", "Migrating from ", old_version, " to 0.5.2"})
      storage._needs_rendering_cleanup = true
    end
  end
  -- Transactions: refresh maps/watchlist after migrations/config changes
  if Transaction and Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end
  if Transaction and Transaction.rebuild_watchlist then
    Transaction.rebuild_watchlist()
  end
  maybe_prompt_runname_for_all_players()
end)

script.on_load(function()
  _needs_marker_refresh_after_load = true
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)

-- -----------------------------------------
-- Commands
-- -----------------------------------------

commands.add_command("gp", "Global Power Network: /gp on | /gp off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter

  if arg == "on" then
    storage.gp_enabled = true
    player.surface.create_global_electric_network()
    player.print({"logistics_simulation.cmd_gp_on"})
  elseif arg == "off" then
    storage.gp_enabled = false
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
    storage.tx_active = true
    player.print({"logistics_simulation.cmd_prot_on"})
  elseif arg == "off" then
    storage.protocol_active = false
    storage.tx_active = false
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

  -- Close TX window
  if element.name == M.GUI_TX_FRAME then
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

  -- PATCH #1: Invalidate entity cache
  if Chests.invalidate_cache_entry then
    Chests.invalidate_cache_entry(ent.unit_number)
  end
 
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
      storage.registry, surf_idx, resolve_entity, SimLog.encode_chest)
    if chest_str ~= "" then parts[#parts+1] = chest_str end
    
    local machine_str = SimLog.build_string_for_surface(
      storage.machines, surf_idx, resolve_entity, SimLog.encode_machine)
    if machine_str ~= "" then parts[#parts+1] = machine_str end
    
    SimLog.append_virtual_buffers(parts) 
	
    Buffer.append_line(SimLog.end_telegram(parts))
    
    ::continue::
  end
end

script.on_nth_tick(600, function()
    if not client_event_id then
        try_register_at_provider()
    end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(e)
  if e.setting == "logsim_sample_interval_ticks" then
    local v = settings.global["logsim_sample_interval_ticks"].value
    game.print("SETTING CHANGED -> " .. tostring(v))
  end
end)


script.on_event(defines.events.on_tick, function(event)
  -- Transactions (in-memory): observe inserter movements every tick
  if Transaction and Transaction.on_tick then
    if storage.protocol_active then
      Transaction.on_tick(event.tick)
    end
  end

  if _needs_marker_refresh_after_load then
    if Chests and Chests.refresh_all_markers then
      Chests.refresh_all_markers()
    end
    if Transaction and Transaction.update_marks then
      Transaction.update_marks()
    end
    _needs_marker_refresh_after_load = false
  end  
  
  if storage._needs_rendering_cleanup then
    if Chests and Chests.refresh_all_markers then
      Chests.refresh_all_markers()
    end
    if Transaction and Transaction.update_marks then
      Transaction.update_marks()
    end
    storage._needs_rendering_cleanup = false
  end

  if (event.tick % M.CLEANUP_INTERVAL_TICKS) == 0 then
    Buffer.cleanup_disconnected_players()
    -- NEU: Blueprint session cleanup
    if Blueprint.cleanup_all_disconnected then
      Blueprint.cleanup_all_disconnected()
    end	
  end

  if storage.marker_dirty then
    tick_update_markers()
    storage.marker_dirty = false
  end
  
  Blueprint.ui_front_tick_handler()

  Buffer.tick_refresh_open_guis(event.tick)
  
  -- TX GUI refresh (throttled, like Buffer)
  if Transaction and Transaction.tx_tick_refresh_open_guis then
    Transaction.tx_tick_refresh_open_guis(event.tick)
  end

  -- Clean up blueprint sidecars (delegated to blueprint module)
  Blueprint.tick_cleanup_sidecars()

  if not storage.protocol_active then return end
  if not tick_should_log() then return end
  tick_build_and_append_logline()
end)

-- -----------------------------------------
-- Player Lifecycle Events
-- -----------------------------------------

script.on_event(defines.events.on_player_left_game, function(event)
  -- Blueprint session cleanup
  if Blueprint.cleanup_session then
    Blueprint.cleanup_session(event.player_index)
  end 
  -- Auch Buffer view state cleanen
  if storage.buffer_view then
    storage.buffer_view[event.player_index] = nil
  end
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

-- NEW: Shift+R - if inserter is selected, allow activation ONLY if watched

local function hotkey_register_chest(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end

  local ent = player.selected

  -- Inserter path: fully handled inside Transaction (messages included)
  if Transaction and Transaction.handle_register_hotkey then
    local handled = Transaction.handle_register_hotkey(player, ent)
    if handled then return end
  end

  -- Default behavior (registry)
  Chests.register_selected(player, Buffer.append_line)

  -- After registering objects: refresh TX maps/watch immediately
  if Transaction and Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end
  if Transaction and Transaction.rebuild_watchlist then
    Transaction.rebuild_watchlist()
  end
end

local function hotkey_register_protect(event)
  local player = game.players[event.player_index]
  Chests.register_protect(player, Buffer.append_line)
end

-- NEW: Shift+U - if inserter is selected, clear active marking (back to yellow)
local function hotkey_unregister_selected(event)
  local player = game.players[event.player_index]
  local ent = player.selected

  if ent and ent.valid and ent.type == "inserter" and ent.unit_number then
    if Transaction and Transaction.set_inserter_active then
      Transaction.set_inserter_active(ent.unit_number, false)
      player.print({"logistics_simulation.tx_inserter_marked_auto"})
    end
    return
  end

  -- default behavior
  Chests.unregister_selected(player, Buffer.append_line)
  -- after unregistering objects, refresh TX maps/watch immediately
  if Transaction and Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end
  if Transaction and Transaction.rebuild_watchlist then
    Transaction.rebuild_watchlist()
  end
  
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

-- TX Window handlers
local function click_tx_open(event)
  local player = game.players[event.player_index]
  UI.show_tx_gui(player)
  if Transaction and Transaction.tx_refresh_for_player then
    Transaction.tx_refresh_for_player(player)
  else
    -- fallback: mark dirty; refresh done on tick
    storage.tx_gui_dirty = storage.tx_gui_dirty or {}
    storage.tx_gui_dirty[player.index] = true
  end
end

local function click_tx_hide(event)
  local player = game.players[event.player_index]
  UI.close_tx_gui(player)
  UI.close_export_dialog_if_owner(player, "tx")
end

local function click_tx_older(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_page_older then Transaction.tx_page_older(player) end
end

local function click_tx_newer(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_page_newer then Transaction.tx_page_newer(player) end
end

local function click_tx_home(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_home then Transaction.tx_home(player) end
end

local function click_tx_end(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_end then Transaction.tx_end(player)
  elseif Transaction and Transaction.tx_tail then Transaction.tx_tail(player) end
end

local function click_tx_copy(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_copy_to_clipboard then Transaction.tx_copy_to_clipboard(player) end
end
-- -----------------------------------------

local function click_buffer_export(event)
  local player = game.players[event.player_index]
  storage.export_mode = "buffer"
  UI.show_export_dialog(player)
end

local function click_tx_export(event)
  local player = game.players[event.player_index]
  storage.export_mode = "tx"
  UI.show_export_dialog(player)
end

local function click_inv_export(event)
  local player = game.players[event.player_index]
  storage.export_mode = "inv"
  UI.show_export_dialog(player)
end


local function click_export_csv(event)
  local player = game.players[event.player_index]
  if storage.export_mode == "tx" then
    Export.export_tx_csv(player)
  elseif storage.export_mode == "inv" then
    Export.export_inv_csv(player)
  else
    Export.export_csv(player) -- buffer/protocol
  end
end

local function click_export_json(event)
  local player = game.players[event.player_index]
  if storage.export_mode == "tx" then
    Export.export_tx_json(player)
  elseif storage.export_mode == "inv" then
    Export.export_inv_json(player)
  else
    Export.export_json(player) -- buffer/protocol
  end
end

local function click_export_close(event)
  local player = game.players[event.player_index]
  UI.close_export_dialog(player)
end

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
  UI.close_export_dialog_if_owner(player, "buffer")
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

  -- >>> FIX: Ringpuffer-State ebenfalls resetten
  storage.buffer_head = 1
  storage.buffer_size = 0
  storage._buffer_last_max = nil
  -- <<<

  storage.run_start_tick = game.tick

  if Transaction and Transaction.reset_tx_log then
    Transaction.reset_tx_log()
  end

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
  UI.close_export_dialog_if_owner(player, "inv")
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
  elseif name == M.GUI_BTN_TX_OPEN then
    click_tx_open(event)
  elseif name == M.GUI_TX_CLOSE or name == M.GUI_TX_BTN_HIDE then
    click_tx_hide(event)
  elseif name == M.GUI_TX_BTN_OLDER then
    click_tx_older(event)
  elseif name == M.GUI_TX_BTN_HOME then
    click_tx_home(event)
  elseif name == M.GUI_TX_BTN_END then
    click_tx_end(event)
  elseif name == M.GUI_TX_BTN_NEWER then
    click_tx_newer(event)
  elseif name == M.GUI_TX_BTN_COPY then
    click_tx_copy(event)	
  elseif name == M.GUI_BTN_EXPORT then
    click_buffer_export(event)
  elseif name == M.GUI_TX_BTN_EXPORT then
    click_tx_export(event)
  elseif name == M.GUI_INV_BTN_EXPORT then
    click_inv_export(event)
  elseif name == M.GUI_BTN_EXPORT_CSV then
    click_export_csv(event)
  elseif name == M.GUI_BTN_EXPORT_JSON then
    click_export_json(event)
  elseif name == M.GUI_EXPORT_CLOSE then
    click_export_close(event)
  end 
end)


-- -----------------------------------------
-- Remote Interface (Debug helpers)
-- -----------------------------------------
remote.add_interface("logsim", {
  registry_size = function()
    return storage and storage.registry and table_size(storage.registry) or 0
  end,

  machines_size = function()
    return storage and storage.machines and table_size(storage.machines) or 0
  end,

  protocol_active = function()
    return storage and storage.protocol_active or false
  end,

  tx_events_size = function()
    return storage and storage.tx_events and #storage.tx_events or 0
  end,
  
  tx_watch_size = function()
    return storage and storage.tx_watch and table_size(storage.tx_watch) or 0
  end,

  tx_objmap_size = function()
    return storage and storage.tx_obj_by_unit and table_size(storage.tx_obj_by_unit) or 0
  end,

  tx_last_rebuild = function()
    return storage and storage.tx_last_rebuild_tick or 0
  end,

  tx_last = function()
    local t = storage and storage.tx_events
    if not t or #t == 0 then return nil end
    return t[#t]
  end,
  
  tx_version = function()
    return Transaction and Transaction.version or "nil"
  end,

  tx_debug_scan = function()
    local rec = nil
    for _, r in pairs(storage.registry or {}) do rec = r; break end
    if not rec then return "no registry" end
    if not rec.surface_index then return "no surface_index" end
    if not rec.position then return "no position" end

    local surface = game.get_surface(rec.surface_index)
    if not (surface and surface.valid) then return "bad surface" end

    local pos = rec.position
    local rads = 20
    local area = { {pos.x - rads, pos.y - rads}, {pos.x + rads, pos.y + rads} }

    local all = surface.find_entities_filtered{ area = area } or {}
    local ins = 0
    for _, e in pairs(all) do
      if e and e.valid and e.type == "inserter" then ins = ins + 1 end
    end

    return string.format("surf=%s pos=(%.1f,%.1f) ents=%d inserters=%d",
      tostring(surface.name), pos.x, pos.y, #all, ins)
  end,

  tx_watch_dbg = function()
    local d = storage and storage.tx_dbg_watch
    if not d then return "no dbg record" end
    return string.format(
      "stamp=%s tick=%s scanned=%s added=%s watch=%s r=%s",
      tostring(d.stamp), tostring(d.tick),
      tostring(d.scanned), tostring(d.added),
      tostring(d.watch_size), tostring(d.r)
    )
  end,

  tx_watch_meta_size = function()
    return storage and storage.tx_watch_meta and table_size(storage.tx_watch_meta) or 0
  end,

  tx_rebuild_now = function()
    if not (Transaction and Transaction.rebuild_object_map and Transaction.rebuild_watchlist) then
      return false
    end
    Transaction.rebuild_object_map()
    Transaction.rebuild_watchlist()
    return true
  end
})


-- -----------------------------------------
-- Blueprint GUI opened (delegated to blueprint module)
-- -----------------------------------------

script.on_event(defines.events.on_gui_opened, Blueprint.on_gui_opened)
