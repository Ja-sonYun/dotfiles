local module = {}
local logger = require("logging").new("application-input-sources")
local rules = hs.json.decode([==[@rulesJson@]==])

module.watcher = hs.application.watcher.new(logger:wrap("application_event_failed", function(appName, event)
	if event ~= hs.application.watcher.activated then
		return
	end

	local sourceID = rules[appName]
	logger:i("application_activated", { app = appName, rule_matched = sourceID ~= nil })
	if sourceID then
		logger:i("input_source_change_requested", { previous = hs.keycodes.currentSourceID(), requested = sourceID })
		local changed = hs.keycodes.currentSourceID(sourceID)
		if changed then
			logger:i("input_source_changed", { current = hs.keycodes.currentSourceID() })
		else
			logger:e("input_source_change_failed", { requested = sourceID })
		end
	end
end))

module.watcher:start()
logger:i("watcher_started")

return module
