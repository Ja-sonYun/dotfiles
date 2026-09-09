local module = {}
local actions = require("shared-actions")
local quitApps = hs.json.decode([==[@quitAppsJson@]==])
local wallpaper = hs.json.decode([==[@wallpaperJson@]==])
local previousPowerSource = hs.battery.powerSource()

module.watcher = hs.battery.watcher.new(function()
	local powerSource = hs.battery.powerSource()
	local disconnected = previousPowerSource == "AC Power" and powerSource == "Battery Power"
	previousPowerSource = powerSource
	if not disconnected then
		return
	end

	actions.run(quitApps, wallpaper)
end)

module.watcher:start()

return module
