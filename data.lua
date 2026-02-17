data:extend({
  -- Bestehende custom-inputs bleiben
  { type = "custom-input", name = "logsim_toggle_buffer",       key_sequence = "SHIFT + B", consuming = "none"},
  { type = "custom-input", name = "logsim_register_chest",      key_sequence = "SHIFT + R", consuming = "game-only"},
  { type = "custom-input", name = "logsim_unregister_selected", key_sequence = "SHIFT + U", consuming = "none"},
  { type = "custom-input", name = "logsim_register_protect",    key_sequence = "SHIFT + P", consuming = "game-only"},
  
  -- NEUE Sprites für die Topbar-Buttons
  {
    type = "sprite",
    name = "ls_button1_icon",
    filename = "__logistics_simulation__/graphics/log-icon.png",
    priority = "extra-high-no-scale",
    width = 32,
    height = 32,
    mipmap_count = 2,
    flags = {"gui-icon"}
  },
  {
    type = "sprite",
    name = "ls_toggle_on_icon",
    filename = "__logistics_simulation__/graphics/record-icon.png",
    priority = "extra-high-no-scale",
    width = 32,
    height = 32,
    mipmap_count = 2,
    flags = {"gui-icon"}
  },
  {
    type = "sprite",
    name = "ls_toggle_off_icon",
    filename = "__logistics_simulation__/graphics/stop-icon.png",
    priority = "extra-high-no-scale",
    width = 32,
    height = 32,
    mipmap_count = 2,
    flags = {"gui-icon"}
  },
  {
    type = "sprite",
    name = "ls_toggle2_on_icon",
    filename = "__logistics_simulation__/graphics/power-on.png",
    priority = "extra-high-no-scale",
    width = 32,
    height = 32,
    mipmap_count = 2,
    flags = {"gui-icon"}
  },
  {
    type = "sprite",
    name = "ls_toggle2_off_icon",
    filename = "__logistics_simulation__/graphics/power-off.png",
    priority = "extra-high-no-scale",
    width = 32,
    height = 32,
    mipmap_count = 2,
    flags = {"gui-icon"}
  }
})