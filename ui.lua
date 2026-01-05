-- =========================================
-- LogSim (Factorio 2.0) 
-- UI Module with Locale Support
-- Version 0.3.0
-- =========================================

local M = require("config")

local UI = {}
UI.version = "0.5.0"

function UI.show_runname_gui(player)
  if player.gui.screen.logsim_runname then return end

  local frame = player.gui.screen.add{
    type = "frame",
    name = "logsim_runname",
    direction = "vertical",
    caption = {"logistics_simulation.name_dialog_title"}
  }
  frame.auto_center = true

  frame.add{
    type = "label",
    caption = {"logistics_simulation.get_sim_name"}
  }

  frame.add{
    type = "textfield",
    name = "logsim_runname_text"
  }

  frame.add{
    type = "button",
    name = "logsim_runname_ok",
    caption = {"logistics_simulation.reset_ok"}
  }  
end

local function add_titlebar(frame, caption, close_name)
  local bar = frame.add{ type="flow", direction="horizontal" }
  bar.drag_target = frame

  bar.add{ type="label", caption=caption, style="frame_title" }

  bar.add{
    type="empty-widget",
    style="draggable_space_header"
  }.style.horizontally_stretchable = true

  bar.add{
    type="sprite-button",
    name = close_name,
    sprite="utility/close",
    style="frame_action_button"
  }
end

function UI.show_buffer_gui(player)
  if player.gui.screen.logsim_buffer then return end

  local frame = player.gui.screen.add{
    type = "frame",
    direction = "vertical",
    name = M.GUI_BUFFER_FRAME
  }
  frame.auto_center = true
  add_titlebar(frame, {"logistics_simulation.gui_buffer_title"}, M.GUI_CLOSE)

  local top = frame.add{
    type = "flow",
    name = "logsim_buffer_toolbar",
    direction = "horizontal"
  }

  top.add{ 
    type = "sprite-button", 
    name = M.GUI_BTN_OLDER,
    sprite = "utility/left_arrow", 
    style = "tool_button", 
    tooltip = {"logistics_simulation.buffer_older"}
  }
  
  top.add{ 
    type = "button", 
    name = M.GUI_BTN_TAIL, 
    caption = {"logistics_simulation.buffer_live"}, 
    tooltip = {"logistics_simulation.buffer_live_tooltip"}
  }
  
  top.add{ 
    type = "sprite-button", 
    name = M.GUI_BTN_NEWER,
    sprite = "utility/right_arrow", 
    style = "tool_button", 
    tooltip = {"logistics_simulation.buffer_newer"}
  }
  
  top.add{ 
    type = "button", 
    name = M.GUI_BTN_COPY, 
    caption = {"logistics_simulation.buffer_copy"}
  } 
  
  top.add{ 
    type = "button", 
    name = M.GUI_BTN_HIDE, 
    caption = {"logistics_simulation.buffer_hide"}
  }
  
  top.add{ 
    type = "button", 
    name = M.GUI_BTN_RESET, 
    caption = {"logistics_simulation.buffer_reset"}
  }
  
  top.add{ 
    type = "button", 
    name = M.GUI_BTN_HELP, 
    caption = {"logistics_simulation.buffer_help"}
  }

  local box = frame.add{ 
    type = "text-box", 
    name = M.GUI_BUFFER_BOX, 
    text = ""
  }
  box.read_only = true
  box.word_wrap = false

  box.style.width = 900
  box.style.height = 500
  
  storage.buffer_view = storage.buffer_view or {}
  storage.buffer_view[player.index] = { start_line = 1, end_line = 0, follow = true }
end

function UI.show_help_gui(player)
  if player.gui.screen[M.GUI_HELP_FRAME] then return end

  local frame = player.gui.screen.add{
    type = "frame",
    name = M.GUI_HELP_FRAME,
    direction = "vertical"
  }
  frame.auto_center = true

  add_titlebar(frame, {"logistics_simulation.help_title"}, M.GUI_HELP_CLOSE)

  local pane = frame.add{ type = "scroll-pane" }
  pane.style.maximal_height = 500
  pane.style.width = 900

  local lbl = pane.add{
    type = "label",
    caption = {"logistics_simulation.help_text"}
  }
  lbl.style.single_line = false
  lbl.style.maximal_width = 880
end

function UI.show_reset_dialog(player)
  if player.gui.screen[M.GUI_RESET_FRAME] then return end

  local frame = player.gui.screen.add{
    type = "frame",
    name = M.GUI_RESET_FRAME,
    direction = "vertical"
  }
  frame.auto_center = true

  add_titlebar(frame, {"logistics_simulation.reset_dialog_title"}, M.GUI_RESET_CANCEL)

  local content = frame.add{ type = "flow", direction = "vertical" }
  content.style.vertical_spacing = 8
  content.style.padding = 12

  content.add{ 
    type = "label", 
    caption = {"logistics_simulation.reset_question"} 
  }

  content.add{
    type = "checkbox",
    name = M.GUI_RESET_CHK_ITEMS,
    state = true,
    caption = {"logistics_simulation.reset_items"}
  }
  
  content.add{
    type = "checkbox",
    name = M.GUI_RESET_CHK_LOG,
    state = true,
    caption = {"logistics_simulation.reset_log"}
  }
  
  content.add{
    type = "checkbox",
    name = M.GUI_RESET_CHK_CHESTS,
    state = false,
    caption = {"logistics_simulation.reset_chests"}
  }
  
  content.add{
    type = "checkbox",
    name = M.GUI_RESET_CHK_MACHINES,
    state = false,
    caption = {"logistics_simulation.reset_machines"}
  }
  
  content.add{
    type = "checkbox",
    name = M.GUI_RESET_CHK_PROT,
    state = false,
    caption = {"logistics_simulation.reset_protected"}
  }

  content.add{ type = "line" }

  local name_row = content.add{ type = "flow", direction = "horizontal" }
  name_row.style.horizontal_spacing = 8

  name_row.add{ 
    type = "label", 
    caption = {"logistics_simulation.reset_run_name"}
  }

  local old = (storage and storage.run_name) or ""
  local name_field = name_row.add{
    type = "textfield",
    name = M.GUI_RESET_NAME_FIELD,
    text = old
  }
  name_field.style.width = 300

  local buttons = frame.add{ type = "flow", direction = "horizontal" }
  buttons.style.horizontal_align = "right"
  buttons.style.padding = 12
  buttons.style.horizontal_spacing = 8

  buttons.add{ 
    type = "button", 
    name = M.GUI_RESET_CANCEL, 
    caption = {"logistics_simulation.reset_cancel"}
  }
  
  buttons.add{ 
    type = "button", 
    name = M.GUI_RESET_OK, 
    caption = {"logistics_simulation.reset_ok"}
  }
end

function UI.close_reset_dialog(player)
  local f = player.gui.screen[M.GUI_RESET_FRAME]
  if f and f.valid then f.destroy() end
end

-- NOTE: find_by_name() is kept simple for now.
-- For large GUIs, consider using direct paths like:
-- frame.children[index] or caching element references
local function find_by_name(root, target)
  if not (root and root.valid) then return nil end
  if root.name == target then return root end
  for _, child in pairs(root.children) do
    local found = find_by_name(child, target)
    if found then return found end
  end
  return nil
end

function UI.read_reset_dialog(player)
  local gui = player.gui.screen[M.GUI_RESET_FRAME]
  if not (gui and gui.valid) then return nil end

  local function chk(name)
    local e = find_by_name(gui, name)
    return (e and e.valid and e.state) == true
  end

  local function txt(name)
    local e = find_by_name(gui, name)
    if not (e and e.valid) then return "" end
    return e.text or ""
  end

  return {
    del_items    = chk(M.GUI_RESET_CHK_ITEMS),
    del_log      = chk(M.GUI_RESET_CHK_LOG),
    del_chests   = chk(M.GUI_RESET_CHK_CHESTS),
    del_machines = chk(M.GUI_RESET_CHK_MACHINES),
    del_prot     = chk(M.GUI_RESET_CHK_PROT),
    new_name     = txt(M.GUI_RESET_NAME_FIELD),
  }
end

return UI