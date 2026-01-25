-- =========================================
-- LogSim (Factorio 2.0)
-- Buffer Module
-- (Buffer lines, paging/windowing, GUI refresh throttling)
--
-- version 0.8.0 first complete working version
-- version 0.8.1 ring buffer M.BUFFER_MAX_LINES load/save secure
-- version 0.8.2 bug in gui-window if /prot off
--
-- =========================================

local M = require("config")

local Buffer = {}
Buffer.version = "0.8.2"

-- -----------------------------------------
-- Defaults
-- -----------------------------------------

function Buffer.ensure_defaults()
  M.ensure_storage_defaults(storage)
end



-- -----------------------------------------
-- Ringbuffer helpers (O(1) append; no table.remove(1))
-- -----------------------------------------

local function buf_rb_get_max()
  return tonumber(storage.buffer_max_lines) or tonumber(M.BUFFER_MAX_LINES) or 500000
end

local function buf_rb_count()
  return tonumber(storage.buffer_size) or 0
end

local function buf_rb_head()
  local h = tonumber(storage.buffer_head) or 1
  if h < 1 then h = 1 end
  return h
end

local function buf_rb_phys(i, max, head)
  -- logical i in [1..size] -> physical index in [1..max]
  return ((head + (i - 1) - 1) % max) + 1
end

local function buf_rb_get_line(i)
  local max = buf_rb_get_max()
  local size = buf_rb_count()
  if i < 1 or i > size then return nil end
  local head = buf_rb_head()
  local p = buf_rb_phys(i, max, head)
  return storage.buffer_lines[p]
end

local function buf_rb_resize(new_max)
  new_max = tonumber(new_max) or buf_rb_get_max()
  if new_max < 1 then new_max = 1 end

  local old_max = buf_rb_get_max()
  local old_size = buf_rb_count()
  local old_head = buf_rb_head()
  local old_lines = storage.buffer_lines or {}

  local keep = old_size
  if keep > new_max then keep = new_max end

  local new_lines = {}
  if keep > 0 then
    -- keep the newest 'keep' lines
    local start_logical = old_size - keep + 1
    for j = 1, keep do
      local i = start_logical + (j - 1)
      local p = buf_rb_phys(i, old_max, old_head)
      new_lines[j] = old_lines[p]
    end
  end

  storage.buffer_lines = new_lines
  storage.buffer_max_lines = new_max
  storage.buffer_head = 1
  storage.buffer_size = keep
end

local function buf_rb_ensure()
  -- migration: if size not set, assume linear table
  if storage.buffer_lines == nil then storage.buffer_lines = {} end
  if storage.buffer_head == nil then storage.buffer_head = 1 end
  if storage.buffer_size == nil then storage.buffer_size = #storage.buffer_lines end
  if storage.buffer_max_lines == nil then storage.buffer_max_lines = tonumber(M.BUFFER_MAX_LINES) or 500000 end

  local max_cfg = tonumber(storage.buffer_max_lines) or tonumber(M.BUFFER_MAX_LINES) or 500000
  local max_now = buf_rb_get_max()
  if max_now ~= max_cfg then
    storage.buffer_max_lines = max_cfg
    max_now = max_cfg
  end

  -- If max changed (e.g., config), resize to match.
  -- Detect by comparing table length to max? Better: store last_max.
  if storage._buffer_last_max ~= max_now then
    storage._buffer_last_max = max_now
    buf_rb_resize(max_now)
  end

  -- clamp head/size
  if storage.buffer_head < 1 then storage.buffer_head = 1 end
  if storage.buffer_size < 0 then storage.buffer_size = 0 end
  if storage.buffer_size > max_now then storage.buffer_size = max_now end
end

-- -----------------------------------------
-- Basics
-- -----------------------------------------

function Buffer.count()
  Buffer.ensure_defaults()
  buf_rb_ensure()
  return buf_rb_count()
end

function Buffer.snapshot_lines()
  Buffer.ensure_defaults()
  buf_rb_ensure()

  local n = buf_rb_count()
  local out = {}
  for i = 1, n do
    out[i] = buf_rb_get_line(i)
  end
  return out, n
end

function Buffer.mark_dirty_for_open_guis()
  for _, player in pairs(game.connected_players) do
    local frame = player.gui.screen[M.GUI_BUFFER_FRAME]
    if frame and frame.valid then
      storage.gui_dirty[player.index] = true
    end
  end
end

function Buffer.append_line(line)
  Buffer.ensure_defaults()
  buf_rb_ensure()

  local max = buf_rb_get_max()
  local size = buf_rb_count()
  local head = buf_rb_head()

  line = tostring(line)

  if size < max then
    local p = buf_rb_phys(size + 1, max, head)
    storage.buffer_lines[p] = line
    storage.buffer_size = size + 1
  else
    -- overwrite oldest
    storage.buffer_lines[head] = line
    storage.buffer_head = (head % max) + 1
    storage.buffer_size = max
  end

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
  buf_rb_ensure()

  local n = buf_rb_count()
  if n == 0 then return "" end

  start_line = math.max(1, math.min(start_line, n))
  end_line   = math.max(1, math.min(end_line, n))
  if end_line < start_line then return "" end

  local t = {}
  for i = start_line, end_line do
    t[#t+1] = buf_rb_get_line(i) or ""
  end
  return table.concat(t, "\n") .. "\n"
end


function Buffer.compute_tail_window(max_chars)
  Buffer.ensure_defaults()
  buf_rb_ensure()

  local n = buf_rb_count()
  if n == 0 then return 1, 0 end

  local chars = 1
  local start = n
  while start > 1 do
    local prev = buf_rb_get_line(start - 1) or ""
    local add = #prev + 1
    if chars + add > max_chars then break end
    chars = chars + add
    start = start - 1
  end
  return start, n
end

function Buffer.fit_window_to_chars(end_line, max_chars)
  Buffer.ensure_defaults()
  buf_rb_ensure()

  local n = buf_rb_count()
  if n == 0 then return 1, 0 end

  end_line = math.max(1, math.min(end_line, n))

  local chars = 1
  local start = end_line
  while start > 1 do
    local prev = buf_rb_get_line(start - 1) or ""
    local add = #prev + 1
    if chars + add > max_chars then break end
    chars = chars + add
    start = start - 1
  end

  return start, end_line
end

function Buffer.fit_window_forward_to_chars(start_line, end_limit, max_chars)
  Buffer.ensure_defaults()
  buf_rb_ensure()

  local n = buf_rb_count()
  if n == 0 then return 1, 0 end

  -- Backward compatibility: old signature (start_line, max_chars)
  if max_chars == nil then
    max_chars = end_limit
    end_limit = nil
  end

  start_line = math.max(1, math.min(start_line, n))
  end_limit  = end_limit and math.max(start_line, math.min(end_limit, n)) or n
  max_chars  = tonumber(max_chars) or M.TEXT_MAX

  local chars = 1
  local e = start_line
  while e < end_limit do
    local nxt = buf_rb_get_line(e + 1) or ""
    local add = #nxt + 1
    if chars + add > max_chars then break end
    chars = chars + add
    e = e + 1
  end

  return start_line, e
end

-- -----------------------------------------
-- View State per Player
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
-- Cleanup Disconnected Players
-- -----------------------------------------

function Buffer.cleanup_disconnected_players()
  if not storage.buffer_view then return end
  
  local connected = {}
  for _, p in pairs(game.connected_players) do
    connected[p.index] = true
  end
  
  for idx, _ in pairs(storage.buffer_view) do
    if not connected[idx] then
      storage.buffer_view[idx] = nil
    end
  end
  
  if storage.gui_dirty then
    for idx, _ in pairs(storage.gui_dirty) do
      if not connected[idx] then
        storage.gui_dirty[idx] = nil
      end
    end
  end
end

-- -----------------------------------------
-- GUI Refresh (v0.5.5 - localized prefix)
-- -----------------------------------------

function Buffer.refresh_for_player(player, force_text_redraw)
  if not (player and player.valid) then return end
  Buffer.ensure_defaults()

  local frame = player.gui.screen[M.GUI_BUFFER_FRAME]
  if not (frame and frame.valid) then
    storage.buffer_view[player.index] = nil
    storage.gui_dirty[player.index] = false
    return
  end

  local box = frame[M.GUI_BUFFER_BOX]
  if not (box and box.valid) then
    storage.buffer_view[player.index] = nil
    storage.gui_dirty[player.index] = false
    return
  end

  local toolbar = frame.logsim_buffer_toolbar
  if not (toolbar and toolbar.valid) then return end

  local view = Buffer.ensure_view(player.index)

  local prot_on = (storage.protocol_active == true)
  if not prot_on then
    view.follow = false
  end

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
   
local prefix = ""
-- Note: text-box content must be a plain string; LocalisedString needs async translation.
-- Keep a simple prefix to avoid LuaPlayer.localised_string (not an API field).
if view.start_line > 1 then
  prefix = "...(truncated)\n"
end

local text = prefix .. Buffer.get_text_range(view.start_line, view.end_line)

    local ok = pcall(function()
      if box and box.valid then
        box.text = text
      end
    end)

    if not ok then
      storage.gui_dirty[player.index] = false
      return
    end

    view.last_start = view.start_line
    view.last_end   = view.end_line
  end

  local live = toolbar[M.GUI_BTN_TAIL]
  if live and live.valid and live.type == "button" then
    if not prot_on then
      live.enabled = false
      live.style = "button"
      live.caption = {"logistics_simulation.buffer_static"}
      live.tooltip = {"logistics_simulation.buffer_static_tooltip"}
    else
      live.enabled = true
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
end

function Buffer.tick_refresh_open_guis(tick)
  Buffer.ensure_defaults()
  tick = tick or game.tick

  if (tick - storage._buf_last_gui_refresh_tick) < M.GUI_REFRESH_TICKS then
    return
  end

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
