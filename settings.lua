data:extend({
  {
    type = "int-setting",
    name = "logsim_sample_interval_ticks",
    setting_type = "runtime-global",
    default_value = 112,
    minimum_value = 30,
    order = "a[sampling]-a[interval]"
  },
  {
    type = "int-setting",
    name = "logsim_buffer_max_lines",
    setting_type = "runtime-global",
    default_value = 5000,
    minimum_value = 100,
    order = "a[sampling]-b[buffer]"
  },
  {
    type = "int-setting",
    name = "logsim_tx_max_events",
    setting_type = "runtime-global",
    default_value = 50000,
    minimum_value = 1000,
    order = "a[sampling]-c[tx]"
  },
  {
    type = "double-setting",
    name = "logsim_ema_alpha_fast",
    setting_type = "runtime-global",
    default_value = 0.3,
    minimum_value = 0.01,
    maximum_value = 0.99,
    order = "b[ema]-a[fast]"
  },
  {
    type = "double-setting",
    name = "logsim_ema_alpha_slow",
    setting_type = "runtime-global",
    default_value = 0.1,
    minimum_value = 0.01,
    maximum_value = 0.99,
    order = "b[ema]-b[slow]"
  },
})
