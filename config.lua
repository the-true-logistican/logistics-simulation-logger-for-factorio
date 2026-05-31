-- =========================================
-- LogSim (Factorio 2.0)
-- Central configuration and storage initialization.
--
-- Defines constants, GUI element names, setting accessors and persistent
-- storage defaults used by the runtime modules.
--
-- Version 0.8.0 first complete working version
-- Version 0.8.1 TX and buffer ring buffer settings
-- Version 0.8.2 runtime-global setting access
-- Version 0.8.3 WIP support and startup default fixes
-- Version 0.8.5 migration-safe storage defaults
-- Version 0.8.6 player inventory reset and day/time clock
-- Version 0.8.7 setup parameter correction
-- Version 0.8.8 EMA and blueprint tab integration
-- Version 0.9.0 Stable Ledger Operational Baseline
-- Version 0.9.1 day/night toggle
-- Version 0.9.2 roboport, cargo-wagon and fluid-wagon registration
-- Version 0.9.3 local cleanup and consistent storage default handling
--
-- =========================================

local M = {}

M.version = "0.9.3"

M.DEBUG = true

-- =========================================
-- Runtime setting keys
-- =========================================

M.SETTING_KEYS = {
  BUFFER_MAX = "logsim_buffer_max_lines",
  TX_MAX = "logsim_tx_max_events",
  INTERVAL = "logsim_sample_interval_ticks",
  EMA_ALPHA_FAST = "logsim_ema_alpha_fast",
  EMA_ALPHA_SLOW = "logsim_ema_alpha_slow"
}

local function get_global_setting_value(key)
  local setting = settings.global[key]
  return setting and setting.value or nil
end

function M.get_buffer_limit()
  return get_global_setting_value(M.SETTING_KEYS.BUFFER_MAX)
end

function M.get_tx_max_events()
  return get_global_setting_value(M.SETTING_KEYS.TX_MAX)
end

function M.get_sample_interval_ticks()
  return get_global_setting_value(M.SETTING_KEYS.INTERVAL)
end

function M.get_ema_alpha_fast()
  return get_global_setting_value(M.SETTING_KEYS.EMA_ALPHA_FAST)
end

function M.get_ema_alpha_slow()
  return get_global_setting_value(M.SETTING_KEYS.EMA_ALPHA_SLOW)
end

-- =========================================
-- Technical constants
-- =========================================

M.POWER_SAMPLES = 5
M.POLLUTION_SAMPLES = 5
M.GUI_REFRESH_TICKS = 10

-- Legacy spelling retained because other modules may reference this key.
M.CLOCk_INTERVAL_TICKS = 17

M.CLEANUP_INTERVAL_TICKS = 600

-- Legacy spelling retained because other modules may reference this key.
M.TX_Topology_Refesh = 60

M.TEXT_MAX = 1500000
M.CHUNK_SIZE = 32
M.MAX_TELEGRAM_LENGTH = 2000
M.BUFFER_PAGE_LINES = 200
M.COLLECT_DEPENDENC_DEPTH = 30

-- =========================================
-- Marker configuration
-- =========================================

M.TX_MARK_INSERTERS = true
M.TX_MARK_COLOR = { r = 1, g = 1, b = 0 }
M.TX_MARK_ACTIVE_COLOR = { r = 1, g = 0, b = 1, a = 1 }
M.TX_MARK_WIP_COLOR = { r = 0, g = 1, b = 0, a = 1 }
M.TX_MARK_SCALE = 1.0
M.TX_MARK_OFFSET = { x = 0, y = -0.3 }

M.REG_MARK_COLOR = { r = 0, g = 1, b = 0, a = 1 }
M.REG_MARK_SCALE = 1.0
M.REG_MARK_OFFSET = { x = 0, y = 0.1 }

M.PROT_MARK_COLOR = { r = 1, g = 0.5, b = 0, a = 1 }
M.PROT_MARK_SCALE = 1.0
M.PROT_MARK_OFFSET = { x = 0, y = -0.7 }

-- =========================================
-- GUI layout configuration
-- =========================================

M.GUI_BUFFER_WIDTH = 900
M.GUI_BUFFER_HEIGHT = 500

M.GUI_HELP_WIDTH = 900
M.GUI_HELP_HEIGHT = 500
M.GUI_HELP_LABEL_WIDTH = 880

M.GUI_RESET_TEXTFIELD_WIDTH = 300

M.GUI_BP_SIDECAR_WIDTH = 260
M.GUI_BP_SIDECAR_MARGIN = 12
M.GUI_BP_SIDECAR_Y_OFFSET = 220

M.GUI_CONTENT_PADDING = 12
M.GUI_CONTENT_SPACING = 8
M.GUI_BUTTON_SPACING = 8
M.GUI_FRAME_PADDING = 8

-- =========================================
-- Item cost configuration
-- =========================================

-- Representative machines used to derive prototype.energy_usage per recipe category.
M.ITEMCOST_CATEGORY_MACHINE = {
  default = "assembling-machine-3",
  smelting = "electric-furnace",
  chemistry = "chemical-plant"
}

M.MAX_CACHE_SIZE = 500
M.ITEMCOST_POWER_FALLBACK_W = 375000

-- =========================================
-- GUI element names
-- =========================================

M.GUI_BUFFER_FRAME = "logsim_buffer"
M.GUI_BUFFER_BOX = "logsim_buffer_box"
M.GUI_BTN_REFRESH = "logsim_buffer_refresh"
M.GUI_BTN_HIDE = "logsim_buffer_hide"
M.GUI_BTN_COPY = "logsim_buffer_copy"
M.GUI_BTN_RESET = "logsim_reset"
M.GUI_CLOSE = "logsim_close"
M.GUI_HELP_FRAME = "logsim_help"
M.GUI_BTN_HELP = "logsim_help_btn"
M.GUI_HELP_CLOSE = "logsim_help_close"

M.GUI_RESET_FRAME = "logsim_reset_dialog"
M.GUI_RESET_OK = "logsim_reset_ok"
M.GUI_RESET_CANCEL = "logsim_reset_cancel"
M.GUI_RESET_CHK_ITEMS = "logsim_reset_chk_items"
M.GUI_RESET_CHK_LOG = "logsim_reset_chk_log"
M.GUI_RESET_CHK_CHESTS = "logsim_reset_chk_chests"
M.GUI_RESET_CHK_MACHINES = "logsim_reset_chk_machines"
M.GUI_RESET_CHK_PROT = "logsim_reset_chk_prot"
M.GUI_RESET_NAME_FIELD = "logsim_reset_name"
M.GUI_RESET_CHK_STATS = "logsim_reset_chk_stats"
M.GUI_RESET_CHK_PLAYERINV = "logsim_reset_chk_playerinv"

M.GUI_BTN_OLDER = "logsim_buffer_older"
M.GUI_BTN_TAIL = "logsim_buffer_tail"
M.GUI_BTN_NEWER = "logsim_buffer_newer"
M.GUI_LBL_RANGE = "logsim_buffer_range"

M.GUI_INV_TABS = "logsim_inv_tabs"
M.GUI_INV_TAB_ASSETS = "logsim_inv_tab_assets"
M.GUI_INV_TAB_COSTS = "logsim_inv_tab_costs"
M.GUI_INV_TAB_SYSTEM = "logsim_inv_tab_system"
M.GUI_INV_TAB_STATS = "logsim_inv_tab_stats"
M.GUI_INV_TAB_WC = "logsim_inv_tab_wc"
M.GUI_INV_ACTIVE_TAB_STYLE = "confirm_button"
M.GUI_INV_INACTIVE_TAB_STYLE = "button"

M.GUI_INV_BTN_EXPORT = "logsim_invwin_export"
M.GUI_INV_FRAME = "logsim_invwin"
M.GUI_INV_BOX = "logsim_invwin_box"
M.GUI_INV_CLOSE_X = "logsim_invwin_close_x"
M.GUI_INV_BTN_COPY = "logsim_invwin_copy"
M.GUI_INV_BTN_CLOSE = "logsim_invwin_close"

M.GUI_BTN_TX_OPEN = "logsim_buffer_tx_open"
M.GUI_TX_FRAME = "logsim_tx"
M.GUI_TX_BOX = "logsim_tx_box"
M.GUI_TX_CLOSE = "logsim_tx_close"
M.GUI_TX_BTN_EXPORT = "logsim_tx_export"
M.GUI_TX_BTN_OLDER = "logsim_tx_older"
M.GUI_TX_BTN_HOME = "logsim_tx_home"
M.GUI_TX_BTN_END = "logsim_tx_end"
M.GUI_TX_BTN_TAIL = M.GUI_TX_BTN_END
M.GUI_TX_BTN_NEWER = "logsim_tx_newer"
M.GUI_TX_LBL_RANGE = "logsim_tx_range"
M.GUI_TX_BTN_COPY = "logsim_tx_copy"
M.GUI_TX_BTN_HIDE = "logsim_tx_hide"

M.GUI_BP_SIDECAR = "logsim_bp_sidecar"
M.GUI_BP_EXTRACTBTN = "logsim_bp_extract"

M.GUI_BTN_EXPORT = "logsim_buffer_export"
M.GUI_BTN_EXPORT_CSV = "logsim_export_csv"
M.GUI_BTN_EXPORT_JSON = "logsim_export_json"
M.GUI_EXPORT_FRAME = "logsim_export_dialog"
M.GUI_EXPORT_CLOSE = "logsim_export_close"
M.GUI_EXPORT_FILENAME = "logsim_export_filename"

-- =========================================
-- Export configuration
-- =========================================

M.EXPORT_FOLDER = "logsim-exports"
M.EXPORT_DEFAULT_NAME = "protocol"

-- =========================================
-- Topbar configuration
-- =========================================

M.TOPBAR_ROOT = "ls_topbar_root"

M.TOPBAR_BTN1 = "ls_topbar_btn1"
M.TOPBAR_BTN2 = "ls_topbar_btn2"
M.TOPBAR_BTN3 = "ls_topbar_btn3"
M.TOPBAR_BTN4 = "logsim_topbar_btn4"

M.TOPBAR_BTN1_SPRITE = "ls_button1_icon"
M.TOPBAR_BTN2_ON_SPRITE = "ls_toggle_on_icon"
M.TOPBAR_BTN2_OFF_SPRITE = "ls_toggle_off_icon"
M.TOPBAR_BTN3_ON_SPRITE = "ls_toggle2_on_icon"
M.TOPBAR_BTN3_OFF_SPRITE = "ls_toggle2_off_icon"
M.TOPBAR_BTN4_ON_SPRITE = "ls_day_on_icon"
M.TOPBAR_BTN4_OFF_SPRITE = "ls_day_off_icon"

M.TOPBAR_BTN1_TOOLTIP = {"logistics_simulation.topbar_btn1_tooltip"}
M.TOPBAR_BTN2_TOOLTIP = {"logistics_simulation.topbar_btn2_tooltip"}
M.TOPBAR_BTN3_TOOLTIP = {"logistics_simulation.topbar_btn3_tooltip"}
M.TOPBAR_BTN4_TOOLTIP = {"logistics_simulation.topbar_btn4_tooltip"}

-- =========================================
-- Item aliases for compact logging
-- =========================================

M.ITEM_ALIASES = {
  ["iron-plate"] = "Fe",
  ["copper-plate"] = "Cu",
  ["steel-plate"] = "St",
  ["coal"] = "Coal",
  ["stone"] = "Stone",
  ["stone-brick"] = "Brick",
  ["plastic-bar"] = "Plastic",
  ["low-density-structure"] = "LDS",

  ["iron-gear-wheel"] = "Gear",
  ["iron-stick"] = "Rod",
  ["copper-cable"] = "Wire",
  ["pipe"] = "Pipe",
  ["pipe-to-ground"] = "UGPipe",

  ["engine-unit"] = "Engine",
  ["electric-engine-unit"] = "EEngine",
  ["battery"] = "Batt",
  ["flying-robot-frame"] = "Frame",

  ["electronic-circuit"] = "cirG",
  ["advanced-circuit"] = "cirR",
  ["processing-unit"] = "cirB",

  ["automation-science-pack"] = "Red",
  ["logistic-science-pack"] = "Green",
  ["chemical-science-pack"] = "Blue",
  ["military-science-pack"] = "Black",
  ["production-science-pack"] = "Purple",
  ["utility-science-pack"] = "Yellow",
  ["space-science-pack"] = "White",

  ["water"] = "H2O",
  ["crude-oil"] = "Oil",
  ["heavy-oil"] = "OIL",
  ["light-oil"] = "oil",
  ["petroleum-gas"] = "Gas",
  ["lubricant"] = "Lube",
  ["sulfuric-acid"] = "H2SO4"
}

-- =========================================
-- Runtime setting application
-- =========================================

local function print_to_players(message)
  if not game or not game.players then return end

  for _, player in pairs(game.players) do
    if player and player.valid then
      player.print(message)
    end
  end
end

local function report_invalid_setting(setting_name, value, stored_value)
  log(string.format(
    "[LogSim][ERROR] Invalid %s=%s. Keeping stored value=%s",
    tostring(setting_name),
    tostring(value),
    tostring(stored_value)
  ))

  print_to_players({
    "",
    "[LogSim] ERROR: ",
    tostring(setting_name),
    " invalid (",
    tostring(value),
    "). Keeping old value: ",
    tostring(stored_value)
  })
end

local function apply_positive_numeric_setting(setting_name, getter_fn, target_key)
  local value = getter_fn()

  if type(value) ~= "number" or value < 1 then
    report_invalid_setting(setting_name, value, storage[target_key])
    return
  end

  storage[target_key] = value
end

local function apply_sample_interval_from_config()
  apply_positive_numeric_setting(
    M.SETTING_KEYS.INTERVAL,
    M.get_sample_interval_ticks,
    "sample_interval"
  )
end

local function apply_tx_max_events_from_config()
  apply_positive_numeric_setting(
    M.SETTING_KEYS.TX_MAX,
    M.get_tx_max_events,
    "tx_max_events"
  )
end

local function apply_buffer_max_lines_from_config()
  apply_positive_numeric_setting(
    M.SETTING_KEYS.BUFFER_MAX,
    M.get_buffer_limit,
    "buffer_max_lines"
  )
end

function M.apply_all_settings()
  apply_sample_interval_from_config()
  apply_buffer_max_lines_from_config()
  apply_tx_max_events_from_config()
end

-- =========================================
-- Storage initialization
-- =========================================

local function max_id_from(map, prefix)
  local max_n = 0

  if not map then return max_n end

  for _, rec in pairs(map) do
    if rec and rec.id then
      local n = tonumber(string.match(rec.id, "^" .. prefix .. "(%d+)$"))
      if n and n > max_n then
        max_n = n
      end
    end
  end

  return max_n
end

local function ensure_registry_counters(st)
  if st.next_chest_id == nil then
    st.next_chest_id = max_id_from(st.registry, "C") + 1
  end

  if st.next_tank_id == nil then
    st.next_tank_id = max_id_from(st.registry, "T") + 1
  end

  if st.next_wagon_id == nil then
    st.next_wagon_id = max_id_from(st.registry, "W") + 1
  end

  if st.next_fluid_wagon_id == nil then
    st.next_fluid_wagon_id = max_id_from(st.registry, "F") + 1
  end

  if st.next_protect_id == nil then
    st.next_protect_id = max_id_from(st.protected, "P") + 1
  end

  if st.next_machine_id == nil then
    st.next_machine_id = max_id_from(st.machines, "M") + 1
  end

  if st.next_roboport_id == nil then
    st.next_roboport_id = max_id_from(st.roboports, "R") + 1
  end
end

function M.ensure_storage_defaults(st)
  st = st or storage

  if not st then
    st = {}
    storage = st
  end

  st.export_mode = st.export_mode or {}

  -- Core run and protocol state.
  st.run_name = st.run_name or nil
  st.run_start_tick = st.run_start_tick or nil

  -- Migration-safe legacy flag retained for external references.
  if st.gp_initialized == nil then
    st.gp_initialized = true
  end

  -- Buffer state.
  st.buffer_lines = st.buffer_lines or {}
  st.buffer_view = st.buffer_view or {}
  st.gui_dirty = st.gui_dirty or {}

  if st._buf_last_gui_refresh_tick == nil then
    st._buf_last_gui_refresh_tick = 0
  end

  if st.buffer_head == nil then
    st.buffer_head = 1
  end

  if st.buffer_size == nil then
    st.buffer_size = #st.buffer_lines
  end

  -- Registered logistics objects.
  st.registry = st.registry or {}
  st.registry_last_id = st.registry_last_id or 0
  st.protected = st.protected or {}
  st.machines = st.machines or {}
  st.roboports = st.roboports or {}

  ensure_registry_counters(st)

  -- Export counters.
  st.export_counter = st.export_counter or 0
  st.export_counter_tx = st.export_counter_tx or 0
  st.export_counter_inv = st.export_counter_inv or 0

  -- Transaction state.
  st.tx_events = st.tx_events or {}
  st.tx_watch = st.tx_watch or {}
  st.tx_active_inserters = st.tx_active_inserters or {}
  st.tx_wip_inserters = st.tx_wip_inserters or {}
  st.tx_object_map = st.tx_object_map or {}

  -- Player hands are pseudo-inserters H01, H02, ...
  st.tx_hand_by_player_index = st.tx_hand_by_player_index or {}
  st.tx_hand_list = st.tx_hand_list or {}
  st.tx_inserter_list = st.tx_inserter_list or {}

  -- Migration-safe transaction maps.
  st.tx_inserter_by_unit = st.tx_inserter_by_unit or {}
  st.tx_next_inserter_id = st.tx_next_inserter_id or 1
  st.tx_watch_meta = st.tx_watch_meta or {}

  -- Newer transaction code uses tx_obj_by_unit; older saves used tx_object_map.
  st.tx_obj_by_unit = st.tx_obj_by_unit or st.tx_object_map or {}

  -- TX ring-buffer state. The _tx_rb_initialized sentinel is owned by transaction.lua.
  st.tx_head = st.tx_head or 1
  st.tx_size = st.tx_size or #st.tx_events

  -- Monotonic transaction IDs are held in storage.tx_seq by transaction.lua.
  st.tx_mark_render_ids = st.tx_mark_render_ids or {}

  -- Virtual buffers derived from TX postings.
  st.tx_virtual = st.tx_virtual or {
    T00 = {},
    SHIP = {},
    RECV = {},
    WIP = {},
    MAN = {}
  }

  st.tx_virtual.T00 = st.tx_virtual.T00 or {}
  st.tx_virtual.SHIP = st.tx_virtual.SHIP or {}
  st.tx_virtual.RECV = st.tx_virtual.RECV or {}
  st.tx_virtual.WIP = st.tx_virtual.WIP or {}
  st.tx_virtual.MAN = st.tx_virtual.MAN or {}

  -- EMA state for current assets.
  if st.ema == nil then
    st.ema = { _last_tick = 0 }
  end

  if st.ema._last_tick == nil then
    st.ema._last_tick = 0
  end

  return st
end

return M