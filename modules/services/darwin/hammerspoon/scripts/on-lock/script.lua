local module = {}
local actions = require("shared-actions")
local logger = require("logging").new("on-lock")
local muteMicrophone = "@muteMicrophone@" == "true"
local muteAudio = "@muteAudio@" == "true"
local quitApps = hs.json.decode([==[@quitAppsJson@]==])
local wallpaper = hs.json.decode([==[@wallpaperJson@]==])

local function muteDefaultInput()
	local device = hs.audiodevice.defaultInputDevice()
	logger:i("microphone_mute_requested", { device_available = device ~= nil })
	if device and not device:setInputMuted(true) then
		local message = "Could not mute the default microphone."
		logger:e(message)
		module.failureNotification = hs.notify.new({
			title = "Microphone Mute Failed",
			informativeText = message,
		})
		module.failureNotification:send()
	elseif device then
		logger:i("microphone_muted")
	else
		logger:w("microphone_mute_skipped", { reason = "no_default_input" })
	end
end

module.screenLockWatcher = hs.caffeinate.watcher.new(logger:wrap("lock_event_failed", function(event)
	logger:i("session_event", { event_code = event })
	if event == hs.caffeinate.watcher.screensDidLock then
		if muteMicrophone then
			muteDefaultInput()
		end
		if muteAudio then
			local device = hs.audiodevice.defaultOutputDevice()
			logger:i("audio_mute_requested", { device_available = device ~= nil })
			if device and not device:setOutputMuted(true) then
				logger:e("Could not mute the default audio output.")
			elseif device then
				logger:i("audio_muted")
			else
				logger:w("audio_mute_skipped", { reason = "no_default_output" })
			end
		end
		actions.run(quitApps, wallpaper)
	end
end))

module.screenLockWatcher:start()
logger:i("watcher_started", { mute_microphone = muteMicrophone, mute_audio = muteAudio })

return module
