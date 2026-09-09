local module = {}

function module.run(quitApps, wallpaper)
	for _, app in ipairs(hs.application.runningApplications()) do
		for _, appName in ipairs(quitApps) do
			if app:title() == appName then
				app:kill()
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
			screen:desktopImageURL(url)
		end
	end
end

return module
