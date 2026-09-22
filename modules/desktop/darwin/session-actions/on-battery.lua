local module = {}
local logger = require("logging").new("on-battery")
local actions = require("shared-actions")
local quitApps = hs.json.decode([==[@quitAppsJson@]==])
local wallpaper = hs.json.decode([==[@wallpaperJson@]==])
local previousPowerSource = hs.battery.powerSource()

module.watcher = hs.battery.watcher.new(logger:wrap("battery_event_failed", function()
	local powerSource = hs.battery.powerSource()
	if previousPowerSource ~= powerSource then
		logger:i("power_source_changed", { previous = previousPowerSource, current = powerSource })
	end
	local disconnected = previousPowerSource == "AC Power" and powerSource == "Battery Power"
	previousPowerSource = powerSource
	if not disconnected then
		return
	end

	actions.run(quitApps, wallpaper)
end))

module.watcher:start()
logger:i("watcher_started", { power_source = previousPowerSource })

return module
