-- =========================================
-- LogSim (Factorio 2.0) 
-- UI Module with Locale Support
-- Version 0.3.0
-- Version 0.5.3 statistics reset checkbox
-- Version 0.6.0 blueprint inventory support, config constants
-- Version 0.6.1 full localization (no hard-coded strings)
-- =========================================

local M = require("config")

local UI = {}
UI.version = "0.6.1"

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

  box.style.width = M.GUI_BUFFER_WIDTH
  box.style.height = M.GUI_BUFFER_HEIGHT
  
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
  pane.style.maximal_height = M.GUI_HELP_HEIGHT
  pane.style.width = M.GUI_HELP_WIDTH

  local lbl = pane.add{
    type = "label",
    caption = {"logistics_simulation.help_text"}
  }
  lbl.style.single_line = false
  lbl.style.maximal_width = M.GUI_HELP_LABEL_WIDTH
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
  content.style.vertical_spacing = M.GUI_CONTENT_SPACING
  content.style.padding = M.GUI_CONTENT_PADDING

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
  
  -- Statistics reset checkbox (v0.5.3)
  content.add{
    type = "checkbox",
    name = M.GUI_RESET_CHK_STATS,
    state = true,
    caption = {"logistics_simulation.reset_statistics"}
  }

  content.add{ type = "line" }

  local name_row = content.add{ type = "flow", direction = "horizontal" }
  name_row.style.horizontal_spacing = M.GUI_BUTTON_SPACING

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
  name_field.style.width = M.GUI_RESET_TEXTFIELD_WIDTH

  local buttons = frame.add{ type = "flow", direction = "horizontal" }
  buttons.style.horizontal_align = "right"
  buttons.style.padding = M.GUI_CONTENT_PADDING
  buttons.style.horizontal_spacing = M.GUI_BUTTON_SPACING

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
    del_stats    = chk(M.GUI_RESET_CHK_STATS),
    new_name     = txt(M.GUI_RESET_NAME_FIELD),
  }
end

-- Blueprint inventory sidecar (v0.6.0)
function UI.show_blueprint_sidecar(player)
  local root = player.gui.screen
  local old = root[M.GUI_BP_SIDECAR]
  if old and old.valid then old.destroy() end

  local scale = player.display_scale or 1

  local frame = root.add{
    type = "frame",
    name = M.GUI_BP_SIDECAR,
    direction = "vertical",
    caption = {"logistics_simulation.bp_inventory_title"}
  }

  frame.style.padding = M.GUI_FRAME_PADDING
  frame.style.minimal_width = M.GUI_BP_SIDECAR_WIDTH
  frame.style.maximal_width = M.GUI_BP_SIDECAR_WIDTH

  local flow = frame.add{ type="flow", direction="vertical" }
  flow.add{
    type = "label",
    caption = {"logistics_simulation.bp_inventory_hint"}
  }

  flow.add{
    type = "button",
    name = M.GUI_BP_EXTRACTBTN,
    caption = {"logistics_simulation.bp_extract_button"}
  }

  -- Position: top left (safe, doesn't collide with minimap)
  frame.location = { 
    x = math.floor(M.GUI_BP_SIDECAR_MARGIN * scale), 
    y = math.floor(M.GUI_BP_SIDECAR_Y_OFFSET * scale) 
  }
end

function UI.hide_blueprint_sidecar(player)
  local root = player.gui.screen
  local el = root[M.GUI_BP_SIDECAR]
  if el and el.valid then el.destroy() end
end

-- -----------------------------------------
-- Blueprint Inventory Result Window (autonomous)
-- Version 0.6.1 - fully localized
-- -----------------------------------------

function UI.show_inventory_window(player, text)
  local root = player.gui.screen

  -- Wenn schon offen: nur Text aktualisieren + nach vorne holen
  local frame = root[M.GUI_INV_FRAME]
  if frame and frame.valid then
    local box = frame[M.GUI_INV_BOX]
    if box and box.valid then box.text = text or "" end
    frame.bring_to_front()
    return
  end

  frame = root.add{
    type = "frame",
    name = M.GUI_INV_FRAME,
    direction = "vertical"
  }
  frame.auto_center = true

  -- Titelzeile mit X (vollständig lokalisiert)
  add_titlebar(frame, {"logistics_simulation.invwin_title"}, M.GUI_INV_CLOSE_X)

  -- Toolbar: nur Copy + Close (lokalisiert)
  local top = frame.add{
    type = "flow",
    name = "logsim_invwin_toolbar",
    direction = "horizontal"
  }

  top.add{
    type = "button",
    name = M.GUI_INV_BTN_COPY,
    caption = {"logistics_simulation.invwin_copy"}
  }

  top.add{
    type = "button",
    name = M.GUI_INV_BTN_CLOSE,
    caption = {"logistics_simulation.invwin_close"}
  }

  -- Content: Textbox für Inventur-Daten (read-only)
  local box = frame.add{
    type = "text-box",
    name = M.GUI_INV_BOX,
    text = text or ""
  }
  box.read_only = true
  box.word_wrap = false

  -- Größe: nimm die Buffer-Dimensionen
  box.style.width  = M.GUI_BUFFER_WIDTH
  box.style.height = M.GUI_BUFFER_HEIGHT
end

function UI.close_inventory_window(player)
  local f = player.gui.screen[M.GUI_INV_FRAME]
  if f and f.valid then f.destroy() end
end

return UI
