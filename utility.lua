-- =========================================
-- LogSim (Factorio 2.0) 
-- Shared helper functions (time conversion, flying text, filename sanitizing).
--
-- version 0.8.0 first complete working version
-- version 0.8.1 Simple Days-Time-Clock
--
-- =========================================

local Util = {}

  Util.version = "0.8.1"

-- Factorio day starts at noon; we shift by +0.5 day so that 00:00 maps to midnight.
-- Provides ISO-8601 UTC-like timestamps and Excel-friendly datetime strings.

-- -----------------------------
-- Helpers
-- -----------------------------
local function pad2(n) return string.format("%02d", n) end
local function pad4(n) return string.format("%04d", n) end

-- Parse "YYYY-MM-DD" -> y,m,d (numbers). Fallback to 2000-01-01 if invalid.
local function parse_base_date(base_date)
  if type(base_date) ~= "string" then return 2000, 1, 1 end
  local y, m, d = base_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not y or not m or not d then return 2000, 1, 1 end
  return y, m, d
end

-- Howard Hinnant algorithms (proleptic Gregorian), adapted to Lua
-- days_from_civil: convert Y-M-D to days since 1970-01-01
local function days_from_civil(y, m, d)
  y = y - (m <= 2 and 1 or 0)
  local era = (y >= 0) and math.floor(y / 400) or math.floor((y - 399) / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- civil_from_days: convert days since 1970-01-01 -> Y-M-D
local function civil_from_days(z)
  z = z + 719468
  local era = (z >= 0) and math.floor(z / 146097) or math.floor((z - 146096) / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe/1460) + math.floor(doe/36524) - math.floor(doe/146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365*yoe + math.floor(yoe/4) - math.floor(yoe/100))
  local mp = math.floor((5*doy + 2) / 153)
  local d = doy - math.floor((153*mp + 2) / 5) + 1
  local m = mp + ((mp < 10) and 3 or -9)
  y = y + ((m <= 2) and 1 or 0)
  return y, m, d
end

-- Determine ticks_per_day. Prefer surface.ticks_per_day if available; fallback to 25000.
local function get_tpd(surface)
  if surface and surface.valid and surface.ticks_per_day then
    return surface.ticks_per_day
  end
  return 25000
end

-- Core: tick -> (day_index starting at 1) + day fraction (0..1 from midnight) + h/m/s
local function tick_to_parts(tick, tpd, surface)
 tick = tonumber(tick) or 0
  tpd = tonumber(tpd) or 25000

  local day = math.floor( (tick + tpd/4) / tpd) + 1
  
  -- HOL EINFACH DAYTIME VOM SURFACE!
  local day_frac = 0
  if surface then
    if surface.valid then
      day_frac = surface.daytime or 0
    end
  end
  
  -- daytime 0..1 → Stunden (0 = noon = 12:00, 0.5 = midnight = 00:00)
  local hours_decimal = (day_frac * 24 + 12) % 24  -- 0..24
  local hh = math.floor(hours_decimal)             -- Stunden
  local minutes_decimal = (hours_decimal % 1) * 60 -- Rest in Minuten
  local mm = math.floor(minutes_decimal)           -- Minuten
  local ss = math.floor((minutes_decimal % 1) * 60) -- Rest in Sekunden
  
  local total_seconds = hh * 3600 + mm * 60 + ss

  return day, day_frac, hh, mm, ss, total_seconds
end

-- -----------------------------
-- Public API
-- -----------------------------

-- Returns a table with breakdown (no date mapping).
function Util.to_parts(tick, surface)
  local tpd = get_tpd(surface)
  if surface then
    local day, day_frac, hh, mm, ss, total_seconds = tick_to_parts(tick, tpd, surface)
  end

  return {
    day = day,                 -- 1..n
    day_frac = day_frac,       -- 0..1 from midnight
    hh = hh, mm = mm, ss = ss,
    clock = string.format("%02d:%02d:%02d", hh, mm, ss),
    seconds_in_day = total_seconds,
    ticks_per_day = tpd
  }
end

-- Seconds since base_date 00:00:00 (synthetic "UTC-like" time axis).
function Util.to_sec_utc(tick, surface)
  local tpd = get_tpd(surface)
  local day, _, _, _, _, total_seconds = tick_to_parts(tick, tpd, surface)
  return (day - 1) * 86400 + total_seconds
end

-- ISO 8601 string: "YYYY-MM-DDTHH:MM:SSZ"
-- base_date: "YYYY-MM-DD" (default "2000-01-01"), maps day 1 to that date.
function Util.to_iso_utc(tick, surface, base_date)
  local y0, m0, d0 = parse_base_date(base_date)
  local base_days_1970 = days_from_civil(y0, m0, d0)

  local tpd = get_tpd(surface)
  local day, _, hh, mm, ss, _ = tick_to_parts(tick, tpd, surface)

  local z1970 = base_days_1970 + (day - 1)
  local y, m, d = civil_from_days(z1970)

  return string.format("%s-%s-%sT%s:%s:%sZ",
    pad4(y), pad2(m), pad2(d),
    pad2(hh), pad2(mm), pad2(ss)
  )
end

-- Excel-friendly datetime string: "YYYY-MM-DD HH:MM:SS"
-- Excel ist mit Leerzeichen oft weniger zickig als mit "T...Z".
function Util.to_excel_datetime(tick, surface, base_date)
  local y0, m0, d0 = parse_base_date(base_date)
  local base_days_1970 = days_from_civil(y0, m0, d0)

  local tpd = get_tpd(surface)
  local day, _, hh, mm, ss, _ = tick_to_parts(tick, tpd, surface)

  local z1970 = base_days_1970 + (day - 1)
  local y, m, d = civil_from_days(z1970)

  return string.format("%s-%s-%s %s:%s:%s",
    pad4(y), pad2(m), pad2(d),
    pad2(hh), pad2(mm), pad2(ss)
  )
end

-- Excel-friendly datetime string: "YYYY-MM-DD HH:MM:SS"
-- Excel ist mit Leerzeichen oft weniger zickig als mit "T...Z".
function Util.to_excel_daystime(tick, surface, base_date)
  local y0, m0, d0 = parse_base_date(base_date)
  local base_days_1970 = days_from_civil(y0, m0, d0)
  local tpd = get_tpd(surface)
  local day, _, hh, mm, ss, _ = tick_to_parts(tick, tpd, surface)

  local z1970 = (day - 1)

  return string.format(" days %s %s:%s", z1970, pad2(hh), pad2(mm) )
end


-- =========================================
-- Helper: Flying Text
-- =========================================

function Util.fly(player, entity, msg, cursor_pos)
  if not (player and player.valid and msg) then return end

  local pos = nil
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
    color = { r=1, g=1, b=1 }
  }
end

function Util.sanitize_filename(s)
  return (tostring(s):gsub("[^%w%._%-]", "_"))
end

-- =========================================
-- GUI: Bring a screen frame to the front
-- =========================================
-- Call this in every show_*() function so that re-opening an already open
-- window always raises it on top instead of silently doing nothing.
-- Usage:
--   local existing = player.gui.screen[FRAME_NAME]
--   if existing and existing.valid then
--     Util.bring_to_front(existing)
--     return
--   end
--   ... create frame ...
--   Util.bring_to_front(frame)   -- also raise on first open
function Util.bring_to_front(frame)
  if frame and frame.valid and frame.bring_to_front then
    frame.bring_to_front()
  end
end


return Util