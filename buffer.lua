-- =========================================
-- LogSim (Factorio 2.0)
-- Buffer Module
-- (Buffer lines, paging/windowing, GUI refresh throttling)
-- Version 0.5.0 first introduced in LogSim 0.5.0
--
-- Responsibilities:
--  - storage defaults: buffer_lines, buffer_view, gui_dirty, perline_counter
--  - append_line / append_multiline
--  - paging/window functions: compute_tail_window, fit_window_to_chars,
--    fit_window_forward_to_chars, get_text_range
--  - throttled GUI refresh: tick_refresh_open_guis, refresh_for_player
-- =========================================

local M = require("config")

local Buffer = {}
Buffer.version = "0.5.0"

-- -----------------------------------------
-- Defaults
-- -----------------------------------------
function Buffer.ensure_defaults()
  storage.buffer_lines     = storage.buffer_lines or {}
  storage.buffer_view      = storage.buffer_view or {}
  storage.gui_dirty        = storage.gui_dirty or {}
  storage.perline_counter  = storage.perline_counter or 0
  storage._buf_last_gui_refresh_tick = storage._buf_last_gui_refresh_tick or 0
end

-- -----------------------------------------
-- Basics
-- -----------------------------------------
function Buffer.count()
  return (storage.buffer_lines and #storage.buffer_lines) or 0
end

function Buffer.mark_dirty_for_open_guis()
  -- Mark only players with open buffer GUI
  for _, player in pairs(game.connected_players) do
    local frame = player.gui.screen[M.GUI_BUFFER_FRAME]
    if frame and frame.valid then
      storage.gui_dirty[player.index] = true
    end
  end
end

function Buffer.append_line(line)
  Buffer.ensure_defaults()

  storage.buffer_lines[#storage.buffer_lines + 1] = tostring(line)

  -- FIX: Use while loop to handle edge case
  local MAX_LINES = M.BUFFER_MAX_LINES
  while #storage.buffer_lines > MAX_LINES do
    table.remove(storage.buffer_lines, 1)
  end

  -- NOT immediately refresh GUI -> throttled
  Buffer.mark_dirty_for_open_guis()
end

function Buffer.append_multiline(text)
  if not text then return end
  for line in string.gmatch(text, "([^\n]+)") do
    Buffer.append_line(line)
  end
end

-- -----------------------------------------
-- Window / Paging
-- -----------------------------------------
function Buffer.get_text_range(start_line, end_line)
  Buffer.ensure_defaults()

  local lines = storage.buffer_lines
  local n = #lines
  if n == 0 then return "" end

  start_line = math.max(1, math.min(start_line, n))
  end_line   = math.max(1, math.min(end_line, n))
  if end_line < start_line then return "" end

  local t = {}
  for i = start_line, end_line do
    t[#t+1] = lines[i]
  end
  return table.concat(t, "\n") .. "\n"
end

function Buffer.compute_tail_window(max_chars)
  Buffer.ensure_defaults()

  local lines = storage.buffer_lines
  local n = #lines
  if n == 0 then return 1, 0 end

  local chars = 1
  local start = n
  while start > 1 do
    local add = #lines[start-1] + 1
    if chars + add > max_chars then break end
    chars = chars + add
    start = start - 1
  end
  return start, n
end

-- Fit backwards (end fixed, start moves up)
function Buffer.fit_window_to_chars(end_line, max_chars)
  Buffer.ensure_defaults()

  local lines = storage.buffer_lines
  local n = #lines
  if n == 0 then return 1, 0 end

  end_line = math.max(1, math.min(end_line, n))

  local chars = 1
  local start = end_line
  while start > 1 do
    local add = #lines[start-1] + 1
    if chars + add > max_chars then break end
    chars = chars + add
    start = start - 1
  end

  return start, end_line
end

-- FIX: Fit forwards (start fixed, end gets truncated)
function Buffer.fit_window_forward_to_chars(start_line, end_limit, max_chars)
  Buffer.ensure_defaults()

  local lines = storage.buffer_lines
  local n = #lines
  if n == 0 then return 1, 0 end

  start_line = math.max(1, math.min(start_line, n))
  end_limit  = math.max(start_line, math.min(end_limit or n, n))

  local chars = 1
  local e = start_line
  
  -- FIX: Added boundary check (e < n)
  while e < end_limit and e < n do
    local add = #lines[e + 1] + 1
    if chars + add > max_chars then break end
    chars = chars + add
    e = e + 1
  end

  return start_line, e
end

-- -----------------------------------------
-- View state per player
-- -----------------------------------------
function Buffer.ensure_view(player_index)
  Buffer.ensure_defaults()

  local view = storage.buffer_view[player_index]
  if not view then
    local s, e = Buffer.compute_tail_window(M.TEXT_MAX)
    view = {
      start_line = s,
      end_line   = e,
      follow     = true,
      last_start = nil,
      last_end   = nil
    }
    storage.buffer_view[player_index] = view
  end
  return view
end

-- -----------------------------------------
-- GUI Refresh (throttled)
-- -----------------------------------------
function Buffer.refresh_for_player(player, force_text_redraw)
  if not (player and player.valid) then return end
  Buffer.ensure_defaults()

  local frame = player.gui.screen[M.GUI_BUFFER_FRAME]
  if not (frame and frame.valid) then return end

  local box = frame[M.GUI_BUFFER_BOX]
  if not (box and box.valid) then return end

  local toolbar = frame.logsim_buffer_toolbar
  if not (toolbar and toolbar.valid) then return end

  local view = Buffer.ensure_view(player.index)

  if view.follow then
    local s, e = Buffer.compute_tail_window(M.TEXT_MAX)
    view.start_line, view.end_line = s, e
  end

  local need_text =
    force_text_redraw
    or view.follow
    or view.last_start ~= view.start_line
    or view.last_end   ~= view.end_line

  if need_text then
    local prefix = (view.start_line > 1) and "...(truncated)\n" or ""
    local text = prefix .. Buffer.get_text_range(view.start_line, view.end_line)
    
    -- FIX: Use pcall to protect against race conditions
    pcall(function()
      box.text = text
    end)
    
    view.last_start = view.start_line
    view.last_end   = view.end_line
  end

  local live = toolbar[M.GUI_BTN_TAIL]
  if live and live.valid and live.type == "button" then
    if view.follow then
      live.style = "confirm_button"
      live.caption = {"logistics_simulation.buffer_live"}
      live.tooltip = {"logistics_simulation.buffer_live_tooltip"}
    else
      live.style = "button"
      live.caption = {"logistics_simulation.buffer_live"}
      live.tooltip = {"logistics_simulation.buffer_paused_tooltip"}
    end
  end
end

-- Called in on_tick; refreshes open GUIs max every M.GUI_REFRESH_TICKS
function Buffer.tick_refresh_open_guis(tick)
  Buffer.ensure_defaults()
  tick = tick or game.tick

  if (tick - storage._buf_last_gui_refresh_tick) < M.GUI_REFRESH_TICKS then
    return
  end

  -- Only if someone is dirty
  local any = false
  for _, v in pairs(storage.gui_dirty) do
    if v then any = true; break end
  end
  if not any then
    storage._buf_last_gui_refresh_tick = tick
    return
  end

  for _, player in pairs(game.connected_players) do
    if storage.gui_dirty[player.index] then
      Buffer.refresh_for_player(player, false)
      storage.gui_dirty[player.index] = false
    end
  end

  storage._buf_last_gui_refresh_tick = tick
end

return Buffer