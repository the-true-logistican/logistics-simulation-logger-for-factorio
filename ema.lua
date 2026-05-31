-- =========================================
-- LogSim (Factorio 2.0)
-- EMA Module
--
-- Calculates exponential moving averages for current assets.
--
-- Snapshot sources:
--   1) Registered logistics objects in storage.registry
--   2) Virtual buffers in storage.tx_virtual: T00, SHIP, RECV, WIP, MAN
--   3) Player inventories: main, trash and cursor stack
--
-- Stored values per material:
--   cur  = current snapshot value
--   fast = fast EMA using alpha_fast
--   slow = slow EMA using alpha_slow
--
-- Version 0.8.0 storage defaults
-- Version 0.8.1 collect_snapshot() and update()
-- Version 0.8.2 format_display()
-- Version 0.8.3 blueprint tab integration
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 EMA display filters zero rows
-- Version 0.9.2 cargo-wagon and fluid-wagon inventory support
-- Version 0.9.3 local cleanup and shared inventory normalization
--
-- =========================================

local M      = require("config")
local Chests = require("chests")
local Util   = require("utility")

local EMA = {}
EMA.version = "0.9.3"

local VIRTUAL_BUCKETS = { "T00", "SHIP", "RECV", "WIP", "MAN" }

local PLAYER_INV_IDS = {
  defines.inventory.character_main,
  defines.inventory.character_trash
}

-- =========================================
-- Settings access
-- =========================================

function EMA.alpha_fast()
  return M.get_ema_alpha_fast()
end

function EMA.alpha_slow()
  return M.get_ema_alpha_slow()
end

-- =========================================
-- Storage defaults
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
-- Local aggregation helpers
-- =========================================

local function add_to(target, name, count)
  count = tonumber(count) or 0
  if not name or count <= 0 then return end

  target[name] = (target[name] or 0) + count
end

local function normalize_inventory_entry(k, v)
  local item_name
  local count = 0

  -- Factorio 2.x returns array entries like { name = ..., count = ..., quality = ... }.
  if type(k) == "number" and type(v) == "table" then
    item_name = v.name or v.item
    count = tonumber(v.count or v.amount) or 0

  -- Defensive fallback for map-style content tables.
  elseif type(k) == "string" then
    item_name = k
    if type(v) == "number" then
      count = v
    elseif type(v) == "table" then
      count = tonumber(v.count or v.amount) or 0
    end

  -- Defensive fallback for item-with-quality keys.
  elseif type(k) == "table" then
    item_name = k.name or k.item
    if type(v) == "number" then
      count = v
    elseif type(v) == "table" then
      count = tonumber(v.count or v.amount) or 0
    end
  end

  count = tonumber(count) or 0
  return item_name, count
end

local function add_inventory_contents(target, inv)
  if not (inv and inv.valid) then return end

  local contents = inv.get_contents()
  if not contents then return end

  for k, v in pairs(contents) do
    local item_name, count = normalize_inventory_entry(k, v)
    add_to(target, item_name, count)
  end
end

local function add_fluid_contents(target, ent)
  if not (ent and ent.valid) then return end

  local fluids = ent.get_fluid_contents()
  if not fluids then return end

  for fluid_name, amount in pairs(fluids) do
    local count = math.floor(tonumber(amount) or 0)
    add_to(target, fluid_name, count)
  end
end

local function read_registered_entity_contents(ent)
  local result = {}
  if not (ent and ent.valid) then return result end

  if ent.type == "storage-tank" or ent.type == "fluid-wagon" then
    add_fluid_contents(result, ent)
    return result
  end

  if ent.type == "cargo-wagon" then
    add_inventory_contents(result, ent.get_inventory(defines.inventory.cargo_wagon))
    return result
  end

  add_inventory_contents(result, ent.get_inventory(defines.inventory.chest))
  return result
end

local function read_player_contents(player)
  local result = {}
  if not (player and player.valid) then return result end

  for _, inv_id in ipairs(PLAYER_INV_IDS) do
    add_inventory_contents(result, player.get_inventory(inv_id))
  end

  local cursor_stack = player.cursor_stack
  if cursor_stack
     and cursor_stack.valid_for_read
     and cursor_stack.name
     and cursor_stack.count
     and cursor_stack.count > 0 then
    add_to(result, cursor_stack.name, cursor_stack.count)
  end

  return result
end

local function add_table_to_snapshot(snapshot, contents)
  for name, count in pairs(contents or {}) do
    add_to(snapshot, name, count)
  end
end

local function base_name_from_virtual_key(key)
  if type(key) ~= "string" then return nil end
  return key:match("^(.-)@") or key
end

-- =========================================
-- Snapshot collection
-- =========================================

function EMA.collect_snapshot(surf_idx)
  EMA.ensure_defaults()

  local snapshot = {}

  if storage.registry then
    for _, rec in pairs(storage.registry) do
      if surf_idx == nil or rec.surface_index == surf_idx then
        local ent = Chests.resolve_entity(rec)
        if ent and ent.valid then
          add_table_to_snapshot(snapshot, read_registered_entity_contents(ent))
        end
      end
    end
  end

  if storage.tx_virtual then
    for _, bucket in ipairs(VIRTUAL_BUCKETS) do
      local buffer = storage.tx_virtual[bucket]
      if buffer then
        for key, count in pairs(buffer) do
          if type(count) == "number" and count > 0 then
            add_to(snapshot, base_name_from_virtual_key(key), count)
          end
        end
      end
    end
  end

  if game and game.players then
    for _, player in pairs(game.players) do
      if player and player.valid and player.character then
        add_table_to_snapshot(snapshot, read_player_contents(player))
      end
    end
  end

  return snapshot
end

-- =========================================
-- EMA update
-- =========================================

function EMA.update(snapshot, tick)
  EMA.ensure_defaults()

  snapshot = snapshot or {}

  local alpha_fast = EMA.alpha_fast()
  local alpha_slow = EMA.alpha_slow()
  local beta_fast = 1.0 - alpha_fast
  local beta_slow = 1.0 - alpha_slow

  local ema = storage.ema

  for name, count in pairs(snapshot) do
    local entry = ema[name]

    if entry == nil then
      ema[name] = {
        cur = count,
        fast = count,
        slow = count
      }
    else
      entry.cur = count
      entry.fast = alpha_fast * count + beta_fast * entry.fast
      entry.slow = alpha_slow * count + beta_slow * entry.slow
    end
  end

  for name, entry in pairs(ema) do
    if name:sub(1, 1) ~= "_" and snapshot[name] == nil then
      entry.cur = 0
      entry.fast = beta_fast * entry.fast
      entry.slow = beta_slow * entry.slow
    end
  end

  ema._last_tick = tick
end

-- =========================================
-- EMA reset
-- =========================================

function EMA.reset_to_current(surf_idx, tick)
  EMA.ensure_defaults()

  local snapshot = EMA.collect_snapshot(surf_idx)
  local new_ema = {
    _last_tick = tick or game.tick
  }

  for name, count in pairs(snapshot) do
    new_ema[name] = {
      cur = count,
      fast = count,
      slow = count
    }
  end

  storage.ema = new_ema
end

-- =========================================
-- Display formatting
-- =========================================

function EMA.format_display(tick, surface)
  EMA.ensure_defaults()

  local ema = storage.ema
  local alpha_fast = EMA.alpha_fast()
  local alpha_slow = EMA.alpha_slow()

  local display_tick = tick or game.tick
  local data_tick = tonumber(ema._last_tick) or 0

  local lines = {}

  lines[#lines + 1] = string.format(
    "# EMA;data_tick=%d;data_time=%s;display_tick=%d;alpha_fast=%.2f;alpha_slow=%.2f",
    data_tick,
    Util.to_excel_datetime(data_tick, surface),
    display_tick,
    alpha_fast,
    alpha_slow
  )
  lines[#lines + 1] = "# Material;current;EMA_fast;EMA_slow"

  local names = {}
  for name, _ in pairs(ema) do
    if name:sub(1, 1) ~= "_" then
      names[#names + 1] = name
    end
  end

  table.sort(names)

  for _, name in ipairs(names) do
    local entry = ema[name]

    if entry
       and not (
         (entry.cur or 0) == 0
         and (entry.fast or 0) < 0.05
         and (entry.slow or 0) < 0.05
       ) then
      lines[#lines + 1] = string.format(
        "%s;%d;%.1f;%.1f",
        name,
        math.floor(entry.cur or 0),
        entry.fast or 0,
        entry.slow or 0
      )
    end
  end

  return table.concat(lines, "\n")
end

return EMA
