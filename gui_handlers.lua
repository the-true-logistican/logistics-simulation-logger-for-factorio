-- =========================================
-- LogSim (Factorio 2.0)
-- Central GUI click handler module.
--
-- Version 0.8.7 introduced as separate module
--               blueprint extraction with tabs
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 Day/night toggle button
--               statistics reset independent from simulation reset
--               EMA reset with statistics reset
-- Version 0.9.2 only code review
--               Protection must be removed before physical reset.
--
-- =========================================

local M = require("config")
local Buffer = require("buffer")
local R = require("reset")
local UI = require("ui")
local Chests = require("chests")
local Export = require("export")
local Transaction = require("transaction")
local SimLog = require("simlog")
local mod_gui = require("mod-gui")
local EMA = require("ema")

local GUI = {}
GUI.version = "0.9.2"

-- =========================================
-- Topbar helpers
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

function GUI.set_protocol_state(player, state)
  if state then
    storage.protocol_active = true
    if player then
      player.print({"logistics_simulation.cmd_prot_on"})
    end
  else
    storage.protocol_active = false
    if player then
      player.print({"logistics_simulation.cmd_prot_off"})
    end
  end

  if player and player.gui.screen[M.GUI_BUFFER_FRAME] then
    Buffer.refresh_for_player(player)
  end

  GUI.update_topbar_buttons()
end

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

function GUI.update_topbar_buttons()
  for _, player in pairs(game.players) do
    local button_flow = mod_gui.get_button_flow(player)
    local root = button_flow[M.TOPBAR_ROOT]

    if root and root.valid then
      local btn2 = root[M.TOPBAR_BTN2]
      if btn2 and btn2.valid then
        btn2.sprite = storage.protocol_active
          and M.TOPBAR_BTN2_ON_SPRITE
          or M.TOPBAR_BTN2_OFF_SPRITE
      end

      local btn3 = root[M.TOPBAR_BTN3]
      if btn3 and btn3.valid then
        btn3.sprite = storage.gp_enabled
          and M.TOPBAR_BTN3_ON_SPRITE
          or M.TOPBAR_BTN3_OFF_SPRITE
      end

      local btn4 = root[M.TOPBAR_BTN4]
      if btn4 and btn4.valid then
        btn4.sprite = storage.permanent_day
          and M.TOPBAR_BTN4_ON_SPRITE
          or M.TOPBAR_BTN4_OFF_SPRITE
      end
    end
  end
end

function GUI.set_permanent_day_state(player, surface, state)
  storage.permanent_day = state

  local s = player.surface
  if s and s.valid then
    if state then
      storage.saved_daytime = s.daytime
      s.always_day = true
    else
      s.always_day = false
      s.freeze_daytime = false

      local tpd = s.ticks_per_day or 25000
      local ticks_frozen = game.tick - (storage.day_freeze_tick or game.tick)
      local offset = (ticks_frozen % tpd) / tpd

      s.daytime = (storage.saved_daytime + offset) % 1.0
    end
  end

  if state then
    storage.day_freeze_tick = game.tick
  end

  if player then
    if state then
      player.print({"logistics_simulation.cmd_day_on"})
    else
      player.print({"logistics_simulation.cmd_day_off"})
    end
  end

  GUI.update_topbar_buttons()
end

function GUI.handle_topbar_click(event, player, element)
  local name = element.name
  local surface = player.surface

  if name == M.TOPBAR_BTN1 then
    GUI.hotkey_toggle_buffer(event)
    return true
  end

  if name == M.TOPBAR_BTN2 then
    local new_state = not storage.protocol_active
    GUI.set_protocol_state(player, new_state)

    element.sprite = new_state
      and M.TOPBAR_BTN2_ON_SPRITE
      or M.TOPBAR_BTN2_OFF_SPRITE

    return true
  end

  if name == M.TOPBAR_BTN3 then
    local new_state = not storage.gp_enabled
    GUI.set_global_power_state(player, surface, new_state)

    element.sprite = new_state
      and M.TOPBAR_BTN3_ON_SPRITE
      or M.TOPBAR_BTN3_OFF_SPRITE

    return true
  end

  if name == M.TOPBAR_BTN4 then
    local new_state = not storage.permanent_day
    GUI.set_permanent_day_state(player, surface, new_state)

    element.sprite = new_state
      and M.TOPBAR_BTN4_ON_SPRITE
      or M.TOPBAR_BTN4_OFF_SPRITE

    return true
  end

  return false
end

-- =========================================
-- TX window handlers
-- =========================================

function GUI.click_tx_open(event)
  local player = game.players[event.player_index]
  UI.show_tx_gui(player)

  if Transaction and Transaction.tx_refresh_for_player then
    Transaction.tx_refresh_for_player(player)
  else
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
  if Transaction and Transaction.tx_page_older then
    Transaction.tx_page_older(player)
  end
end

function GUI.click_tx_newer(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_page_newer then
    Transaction.tx_page_newer(player)
  end
end

function GUI.click_tx_home(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_home then
    Transaction.tx_home(player)
  end
end

function GUI.click_tx_end(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_end then
    Transaction.tx_end(player)
  elseif Transaction and Transaction.tx_tail then
    Transaction.tx_tail(player)
  end
end

function GUI.click_tx_copy(event)
  local player = game.players[event.player_index]
  if Transaction and Transaction.tx_copy_to_clipboard then
    Transaction.tx_copy_to_clipboard(player)
  end
end

-- =========================================
-- Buffer/export window handlers
-- =========================================

local function get_export_mode_table()
  if type(storage.export_mode) ~= "table" then
    storage.export_mode = {}
  end

  return storage.export_mode
end

function GUI.click_buffer_export(event)
  local player = game.players[event.player_index]
  get_export_mode_table()[player.index] = "buffer"
  UI.show_export_dialog(player)
end

function GUI.click_tx_export(event)
  local player = game.players[event.player_index]
  get_export_mode_table()[player.index] = "tx"
  UI.show_export_dialog(player)
end

function GUI.click_inv_export(event)
  local player = game.players[event.player_index]
  get_export_mode_table()[player.index] = "inv"
  UI.show_export_dialog(player)
end

function GUI.click_export_csv(event)
  local player = game.players[event.player_index]
  local mode = storage.export_mode and storage.export_mode[player.index]
  local ok = false

  if mode == "tx" then
    ok = Export.export_tx_csv(player)
  elseif mode == "inv" then
    ok = Export.export_inv_csv(player)
  else
    ok = Export.export_csv(player)
  end

  if ok then
    UI.close_export_dialog(player)
  end
end

function GUI.click_export_json(event)
  local player = game.players[event.player_index]
  local mode = storage.export_mode and storage.export_mode[player.index]
  local ok = false

  if mode == "tx" then
    ok = Export.export_tx_json(player)
  elseif mode == "inv" then
    ok = Export.export_inv_json(player)
  else
    ok = Export.export_json(player)
  end

  if ok then
    UI.close_export_dialog(player)
  end
end

function GUI.click_export_close(event)
  local player = game.players[event.player_index]
  UI.close_export_dialog(player)
end

-- =========================================
-- Run name dialog
-- =========================================

function GUI.click_runname_ok(event)
  local player = game.players[event.player_index]

  local frame = player.gui.screen.logsim_runname
  if not (frame and frame.valid) then return end

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
      run_name = storage.run_name,
      start_tick = storage.run_start_tick,
      surface = player.surface and player.surface.name or nil,
      force = player.force and player.force.name or nil
    }

    Buffer.append_multiline(header)
  end

  player.print({"logistics_simulation.show_prot_name", storage.run_name})
  player.print({"logistics_simulation.show_start_tick", tostring(storage.run_start_tick)})

  frame.destroy()

  UI.show_buffer_gui(player)
  Buffer.refresh_for_player(player)
end

-- =========================================
-- Hide/close handlers
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
-- Reset dialog handlers
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

  if opts.new_name and opts.new_name ~= "" then
    storage.run_name = opts.new_name
  end

-- Protection must be removed before physical reset.
-- Otherwise protected entities keep their contents during R.do_reset_simulation().
if opts.del_prot then
  Chests.reset_lists{
    protected = true
  }
end

if opts.del_items then
  R.do_reset_simulation(player.surface, player.force, Buffer.append_line)
end

if opts.del_playerinv then
  R.wipe_all_player_inventories(game.players)
end

-- Object registrations are removed only after the physical reset.
-- This keeps registered/protected entities resolvable during reset execution.
if opts.del_chests or opts.del_machines then
  Chests.reset_lists{
    chests = opts.del_chests,
    machines = opts.del_machines
  }
end

  if opts.del_log then
    Buffer.reset_log()

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

  if opts.del_stats then
    R.reset_statistics(player.surface, player.force, Buffer.append_line)
  end

  if opts.del_stats and EMA and EMA.reset_to_current then
    EMA.reset_to_current(player.surface.index, game.tick)
  end

  Buffer.refresh_for_player(player)
end

-- =========================================
-- Buffer navigation
-- =========================================

function GUI.click_buffer_nav(event, element)
  local player = game.players[event.player_index]
  local n = Buffer.count()

  if n == 0 then
    Buffer.refresh_for_player(player)
    return
  end

  local view = Buffer.ensure_view(player.index)

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

  local win = math.max(1, (view.end_line - view.start_line + 1))
  local page = math.max(M.BUFFER_PAGE_LINES, win)

  if element.name == M.GUI_BTN_OLDER then
    view.follow = false

    local new_end = math.max(1, view.start_line - 1)
    local new_start = math.max(1, new_end - (page - 1))

    new_start, new_end = Buffer.fit_window_to_chars(new_end, M.TEXT_MAX)
    view.start_line = new_start
    view.end_line = new_end
  else
    view.follow = false

    local new_start = math.min(n, view.end_line + 1)
    local end_limit = math.min(n, new_start + (page - 1))

    local s, e = Buffer.fit_window_forward_to_chars(new_start, end_limit, M.TEXT_MAX)
    view.start_line = s
    view.end_line = e
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
-- Help window handlers
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
-- Inventory window tab handlers
-- =========================================

function GUI.click_invwin_tab(event, element)
  local player = game.players[event.player_index]
  if not (player and player.valid and element and element.valid) then return false end

  if element.name == M.GUI_INV_TAB_ASSETS then
    storage.invwin_active_tab[player.index] = "assets"
  elseif element.name == M.GUI_INV_TAB_COSTS then
    storage.invwin_active_tab[player.index] = "costs"
  elseif element.name == M.GUI_INV_TAB_SYSTEM then
    storage.invwin_active_tab[player.index] = "system"
  elseif element.name == M.GUI_INV_TAB_STATS then
    storage.invwin_active_tab[player.index] = "stats"
  elseif element.name == M.GUI_INV_TAB_WC then
    storage.invwin_active_tab[player.index] = "working_capital"
  else
    return false
  end

  UI.refresh_inventory_window(player)
  return true
end

-- =========================================
-- Inventory window handlers
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