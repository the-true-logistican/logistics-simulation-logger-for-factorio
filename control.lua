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
--               Blueprint.ui_front_tick_handler()
-- Version 0.8.5 manual transactions traced with mod "BIG Brother 1984"
-- Version 0.8.6 periodic action moved to on_nth_tick
--               Reset clears players inventory too
--               Simple Days-Time-Clock
-- Version 0.8.7 event_registry as general solution
--               new topbar show, prot on/off, global power
--               GUI-Handler moved to separate module
-- Version 0.8.8 show_xxxx if exists then bring_to_front + return
--               Reset clears roboports (robots + repair mats) + destroys flying bots
-- Version 0.8.x only small debugging and code revision
-- Version 0.8.12 Config correct handle
-- Version 0.8.14 sync topbar with statuw
-- Version 0.8.15 EMA Module – Exponential Moving Average über Bestände
--                extract from blueprint with tabs
-- Version 0.9.0 Stable Ledger Operational Baseline 
--
-- =========================================
-- Version 0.9 consolidates Factory Ledger into an operational pre-1.0 baseline. 
-- The core simulation logger, accounting ledger, transaction tracking, inventory 
-- analysis, reset workflow, and export pipeline are now functionally complete and 
-- ready for structured bookkeeping runs.
-- =========================================

local M = require("config")
local Buffer = require("buffer")
local R = require("reset")
local UI = require("ui")
local EMA = require("ema")
local Chests = require("chests")
local SimLog = require("simlog")
local ItemCost = require("itemcost")
local Blueprint = require("blueprint")
local Export = require("export")
local Transaction = require("transaction")
local Util = require("utility")
local mod_gui = require("mod-gui")
local GUI = require("gui_handlers")  


local _needs_marker_refresh_after_load = false
local _needs_topbar_sync = false

local Registry = require("event_registry")
local PROVIDER_API = "logistics_events_api"

-- Forward declarations
local ensure_storage_defaults
local maybe_prompt_runname_for_all_players
local resolve_entity
local cleanup_entity_from_registries
local clear_invalid_rendering_objects

local needs_registration = false
local event_registry = nil
local _needs_UI_time_Window = false

-- Funktion, die die Daten vom Provider verarbeitet
local function handle_logistics_event(event)
  local le = event.logistics_event
  if not le then return end
  -- Feed manual actions into transaction log (player hand behaves like pseudo-inserter Hxx)
  if Transaction and Transaction.ingest_manual_logistics_event then
    Transaction.ingest_manual_logistics_event(le)
  end
end

-- Funktion zur Registrierung des Events beim Provider
local function try_register_logistics_events()
    -- Prüfen, ob das Interface des Big Brother existiert
    if not remote.interfaces[PROVIDER_API] then
        return false
    end
    
    local event_id = remote.call(PROVIDER_API, "get_event_id")
    if not event_id then
        return false
    end
    
    -- Registry komplett neu aufbauen und Event registrieren
    event_registry = Registry.new()
    event_registry:add(event_id, handle_logistics_event)
    event_registry:bind()
    
    game.print("[Logistics-Client] Erfolgreich beim Big Brother registriert. Event-ID: " .. tostring(event_id))
    return true
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


ensure_storage_defaults = function()
  M.ensure_storage_defaults(storage)
end

local function init_storage()
  storage = storage or {}
  M.ensure_storage_defaults(storage)
  M.apply_all_settings()
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
  M.apply_all_settings()

  -- Force ringbuffer systems to react immediately
  if Buffer and Buffer.ensure_defaults then
    Buffer.ensure_defaults()
  end
  if Transaction and Transaction.ensure_defaults then
    Transaction.ensure_defaults()
  end
end

-- -----------------------------------------
-- Custom Inputs (Hotkeys)
-- -----------------------------------------

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


-- =====================================
-- Topbar Button Handler mit Protokoll und Global Power
-- =====================================

-- moved to gui_handlers.lua

-- -----------------------------------------
-- Lifecycle Events
-- -----------------------------------------

script.on_init(function()
    -- Setze Flag, dass wir beim nächsten Tick registrieren müssen
    needs_registration = true
    event_registry = Registry.new()

  init_storage()
  Util.debug_print({"logistics_simulation.mod_initialised"})
  -- Transactions: build initial maps/watchlist (in-memory only)
  if Transaction and Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end
  if Transaction and Transaction.rebuild_watchlist then
    Transaction.rebuild_watchlist()
  end
  maybe_prompt_runname_for_all_players()
  UI.rebuild_all_topbars()
  GUI.update_topbar_buttons()  -- States nach dem Bauen setzen
end)

script.on_configuration_changed(function(data)
    -- Setze Flag, dass wir beim nächsten Tick registrieren müssen
    needs_registration = true
    event_registry = Registry.new()

  init_storage()
  local mod_changes = data.mod_changes and data.mod_changes["logistics_simulation"]
  if mod_changes then
    local old_version = mod_changes.old_version
    if old_version and old_version < "0.5.2" then
      Util.debug_print({"", "Migrating from ", old_version, " to 0.5.2"})
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
  UI.rebuild_all_topbars()
  GUI.update_topbar_buttons()  -- States nach dem Bauen setzen
end)

script.on_load(function()
    -- Setze Flag, dass wir beim nächsten Tick registrieren müssen
    needs_registration = true
    event_registry = Registry.new()

  _needs_marker_refresh_after_load = true
  _needs_UI_time_Window = true
  _needs_topbar_sync = true  -- Button-Sprites beim ersten Tick nach Load synchronisieren
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)

-- -----------------------------------------
-- Commands
-- -----------------------------------------

-- Befehl: /prot
commands.add_command("prot", "Protocol Recording: /prot on | /prot off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter
  
  if arg == "on" then
    GUI.set_protocol_state(player, true)  -- Jetzt über GUI
  elseif arg == "off" then
    GUI.set_protocol_state(player, false) -- Jetzt über GUI
  else
    player.print({"logistics_simulation.cmd_prot_usage"})
  end
end)

-- Befehl: /gp
commands.add_command("gp", "Global Power Network: /gp on | /gp off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter
  local surface = player.surface

  if arg == "on" then
    GUI.set_global_power_state(player, surface, true)  -- Jetzt über GUI
  elseif arg == "off" then
    GUI.set_global_power_state(player, surface, false) -- Jetzt über GUI
  else
    player.print({"logistics_simulation.cmd_gp_usage"})
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
  GUI.click_runname_ok(event) 
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

    -- EMA: Snapshot sammeln und gleitenden Durchschnitt updaten
    local ema_snap = EMA.collect_snapshot(surf_idx)
    EMA.update(ema_snap, tick)
   
    ::continue::
  end
end

script.on_nth_tick(M.CLOCk_INTERVAL_TICKS, function()
for _, player in pairs(game.players) do
    -- Prüfen, ob der Spieler überhaupt im Spiel (valid) ist
    if player.valid then
      local tick = game.tick 
      
      -- Hol dir die Oberfläche direkt vom Spieler-Objekt
      local surface = player.surface
      
      -- Jetzt kannst du die Oberfläche für deine Zeitberechnung nutzen
      local zeit = Util.to_excel_daystime(tick, surface)
      
      UI.set_status_text(player, zeit)
    end
  end
end)

script.on_nth_tick(M.CLEANUP_INTERVAL_TICKS, function()

  if needs_registration then
    needs_registration = false
    try_register_logistics_events()
  end

  Buffer.cleanup_disconnected_players()
  if Blueprint.cleanup_all_disconnected then
    Blueprint.cleanup_all_disconnected()
  end	
end)

script.on_nth_tick(M.GUI_REFRESH_TICKS, function()
  Buffer.tick_refresh_open_guis()
  Transaction.tx_tick_refresh_open_guis()
end)

script.on_event(defines.events.on_tick, function(event)
  -- Transactions (in-memory): observe inserter movements every tick
  if Transaction and Transaction.on_tick then
    if storage.protocol_active then
      Transaction.on_tick(event.tick)
    end
  end

  if _needs_UI_time_Window then
    _needs_UI_time_Window = false
    for _, player in pairs(game.players) do
      UI.ensure_placeholder_frame(player)

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

  -- Button-Sprites nach Save-Load mit storage-Zustand synchronisieren
  -- (on_load darf keine game-API nutzen; daher Flag-Pattern über on_tick)
  if _needs_topbar_sync then
    _needs_topbar_sync = false
    GUI.update_topbar_buttons()
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

  if storage.marker_dirty then
    tick_update_markers()
    storage.marker_dirty = false
  end
  
  Blueprint.ui_front_tick_handler()

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
      GUI.hotkey_toggle_buffer(event)
    elseif name == "logsim_register_chest" then
      hotkey_register_chest(event)
    elseif name == "logsim_register_protect" then
      hotkey_register_protect(event)
    elseif name == "logsim_unregister_selected" then
      hotkey_unregister_selected(event)
    end
  end
)

-- =========================================
-- GUI Click Handlers (JETZT SEHR SCHLANK)
-- =========================================

script.on_event(defines.events.on_gui_click, function(event)

  local player = game.get_player(event.player_index)
  if not player then return end

  local element = event.element
  if not (element and element.valid) then return end
    
  -- Zuerst prüfen, ob es einer unserer Topbar-Buttons ist
  if element.name == M.TOPBAR_BTN1 or 
     element.name == M.TOPBAR_BTN2 or 
     element.name == M.TOPBAR_BTN3 then
    GUI.handle_topbar_click(event, player, element)  -- Jetzt über GUI
    return
  end

  local name = element.name

  -- Inventory Window Tabs
  if GUI.click_invwin_tab(event, element) then return end

  -- Run Name Dialog
  if name == "logsim_runname_ok" then
    GUI.click_runname_ok(event)
  
  -- Buffer/TX/Help Windows  
  elseif name == M.GUI_BTN_HIDE or name == M.GUI_CLOSE then
    GUI.click_hide_or_close(event)
  elseif name == M.GUI_BTN_RESET then
    GUI.click_reset_open(event)
  elseif name == M.GUI_RESET_CANCEL then
    GUI.click_reset_cancel(event)
  elseif name == M.GUI_RESET_OK then
    GUI.click_reset_ok(event)
  elseif name == M.GUI_BTN_OLDER or name == M.GUI_BTN_TAIL or name == M.GUI_BTN_NEWER then
    GUI.click_buffer_nav(event, element)
  elseif name == M.GUI_BTN_COPY then
    GUI.click_copy(event)
  elseif name == M.GUI_BTN_HELP then
    GUI.click_help_toggle(event)
  elseif name == M.GUI_HELP_CLOSE then
    GUI.click_help_close(event)
  elseif name == M.GUI_BP_EXTRACTBTN then
    Blueprint.click_bp_extract(event)
  
  -- Inventory Window
  elseif name == "logsim_invwin_copy" then
    GUI.click_invwin_copy(event)
  elseif name == "logsim_invwin_close" or name == "logsim_invwin_close_x" then
    GUI.click_invwin_close(event)
  
  -- TX Window
  elseif name == M.GUI_BTN_TX_OPEN then
    GUI.click_tx_open(event)
  elseif name == M.GUI_TX_CLOSE or name == M.GUI_TX_BTN_HIDE then
    GUI.click_tx_hide(event)
  elseif name == M.GUI_TX_BTN_OLDER then
    GUI.click_tx_older(event)
  elseif name == M.GUI_TX_BTN_HOME then
    GUI.click_tx_home(event)
  elseif name == M.GUI_TX_BTN_END then
    GUI.click_tx_end(event)
  elseif name == M.GUI_TX_BTN_NEWER then
    GUI.click_tx_newer(event)
  elseif name == M.GUI_TX_BTN_COPY then
    GUI.click_tx_copy(event)
  
  -- Export Dialog  
  elseif name == M.GUI_BTN_EXPORT then
    GUI.click_buffer_export(event)
  elseif name == M.GUI_TX_BTN_EXPORT then
    GUI.click_tx_export(event)
  elseif name == M.GUI_INV_BTN_EXPORT then
    GUI.click_inv_export(event)
  elseif name == M.GUI_BTN_EXPORT_CSV then
    GUI.click_export_csv(event)
  elseif name == M.GUI_BTN_EXPORT_JSON then
    GUI.click_export_json(event)
  elseif name == M.GUI_EXPORT_CLOSE then
    GUI.click_export_close(event)
  end 
end)





script.on_event(defines.events.on_player_created, function(e)
  local player = game.get_player(e.player_index)
  if player then
    UI.build_topbar(player)
    -- Nach dem Bauen die korrekten Sprites setzen
    local button_flow = mod_gui.get_button_flow(player)
    local root = button_flow[M.TOPBAR_ROOT]
    if root and root.valid then
      local btn2 = root[M.TOPBAR_BTN2]
      if btn2 and btn2.valid then
        btn2.sprite = storage.protocol_active and M.TOPBAR_BTN2_ON_SPRITE or M.TOPBAR_BTN2_OFF_SPRITE
      end
      local btn3 = root[M.TOPBAR_BTN3]
      if btn3 and btn3.valid then
        btn3.sprite = storage.gp_enabled and M.TOPBAR_BTN3_ON_SPRITE or M.TOPBAR_BTN3_OFF_SPRITE
      end
    end
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
