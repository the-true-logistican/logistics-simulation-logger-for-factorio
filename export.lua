-- =========================================
-- LogSim (Factorio 2.0)
-- Export Module
--
-- Exports protocol, inventory report and transaction data to CSV and JSON files.
--
-- Version 0.8.0 first complete working version
-- Version 0.8.1 ring buffer export support
-- Version 0.8.2 line-count fixes
-- Version 0.8.3 blueprint tab integration
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 UI.find_by_name() integration
-- Version 0.9.2 local cleanup and shared file-write helper
--
-- =========================================

local M = require("config")
local UI = require("ui")
local Buffer = require("buffer")
local Transaction = require("transaction")
local Util = require("utility")

local Export = {}
Export.version = "0.9.2"

local INV_EXPORT_ORDER = {
  { key = "assets",          title = "FIXED ASSETS" },
  { key = "costs",           title = "ITEMS/COSTS" },
  { key = "system",          title = "SYSTEM/MODS" },
  { key = "stats",           title = "STATISTICS" },
  { key = "working_capital", title = "WORKING CAPITAL" }
}

-- =========================================
-- Filename and file output helpers
-- =========================================

local function get_export_filename(player)
  local fallback = Util.sanitize_filename(M.EXPORT_DEFAULT_NAME)

  if not (player and player.valid) then
    return fallback
  end

  local frame = player.gui.screen[M.GUI_EXPORT_FRAME]
  if not (frame and frame.valid) then
    return fallback
  end

  local field = UI.find_by_name(frame, M.GUI_EXPORT_FILENAME)
  if not (field and field.valid) then
    return fallback
  end

  local name = field.text or ""
  if name == "" then
    return fallback
  end

  return Util.sanitize_filename(name)
end

local function build_export_path(player, extension)
  return M.EXPORT_FOLDER .. "/" .. get_export_filename(player) .. "." .. extension
end

local function write_export_file(player, filepath, content, item_count)
  -- Factorio 2.x writes files through helpers.write_file into script-output.
  local ok, err = pcall(function()
    helpers.write_file(filepath, content)
  end)

  if ok then
    player.print({"logistics_simulation.export_success", filepath, item_count})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end

  return ok
end

-- =========================================
-- Transaction export helpers
-- =========================================

function Export._tx_events_for_json(tx_n)
  local out = {}

  for i = 1, tx_n do
    out[#out + 1] = Transaction.tx_get_event(i)
  end

  return out
end

-- =========================================
-- Transaction CSV export
-- =========================================

function Export.export_tx_csv(player)
  Buffer.ensure_defaults()

  local tx_n = Transaction.tx_line_count() or 0
  if tx_n == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

  local lines = {}
  local surface = player.surface

  for i = 1, tx_n do
    local line = Transaction.tx_get_line(i, surface)
    if line then
      lines[#lines + 1] = line
    end
  end

  local filepath = build_export_path(player, "csv")
  local content = table.concat(lines, "\n")

  return write_export_file(player, filepath, content, tx_n)
end

-- =========================================
-- Transaction JSON export
-- =========================================

function Export.export_tx_json(player)
  Buffer.ensure_defaults()

  local tx_n = Transaction.tx_line_count() or 0
  if tx_n == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

  local data = {
    metadata = {
      mod_version = Util.get_logger_version(),
      run_name = storage.run_name or "unnamed",
      start_tick = storage.run_start_tick or 0,
      export_tick = game.tick,
      event_count = tx_n,
      kind = "transactions"
    },
    tx_events = Export._tx_events_for_json(tx_n)
  }

  local filepath = build_export_path(player, "json")
  local content = Export.table_to_json(data)

  return write_export_file(player, filepath, content, tx_n)
end

-- =========================================
-- Inventory report export helpers
-- =========================================

local function get_inv_tabs(player)
  if not (player and player.valid) then return nil end

  if storage
     and storage.invwin_data
     and type(storage.invwin_data[player.index]) == "table" then
    return storage.invwin_data[player.index]
  end

  local frame = player.gui.screen[M.GUI_INV_FRAME]
  if not (frame and frame.valid) then return nil end

  local box = frame[M.GUI_INV_BOX]
  if not (box and box.valid) then return nil end

  local text = box.text or ""
  if text == "" then return nil end

  return {
    assets = text,
    costs = "",
    system = "",
    stats = "",
    working_capital = ""
  }
end

local function inv_tabs_have_data(tabs)
  if type(tabs) ~= "table" then return false end

  for _, def in ipairs(INV_EXPORT_ORDER) do
    local text = tabs[def.key]
    if type(text) == "string" and text ~= "" then
      return true
    end
  end

  return false
end

local function inv_tabs_to_text(tabs)
  local lines = {}

  for _, def in ipairs(INV_EXPORT_ORDER) do
    local text = tabs[def.key] or ""

    lines[#lines + 1] = "# =================================================="
    lines[#lines + 1] = "# " .. def.title
    lines[#lines + 1] = "# =================================================="

    if text ~= "" then
      lines[#lines + 1] = text
    else
      lines[#lines + 1] = "# no data"
    end

    lines[#lines + 1] = ""
  end

  return table.concat(lines, "\n")
end

-- =========================================
-- Inventory report CSV export
-- =========================================

function Export.export_inv_csv(player)
  Buffer.ensure_defaults()

  local tabs = get_inv_tabs(player)
  if not inv_tabs_have_data(tabs) then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

  local filepath = build_export_path(player, "csv")
  local content = inv_tabs_to_text(tabs)

  return write_export_file(player, filepath, content, #INV_EXPORT_ORDER)
end

-- =========================================
-- Inventory report JSON export
-- =========================================

function Export.export_inv_json(player)
  Buffer.ensure_defaults()

  local tabs = get_inv_tabs(player)
  if not inv_tabs_have_data(tabs) then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

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

  local filepath = build_export_path(player, "json")
  local content = Export.table_to_json(data)

  return write_export_file(player, filepath, content, #INV_EXPORT_ORDER)
end

-- =========================================
-- Protocol CSV export
-- =========================================

function Export.export_csv(player)
  Buffer.ensure_defaults()

  local lines, line_count = Buffer.snapshot_lines()
  if line_count == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

  local filepath = build_export_path(player, "csv")
  local content = table.concat(lines, "\n")

  return write_export_file(player, filepath, content, #lines)
end

-- =========================================
-- Protocol JSON export
-- =========================================

function Export.export_json(player)
  Buffer.ensure_defaults()

  local lines, line_count = Buffer.snapshot_lines()
  if line_count == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return false
  end

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

  local filepath = build_export_path(player, "json")
  local content = Export.table_to_json(data)

  return write_export_file(player, filepath, content, #lines)
end

-- =========================================
-- Registry serialization
-- =========================================

function Export.serialize_registry(registry)
  if not registry then return {} end

  local result = {}

  for _, rec in pairs(registry) do
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

-- =========================================
-- JSON encoding
-- =========================================

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

  local is_array = true
  local max_index = 0

  for key, _ in pairs(tbl) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      is_array = false
      break
    end

    max_index = math.max(max_index, key)
  end

  if is_array and max_index > 0 then
    local parts = {}

    for i = 1, max_index do
      parts[#parts + 1] = next_indent_str .. Export.table_to_json(tbl[i], indent + 1)
    end

    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "]"
  end

  local parts = {}
  local keys = {}

  for key, _ in pairs(tbl) do
    keys[#keys + 1] = key
  end

  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  for _, key in ipairs(keys) do
    local value = tbl[key]
    local key_str = '"' .. Util.json_escape_string(key) .. '"'
    local value_str = Export.table_to_json(value, indent + 1)

    parts[#parts + 1] = next_indent_str .. key_str .. ": " .. value_str
  end

  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "}"
end

return Export