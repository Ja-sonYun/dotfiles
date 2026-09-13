local module = {}
local logger = require("logging").new("shared-actions")

module.run = logger:wrap("actions_failed", function(quitApps, wallpaper)
	local started = hs.timer.secondsSinceEpoch()
	logger.context.job_id = hs.host.uuid()
	logger:i("actions_started", { quit_rules = #quitApps, change_wallpaper = wallpaper ~= "" })
	local requested = 0
	for _, app in ipairs(hs.application.runningApplications()) do
		for _, appName in ipairs(quitApps) do
			if app:title() == appName then
				logger:i("application_quit_requested", { app = appName, pid = app:pid() })
				app:kill()
				requested = requested + 1
				break
			end
		end
	end

	if wallpaper ~= "" then
		local path = os.getenv("HOME")
			.. "/Library/Application Support/com.apple.mobileAssetDesktop/"
			.. wallpaper
			.. ".heic"
		local url = hs.fs.urlFromPath(path)
		for _, screen in ipairs(hs.screen.allScreens()) do
			logger:i("wallpaper_change_requested", { screen_id = screen:id() })
			screen:desktopImageURL(url)
			logger:i("wallpaper_change_returned", { screen_id = screen:id() })
		end
	end
	logger:i(
		"actions_finished",
		{ quit_requests = requested, elapsed_seconds = hs.timer.secondsSinceEpoch() - started }
	)
end)

return module
