-- =========================================
-- LogSim (Factorio 2.0) 
-- Logging & Trace Module for Logistics Simulation
-- Builds protocol log strings from live factory state (power, pollution, machines, inventories).
--
-- Version 0.8.1 introduce WIP (work in progress)
-- Version 0.8.2 format_factory_stats: scenario, mods, power (3 windows), pollution (3 windows)
--
-- =========================================

local M = require("config")
local T = M.T
local R = require("reset")
local UI = require("ui")
local Chests = require("chests")
local Util = require("utility")

local SimLog = {}
SimLog.version = "0.8.2"

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

-- =========================================
-- FACTORY STATS (für Blueprint-Analyse, Teil 3)
-- Einheitliche Tabelle: POWER / POLLUTION / ITEM / FLUID
-- Basis: 10-Minuten-Fenster, sample_index=1 (aktuellster 10-min-Bucket)
-- =========================================

local P10 = defines.flow_precision_index.ten_minutes

-- Formatiert Watt menschenlesbar
local function fmt_watts(w)
  if not w or w ~= w then return "NA" end
  w = tonumber(w) or 0
  if     w >= 1e9 then return string.format("%.2f GW", w / 1e9)
  elseif w >= 1e6 then return string.format("%.2f MW", w / 1e6)
  elseif w >= 1e3 then return string.format("%.2f kW", w / 1e3)
  else                 return string.format("%.0f W",  w)
  end
end

-- Items, Fluids, Pollution: get_flow_count liefert bereits /min (API-normalisiert).
-- Kein Faktor nötig.
local function safe_flow(stats, name, category)
  local ok, v = pcall(function()
    return stats.get_flow_count{
      name            = name,
      category        = category,
      precision_index = P10
    }
  end)
  return (ok and v) and v or 0
end

-- Power (electric networks): get_flow_count liefert /tick → × 60 = Watt.
local function safe_flow_power(stats, name, category)
  local ok, v = pcall(function()
    return stats.get_flow_count{
      name            = name,
      category        = category,
      precision_index = P10
    }
  end)
  return ((ok and v) and v or 0) * 60
end

-- Liest alle produced/consumed-Paare aus einem LuaFlowStatistics-Objekt.
-- Rückgabe: { [name] = {produced=number, consumed=number} }
-- Einheit: was get_flow_count liefert (/min für Pollution/Items/Fluids, W für Power)
local function read_flow_stats(stats)
  if not stats then return {} end
  local result = {}

  for name, _ in pairs(stats.input_counts or {}) do
    local v = safe_flow(stats, name, "input")
    if not result[name] then result[name] = {produced=0, consumed=0} end
    result[name].produced = v
  end

  for name, _ in pairs(stats.output_counts or {}) do
    local v = safe_flow(stats, name, "output")
    if not result[name] then result[name] = {produced=0, consumed=0} end
    result[name].consumed = v
  end

  return result
end

-- Liest Strom: Pol-Iteration + Netz-Deduplizierung (bewährte Methode).
-- Gibt {produced=W, consumed=W} zurück.
-- ACHTUNG: get_flow_count-Einheit für Strom muss noch kalibriert werden;
-- wir geben Rohwert aus damit der User den Faktor sehen kann.
local function read_power_stats(surface)
  if not (surface and surface.valid) then return {produced=0, consumed=0} end

  local seen = {}
  local poles = surface.find_entities_filtered{type = "electric-pole"}
  for _, pole in pairs(poles) do
    if pole.valid and pole.electric_network_id and not seen[pole.electric_network_id] then
      local s = pole.electric_network_statistics
      if s then seen[pole.electric_network_id] = s end
    end
  end

  local prod = 0.0
  local cons = 0.0
  for _, stats in pairs(seen) do
    -- input_counts = Verbrauch (Consumption), output_counts = Produktion (Production)
    for name, _ in pairs(stats.input_counts or {}) do
      prod = prod + safe_flow_power(stats, name, "input")
    end
    for name, _ in pairs(stats.output_counts or {}) do
      cons = cons + safe_flow_power(stats, name, "output")
    end
  end
  return {produced = prod, consumed = cons}
end

-- Sortiert eine {[name]={produced,consumed}} Tabelle alphabetisch nach name.
local function sorted_pairs(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys+1] = k end
  table.sort(keys)
  local i = 0
  return function()
    i = i + 1
    if keys[i] then return keys[i], tbl[keys[i]] end
  end
end

-- =========================================
-- Öffentliche Funktion: Baut den dritten Block.
-- surface: LuaSurface des aktuellen Spielers
-- force:   LuaForce des aktuellen Spielers (für Item/Fluid-Statistiken)
-- =========================================
function SimLog.format_factory_stats(surface, force)
  local lines = {}

  -- --------------------------------------------------
  -- Kopfzeile: Szenario + Mods
  -- --------------------------------------------------
  lines[#lines+1] = "# ----"
  lines[#lines+1] = "# FACTORY_STATS (tick=" .. tostring(game.tick) .. ")"

  local ok_lvl, lvl = pcall(function() return script.level end)
  if ok_lvl and lvl then
    local sname = tostring(lvl.level_name    or "unknown")
    local cname = tostring(lvl.campaign_name or "")
    local mname = tostring(lvl.mod_name      or "base")
    if cname ~= "" then
      lines[#lines+1] = "# scenario=" .. sname .. "  campaign=" .. cname .. "  provided_by=" .. mname
    else
      lines[#lines+1] = "# scenario=" .. sname .. "  provided_by=" .. mname
    end
  else
    lines[#lines+1] = "# scenario=NA"
  end

  local run_name = (storage and storage.run_name) or ""
  lines[#lines+1] = "# run_name=" .. (run_name ~= "" and run_name or "(not set)")

  lines[#lines+1] = "# ----"
  lines[#lines+1] = "# ACTIVE_MODS"
  lines[#lines+1] = "# id;mod_name;version"
  local ok_mods, mods = pcall(function() return script.active_mods end)
  if ok_mods and mods then
    local mod_list = {}
    for name, version in pairs(mods) do mod_list[#mod_list+1] = {name=name, version=tostring(version)} end
    table.sort(mod_list, function(a,b) return a.name < b.name end)
    for i, e in ipairs(mod_list) do
      lines[#lines+1] = string.format("%d;%s;%s", i, e.name, e.version)
    end
  else
    lines[#lines+1] = "NA"
  end

  -- --------------------------------------------------
  -- Statistik-Tabelle (10-Minuten-Basis)
  -- --------------------------------------------------
  lines[#lines+1] = "# ----"
  lines[#lines+1] = "# STATISTICS_10MIN  (precision=10min, sample_index=1)"
  lines[#lines+1] = "# category;name;produced;consumed;delta"

  if not (surface and surface.valid) then
    lines[#lines+1] = "# (no valid surface)"
    return table.concat(lines, "\n")
  end

  -- 1) POWER
  local pwr = read_power_stats(surface)
  local delta_pwr = pwr.produced - pwr.consumed
  lines[#lines+1] = string.format("POWER;;%s;%s;%s",
    fmt_watts(pwr.produced), fmt_watts(pwr.consumed), fmt_watts(delta_pwr))

  -- 2) POLLUTION
  if surface.pollution_statistics then
    local pol_data = read_flow_stats(surface.pollution_statistics)
    -- Pollution hat keinen "name" im Sinne eines Items — wir summieren alles
    local pol_prod, pol_cons = 0.0, 0.0
    for _, v in pairs(pol_data) do
      pol_prod = pol_prod + v.produced
      pol_cons = pol_cons + v.consumed
    end
    lines[#lines+1] = string.format("POLLUTION;;%.2f;%.2f;%.2f",
      pol_prod, pol_cons, pol_prod - pol_cons)
  end

  -- 3) ITEMS
  if force and force.valid then
    local ok_is, item_stats = pcall(function()
      return force.get_item_production_statistics(surface)
    end)
    if ok_is and item_stats then
      local items = read_flow_stats(item_stats)
      for name, v in sorted_pairs(items) do
        lines[#lines+1] = string.format("ITEM;%s;%.1f;%.1f;%.1f",
          name, v.produced, v.consumed, v.produced - v.consumed)
      end
    end
  end

  -- 4) FLUIDS
  if force and force.valid then
    local ok_fs, fluid_stats = pcall(function()
      return force.get_fluid_production_statistics(surface)
    end)
    if ok_fs and fluid_stats then
      local fluids = read_flow_stats(fluid_stats)
      for name, v in sorted_pairs(fluids) do
        lines[#lines+1] = string.format("FLUID;%s;%.1f;%.1f;%.1f",
          name, v.produced, v.consumed, v.produced - v.consumed)
      end
    end
  end

  return table.concat(lines, "\n")
end

-- =========================================
-- Bestehende Funktionen (unverändert)
-- =========================================

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
  local s4 = SimLog.encode_virtual("WIP",  v.WIP)   -- NEU
  local s3 = SimLog.encode_virtual("RECV", v.RECV)
  local s1 = SimLog.encode_virtual("T00",  v.T00)
  local s2 = SimLog.encode_virtual("SHIP", v.SHIP)

  if s1 then parts[#parts+1] = s1 end
  if s2 then parts[#parts+1] = s2 end
  if s3 then parts[#parts+1] = s3 end
  if s4 then parts[#parts+1] = s4 end              -- NEU
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
