-- =========================================
-- LogSim (Factorio 2.0)
-- Main Runtime Controller
--
-- Wires lifecycle events, ticks, commands, hotkeys, GUI actions and the
-- optional manual-logistics provider into the runtime modules.
--
-- Version 0.1.0 initial runtime controller
-- Version 0.2.0 first modularization
-- Version 0.3.0 machine support
-- Version 0.4.0 power, pollution and help support
-- Version 0.5.0 locale and buffer module integration
-- Version 0.5.2 multiplayer and multi-surface stability
-- Version 0.6.0 blueprint inventory extraction with cost calculation
-- Version 0.7.x inserter-based transaction tracking
-- Version 0.8.0 operational accounting baseline with export
-- Version 0.8.7 GUI handlers moved to separate module
-- Version 0.8.15 EMA module integration
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 day/night toggle and transitive machine registration
-- Version 0.9.2 roboport, cargo-wagon and fluid-wagon registration
-- Version 0.9.3 local cleanup and controller simplification
--
-- =========================================

local M = require("config")
local Buffer = require("buffer")
local UI = require("ui")
local EMA = require("ema")
local Chests = require("chests")
local SimLog = require("simlog")
local Blueprint = require("blueprint")
local Transaction = require("transaction")
local Util = require("utility")
local Registry = require("event_registry")
local GUI = require("gui_handlers")

local PROVIDER_API = "logistics_events_api"

local needs_registration = false
local event_registry = nil
local needs_marker_refresh_after_load = false
local needs_topbar_sync = false
local needs_time_window = false

-- =========================================
-- Manual-logistics provider integration
-- =========================================

local function handle_logistics_event(event)
  local logistics_event = event.logistics_event
  if not logistics_event then return end

  if Transaction and Transaction.ingest_manual_logistics_event then
    Transaction.ingest_manual_logistics_event(logistics_event)
  end
end

local function try_register_logistics_events()
  if not remote.interfaces[PROVIDER_API] then
    return false
  end

  local event_id = remote.call(PROVIDER_API, "get_event_id")
  if not event_id then
    return false
  end

  event_registry = Registry.new()
  event_registry:add(event_id, handle_logistics_event)
  event_registry:bind()

  game.print("[LogSim] Manual logistics provider registered. Event-ID: " .. tostring(event_id))
  return true
end

-- =========================================
-- Shared controller helpers
-- =========================================

local function init_storage()
  storage = storage or {}
  M.ensure_storage_defaults(storage)
  M.apply_all_settings()
end

local function maybe_prompt_runname_for_all_players()
  if storage.run_name and storage.run_name ~= "" then
    return
  end

  for _, player in pairs(game.players) do
    UI.show_runname_gui(player)
  end
end

local function rebuild_transaction_topology()
  if Transaction and Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end

  if Transaction and Transaction.rebuild_watchlist then
    Transaction.rebuild_watchlist()
  end
end

local function rebuild_runtime_markers()
  if Chests and Chests.refresh_all_markers then
    Chests.refresh_all_markers()
  end

  if Transaction and Transaction.update_marks then
    Transaction.update_marks()
  end
end

local function has_registered_endpoints()
  return (storage.registry and next(storage.registry) ~= nil)
      or (storage.machines and next(storage.machines) ~= nil)
end

local function is_logsim_topbar_button(name)
  return name == M.TOPBAR_BTN1
      or name == M.TOPBAR_BTN2
      or name == M.TOPBAR_BTN3
      or name == M.TOPBAR_BTN4
end

local function is_supported_runtime_setting(name)
  return name == M.SETTING_KEYS.INTERVAL
      or name == M.SETTING_KEYS.BUFFER_MAX
      or name == M.SETTING_KEYS.TX_MAX
end

local function on_runtime_mod_setting_changed(event)
  if not (event and event.setting_type == "runtime-global") then return end
  if not storage then return end
  if not is_supported_runtime_setting(event.setting) then return end

  M.ensure_storage_defaults(storage)
  M.apply_all_settings()

  if Buffer and Buffer.ensure_defaults then
    Buffer.ensure_defaults()
  end

  if Transaction and Transaction.ensure_defaults then
    Transaction.ensure_defaults()
  end
end

-- =========================================
-- Hotkeys
-- =========================================

local function hotkey_register_chest(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end

  local ent = player.selected

  if Transaction and Transaction.handle_register_hotkey then
    local handled = Transaction.handle_register_hotkey(player, ent)
    if handled then return end
  end

  Chests.register_selected(player, Buffer.append_line)

  if Transaction and Transaction.rebuild_object_map then
    Transaction.rebuild_object_map()
  end

  if Transaction and Transaction.autoregister_machine_closure then
    Transaction.autoregister_machine_closure(player, Buffer.append_line)
  end

  rebuild_transaction_topology()
end

local function hotkey_register_protect(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end

  Chests.register_protect(player, Buffer.append_line)
end

local function selected_machine_is_required(ent)
  return ent
     and ent.valid
     and ent.unit_number
     and storage.machines
     and storage.machines[ent.unit_number]
     and Transaction
     and Transaction.is_machine_required_by_closure
     and Transaction.is_machine_required_by_closure(ent.unit_number)
end

local function log_blocked_machine_unregister(player, ent)
  local rec = storage.machines[ent.unit_number]
  local id = rec and rec.id or "?"

  Util.info_print(player, {"", "[LogSim] Cannot unregister ", id, ": machine is still required by registered objects."})
  Util.fly(player, ent, {"", "KEEP ", id})

  if Buffer and Buffer.append_line then
    Buffer.append_line(string.format(
      "EV;%d;UNMACH_BLOCKED;%s;%d;reason=closure_required",
      game.tick,
      id,
      ent.unit_number
    ))
  end
end

local function hotkey_unregister_selected(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end

  local ent = player.selected

  if ent and ent.valid and ent.type == "inserter" and ent.unit_number then
    if Transaction and Transaction.set_inserter_active then
      Transaction.set_inserter_active(ent.unit_number, false)
      player.print({"logistics_simulation.tx_inserter_marked_auto"})
    end
    return
  end

  if selected_machine_is_required(ent) then
    log_blocked_machine_unregister(player, ent)
    return
  end

  Chests.unregister_selected(player, Buffer.append_line)
  rebuild_transaction_topology()
end

-- =========================================
-- Lifecycle events
-- =========================================

script.on_init(function()
  needs_registration = true

  init_storage()
  Util.debug_print({"logistics_simulation.mod_initialised"})

  rebuild_transaction_topology()
  maybe_prompt_runname_for_all_players()
  UI.rebuild_all_topbars()
  GUI.update_topbar_buttons()
end)

script.on_configuration_changed(function(data)
  needs_registration = true

  init_storage()

  local mod_changes = data.mod_changes and data.mod_changes["logistics_simulation"]
  if mod_changes then
    local old_version = mod_changes.old_version
    if old_version and old_version < "0.5.2" then
      Util.debug_print({"", "Migrating from ", old_version, " to 0.5.2"})
      storage._needs_rendering_cleanup = true
    end
  end

  rebuild_transaction_topology()
  maybe_prompt_runname_for_all_players()
  UI.rebuild_all_topbars()
  GUI.update_topbar_buttons()
end)

script.on_load(function()
  needs_registration = true
  needs_marker_refresh_after_load = true
  needs_time_window = true
  needs_topbar_sync = true
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)

-- =========================================
-- Commands
-- =========================================

commands.add_command("prot", "Protocol Recording: /prot on | /prot off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter

  if arg == "on" then
    GUI.set_protocol_state(player, true)
  elseif arg == "off" then
    GUI.set_protocol_state(player, false)
  else
    player.print({"logistics_simulation.cmd_prot_usage"})
  end
end)

commands.add_command("gp", "Global Power Network: /gp on | /gp off", function(event)
  local player = game.players[event.player_index]
  local arg = event.parameter
  local surface = player.surface

  if arg == "on" then
    GUI.set_global_power_state(player, surface, true)
  elseif arg == "off" then
    GUI.set_global_power_state(player, surface, false)
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

-- =========================================
-- GUI lifecycle events
-- =========================================

script.on_event(defines.events.on_gui_confirmed, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  if element.name ~= "logsim_runname_text" then return end

  GUI.click_runname_ok(event)
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local element = event.element
  if not (element and element.valid) then return end

  if element.name == M.GUI_BUFFER_FRAME then
    element.destroy()
    return
  end

  if element.name == M.GUI_TX_FRAME then
    element.destroy()
    return
  end

  if element.name == M.GUI_INV_FRAME then
    element.destroy()
    return
  end
end)

-- =========================================
-- Entity cleanup events
-- =========================================

local entity_cleanup_events = {
  defines.events.on_entity_died,
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.script_raised_destroy
}

script.on_event(entity_cleanup_events, function(event)
  local ent = event.entity
  if not (ent and ent.unit_number) then return end

  if Chests and Chests.cleanup_entity_from_registries then
    Chests.cleanup_entity_from_registries(ent.unit_number, Buffer.append_line)
  end
end)

-- =========================================
-- Logging ticks
-- =========================================

local function tick_should_log()
  if not storage.run_name then return false end
  if (game.tick % storage.sample_interval) ~= 0 then return false end
  return true
end

local function build_surfaces_used()
  local surfaces_used = {}

  for _, rec in pairs(storage.registry or {}) do
    surfaces_used[rec.surface_index] = true
  end

  for _, rec in pairs(storage.machines or {}) do
    surfaces_used[rec.surface_index] = true
  end

  for _, player in pairs(game.players) do
    if player
       and player.valid
       and player.character
       and player.surface
       and player.surface.valid then
      surfaces_used[player.surface.index] = true
    end
  end

  if not next(surfaces_used) then
    surfaces_used[1] = true
  end

  return surfaces_used
end

local function append_surface_logline(tick, surface_index)
  local surface = game.get_surface(surface_index)
  if not (surface and surface.valid) then return end

  local force = game.forces["player"]
  if not (force and force.valid) then return end

  local parts = SimLog.begin_telegram(tick, surface, force)

  local chest_str = SimLog.build_string_for_surface(
    storage.registry,
    surface_index,
    Chests.resolve_entity,
    SimLog.encode_chest
  )
  if chest_str ~= "" then
    parts[#parts + 1] = chest_str
  end

  local player_inv_str = SimLog.build_player_inventory_string_for_surface(surface_index)
  if player_inv_str ~= "" then
    parts[#parts + 1] = player_inv_str
  end

  local machine_str = SimLog.build_string_for_surface(
    storage.machines,
    surface_index,
    Chests.resolve_entity,
    SimLog.encode_machine
  )
  if machine_str ~= "" then
    parts[#parts + 1] = machine_str
  end

  SimLog.append_virtual_buffers(parts)
  Buffer.append_line(SimLog.end_telegram(parts))

  local ema_snapshot = EMA.collect_snapshot(surface_index)
  EMA.update(ema_snapshot, tick)
end

local function tick_build_and_append_logline()
  local tick = game.tick
  local surfaces_used = build_surfaces_used()

  if Transaction and Transaction.rebuild_hand_list then
    Transaction.rebuild_hand_list()
  end

  for surface_index, _ in pairs(surfaces_used) do
    append_surface_logline(tick, surface_index)
  end
end

-- =========================================
-- Periodic tasks
-- =========================================

script.on_nth_tick(M.CLOCk_INTERVAL_TICKS, function()
  for _, player in pairs(game.players) do
    if player.valid then
      local text = Util.to_excel_daystime(game.tick, player.surface)
      storage.current_daytime_text = text
      UI.set_status_text(player, text)
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

script.on_nth_tick(M.TX_Topology_Refesh, function()
  if not storage then return end
  if not has_registered_endpoints() then return end

  rebuild_transaction_topology()
end)

script.on_nth_tick(M.GUI_REFRESH_TICKS, function()
  Buffer.tick_refresh_open_guis()
  Transaction.tx_tick_refresh_open_guis()
end)

script.on_event(defines.events.on_tick, function(event)
  if Transaction and Transaction.on_tick and storage.protocol_active then
    Transaction.on_tick(event.tick)
  end

  if needs_time_window then
    needs_time_window = false
    for _, player in pairs(game.players) do
      UI.ensure_placeholder_frame(player)
    end
  end

  if needs_marker_refresh_after_load then
    rebuild_runtime_markers()
    needs_marker_refresh_after_load = false
  end

  if needs_topbar_sync then
    needs_topbar_sync = false
    GUI.update_topbar_buttons()
  end

  if storage._needs_rendering_cleanup then
    rebuild_runtime_markers()
    storage._needs_rendering_cleanup = false
  end

  if Chests and Chests.tick_marker_refresh then
    Chests.tick_marker_refresh()
  end

  Blueprint.ui_front_tick_handler()
  Blueprint.tick_cleanup_sidecars()

  if not storage.protocol_active then return end
  if not tick_should_log() then return end

  tick_build_and_append_logline()
end)

-- =========================================
-- Player lifecycle events
-- =========================================

script.on_event(defines.events.on_player_left_game, function(event)
  if Blueprint.cleanup_session then
    Blueprint.cleanup_session(event.player_index)
  end

  if storage.buffer_view then
    storage.buffer_view[event.player_index] = nil
  end
end)

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  UI.build_topbar(player)
  GUI.update_topbar_buttons()
end)

-- =========================================
-- Custom input dispatch
-- =========================================

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
-- GUI click dispatch
-- =========================================

script.on_event(defines.events.on_gui_click, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local element = event.element
  if not (element and element.valid) then return end

  if is_logsim_topbar_button(element.name) then
    GUI.handle_topbar_click(event, player, element)
    return
  end

  if GUI.click_invwin_tab(event, element) then return end

  local name = element.name

  if name == "logsim_runname_ok" then
    GUI.click_runname_ok(event)

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

  elseif name == M.GUI_INV_BTN_COPY then
    GUI.click_invwin_copy(event)
  elseif name == M.GUI_INV_BTN_CLOSE or name == M.GUI_INV_CLOSE_X then
    GUI.click_invwin_close(event)

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

-- =========================================
-- Remote interface
-- =========================================

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
    local events = storage and storage.tx_events
    if not events or #events == 0 then return nil end
    return events[#events]
  end,

  tx_version = function()
    return Transaction and Transaction.version or "nil"
  end,

  tx_debug_scan = function()
    local rec = nil
    for _, candidate in pairs(storage.registry or {}) do
      rec = candidate
      break
    end

    if not rec then return "no registry" end
    if not rec.surface_index then return "no surface_index" end
    if not rec.position then return "no position" end

    local surface = game.get_surface(rec.surface_index)
    if not (surface and surface.valid) then return "bad surface" end

    local pos = rec.position
    local radius = 20
    local area = {
      { pos.x - radius, pos.y - radius },
      { pos.x + radius, pos.y + radius }
    }

    local entities = surface.find_entities_filtered{ area = area } or {}
    local inserters = 0

    for _, ent in pairs(entities) do
      if ent and ent.valid and ent.type == "inserter" then
        inserters = inserters + 1
      end
    end

    return string.format(
      "surf=%s pos=(%.1f,%.1f) ents=%d inserters=%d",
      tostring(surface.name),
      pos.x,
      pos.y,
      #entities,
      inserters
    )
  end,

  tx_watch_dbg = function()
    local dbg = storage and storage.tx_dbg_watch
    if not dbg then return "no dbg record" end

    return string.format(
      "stamp=%s tick=%s scanned=%s added=%s watch=%s r=%s",
      tostring(dbg.stamp),
      tostring(dbg.tick),
      tostring(dbg.scanned),
      tostring(dbg.added),
      tostring(dbg.watch_size),
      tostring(dbg.r)
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

-- =========================================
-- Blueprint GUI opened
-- =========================================

script.on_event(defines.events.on_gui_opened, Blueprint.on_gui_opened)
