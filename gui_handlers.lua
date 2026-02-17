-- =========================================
-- LogSim (Factorio 2.0)
-- GUI Click Handler - alle onClick-Funktionen zentralisiert
--
-- version 0.8.7 new introduced
--
-- =========================================

local M = require("config")
local Buffer = require("buffer")
local R = require("reset")
local UI = require("ui")
local Chests = require("chests")
local Blueprint = require("blueprint")
local Export = require("export")
local Transaction = require("transaction")
local mod_gui = require("mod-gui")  -- WICHTIG: für update_topbar_buttons

local GUI = {}
GUI.version = "0.8.7"




-- =========================================
-- Topbar Hilfsfunktionen (aus control.lua übernommen)
-- =========================================

function GUI.hotkey_toggle_buffer(event)
  local player = game.players[event.player_index]
  local frame = player.gui.screen.logsim_buffer

  if frame and frame.valid then
    frame.destroy()
  else
    UI.show_buffer_gui(player)
    Buffer.refresh_for_player(player)
  end
end

-- Hilfsfunktion für Protocol Recording
function GUI.set_protocol_state(player, state)
  if state then
    storage.protocol_active = true
    storage.tx_active = true
    if player then
      player.print({"logistics_simulation.cmd_prot_on"})
    end
  else
    storage.protocol_active = false
    storage.tx_active = false
    if player then
      player.print({"logistics_simulation.cmd_prot_off"})
    end
  end
  
  -- GUI aktualisieren (falls offen)
  if player and player.gui.screen[M.GUI_BUFFER_FRAME] then
    Buffer.refresh_for_player(player)
  end
  
  GUI.update_topbar_buttons()
end

-- Hilfsfunktion für Global Power Network
function GUI.set_global_power_state(player, surface, state)
  if state then
    storage.gp_enabled = true
    surface.create_global_electric_network()
    if player then
      player.print({"logistics_simulation.cmd_gp_on"})
    end
  else
    storage.gp_enabled = false
    surface.destroy_global_electric_network()
    if player then
      player.print({"logistics_simulation.cmd_gp_off"})
    end
  end
  
  GUI.update_topbar_buttons()
end

-- Topbar Buttons aktualisieren
function GUI.update_topbar_buttons()
  for _, player in pairs(game.players) do
    local button_flow = mod_gui.get_button_flow(player)
    local root = button_flow[M.TOPBAR_ROOT]
    if root and root.valid then
      -- Button 2 (Protocol) aktualisieren
      local btn2 = root[M.TOPBAR_BTN2]
      if btn2 and btn2.valid then
        local new_sprite = storage.protocol_active and M.TOPBAR_BTN2_ON_SPRITE or M.TOPBAR_BTN2_OFF_SPRITE
        btn2.sprite = new_sprite
      end
      
      -- Button 3 (Global Power) aktualisieren
      local btn3 = root[M.TOPBAR_BTN3]
      if btn3 and btn3.valid then
        local new_sprite = storage.gp_enabled and M.TOPBAR_BTN3_ON_SPRITE or M.TOPBAR_BTN3_OFF_SPRITE
        btn3.sprite = new_sprite
      end
    end
  end
end

-- Topbar Click Handler
function GUI.handle_topbar_click(event, player, element)
  local name = element.name
  local surface = player.surface
  
  -- Button 1: Einfacher Klick (Buffer anzeigen)
  if name == M.TOPBAR_BTN1 then
    GUI.hotkey_toggle_buffer(event)
    return true
  end
  
  -- Button 2: Protocol Recording Toggle
  if name == M.TOPBAR_BTN2 then
    local new_state = not storage.protocol_active 
    GUI.set_protocol_state(player, new_state)
    
    -- Sprite aktualisieren
    local new_sprite = new_state and M.TOPBAR_BTN2_ON_SPRITE or M.TOPBAR_BTN2_OFF_SPRITE
    element.sprite = new_sprite
    
    return true
  end
  
  -- Button 3: Global Power Network Toggle
  if name == M.TOPBAR_BTN3 then
    local new_state = not storage.gp_enabled 
    GUI.set_global_power_state(player, surface, new_state)
    
    -- Sprite aktualisieren
    local new_sprite = new_state and M.TOPBAR_BTN3_ON_SPRITE or M.TOPBAR_BTN3_OFF_SPRITE
    element.sprite = new_sprite
    
    return true
  end
  
  return false
end


-- =========================================
-- TX Window handlers
-- =========================================

function GUI.click_tx_open(event)
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

function GUI.click_tx_hide(event)
  local player = game.players[event.player_index]
  UI.close_tx_gui(player)
  UI.close_export_dialog_if_owner(player, "tx")
end

function GUI.click_tx_older(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_page_older then Transaction.tx_page_older(player) end
end

function GUI.click_tx_newer(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_page_newer then Transaction.tx_page_newer(player) end
end

function GUI.click_tx_home(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_home then Transaction.tx_home(player) end
end

function GUI.click_tx_end(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_end then Transaction.tx_end(player)
  elseif Transaction and Transaction.tx_tail then Transaction.tx_tail(player) end
end

function GUI.click_tx_copy(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_copy_to_clipboard then Transaction.tx_copy_to_clipboard(player) end
end

-- =========================================
-- Buffer/Export Window handlers
-- =========================================

function GUI.click_buffer_export(event)
  local player = game.players[event.player_index]
  storage.export_mode = "buffer"
  UI.show_export_dialog(player)
end

function GUI.click_tx_export(event)
  local player = game.players[event.player_index]
  storage.export_mode = "tx"
  UI.show_export_dialog(player)
end

function GUI.click_inv_export(event)
  local player = game.players[event.player_index]
  storage.export_mode = "inv"
  UI.show_export_dialog(player)
end

function GUI.click_export_csv(event)
  local player = game.players[event.player_index]
  if storage.export_mode == "tx" then
    Export.export_tx_csv(player)
  elseif storage.export_mode == "inv" then
    Export.export_inv_csv(player)
  else
    Export.export_csv(player) -- buffer/protocol
  end
end

function GUI.click_export_json(event)
  local player = game.players[event.player_index]
  if storage.export_mode == "tx" then
    Export.export_tx_json(player)
  elseif storage.export_mode == "inv" then
    Export.export_inv_json(player)
  else
    Export.export_json(player) -- buffer/protocol
  end
end

function GUI.click_export_close(event)
  local player = game.players[event.player_index]
  UI.close_export_dialog(player)
end

-- =========================================
-- Run Name Dialog
-- =========================================

function GUI.click_runname_ok(event)
  local player = game.players[event.player_index]
  -- Diese Funktion kommt aus control.lua (forward declaration)
  if handle_runname_submit then
    handle_runname_submit(player)
  end
end

-- =========================================
-- Hide/Close handlers
-- =========================================

function GUI.click_hide_or_close(event)
  local player = game.players[event.player_index]

  local frame = player.gui.screen.logsim_buffer
  if frame and frame.valid then frame.destroy() end

  local hf = player.gui.screen[M.GUI_HELP_FRAME]
  if hf and hf.valid then hf.destroy() end
  UI.close_export_dialog_if_owner(player, "buffer")
end

-- =========================================
-- Reset Dialog handlers
-- =========================================

function GUI.click_reset_open(event)
  local player = game.players[event.player_index]
  UI.show_reset_dialog(player)
end

function GUI.click_reset_cancel(event)
  local player = game.players[event.player_index]
  UI.close_reset_dialog(player)
end

function GUI.click_reset_ok(event)
  local player = game.players[event.player_index]

  local opts = UI.read_reset_dialog(player)
  UI.close_reset_dialog(player)
  if not opts then return end

  if opts.del_items then
    R.do_reset_simulation(player.surface, player.force, Buffer.append_line, opts.del_stats)
  end

  if opts.del_playerinv then
    R.wipe_all_player_inventories(game.players)
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

    storage.buffer_head = 1
    storage.buffer_size = 0
    storage._buffer_last_max = nil

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

-- =========================================
-- Buffer Navigation
-- =========================================

function GUI.click_buffer_nav(event, element)
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

function GUI.click_copy(event)
  local player = game.players[event.player_index]
  local frame = player.gui.screen.logsim_buffer
  if not (frame and frame.valid) then return end

  local box = frame.logsim_buffer_box
  if not (box and box.valid) then return end

  box.focus()
  box.select_all()
  player.print({"logistics_simulation.msg_copied"})
end

-- =========================================
-- Help Window handlers
-- =========================================

function GUI.click_help_toggle(event)
  local player = game.players[event.player_index]
  local hf = player.gui.screen[M.GUI_HELP_FRAME]
  if hf and hf.valid then
    hf.destroy()
  else
    UI.show_help_gui(player)
  end
end

function GUI.click_help_close(event)
  local player = game.players[event.player_index]
  local hf = player.gui.screen[M.GUI_HELP_FRAME]
  if hf and hf.valid then hf.destroy() end
end

-- =========================================
-- Inventory Window handlers
-- =========================================

function GUI.click_invwin_copy(event)
  local player = game.players[event.player_index]
  local frame = player.gui.screen["logsim_invwin"]
  if not (frame and frame.valid) then return end
  
  local box = frame["logsim_invwin_box"]
  if not (box and box.valid) then return end
  
  box.focus()
  box.select_all()
  player.print({"logistics_simulation.msg_copied"})
end

function GUI.click_invwin_close(event)
  local player = game.players[event.player_index]
  UI.close_inventory_window(player)
  UI.close_export_dialog_if_owner(player, "inv")
end

return GUI