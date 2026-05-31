-- =========================================
-- LogSim (Factorio 2.0)
-- Event Registry
--
-- Registers Factorio event handlers and supports multiple handlers per event id.
--
-- Version 0.1.0 initial version
-- Version 0.2.0 first operational version
-- Version 0.9.0 Stable Ledger Operational Baseline 
--
-- =========================================

local Registry = {}

Registry.version = "0.9.0"
Registry.__index = Registry

function Registry.new()
  return setmetatable({ map = {} }, Registry)
end

-- Add a handler for one Factorio event id.
-- Multiple handlers for the same event id are preserved in registration order.
function Registry:add(event_id, fn)
  local cur = self.map[event_id]

  if cur == nil then
    self.map[event_id] = fn
    return
  end

  if type(cur) == "table" then
    cur[#cur + 1] = fn
  else
    self.map[event_id] = { cur, fn }
  end
end

-- Bind all registered handlers via script.on_event().
-- Events with multiple handlers are dispatched through one chained callback.
function Registry:bind()
  for event_id, handler in pairs(self.map) do
    if type(handler) == "table" then
      script.on_event(event_id, function(event)
        for _, fn in ipairs(handler) do
          fn(event)
        end
      end)
    else
      script.on_event(event_id, handler)
    end
  end
end

return Registry