-- =========================================
-- LogSim (Factorio 2.0)
-- EMA Module – Exponential Moving Average über Bestände
--
-- Aggregiert pro Sample-Tick:
--   1) Registrierte Kisten & Tanks  (storage.registry)
--   2) Virtuelle Puffer             (storage.tx_virtual: T00/SHIP/RECV/WIP/MAN)
--   3) Spieler-Inventare            (game.players: main + trash + cursor)
--
-- Hält pro Material 3 Werte:
--   cur  = aktueller Snapshot-Wert
--   fast = EMA mit alpha_fast (schnell reagierend, default 0.3)
--   slow = EMA mit alpha_slow (träge,              default 0.1)
--
-- Version 0.8.0 Struktur + Storage-Defaults (Stubs)
-- Version 0.8.1 Phase 2: collect_snapshot + update implementiert
-- Version 0.8.2 Phase 3: format_display implementiert
-- Versioj 0.8.3 extract from blueprint with tabs
-- Version 0.9.0 Stable Ledger Operational Baseline 
--
-- =========================================

local M      = require("config")
local Chests = require("chests")
local Util   = require("utility")


local EMA = {}
EMA.version = "0.9.0"

-- =========================================
-- Alpha-Getter (aus Settings via config.lua)
-- =========================================

function EMA.alpha_fast()
  return M.get_ema_alpha_fast()
end

function EMA.alpha_slow()
  return M.get_ema_alpha_slow()
end

-- =========================================
-- Storage-Defaults
-- idempotent – sicher mehrfach aufrufbar
-- =========================================

function EMA.ensure_defaults()
  if not storage.ema then
    storage.ema = {}
  end
  if storage.ema._last_tick == nil then
    storage.ema._last_tick = 0
  end
end

-- =========================================
-- Interner Helfer: Zähler sicher addieren
-- =========================================

local function add_to(snap, name, count)
  if not name or type(count) ~= "number" or count <= 0 then return end
  snap[name] = (snap[name] or 0) + count
end

-- =========================================
-- Interner Helfer: Kisten-Inhalt lesen
-- Gibt { [itemname] = count } zurück.
-- Gleiche Logik wie SimLog.encode_chest, aber als Tabelle.
-- =========================================

local function read_chest_contents(ent)
  local result = {}
  if not (ent and ent.valid) then return result end

  if ent.type == "storage-tank" then
    local fluids = ent.get_fluid_contents()
    if fluids then
      for fname, amount in pairs(fluids) do
        local n = math.floor(tonumber(amount) or 0)
        if n > 0 then result[fname] = (result[fname] or 0) + n end
      end
    end
    return result
  end

  -- Normale Kiste
  local inv = ent.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then return result end

  local contents = inv.get_contents()
  if not contents then return result end

  for k, v in pairs(contents) do
    local item_name, count

    if type(k) == "number" and type(v) == "table" then
      item_name = v.name or v.item
      count     = tonumber(v.count or v.amount) or 0
    elseif type(k) == "string" then
      item_name = k
      count     = type(v) == "number" and v or (type(v) == "table" and (v.count or v.amount) or 0)
    elseif type(k) == "table" then
      item_name = k.name or k.item
      count     = type(v) == "number" and v or (type(v) == "table" and (v.count or v.amount) or 0)
    end

    count = tonumber(count) or 0
    if item_name and count > 0 then
      result[item_name] = (result[item_name] or 0) + count
    end
  end

  return result
end

-- =========================================
-- Interner Helfer: Spieler-Inventar lesen
-- =========================================

local PLAYER_INV_IDS = {
  defines.inventory.character_main,
  defines.inventory.character_trash,
}

local function read_player_contents(player)
  local result = {}
  if not (player and player.valid) then return result end

  for _, inv_id in ipairs(PLAYER_INV_IDS) do
    local inv = player.get_inventory(inv_id)
    if inv and inv.valid then
      local contents = inv.get_contents()
      if contents then
        for k, v in pairs(contents) do
          local item_name, count

          if type(k) == "number" and type(v) == "table" then
            item_name = v.name or v.item
            count     = tonumber(v.count or v.amount) or 0
          elseif type(k) == "string" then
            item_name = k
            count     = type(v) == "number" and v or (type(v) == "table" and (v.count or v.amount) or 0)
          elseif type(k) == "table" then
            item_name = k.name or k.item
            count     = type(v) == "number" and v or (type(v) == "table" and (v.count or v.amount) or 0)
          end

          count = tonumber(count) or 0
          if item_name and count > 0 then
            result[item_name] = (result[item_name] or 0) + count
          end
        end
      end
    end
  end

  -- Cursor-Stack (liegt außerhalb der normalen Inventare)
  local cs = player.cursor_stack
  if cs and cs.valid_for_read and cs.name and cs.count and cs.count > 0 then
    result[cs.name] = (result[cs.name] or 0) + cs.count
  end

  return result
end

-- =========================================
-- Snapshot-Sammlung
-- Gibt { [itemname] = totalcount } zurück.
--
-- surf_idx: optional – nur Registry-Einträge dieser Surface.
--           nil = alle Surfaces.
-- =========================================

function EMA.collect_snapshot(surf_idx)
  EMA.ensure_defaults()

  local snap = {}

  -- --------------------------------------------------
  -- 1) Registrierte Kisten & Tanks (storage.registry)
  -- --------------------------------------------------
  if storage.registry then
    for _, rec in pairs(storage.registry) do
      if (surf_idx == nil) or (rec.surface_index == surf_idx) then
        local ent = Chests.resolve_entity(rec)
        if ent and ent.valid then
          local contents = read_chest_contents(ent)
          for name, count in pairs(contents) do
            add_to(snap, name, count)
          end
        end
      end
    end
  end

  -- --------------------------------------------------
  -- 2) Virtuelle Puffer (storage.tx_virtual)
  --    Schlüssel-Format: "itemname" oder "itemname@quality"
  --    Qualität ignorieren wir beim Aggregieren (Qualitäts-Varianten
  --    landen unter demselben Basis-Namen).
  -- --------------------------------------------------
  if storage.tx_virtual then
    local buckets = { "T00", "SHIP", "RECV", "WIP", "MAN" }
    for _, bucket in ipairs(buckets) do
      local tbl = storage.tx_virtual[bucket]
      if tbl then
        for key, count in pairs(tbl) do
          if type(count) == "number" and count > 0 then
            -- "iron-plate@normal" → "iron-plate"
            local base_name = key:match("^(.-)@") or key
            add_to(snap, base_name, count)
          end
        end
      end
    end
  end

  -- --------------------------------------------------
  -- 3) Spieler-Inventare
  -- --------------------------------------------------
  if game and game.players then
    for _, player in pairs(game.players) do
      if player and player.valid and player.character then
        local contents = read_player_contents(player)
        for name, count in pairs(contents) do
          add_to(snap, name, count)
        end
      end
    end
  end

  return snap
end

-- =========================================
-- EMA-Update
-- Einmal pro Sample-Tick aufgerufen.
--
-- snapshot: { [itemname] = count }  (aus EMA.collect_snapshot)
-- tick:     game.tick
-- =========================================

function EMA.update(snapshot, tick)
  EMA.ensure_defaults()

  local af = EMA.alpha_fast()
  local as_ = EMA.alpha_slow()     -- 'as' ist Lua-Keyword in manchen Versionen → as_
  local bf = 1.0 - af
  local bs = 1.0 - as_

  local ema = storage.ema

  -- Alle im Snapshot vorhandenen Materialien updaten
  for name, count in pairs(snapshot) do
    local entry = ema[name]
    if entry == nil then
      -- Kalt initialisieren: beide EMAs starten beim ersten echten Wert
      ema[name] = { cur = count, fast = count, slow = count }
    else
      entry.cur  = count
      entry.fast = af * count + bf * entry.fast
      entry.slow = as_ * count + bs * entry.slow
    end
  end

  -- Materialien die NICHT im Snapshot sind: cur=0, EMA läuft weiter
  -- (kein Löschen – sie können jederzeit wieder auftauchen)
  for name, entry in pairs(ema) do
    if name:sub(1, 1) ~= "_" then        -- Sentinel-Felder überspringen
      if snapshot[name] == nil then
        entry.cur  = 0
        entry.fast = af * 0 + bf * entry.fast
        entry.slow = as_ * 0 + bs * entry.slow
      end
    end
  end

  ema._last_tick = tick
end

-- =========================================
-- EMA-Reset
-- Baut die EMA-Liste vollständig aus dem aktuellen Snapshot neu auf.
--
-- Zweck:
--   Nach einem Simulationsreset sollen keine alten Materialien
--   mit cur=0 / fast / slow weiter sichtbar bleiben.
--   Nur Materialien, die aktuell wirklich vorhanden sind, bleiben drin.
-- =========================================
function EMA.reset_to_current(surf_idx, tick)
  EMA.ensure_defaults()

  local snapshot = EMA.collect_snapshot(surf_idx)
  local new_ema = {
    _last_tick = tick or game.tick
  }

  for name, count in pairs(snapshot) do
    new_ema[name] = {
      cur  = count,
      fast = count,
      slow = count
    }
  end

  storage.ema = new_ema
end

-- =========================================
-- Formatierte Ausgabe (4 Spalten, semikolon-getrennt)
--
-- Format:
--   # EMA;tick=12345;2025-01-01 08:00:00;alpha_fast=0.3;alpha_slow=0.1
--   # Material;current;EMA_fast;EMA_slow
--   Fe;1240;1187.4;1205.1
--   Cu;880;901.2;912.8
--   Wire;0;45.3;67.2
--
-- Sortierung: alphabetisch nach Materialname.
-- Zahlen: cur = Integer, fast/slow = 1 Nachkommastelle.
-- =========================================

function EMA.format_display(tick, surface)
  EMA.ensure_defaults()

  local ema   = storage.ema
  local af    = EMA.alpha_fast()
  local as_   = EMA.alpha_slow()

  -- Kopfzeilen
  local display_tick = tick or game.tick
  local data_tick = tonumber(ema._last_tick) or 0

  local lines = {}
    lines[#lines+1] = string.format(
    "# EMA;data_tick=%d;data_time=%s;display_tick=%d;alpha_fast=%.2f;alpha_slow=%.2f",
    data_tick,
    Util.to_excel_datetime(data_tick, surface),
    display_tick,
    af, as_
  )
  lines[#lines+1] = "# Material;current;EMA_fast;EMA_slow"

  -- Alle Materialien alphabetisch sortieren
  local names = {}
  for name, _ in pairs(ema) do
    if name:sub(1, 1) ~= "_" then   -- Sentinel-Felder (_last_tick etc.) überspringen
      names[#names+1] = name
    end
  end
  table.sort(names)

  -- Zeilen bauen
  for _, name in ipairs(names) do
    local entry = ema[name]
    if entry then
      local alias = M.ITEM_ALIASES[name] or name
      lines[#lines+1] = string.format(
        "%s;%d;%.1f;%.1f",
        alias,
        math.floor(entry.cur  or 0),
        entry.fast or 0,
        entry.slow or 0
      )
    end
  end

  return table.concat(lines, "\n")
end

return EMA
