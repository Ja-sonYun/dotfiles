local module = {}

local function muteDefaultInput()
	local device = hs.audiodevice.defaultInputDevice()
	if device then
		device:setInputMuted(true)
	end
end

module.screenLockWatcher = hs.caffeinate.watcher.new(function(event)
	if event == hs.caffeinate.watcher.screensDidLock then
		muteDefaultInput()
	end
end)

module.screenLockWatcher:start()

return module
