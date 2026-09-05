local module = {}
local logger = hs.logger.new("mute-microphone-on-lock")

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
		muteDefaultInput()
	end
end)

module.screenLockWatcher:start()

return module
