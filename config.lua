-- =========================================
-- LogSim (Factorio 2.0) 
-- Central configuration and storage initialization for LogSim (constants, GUI IDs, defaults).
--
-- version 0.8.0 first complete working version
-- version 0.8.1 tx window with buttons <<  <  >  >> 
--               ring buffer M.TX_MAX_EVENTS load/save secure
--               ring buffer M.BUFFER_MAX_LINES load/save secure
-- Version 0.8.2 get global parameters from settings
--
-- =========================================

local M = {}

M.version = "0.8.1"

-- =====================================
-- Technical Configuration
-- =====================================

-- Begin Parameters from Setup

-- ticks_per_day (z.B. 25 000) → Spielzeit / Tageslänge
-- 1 ISO-Minute = 1/1440 of one Factorio-Day
M.SAMPLE_INTERVAL_TICKS = 173 -- (60fps) this is 10min in ISO-Time (exact 173,6)
M.BUFFER_MAX_LINES = 5000    -- max number of complete inventory
M.TX_MAX_EVENTS = 50000     -- max number of transaction records kept in memory

-- End Parameters from Setup

M.POWER_SAMPLES = 5           -- ~1.0s (5 * 0.2s)  
M.POLLUTION_SAMPLES = 5       -- ~1.0s (5 * 0.2s)
M.GUI_REFRESH_TICKS = 10      -- throttle GUI refresh (ticks)
M.TEXT_MAX = 1500000
M.CHUNK_SIZE = 32 
M.MAX_TELEGRAM_LENGTH = 2000
M.BUFFER_PAGE_LINES = 200
M.COLLECT_DEPENDENC_DEPTH = 30 -- limit of depth for recursion

-- Transaction watch markers (rendering)
M.TX_MARK_INSERTERS = true
M.TX_MARK_COLOR = { r = 1, g = 1, b = 0 }   -- yellow
M.TX_MARK_ACTIVE_COLOR = { r=1, g=0, b=1, a=1 } -- 
M.TX_MARK_SCALE = 1.0
M.TX_MARK_OFFSET = { x = 0, y = -0.3 }     

-- Registry markers (chests / tanks / machines / protected)
M.REG_MARK_COLOR  = { r = 0, g = 1, b = 0, a = 1 }  -- green default
M.REG_MARK_SCALE  = 1.0
M.REG_MARK_OFFSET = { x = 0, y = 0.1 }            
M.PROT_MARK_COLOR  = { r = 1, g = 0.5, b = 0, a = 1 } -- orange-ish
M.PROT_MARK_SCALE  = 1.0
M.PROT_MARK_OFFSET = { x = 0, y = -0.7 }

-- Performance
M.CLEANUP_INTERVAL_TICKS = 600  -- 10 seconds - cleanup disconnected players

-- =====================================
-- GUI Configuration
-- =====================================

-- Buffer Window
M.GUI_BUFFER_WIDTH = 900
M.GUI_BUFFER_HEIGHT = 500

-- Help Window
M.GUI_HELP_WIDTH = 900
M.GUI_HELP_HEIGHT = 500
M.GUI_HELP_LABEL_WIDTH = 880

-- Reset Dialog
M.GUI_RESET_TEXTFIELD_WIDTH = 300

-- Blueprint Sidecar
M.GUI_BP_SIDECAR_WIDTH = 260
M.GUI_BP_SIDECAR_MARGIN = 12
M.GUI_BP_SIDECAR_Y_OFFSET = 220

-- Styling (Padding & Spacing)
M.GUI_CONTENT_PADDING = 12
M.GUI_CONTENT_SPACING = 8
M.GUI_BUTTON_SPACING = 8
M.GUI_FRAME_PADDING = 8

-- TX Window
M.GUI_TX_BTN_EXPORT = "logsim_tx_export"

-- Inventory/Anlagevermögen Window
M.GUI_INV_BTN_EXPORT = "logsim_invwin_export"
-- =====================================
-- ItemCost configuration
-- =====================================

-- Which entity prototype represents the "typical" machine for a recipe category.
-- These are only used to read prototype.energy_usage. Mods may change that value.
M.ITEMCOST_CATEGORY_MACHINE = {
  default  = "assembling-machine-3",
  smelting = "electric-furnace",
  chemistry = "chemical-plant",
}

M.MAX_CACHE_SIZE = 500 -- Limit cache to prevent memory bloat

-- Absolute fallback (Watts) if prototype lookup fails or energy_usage is missing/unparseable
M.ITEMCOST_POWER_FALLBACK_W = 375000
-- =====================================
-- GUI Element Names (internal)
-- =====================================

M.GUI_BUFFER_FRAME = "logsim_buffer"
M.GUI_BUFFER_BOX   = "logsim_buffer_box"
M.GUI_BTN_REFRESH  = "logsim_buffer_refresh"
M.GUI_BTN_HIDE     = "logsim_buffer_hide"
M.GUI_BTN_COPY     = "logsim_buffer_copy"
M.GUI_BTN_RESET    = "logsim_reset"
M.GUI_CLOSE        = "logsim_close"
M.GUI_HELP_FRAME   = "logsim_help"
M.GUI_BTN_HELP     = "logsim_help_btn"
M.GUI_HELP_CLOSE   = "logsim_help_close"

M.GUI_RESET_FRAME        = "logsim_reset_dialog"
M.GUI_RESET_OK           = "logsim_reset_ok"
M.GUI_RESET_CANCEL       = "logsim_reset_cancel"
M.GUI_RESET_CHK_ITEMS    = "logsim_reset_chk_items"
M.GUI_RESET_CHK_LOG      = "logsim_reset_chk_log"
M.GUI_RESET_CHK_CHESTS   = "logsim_reset_chk_chests"
M.GUI_RESET_CHK_MACHINES = "logsim_reset_chk_machines"
M.GUI_RESET_CHK_PROT     = "logsim_reset_chk_prot"
M.GUI_RESET_NAME_FIELD   = "logsim_reset_name"
M.GUI_RESET_CHK_STATS    = "logsim_reset_chk_stats"

M.GUI_BTN_OLDER = "logsim_buffer_older"
M.GUI_BTN_TAIL  = "logsim_buffer_tail"
M.GUI_BTN_NEWER = "logsim_buffer_newer"
M.GUI_LBL_RANGE = "logsim_buffer_range"


-- TX Window (Transactions)
M.GUI_BTN_TX_OPEN = "logsim_buffer_tx_open"

M.GUI_TX_FRAME = "logsim_tx"
M.GUI_TX_BOX   = "logsim_tx_box"
M.GUI_TX_CLOSE = "logsim_tx_close"

M.GUI_TX_BTN_OLDER = "logsim_tx_older"
M.GUI_TX_BTN_HOME  = "logsim_tx_home"
M.GUI_TX_BTN_END   = "logsim_tx_end"
M.GUI_TX_BTN_TAIL  = M.GUI_TX_BTN_END  -- backward alias
M.GUI_TX_BTN_NEWER = "logsim_tx_newer"
M.GUI_TX_LBL_RANGE = "logsim_tx_range"
M.GUI_TX_BTN_COPY  = "logsim_tx_copy"
M.GUI_TX_BTN_HIDE  = "logsim_tx_hide"

M.GUI_BP_SIDECAR    = "logsim_bp_sidecar"
M.GUI_BP_EXTRACTBTN = "logsim_bp_extract"

M.GUI_INV_FRAME = "logsim_invwin"
M.GUI_INV_BOX = "logsim_invwin_box"
M.GUI_INV_CLOSE_X = "logsim_invwin_close_x"
M.GUI_INV_BTN_COPY = "logsim_invwin_copy"
M.GUI_INV_BTN_CLOSE = "logsim_invwin_close"

-- GUI Configuration section:
M.GUI_BTN_EXPORT = "logsim_buffer_export"
M.GUI_BTN_EXPORT_CSV = "logsim_export_csv"
M.GUI_BTN_EXPORT_JSON = "logsim_export_json"
M.GUI_EXPORT_FRAME = "logsim_export_dialog"
M.GUI_EXPORT_CLOSE = "logsim_export_close"
M.GUI_EXPORT_FILENAME = "logsim_export_filename"

-- Export configuration
M.EXPORT_FOLDER = "logsim-exports"
M.EXPORT_DEFAULT_NAME = "protocol"

-- =====================================
-- Item Aliases (for compact logging)
-- =====================================

M.ITEM_ALIASES = {
  -- Basic materials
  ["iron-plate"]        = "Fe",
  ["copper-plate"]      = "Cu",
  ["steel-plate"]       = "St",
  ["coal"]              = "Coal",
  ["stone"]             = "Stone",
  ["stone-brick"]       = "Brick",
  ["plastic-bar"]       = "Plastic",
  ["low-density-structure"] = "LDS",

  -- Intermediate products
  ["iron-gear-wheel"]   = "Gear",
  ["iron-stick"]        = "Rod",
  ["copper-cable"]      = "Wire",
  ["pipe"]              = "Pipe",
  ["pipe-to-ground"]    = "UGPipe",

  -- Advanced intermediates
  ["engine-unit"]           = "Engine",
  ["electric-engine-unit"]  = "EEngine",
  ["battery"]               = "Batt",
  ["flying-robot-frame"]    = "Frame",

  -- Electronics (color-coded)
  ["electronic-circuit"] = "cirG",
  ["advanced-circuit"]   = "cirR",
  ["processing-unit"]    = "cirB",

  -- Science packs (colors)
  ["automation-science-pack"] = "Red",
  ["logistic-science-pack"]   = "Green",
  ["chemical-science-pack"]   = "Blue",
  ["military-science-pack"]   = "Black",
  ["production-science-pack"] = "Purple",
  ["utility-science-pack"]    = "Yellow",
  ["space-science-pack"]      = "White",

  -- Fluids
  ["water"]             = "H2O",
  ["crude-oil"]         = "Oil",
  ["heavy-oil"]         = "OIL",
  ["light-oil"]         = "oil",
  ["petroleum-gas"]     = "Gas",
  ["lubricant"]         = "Lube",
  ["sulfuric-acid"]     = "H2SO4",
}

-- =====================================
-- Central Storage Initialization (Factorio 2.0)
-- idempotent: safe to call anytime
-- =====================================

local function apply_sample_interval_from_config()
  -- Source of truth: Mod settings (runtime-global). Fallback: config.lua constant.
  local cfg = nil
  if settings and settings.global and settings.global["logsim_sample_interval_ticks"] then
    cfg = settings.global["logsim_sample_interval_ticks"].value
  end
  if cfg == nil then
    cfg = M.SAMPLE_INTERVAL_TICKS
  end

  -- Validate
  if type(cfg) ~= "number" or cfg < 1 then
    -- hard warning, but KEEP old stored value so the mod continues
    log(string.format("[LogSim][ERROR] Invalid SAMPLE_INTERVAL_TICKS=%s. Keeping stored sample_interval=%s",
      tostring(cfg), tostring(storage.sample_interval)))

    for _, p in pairs(game.players) do
      if p and p.valid then
        p.print({"", "[LogSim] ERROR: SAMPLE_INTERVAL_TICKS invalid (", tostring(cfg),
                 "). Keeping old interval: ", tostring(storage.sample_interval)})
      end
    end
    return
  end

  -- ALWAYS apply
  storage.sample_interval = cfg
end

local function apply_tx_max_events_from_config()
  -- Source of truth: Mod settings (runtime-global). Fallback: config.lua constant.
  local cfg = nil
  if settings and settings.global and settings.global["logsim_tx_max_events"] then
    cfg = settings.global["logsim_tx_max_events"].value
  end
  if cfg == nil then
    cfg = M.TX_MAX_EVENTS
  end

  -- Validate
  if type(cfg) ~= "number" or cfg < 1 then
    log(string.format("[LogSim][ERROR] Invalid TX_MAX_EVENTS=%s. Keeping stored tx_max_events=%s",
      tostring(cfg), tostring(storage.tx_max_events)))

    for _, p in pairs(game.players) do
      if p and p.valid then
        p.print({"", "[LogSim] ERROR: TX_MAX_EVENTS invalid (", tostring(cfg),
                 "). Keeping old value: ", tostring(storage.tx_max_events)})
      end
    end
    return
  end

  -- ALWAYS apply (tx ringbuffer reacts if changed)
  storage.tx_max_events = cfg
end

local function apply_buffer_max_lines_from_config()
  -- Source of truth: Mod settings (runtime-global). Fallback: config.lua constant.
  local cfg = nil
  if settings and settings.global and settings.global["logsim_buffer_max_lines"] then
    cfg = settings.global["logsim_buffer_max_lines"].value
  end
  if cfg == nil then
    cfg = M.BUFFER_MAX_LINES
  end

  -- Validate
  if type(cfg) ~= "number" or cfg < 1 then
    log(string.format("[LogSim][ERROR] Invalid BUFFER_MAX_LINES=%s. Keeping stored buffer_max_lines=%s",
      tostring(cfg), tostring(storage.buffer_max_lines)))

    for _, p in pairs(game.players) do
      if p and p.valid then
        p.print({"", "[LogSim] ERROR: BUFFER_MAX_LINES invalid (", tostring(cfg),
                 "). Keeping old value: ", tostring(storage.buffer_max_lines)})
      end
    end
    return
  end

  -- ALWAYS apply (buffer ringbuffer reacts if changed)
  storage.buffer_max_lines = cfg
end

function M.ensure_storage_defaults(st)
  st = st or storage
  if not st then
    st = {}
    storage = st
  end

  -- Always re-apply the 3 numeric settings (true config knobs)
  apply_sample_interval_from_config()
  apply_buffer_max_lines_from_config()
  apply_tx_max_events_from_config()

  -- -------- core run / protocol --------
  st.run_name = st.run_name or nil
  st.run_start_tick = st.run_start_tick or nil

  -- gp_initialized is no longer needed for "default once" behavior, but we keep it
  -- as a migration-safe flag in case other code still references it.
  if st.gp_initialized == nil then st.gp_initialized = true end

  -- -------- buffer --------
  st.buffer_lines     = st.buffer_lines or {}
  st.buffer_view      = st.buffer_view or {}

  -- Buffer ring state (migration-safe)
  if st.buffer_head == nil then st.buffer_head = 1 end
  if st.buffer_size == nil then st.buffer_size = #st.buffer_lines end

  -- -------- registry --------
  st.registry = st.registry or {}
  st.registry_last_id = st.registry_last_id or 0
  st.protected = st.protected or {}

  -- -------- export counters / filenames --------
  st.export_counter = st.export_counter or 0
  st.export_counter_tx = st.export_counter_tx or 0
  st.export_counter_inv = st.export_counter_inv or 0

  -- -------- tx system --------
  st.tx_events = st.tx_events or {}
  st.tx_watch = st.tx_watch or {}
  st.tx_active_inserters = st.tx_active_inserters or {}
  st.tx_object_map = st.tx_object_map or {}

  -- TX ringbuffer state (migration-safe)
  st.tx_head = st.tx_head or 1
  st.tx_size = st.tx_size or #st.tx_events
  st.tx_next_id = st.tx_next_id or (#st.tx_events + 1)

  -- Rendering ids
  st.tx_mark_render_ids = st.tx_mark_render_ids or {}

  -- virtual buffers derived from TX postings (running balances)
  st.tx_virtual = st.tx_virtual or {
    T00  = {},
    SHIP = {},
    RECV = {},
  }

  return st
end



return M