-- =========================================
-- LogSim (Factorio 2.0) 
-- Logging&Trace Module for Logistics Simulation
-- (String generation, no side effects)
--
-- Version 0.3.0 first für LogSim 0.3.0
-- Version 0.3.1 power and more infos
-- Version 0.3.2 machines finished products
-- Version 0.3.3 simlog.M.ITEM_ALIASES
-- =========================================

local M = require("config")
local T = M.T
local R = require("reset")
local UI = require("ui")
local Chests = require("chests")

local SimLog = {}
SimLog.version = "0.3.3"

SimLog.MACHINE_STATE = {
  RUN       = "RUN",
  IDLE      = "IDLE",
  WAIT_IN   = "NOIN",
  OUT_FULL  = "FULL",
  NO_POWER  = "POWER",
  DISABLED  = "DIS",
  MISSING   = "MISS",
  NO_RECIPE = "RCP",
  UNK       = "UNK",
}

local function add_status(map, key, value)
  if key ~= nil then
    map[key] = value
  end
end

SimLog.STATUS_MAP = {}
add_status(SimLog.STATUS_MAP, defines.entity_status.working,                      SimLog.MACHINE_STATE.RUN)
add_status(SimLog.STATUS_MAP, defines.entity_status.no_power,                     SimLog.MACHINE_STATE.NO_POWER)
add_status(SimLog.STATUS_MAP, defines.entity_status.low_power,                    SimLog.MACHINE_STATE.NO_POWER)
add_status(SimLog.STATUS_MAP, defines.entity_status.disabled_by_control_behavior, SimLog.MACHINE_STATE.DISABLED)
add_status(SimLog.STATUS_MAP, defines.entity_status.item_ingredient_shortage,     SimLog.MACHINE_STATE.WAIT_IN)
add_status(SimLog.STATUS_MAP, defines.entity_status.fluid_ingredient_shortage,    SimLog.MACHINE_STATE.WAIT_IN)
add_status(SimLog.STATUS_MAP, defines.entity_status.full_output,                  SimLog.MACHINE_STATE.OUT_FULL)
add_status(SimLog.STATUS_MAP, defines.entity_status.no_recipe,                    SimLog.MACHINE_STATE.NO_RECIPE)
add_status(SimLog.STATUS_MAP, defines.entity_status.idle,                         SimLog.MACHINE_STATE.IDLE)

function SimLog.get_pollution_per_s(surface)
  local stats = surface and surface.pollution_statistics
  if not stats then return nil end

  local precision = defines.flow_precision_index.one_minute
  local samples = M.POLLUTION_SAMPLES

  local function sum_category(cat, counts_table)
    local sum = 0
    for proto, _ in pairs(counts_table or {}) do
      for i = 1, samples do
        sum = sum + stats.get_flow_count{
          name = proto,
          category = cat,
          precision_index = precision,
          sample_index = i,
          count = true
        }
      end
    end
    return sum
  end

  local produced = sum_category("input",  stats.input_counts)
  local absorbed = sum_category("output", stats.output_counts)

  return { produced = produced, absorbed = absorbed, delta = produced - absorbed }
end

function SimLog.get_power_w_1s(surface)
  if not surface then return nil end

  local stats = surface.global_electric_network_statistics
  if not stats then
    surface.create_global_electric_network()
    stats = surface.global_electric_network_statistics
  end
  if not stats then return nil end

  local precision = defines.flow_precision_index.one_minute
  local samples = M.POWER_SAMPLES
  local sum_samples = 0.0

  for i = 1, samples do
    local sample_total = 0.0

    for proto, _ in pairs(stats.input_counts or {}) do
      sample_total = sample_total + stats.get_flow_count{
        name = proto,
        category = "input",
        precision_index = precision,
        sample_index = i
      }
    end

    sum_samples = sum_samples + sample_total
  end

  return sum_samples / samples
end

-- Begin of a line (telegram)
function SimLog.begin_telegram(tick, surface, force)
  storage.perline_counter = (storage.perline_counter or 0) + 1
  local line_counter = storage.perline_counter
  local parts = {}
  parts[#parts+1] = tostring(line_counter) .. " " .. "tick=" .. tostring(tick)
  parts[#parts+1] = "0000"  -- Placeholder for total length (4 digits)
 
  -- Power 
  local pwr = SimLog.get_power_w_1s(surface)
  parts[#parts+1] = pwr and ("PWR:" .. string.format("%.0f", pwr)) or "PWR:NA"
  
  -- FIX: Removed leading semicolon from pollution string
  local pol = SimLog.get_pollution_per_s(surface)
  if pol then
    parts[#parts+1] = string.format("POL=%.2f,%.2f,%+.2f", pol.produced, pol.absorbed, pol.delta)
  else
    parts[#parts+1] = "POL:NA"
  end
  
  return parts
end

-- End of a line (telegram)
function SimLog.end_telegram(parts)
  local s = table.concat(parts, ";")
  local n = #s
  if n > M.MAX_TELEGRAM_LENGTH then n = M.MAX_TELEGRAM_LENGTH end
  parts[2] = string.format("%04d", n)
  return table.concat(parts, ";")
end

-- Build sorted output string from list
function SimLog.build_string(list, resolve_fn, encode_fn)
  if not list or next(list) == nil then return "" end

  local arr = {}
  for _, rec in pairs(list) do
    arr[#arr+1] = rec
  end

  -- Stable sort (primary by id, fallback unit_number)
  table.sort(arr, function(a, b)
    local aid = a.id or ""
    local bid = b.id or ""
    if aid ~= bid then return aid < bid end
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)

  local segs = {}
  for i = 1, #arr do
    local rec = arr[i]
    local ent = resolve_fn(rec)
    segs[#segs+1] = encode_fn(rec, ent)
  end

  return table.concat(segs, ";")
end

function SimLog.encode_machine(rec, ent)
  if not ent or not ent.valid then
    return rec.id .. "=MISSING"
  end

  -- Local short-name function
  local function short_name(name)
    if not name then return "" end
    return M.ITEM_ALIASES[name] or name
  end

  -- Status
  local mapped = SimLog.STATUS_MAP[ent.status] or SimLog.MACHINE_STATE.UNK
  if not mapped then
    local sname = "?"
    for k, v in pairs(defines.entity_status) do
      if v == ent.status then sname = k; break end
    end
    mapped = SimLog.MACHINE_STATE.UNK .. "(" .. tostring(sname) .. ":" .. tostring(ent.status) .. ")"
  end

  -- Recipe / Products
  local prod_str = "NO_RECIPE"
  local recipe = nil

  if ent.get_recipe then
    recipe = ent.get_recipe()
  end

  if recipe and recipe.valid and recipe.products then
    local names = {}
    for i = 1, #recipe.products do
      local p = recipe.products[i]
      if p and p.name then
        local pname = short_name(p.name)

        -- Append quality only if present AND not "normal"
        if p.quality and p.quality ~= "normal" then
          pname = pname .. "@" .. tostring(p.quality)
        end

        names[#names + 1] = pname
      end
    end

    if #names > 0 then
      prod_str = table.concat(names, ",")
    else
      prod_str = "NO_PRODUCTS"
    end
  end

  -- Production counter
  local finished = nil
  local ok = pcall(function()
    finished = ent.products_finished
  end)
  local fin_str = (ok and finished ~= nil) and tostring(finished) or "NA"

  return rec.id .. ":" .. mapped .. "|" .. prod_str .. "=" .. fin_str
end

function SimLog.encode_chest(rec, ent)
  if not ent or not ent.valid then
    return rec.id .. ":MISSING=0"
  end

  local inv = ent.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then
    return rec.id .. ":NOINV=0"
  end

  local contents = inv.get_contents()
  if not contents then
    return rec.id .. ":LEER=0"
  end

  local items = {}
  local any = false

  -- Local short-name function
  local function short_name(name)
    if not name then return "" end
    return M.ITEM_ALIASES[name] or name
  end

  -- Decode contents (supports Factorio 1.x and 2.x with Quality)
  for k, v in pairs(contents) do
    local item_name = nil
    local quality = nil
    local count = 0

    -- Case A: List of tables (Factorio 2.x / Quality)
    if type(k) == "number" and type(v) == "table" then
      item_name = v.name or v.item
      quality   = v.quality or v.quality_name
      count     = v.count or v.amount or 0

    -- Case B: Map structure
    else
      if type(k) == "string" then
        item_name = k
      elseif type(k) == "table" then
        item_name = k.name or k.item
        quality   = k.quality or k.quality_name
      else
        item_name = tostring(k)
      end

      if type(v) == "number" then
        count = v
      elseif type(v) == "table" then
        count = v.count or v.amount or 0
      else
        count = tonumber(v) or 0
      end
    end

    count = tonumber(count) or 0

    if item_name and count > 0 then
      any = true
      local sname = short_name(item_name)

      if quality and quality ~= "normal" then
        items[#items+1] = sname .. "@" .. tostring(quality) .. "=" .. tostring(count)
      else
        items[#items+1] = sname .. "=" .. tostring(count)
      end
    end
  end

  if not any then
    return rec.id .. ":LEER=0"
  end

  return rec.id .. ":" .. table.concat(items, "|")
end

function get_logger_version()
  return (script.active_mods and script.active_mods["logistics_simulation"]) or "unknown"
end

function SimLog.build_header(meta)
  meta = meta or {}

  local lines = {}
  lines[#lines+1] = "# LogSim Protocol"
  lines[#lines+1] = "# version=" .. tostring(get_logger_version())
  lines[#lines+1] = "# modules config=" .. M.version ..
                    " reset=" .. R.version ..
                    " chests=" .. Chests.version ..
                    " dialogs=" .. UI.version ..
                    " logging=" .. SimLog.version

  if meta.run_name then   lines[#lines+1] = "# run_name=" .. tostring(meta.run_name) end
  if meta.start_tick then lines[#lines+1] = "# start_tick=" .. tostring(meta.start_tick) end
  if meta.surface then    lines[#lines+1] = "# surface=" .. tostring(meta.surface) end
  if meta.force then      lines[#lines+1] = "# force=" .. tostring(meta.force) end

  lines[#lines+1] = "# format: tick;len4;segments..."
  lines[#lines+1] = "# ----"

  return table.concat(lines, "\n")
end

return SimLog