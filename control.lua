-- =========================================
-- LogSim (Factorio 2.0) 
-- Main Control 
--
-- Version 0.1.0 first für LogSim 
-- Version 0.2.0 first modularisation
-- Version 0.3.0 machines too
-- Version 0.4.0 power, pollution, help etc.
-- Version 0.4.1 code optimisation
-- Version 0.4.2 flexible buffer diplay
-- Version 0.4.3 reorganise code
-- Version 0.5.0 locale de/en; buffer module
-- =========================================

local DEBUG = true

local M = require("config")
local Buffer = require("buffer")
local R = require("reset")
local UI = require("ui")
local Chests = require("chests")
local SimLog = require("simlog")

-- Forward declarations
local debug_print
local ensure_storage_defaults
local sanitize_filename
local build_base_filename
local maybe_prompt_runname_for_all_players
local handle_runname_submit
local resolve_entity

-- -----------------------------------------
-- Implementations
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
      -- msg is already a locale table
      game.print({"", prefix, " ", msg})
    else
      -- msg is a string
      game.print({"", prefix, " ", tostring(msg)})
    end
  end
end

ensure_storage_defaults = function()
  storage.run_name = storage.run_name or nil
  storage.run_start_tick = storage.run_start_tick or nil
  storage.base_filename = storage.base_filename or nil
  storage.sample_interval = storage.sample_interval or M.SAMPLE_INTERVAL_TICKS

  -- Buffer defaults centrally in module
  Buffer.ensure_defaults()

  storage.registry = storage.registry or {}
  storage.next_chest_id = storage.next_chest_id or 1
  storage.machines = storage.machines or {}
  storage.next_machine_id = storage.next_machine_id or 1
  storage.protected = storage.protected or {}
  storage.next_protect_id = storage.next_protect_id or 1
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

-- -----------------------------------------
-- Events
-- -----------------------------------------

script.on_init(function()
  ensure_storage_defaults()
  debug_print({"logistics_simulation.mod_initialised"})
  maybe_prompt_runname_for_all_players()
end)

script.on_configuration_changed(function(_)
  ensure_storage_defaults()
  maybe_prompt_runname_for_all_players()
end)

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

  if element.name == M.GUI_BUFFER_FRAME then
    element.destroy()
    return
  end
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
  local parts = SimLog.begin_telegram(tick, game.surfaces[1], game.forces.player)

  local chest_str = SimLog.build_string(storage.registry, resolve_entity, SimLog.encode_chest)
  if chest_str ~= "" then
    parts[#parts+1] = chest_str
  end

  local machine_str = SimLog.build_string(storage.machines, resolve_entity, SimLog.encode_machine)
  if machine_str ~= "" then
    parts[#parts+1] = machine_str
  end

  Buffer.append_line(SimLog.end_telegram(parts))
end

script.on_event(defines.events.on_tick, function(event)
  if not tick_should_log() then
    -- Even when not logging: GUI might be dirty (e.g. Copy/Navigation/Runname)
    Buffer.tick_refresh_open_guis(event.tick)
    return
  end
  tick_update_markers()
  tick_build_and_append_logline()
  -- Throttled GUI refresh
  Buffer.tick_refresh_open_guis(event.tick)
end)

-- -----------------------------------------
-- Custom inputs (Hotkeys)
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
      hotkey_toggle_buffer(event); return
    end
    if name == "logsim_register_chest" then
      hotkey_register_chest(event); return
    end
    if name == "logsim_register_protect" then
      hotkey_register_protect(event); return
    end
    if name == "logsim_unregister_selected" then
      hotkey_unregister_selected(event); return
    end
  end
)

-- -----------------------------------------
-- GUI click handlers 
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
    R.do_reset_simulation(player.surface, player.force, Buffer.append_line)
  end

  if opts.del_chests or opts.del_machines or opts.del_prot then
    Chests.reset_lists{
      chests = opts.del_chests,
      machines = opts.del_machines,
      protected = opts.del_prot
    }
  end

  -- FIX: Consolidated del_log handling
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

  else -- NEWER
    view.follow = false 

    local new_start = math.min(n, view.end_line + 1)
    local end_limit = math.min(n, new_start + (page - 1))

    -- Start stays new_start, only end gets truncated if TEXT_MAX applies
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

-- -----------------------------------------
-- on_gui_click (Dispatcher)
-- -----------------------------------------
script.on_event(defines.events.on_gui_click, function(event)
  local element = event.element
  if not (element and element.valid) then return end

  local name = element.name

  if name == "logsim_runname_ok" then
    click_runname_ok(event); return
  end

  if name == M.GUI_BTN_HIDE or name == M.GUI_CLOSE then
    click_hide_or_close(event); return
  end

  if name == M.GUI_BTN_RESET then
    click_reset_open(event); return
  end
  if name == M.GUI_RESET_CANCEL then
    click_reset_cancel(event); return
  end
  if name == M.GUI_RESET_OK then
    click_reset_ok(event); return
  end

  if name == M.GUI_BTN_OLDER or name == M.GUI_BTN_TAIL or name == M.GUI_BTN_NEWER then
    click_buffer_nav(event, element); return
  end

  if name == M.GUI_BTN_COPY then
    click_copy(event); return
  end

  if name == M.GUI_BTN_HELP then
    click_help_toggle(event); return
  end
  if name == M.GUI_HELP_CLOSE then
    click_help_close(event); return
  end
end)