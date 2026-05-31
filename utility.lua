-- =========================================
-- LogSim (Factorio 2.0)
-- Shared helper functions for time conversion, flying text, filename sanitizing and diagnostics.
--
-- Version 0.8.0 first complete working version
-- Version 0.8.1 simple day/time clock
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 local cleanup, English comments and fallback constants
--
-- =========================================

local M = require("config")

local Util = {}
Util.version = "0.9.1"

local DEFAULT_BASE_YEAR = 2000
local DEFAULT_BASE_MONTH = 1
local DEFAULT_BASE_DAY = 1
local DEFAULT_TICKS_PER_DAY = 25000

-- Factorio day starts at noon. The conversion shifts the displayed time so
-- daytime 0.5 maps to 00:00 and daytime 0.0 maps to 12:00.

-- =========================================
-- Local helpers
-- =========================================

local function pad2(n)
  return string.format("%02d", n)
end

local function pad4(n)
  return string.format("%04d", n)
end

-- Parse "YYYY-MM-DD" into numeric year, month and day.
-- Invalid input falls back to the synthetic LogSim base date.
local function parse_base_date(base_date)
  if type(base_date) ~= "string" then
    return DEFAULT_BASE_YEAR, DEFAULT_BASE_MONTH, DEFAULT_BASE_DAY
  end

  local y, m, d = base_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)

  if not y or not m or not d then
    return DEFAULT_BASE_YEAR, DEFAULT_BASE_MONTH, DEFAULT_BASE_DAY
  end

  return y, m, d
end

-- Howard Hinnant proleptic Gregorian date algorithm, adapted to Lua.
-- Converts Y-M-D to days since 1970-01-01.
local function days_from_civil(y, m, d)
  y = y - (m <= 2 and 1 or 0)

  local era = (y >= 0)
    and math.floor(y / 400)
    or math.floor((y - 399) / 400)

  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy

  return era * 146097 + doe - 719468
end

-- Howard Hinnant proleptic Gregorian date algorithm, adapted to Lua.
-- Converts days since 1970-01-01 to Y-M-D.
local function civil_from_days(z)
  z = z + 719468

  local era = (z >= 0)
    and math.floor(z / 146097)
    or math.floor((z - 146096) / 146097)

  local doe = z - era * 146097
  local yoe = math.floor(
    (doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365
  )

  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + ((mp < 10) and 3 or -9)

  y = y + ((m <= 2) and 1 or 0)

  return y, m, d
end

local function get_tpd(surface)
  if surface and surface.valid and surface.ticks_per_day then
    return surface.ticks_per_day
  end

  return DEFAULT_TICKS_PER_DAY
end

-- Convert a game tick and current surface daytime into day/time components.
-- Surface daytime is used because Factorio can change, freeze or scale daylight.
local function tick_to_parts(tick, tpd, surface)
  tick = tonumber(tick) or 0
  tpd = tonumber(tpd) or DEFAULT_TICKS_PER_DAY

  local day = math.floor((tick + tpd / 4) / tpd) + 1
  local day_frac = 0

  if surface and surface.valid then
    day_frac = surface.daytime or 0
  end

  local hours_decimal = (day_frac * 24 + 12) % 24
  local hh = math.floor(hours_decimal)
  local minutes_decimal = (hours_decimal % 1) * 60
  local mm = math.floor(minutes_decimal)
  local ss = math.floor((minutes_decimal % 1) * 60)
  local total_seconds = hh * 3600 + mm * 60 + ss

  return day, day_frac, hh, mm, ss, total_seconds
end

-- =========================================
-- Time conversion
-- =========================================

-- Seconds since synthetic day 1 at 00:00:00.
function Util.to_sec_utc(tick, surface)
  local tpd = get_tpd(surface)
  local day, _, _, _, _, total_seconds = tick_to_parts(tick, tpd, surface)

  return (day - 1) * 86400 + total_seconds
end

-- ISO 8601 timestamp: "YYYY-MM-DDTHH:MM:SSZ".
-- base_date maps synthetic day 1 to the given date.
function Util.to_iso_utc(tick, surface, base_date)
  local y0, m0, d0 = parse_base_date(base_date)
  local base_days_1970 = days_from_civil(y0, m0, d0)

  local tpd = get_tpd(surface)
  local day, _, hh, mm, ss = tick_to_parts(tick, tpd, surface)

  local z1970 = base_days_1970 + (day - 1)
  local y, m, d = civil_from_days(z1970)

  return string.format(
    "%s-%s-%sT%s:%s:%sZ",
    pad4(y),
    pad2(m),
    pad2(d),
    pad2(hh),
    pad2(mm),
    pad2(ss)
  )
end

-- Excel-friendly datetime string: "YYYY-MM-DD HH:MM:SS".
-- base_date maps synthetic day 1 to the given date.
function Util.to_excel_datetime(tick, surface, base_date)
  local y0, m0, d0 = parse_base_date(base_date)
  local base_days_1970 = days_from_civil(y0, m0, d0)

  local tpd = get_tpd(surface)
  local day, _, hh, mm, ss = tick_to_parts(tick, tpd, surface)

  local z1970 = base_days_1970 + (day - 1)
  local y, m, d = civil_from_days(z1970)

  return string.format(
    "%s-%s-%s %s:%s:%s",
    pad4(y),
    pad2(m),
    pad2(d),
    pad2(hh),
    pad2(mm),
    pad2(ss)
  )
end

-- Excel-friendly relative day/time string: "days N HH:MM".
function Util.to_excel_daystime(tick, surface)
  local tpd = get_tpd(surface)
  local day, _, hh, mm = tick_to_parts(tick, tpd, surface)

  return string.format(" days %s %s:%s", day - 1, pad2(hh), pad2(mm))
end

-- =========================================
-- Flying text
-- =========================================

function Util.fly(player, entity, msg, cursor_pos)
  if not (player and player.valid and msg) then return end

  local pos
  if entity and entity.valid and entity.position then
    pos = entity.position
  elseif cursor_pos then
    pos = cursor_pos
  else
    pos = player.position
  end

  player.create_local_flying_text{
    text = msg,
    position = pos,
    color = { r = 1, g = 1, b = 1 }
  }
end

-- =========================================
-- String and file helpers
-- =========================================

function Util.sanitize_filename(s)
  return tostring(s):gsub("[^%w%._%-]", "_")
end

function Util.json_escape_string(s)
  s = tostring(s or "")

  return s
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
end

-- =========================================
-- GUI helpers
-- =========================================

function Util.bring_to_front(frame)
  if frame and frame.valid and frame.bring_to_front then
    frame.bring_to_front()
  end
end

-- =========================================
-- Version helper
-- =========================================

function Util.get_logger_version()
  return (script.active_mods and script.active_mods["logistics_simulation"]) or "unknown"
end

-- =========================================
-- Output helpers
-- =========================================

function Util.info_print(player, msg)
  if not storage or not storage.info_mode then return end
  if not (player and player.valid) then return end

  player.print(msg)
end

function Util.debug_print(msg)
  if not M.DEBUG then return end

  local prefix = {"logistics_simulation.chat_name"}

  if type(msg) == "table" then
    game.print({"", prefix, " ", msg})
  else
    game.print({"", prefix, " ", tostring(msg)})
  end
end

return Util