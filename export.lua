-- =========================================
-- LogSim (Factorio 2.0) 
-- Exports protocol, inventory and transaction data to CSV and JSON files.
-- 
-- version 0.8.0 first complete working version
-- version 0.8.1 ring buffer M.TX_MAX_EVENTS load/save secure
--               ring buffer M.BUFFER_MAX_LINES load/save secure
-- version 0.8.2 minor bugs in line counting
-- version 0.8.3 extract from blueprint with tabs
-- Version 0.9.0 Stable Ledger Operational Baseline 
--
-- =========================================

local M = require("config")
local Buffer = require("buffer")
local Transaction = require("transaction")
local Util = require("utility")

local Export = {}
Export.version = "0.9.0"

-- Build a JSON-friendly TX array containing ONLY the used portion.
-- Order is not guaranteed/required (Martin), but we still export in logical (oldest->newest) order for convenience.
function Export._tx_events_for_json(tx_n)
  local out = {}
  for i = 1, tx_n do
    out[#out+1] = Transaction.tx_get_event(i)
  end
  return out
end

-- Helper: Find element by name in GUI tree
local function find_by_name(root, target)
  if not (root and root.valid) then return nil end
  if root.name == target then return root end
  for _, child in pairs(root.children) do
    local found = find_by_name(child, target)
    if found then return found end
  end
  return nil
end

-- Get filename from dialog
local function get_export_filename(player)
  local frame = player.gui.screen[M.GUI_EXPORT_FRAME]
  if not (frame and frame.valid) then 
    return Util.sanitize_filename(M.EXPORT_DEFAULT_NAME)
  end
  
  local field = find_by_name(frame, M.GUI_EXPORT_FILENAME)
  if not (field and field.valid) then
    return Util.sanitize_filename(M.EXPORT_DEFAULT_NAME)
  end
  
  local name = field.text or ""
  if name == "" then
    return Util.sanitize_filename(M.EXPORT_DEFAULT_NAME)
  end
  
  return Util.sanitize_filename(name)
end

-- =========================================
-- TX EXPORT (CSV) – uses TX viewer lines
-- =========================================
function Export.export_tx_csv(player)
  Buffer.ensure_defaults()

  local tx_n = (Transaction.tx_line_count() or 0)
  if tx_n == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

  local filename = get_export_filename(player)
  local filepath = M.EXPORT_FOLDER .. "/" .. filename .. ".csv"

  local surface = player.surface

  -- Build exactly the same lines as the TX viewer
  local total_lines = tx_n
  local lines = {}

  for i = 1, total_lines do
    local line = Transaction.tx_get_line(i, surface)
    if line then
      lines[#lines+1] = line
    end
  end

  local content = table.concat(lines, "\n")

-- Factorio 2.x: file export is sandboxed to script-output.
-- Use helpers.write_file; game.write_file is Factorio 1.x-era and not available in 2.x.
  local ok, err = pcall(function()
    helpers.write_file(filepath, content)
  end)

  if ok then
    player.print({"logistics_simulation.export_success", filepath, tx_n})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  return ok

end

-- =========================================
-- TX EXPORT (JSON) – raw tx_events + metadata
-- =========================================
function Export.export_tx_json(player)
  Buffer.ensure_defaults()

  local tx_n = (Transaction.tx_line_count() or 0)
  if tx_n == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

  local filename = get_export_filename(player)
  local filepath = M.EXPORT_FOLDER .. "/" .. filename .. ".json"

  local data = {
    metadata = {
      mod_version   = Util.get_logger_version(),
      run_name      = storage.run_name or "unnamed",
      start_tick    = storage.run_start_tick or 0,
      export_tick   = game.tick,
      event_count   = tx_n,
      kind          = "transactions"
    },
    tx_events = Export._tx_events_for_json(tx_n)
  }

  local json_str = Export.table_to_json(data)

  local ok, err = pcall(function()
    helpers.write_file(filepath, json_str)
  end)

  if ok then
    player.print({"logistics_simulation.export_success", filepath, tx_n})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  return ok

end


-- =========================================
-- INV EXPORT
-- =========================================

local INV_EXPORT_ORDER = {
  { key = "assets",          title = "FIXED ASSETS" },
  { key = "costs",           title = "ITEMS/COSTS" },
  { key = "system",          title = "SYSTEM/MODS" },
  { key = "stats",           title = "STATISTICS" },
  { key = "working_capital", title = "WORKING CAPITAL" },
}

local function get_inv_tabs(player)
  if not (player and player.valid) then return nil end

  -- New tabbed inventory report: set by UI.show_inventory_window(player, report_tabs).
  if storage
     and storage.invwin_data
     and type(storage.invwin_data[player.index]) == "table" then
    return storage.invwin_data[player.index]
  end

  -- Backward-compatible fallback: export the currently visible text box.
  local frame = player.gui.screen[M.GUI_INV_FRAME]
  if not (frame and frame.valid) then return nil end

  local box = frame[M.GUI_INV_BOX]
  if not (box and box.valid) then return nil end

  local txt = box.text or ""
  if txt == "" then return nil end

  return {
    assets = txt,
    costs = "",
    system = "",
    stats = "",
    working_capital = ""
  }
end

local function inv_tabs_have_data(tabs)
  if type(tabs) ~= "table" then return false end

  for _, def in ipairs(INV_EXPORT_ORDER) do
    local txt = tabs[def.key]
    if type(txt) == "string" and txt ~= "" then
      return true
    end
  end

  return false
end

local function inv_tabs_to_text(tabs)
  local lines = {}

  for _, def in ipairs(INV_EXPORT_ORDER) do
    local txt = tabs[def.key] or ""

    lines[#lines + 1] = "# =================================================="
    lines[#lines + 1] = "# " .. def.title
    lines[#lines + 1] = "# =================================================="

    if txt ~= "" then
      lines[#lines + 1] = txt
    else
      lines[#lines + 1] = "# no data"
    end

    lines[#lines + 1] = ""
  end

  return table.concat(lines, "\n")
end

function Export.export_inv_csv(player)
  Buffer.ensure_defaults()

  local tabs = get_inv_tabs(player)
  if not inv_tabs_have_data(tabs) then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end 

  local filename = get_export_filename(player)
  local filepath = M.EXPORT_FOLDER .. "/" .. filename .. ".csv"
  local content = inv_tabs_to_text(tabs)

  local ok, err = pcall(function()
    helpers.write_file(filepath, content)
  end)

  if ok then
    player.print({"logistics_simulation.export_success", filepath, #INV_EXPORT_ORDER})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  return ok

end

function Export.export_inv_json(player)
  Buffer.ensure_defaults()

  local tabs = get_inv_tabs(player)
  if not inv_tabs_have_data(tabs) then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

  local filename = get_export_filename(player)
  local filepath = M.EXPORT_FOLDER .. "/" .. filename .. ".json"

  local data = {
    metadata = {
      mod_version = Util.get_logger_version(),
      run_name = storage.run_name or "unnamed",
      start_tick = storage.run_start_tick or 0,
      export_tick = game.tick,
      kind = "inventory_report_tabs",
      tab_count = #INV_EXPORT_ORDER
    },
    inventory_report = {
      assets = tabs.assets or "",
      costs = tabs.costs or "",
      system = tabs.system or "",
      stats = tabs.stats or "",
      working_capital = tabs.working_capital or ""
    }
  }

  local json_str = Export.table_to_json(data)

  local ok, err = pcall(function()
    helpers.write_file(filepath, json_str)
  end)

  if ok then
    player.print({"logistics_simulation.export_success", filepath, #INV_EXPORT_ORDER})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  return ok
end

-- Export as CSV (raw protocol format)
function Export.export_csv(player)
  Buffer.ensure_defaults()
  
  local lines, line_count = Buffer.snapshot_lines()
  if line_count == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end
  
  local filename = get_export_filename(player)
  local filepath = M.EXPORT_FOLDER .. "/" .. filename .. ".csv"
  
  local content = table.concat(lines, "\n")
  
  -- Use helpers.write_file (Factorio 2.0+)
  local ok, err = pcall(function()
    helpers.write_file(filepath, content)
  end)
  
  if ok then
    player.print({"logistics_simulation.export_success", filepath, #lines})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  return ok  

end

-- Export as JSON (structured format)
function Export.export_json(player)
  Buffer.ensure_defaults()
  
  local lines, line_count = Buffer.snapshot_lines()
  if line_count == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end
  
  -- Build JSON structure (without os.date - not available in Factorio!)
  local data = {
    metadata = {
      mod_version = Util.get_logger_version(),
      run_name = storage.run_name or "unnamed",
      start_tick = storage.run_start_tick or 0,
      export_tick = game.tick,
      line_count = line_count,
      sample_interval = M.get_sample_interval_ticks()
    },
    registrations = {
      chests = Export.serialize_registry(storage.registry),
      machines = Export.serialize_registry(storage.machines),
      protected = Export.serialize_registry(storage.protected)
    },
    protocol_lines = lines
  }
  
  local json_str = Export.table_to_json(data)
  
  local filename = get_export_filename(player)
  local filepath = M.EXPORT_FOLDER .. "/" .. filename .. ".json"
  
  -- Use helpers.write_file (Factorio 2.0+)
  local ok, err = pcall(function()
    helpers.write_file(filepath, json_str)
  end)
  
  if ok then
    player.print({"logistics_simulation.export_success", filepath, #lines})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  return ok

end


-- Serialize registry for JSON export
function Export.serialize_registry(registry)
  if not registry then return {} end
  
  local result = {}
  for unit_number, rec in pairs(registry) do
    result[#result + 1] = {
      id = rec.id,
      unit_number = rec.unit_number,
      name = rec.name,
      surface_index = rec.surface_index,
      position = rec.position,
      type = rec.type or rec.kind
    }
  end
  
  table.sort(result, function(a, b)
    return (a.id or "") < (b.id or "")
  end)
  
  return result
end

-- Simple JSON encoder (handles basic types)
-- NOTE: Lua cannot distinguish an empty array from an empty object.
-- Empty tables are serialized as JSON objects ({}) by this generic encoder.
-- List-like fields that must export [] need explicit handling before calling this function.
function Export.table_to_json(tbl, indent)
  indent = indent or 0
  local indent_str = string.rep("  ", indent)
  local next_indent_str = string.rep("  ", indent + 1)
  
  if type(tbl) ~= "table" then
    if type(tbl) == "string" then
      return '"' .. Util.json_escape_string(tbl) .. '"'
    elseif type(tbl) == "number" or type(tbl) == "boolean" then
      return tostring(tbl)
    elseif tbl == nil then
      return "null"
    else
      return '""'
    end
  end
  
  -- Check if array or object
  local is_array = true
  local max_index = 0
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      is_array = false
      break
    end
    max_index = math.max(max_index, k)
  end
  
  if is_array and max_index > 0 then
    -- Array
    local parts = {}
    for i = 1, max_index do
      parts[#parts + 1] = next_indent_str .. Export.table_to_json(tbl[i], indent + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "]"
  else
    -- Object
    local parts = {}
    local keys = {}
    for k, _ in pairs(tbl) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    
    for _, k in ipairs(keys) do
      local v = tbl[k]
      local key_str = '"' .. Util.json_escape_string(k) .. '"'
      local val_str = Export.table_to_json(v, indent + 1)
      parts[#parts + 1] = next_indent_str .. key_str .. ": " .. val_str
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "}"
  end
end



return Export