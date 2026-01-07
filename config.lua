-- =========================================
-- LogSim (Factorio 2.0) 
-- Configuration Module
--
-- Version 0.3.0 - Locale support
-- =========================================

local M = {}

M.version = "0.5.3"

-- =====================================
-- Technical Configuration
-- =====================================

M.SAMPLE_INTERVAL_TICKS = 60  -- 1x per second (60fps)
M.POWER_SAMPLES = 5           -- ~1.0s (5 * 0.2s)  
M.POLLUTION_SAMPLES = 5       -- ~1.0s (5 * 0.2s)
M.GUI_REFRESH_TICKS = 10      -- throttle GUI refresh (ticks)
M.BUFFER_MAX_LINES = 20000
M.TEXT_MAX = 150000
M.CHUNK_SIZE = 32 
M.MAX_TELEGRAM_LENGTH = 2000
M.BUFFER_PAGE_LINES = 200

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

return M