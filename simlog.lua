-- =========================================
-- LogSim (Factorio 2.0) 
-- Logging & Trace Module for Logistics Simulation
-- Builds protocol log strings from live factory state (power, pollution, machines, inventories).
-- =========================================

local M = require("config")
local T = M.T
local R = require("reset")
local UI = require("ui")
local Chests = require("chests")
local Util = require("utility")

local SimLog = {}
SimLog.version = "0.8.0"

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
add_status(SimLog.STATUS_MAP, defines.entity_status.working,                          SimLog.MACHINE_STATE.RUN)
add_status(SimLog.STATUS_MAP, defines.entity_status.no_power,                         SimLog.MACHINE_STATE.NO_POWER)
add_status(SimLog.STATUS_MAP, defines.entity_status.low_power,                        SimLog.MACHINE_STATE.NO_POWER)
add_status(SimLog.STATUS_MAP, defines.entity_status.disabled_by_control_behavior,     SimLog.MACHINE_STATE.DISABLED)
add_status(SimLog.STATUS_MAP, defines.entity_status.item_ingredient_shortage,         SimLog.MACHINE_STATE.WAIT_IN)
add_status(SimLog.STATUS_MAP, defines.entity_status.fluid_ingredient_shortage,        SimLog.MACHINE_STATE.WAIT_IN)
add_status(SimLog.STATUS_MAP, defines.entity_status.full_output,                      SimLog.MACHINE_STATE.OUT_FULL)
add_status(SimLog.STATUS_MAP, defines.entity_status.no_recipe,                        SimLog.MACHINE_STATE.NO_RECIPE)
add_status(SimLog.STATUS_MAP, defines.entity_status.idle,                             SimLog.MACHINE_STATE.IDLE)
add_status(SimLog.STATUS_MAP, defines.entity_status.waiting_for_space_in_destination, SimLog.MACHINE_STATE.OUT_FULL)
add_status(SimLog.STATUS_MAP, defines.entity_status.not_enough_space_in_output,       SimLog.MACHINE_STATE.OUT_FULL)

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

  local precision = defines.flow_precision_index.one_minute
  local samples = M.POWER_SAMPLES
  local sum_samples = 0.0

  -- Collect unique networks (fixed: store actual statistics object, not just true)
  local seen_networks = {}
  local networks = surface.find_entities_filtered{type = "electric-pole"}
  
  for _, pole in pairs(networks) do
    if pole.valid and pole.electric_network_id then
      local net_id = pole.electric_network_id
      
      -- Only process each network ONCE
      if not seen_networks[net_id] then
        local stats = pole.electric_network_statistics
        if stats then
          seen_networks[net_id] = stats  -- ← FIX: Speichere stats, nicht true
        end
      end
    end
  end
  
  -- Now sum up power from each unique network
  for net_id, stats in pairs(seen_networks) do
    for i = 1, samples do
      local sample_total = 0.0
      
      -- Sum all inputs for this sample
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
  end
  
  return sum_samples / samples
end

function SimLog.begin_telegram(tick, surface, force)
  storage.perline_counter = (storage.perline_counter or 0) + 1
  surface = surface or (game and game.surfaces and game.surfaces[1])  -- fallback
  local line_counter = storage.perline_counter
  
  local parts = {}
  parts[#parts+1] = table.concat({ tostring(line_counter),";Zeit=", Util.to_excel_datetime(game.tick, surface), ";tick=", tostring(tick) })
  parts[#parts+1] = "0000"
 
  if surface and surface.valid then
    parts[#parts+1] = "SURF:" .. tostring(surface.name)
  end
  
  local pwr = SimLog.get_power_w_1s(surface)
  parts[#parts+1] = pwr and ("PWR:" .. string.format("%.0f", pwr)) or "PWR:NA"
  
  local pol = SimLog.get_pollution_per_s(surface)
  if pol then
    parts[#parts+1] = string.format("POL=%.2f,%.2f,%+.2f", pol.produced, pol.absorbed, pol.delta)
  else
    parts[#parts+1] = "POL:NA"
  end
  
  return parts
end

function SimLog.end_telegram(parts)
  local s = table.concat(parts, ";")
  local n = #s
  if n > M.MAX_TELEGRAM_LENGTH then n = M.MAX_TELEGRAM_LENGTH end
  parts[2] = string.format("%04d", n)
  return table.concat(parts, ";")
end

function SimLog.build_string(list, resolve_fn, encode_fn)
  if not list or next(list) == nil then return "" end

  local arr = {}
  for _, rec in pairs(list) do
    arr[#arr+1] = rec
  end

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

-- -----------------------------------------
-- Virtual buffers (T00 / SHIP / RECV)
-- Appends snapshot balances to the telegram parts.
-- -----------------------------------------

function SimLog.encode_virtual(obj_id, contents)
  if not obj_id or not contents or next(contents) == nil then return nil end

  local function short_name(name)
    return M.ITEM_ALIASES[name] or name
  end

  local items = {}
  for key, count in pairs(contents) do
    if type(count) == "number" then
      local name, qual = key:match("^(.-)@(.+)$")
      name = name or key

      local sname = short_name(name)
      if qual and qual ~= "normal" then
        items[#items+1] = sname .. "@" .. qual .. "=" .. tostring(count)
      else
        items[#items+1] = sname .. "=" .. tostring(count)
      end
    end
  end

  if #items == 0 then return nil end
  table.sort(items)
  return obj_id .. ":" .. table.concat(items, "|")
end

function SimLog.append_virtual_buffers(parts)
  -- parts is the telegram "parts" array (strings)
  if not parts then return end
  if not (storage and storage.tx_virtual) then return end

  local v = storage.tx_virtual

  -- fixed order
  local s3 = SimLog.encode_virtual("RECV", v.RECV)
  local s1 = SimLog.encode_virtual("T00",  v.T00)
  local s2 = SimLog.encode_virtual("SHIP", v.SHIP)

  if s1 then parts[#parts+1] = s1 end
  if s2 then parts[#parts+1] = s2 end
  if s3 then parts[#parts+1] = s3 end
end

function SimLog.build_string_for_surface(list, surface_index, resolve_fn, encode_fn)
  if not list or next(list) == nil then return "" end

  local arr = {}
  for _, rec in pairs(list) do
    if rec.surface_index == surface_index then
      arr[#arr+1] = rec
    end
  end

  if #arr == 0 then return "" end

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

  local function short_name(name)
    if not name then return "" end
    return M.ITEM_ALIASES[name] or name
  end

  local mapped = SimLog.STATUS_MAP[ent.status]
  if not mapped then
    local sname = "?"
    for k, v in pairs(defines.entity_status) do
      if v == ent.status then sname = k; break end
    end
    mapped = SimLog.MACHINE_STATE.UNK .. "(" .. tostring(sname) .. ":" .. tostring(ent.status) .. ")"
  end

  -- Welche "Produkte" hat die Maschine?
  -- Crafting-Maschinen: aus Recipe
  -- Mining-Drills (inkl. Pumpjack): aus Mining-Target (Resource -> mineable products)
  local prod_str = "NO_PRODUCTS"
  local recipe = nil

  -- 1) Crafting-Rezept sicher holen (wirft bei mining-drill/pumpjack sonst Exception)
  if ent.get_recipe then
    local ok, r = pcall(function() return ent.get_recipe() end)
    if ok then recipe = r end
  end

  local function products_to_string(products)
    if not products then return "NO_PRODUCTS" end

    local names = {}
    for i = 1, #products do
      local p = products[i]
      if p and p.name then
        local pname = short_name(p.name)
        if p.quality and p.quality ~= "normal" then
          pname = pname .. "@" .. tostring(p.quality)
        end
        names[#names + 1] = pname
      end
    end

    if #names == 0 then return "NO_PRODUCTS" end
    return table.concat(names, ",")
  end

  -- 2) Wenn Recipe da ist: daraus Produkte
  if recipe and recipe.valid and recipe.products then
    prod_str = products_to_string(recipe.products)

  -- 3) Sonst: mining-drill/pumpjack über Mining-Target
  elseif ent.type == "mining-drill" then
    local tgt = ent.mining_target
    if tgt and tgt.valid and tgt.prototype and tgt.prototype.mineable_properties then
      prod_str = products_to_string(tgt.prototype.mineable_properties.products)
    else
      prod_str = "NO_TARGET"
    end

  -- 4) Sonstige Maschinen ohne Recipe
  else
    prod_str = "NO_RECIPE"
  end

  local finished = nil
  local ok = pcall(function()
    finished = ent.products_finished
  end)
  local fin_str = (ok and finished ~= nil) and tostring(finished) or "NA"

  local out = {}
  out[1] = rec.id
  out[2] = ":"
  out[3] = mapped
  out[4] = "|"
  out[5] = prod_str
  out[6] = "="
  out[7] = fin_str
  return table.concat(out)
end

function SimLog.encode_chest(rec, ent)
  if not ent or not ent.valid then
    return rec.id .. ":MISSING=0"
  end

  -- NEU: Tanks (Fluids) loggen
  if ent.type == "storage-tank" then
    local fluids = ent.get_fluid_contents() -- {["water"]=123.4, ...} (Factorio 2.x ok)
    if not fluids or next(fluids) == nil then
      return rec.id .. ":LEER=0"
    end

    local function short_name(name)
      if not name then return "" end
      return M.ITEM_ALIASES[name] or name
    end

    local items = {}
    for fname, amount in pairs(fluids) do
      local sname = short_name(fname)
      -- Fluids können fractional sein → kompakt mit 1 Nachkommastelle
      items[#items+1] = string.format("%s=%.1f", sname, tonumber(amount) or 0)
    end

    table.sort(items) -- stabile Ausgabe
    return rec.id .. ":" .. table.concat(items, "|")
  end

  -- Alt: normale Kisten
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

  local function short_name(name)
    if not name then return "" end
    return M.ITEM_ALIASES[name] or name
  end

  for k, v in pairs(contents) do
    local item_name = nil
    local quality = nil
    local count = 0

    if type(k) == "number" and type(v) == "table" then
      item_name = v.name or v.item
      quality   = v.quality or v.quality_name
      count     = v.count or v.amount or 0
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

  local out = {}
  out[1] = rec.id
  out[2] = ":"
  out[3] = table.concat(items, "|")
  return table.concat(out)
end

function get_logger_version()
  return (script.active_mods and script.active_mods["logistics_simulation"]) or "unknown"
end

function SimLog.build_header(meta)
  meta = meta or {}

  local lines = {}
  lines[#lines+1] = "# LogSim Protocol"
  lines[#lines+1] = "# version=" .. tostring(get_logger_version())

  if meta.run_name then   lines[#lines+1] = "# run_name=" .. tostring(meta.run_name) end
  if meta.start_tick then lines[#lines+1] = "# start_tick=" .. tostring(meta.start_tick) end
  if meta.surface then    lines[#lines+1] = "# surface=" .. tostring(meta.surface) end
  if meta.force then      lines[#lines+1] = "# force=" .. tostring(meta.force) end

  lines[#lines+1] = "# format: ID;DateTime;tick;len4;surface;Power;Pollution;Inventory of registered Chests;Activity of registered Machines"
  lines[#lines+1] = "# ----"

  return table.concat(lines, "\n")
end

return SimLog
