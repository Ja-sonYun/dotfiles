local module = { subscribers = {} }
local logger = require("logging").new("yabai-events")

function module.subscribe(name, callback)
	module.subscribers[name] = callback
end

function module.emit(event)
	-- Signals can arrive out of order; subscribers must query current state.
	for name, callback in pairs(module.subscribers) do
		local ok, err = xpcall(callback, debug.traceback, event)
		if not ok then
			logger:e("subscriber_failed", { subscriber = name, event_name = event, error = err })
		end
	end
end

return module
