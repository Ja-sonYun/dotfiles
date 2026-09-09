local module = {}
local actions = require("shared-actions")
local logger = hs.logger.new("on-lock")
local muteMicrophone = "@muteMicrophone@" == "true"
local muteAudio = "@muteAudio@" == "true"
local quitApps = hs.json.decode([==[@quitAppsJson@]==])
local wallpaper = hs.json.decode([==[@wallpaperJson@]==])

local function muteDefaultInput()
	local device = hs.audiodevice.defaultInputDevice()
	if device and not device:setInputMuted(true) then
		local message = "Could not mute the default microphone."
		logger:e(message)
		module.failureNotification = hs.notify.new({
			title = "Microphone Mute Failed",
			informativeText = message,
		})
		module.failureNotification:send()
	end
end

module.screenLockWatcher = hs.caffeinate.watcher.new(function(event)
	if event == hs.caffeinate.watcher.screensDidLock then
		if muteMicrophone then
			muteDefaultInput()
		end
		if muteAudio then
			local device = hs.audiodevice.defaultOutputDevice()
			if device and not device:setOutputMuted(true) then
				logger:e("Could not mute the default audio output.")
			end
		end
		actions.run(quitApps, wallpaper)
	end
end)

module.screenLockWatcher:start()

return module
