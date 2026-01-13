-- =========================================
-- LogSim (Factorio 2.0) 
-- Export Data to file
--
-- Version 0.6.2 first für LogSim 0.6.2
-- =========================================

local M = require("config")
local UI = require("ui")
local Buffer = require("buffer")

local Export = {}
Export.version = "0.6.2"

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

-- Sanitize filename
local function sanitize_filename(s)
  return (tostring(s):gsub("[^%w%._%-]", "_"))
end

-- Get filename from dialog
local function get_export_filename(player)
  local frame = player.gui.screen[M.GUI_EXPORT_FRAME]
  if not (frame and frame.valid) then 
    return sanitize_filename(M.EXPORT_DEFAULT_NAME)
  end
  
  local field = find_by_name(frame, M.GUI_EXPORT_FILENAME)
  if not (field and field.valid) then
    return sanitize_filename(M.EXPORT_DEFAULT_NAME)
  end
  
  local name = field.text or ""
  if name == "" then
    return sanitize_filename(M.EXPORT_DEFAULT_NAME)
  end
  
  return sanitize_filename(name)
end

-- Export as CSV (raw protocol format)
function Export.export_csv(player)
  Buffer.ensure_defaults()
  
  local lines = storage.buffer_lines or {}
  if #lines == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return
  end
  
  local filename = get_export_filename(player)
  local filepath = M.EXPORT_FOLDER .. "/" .. filename .. ".csv"
  
  local content = table.concat(lines, "\n")
  
  -- Use helpers.write_file (Factorio 2.0+)
  local success, err = pcall(function()
    helpers.write_file(filepath, content)
  end)
  
  if success then
    player.print({"logistics_simulation.export_success", filepath, #lines})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  
  UI.close_export_dialog(player)
end

-- Export as JSON (structured format)
function Export.export_json(player)
  Buffer.ensure_defaults()
  
  local lines = storage.buffer_lines or {}
  if #lines == 0 then
    player.print({"logistics_simulation.export_no_data"})
    return
  end
  
  -- Build JSON structure (without os.date - not available in Factorio!)
  local data = {
    metadata = {
      mod_version = get_logger_version(),
      run_name = storage.run_name or "unnamed",
      start_tick = storage.run_start_tick or 0,
      export_tick = game.tick,
      line_count = #lines,
      sample_interval = storage.sample_interval or M.SAMPLE_INTERVAL_TICKS
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
  local success, err = pcall(function()
    helpers.write_file(filepath, json_str)
  end)
  
  if success then
    player.print({"logistics_simulation.export_success", filepath, #lines})
  else
    player.print({"logistics_simulation.export_failed", tostring(err)})
  end
  
  UI.close_export_dialog(player)
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
function Export.table_to_json(tbl, indent)
  indent = indent or 0
  local indent_str = string.rep("  ", indent)
  local next_indent_str = string.rep("  ", indent + 1)
  
  if type(tbl) ~= "table" then
    if type(tbl) == "string" then
      return '"' .. tbl:gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
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
      local key_str = '"' .. tostring(k) .. '"'
      local val_str = Export.table_to_json(v, indent + 1)
      parts[#parts + 1] = next_indent_str .. key_str .. ": " .. val_str
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "}"
  end
end

return Export