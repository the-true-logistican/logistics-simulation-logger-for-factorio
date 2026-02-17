-- =========================================
-- Change Ledger (Factorio 2.0) 
-- Register for factorio events
--
-- version 0.1.0 first try
-- version 0.2.0 first opertional Version
--
-- =========================================

local Registry = {}

Registry.version = "0.2.0"

Registry.__index = Registry

function Registry.new()
  return setmetatable({ map = {} }, Registry)
end

-- Add a handler for a single Factorio event id.
-- Supports multiple handlers per event id.
function Registry:add(event_id, fn)
  local cur = self.map[event_id]
  if cur == nil then
    self.map[event_id] = fn
    return
  end
  if type(cur) == "table" then
    cur[#cur+1] = fn
  else
    self.map[event_id] = { cur, fn }
  end
end

-- Bind all registered handlers via script.on_event.
-- If multiple handlers were added for the same event_id, they are chained.
function Registry:bind()
  for event_id, handler in pairs(self.map) do
    if type(handler) == "table" then
      script.on_event(event_id, function(e)
        for _, fn in ipairs(handler) do
          fn(e)
        end
      end)
    else
      script.on_event(event_id, handler)
    end
  end
end

return Registry
