data:extend({
  {
    type = "int-setting",
    name = "logsim_sample_interval_ticks",
    setting_type = "runtime-global",
    default_value = 173,
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
})
