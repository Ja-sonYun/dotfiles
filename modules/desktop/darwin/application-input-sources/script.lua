local module = {}
local logger = require("logging").new("application-input-sources")
local configuration = hs.json.decode([==[@configurationJson@]==])
local activeBundleID
local gesture
local siriPID

local function selectSource(application, sourceID, reason)
	if not sourceID then
		return
	end

	local previousSourceID = hs.keycodes.currentSourceID()
	if sourceID == previousSourceID then
		return
	end

	local changed = hs.keycodes.currentSourceID(sourceID)
	logger:write(changed and "info" or "error", changed and "input_source_changed" or "input_source_change_failed", {
		app = application:name(),
		bundle_id = application:bundleID(),
		previous = previousSourceID,
		requested = sourceID,
		current = hs.keycodes.currentSourceID(),
		accepted = changed,
		reason = reason,
	})
end

local watchSiri = logger:wrap("siri_watch_failed", function(application)
	if module.siriObserver then
		module.siriObserver:stop()
		module.siriObserver = nil
	end
	siriPID = nil
	if not application then
		return
	end

	-- Siri's search panel emits AX events without regular application activation.
	local element = hs.axuielement.applicationElement(application)
	module.siriObserver = hs.axuielement.observer.new(application:pid())
	module.siriObserver:callback(logger:wrap("siri_focus_failed", function()
		if element:attributeValue("AXFocusedWindow") then
			selectSource(application, configuration.rules.Siri, "siri_focus")
		end
	end))
	module.siriObserver:addWatcher(element, "AXFocusedWindowChanged")
	module.siriObserver:addWatcher(element, "AXWindowCreated")
	module.siriObserver:start()
	siriPID = application:pid()
end)

local application = hs.application.frontmostApplication()
if application and application:kind() == 1 then
	activeBundleID = application:bundleID()
end

module.watcher =
	hs.application.watcher.new(logger:wrap("application_event_failed", function(appName, event, application)
		if configuration.rules.Siri and application then
			if event == hs.application.watcher.launched and application:bundleID() == "com.apple.campo" then
				watchSiri(application)
			elseif event == hs.application.watcher.terminated and application:pid() == siriPID then
				watchSiri(nil)
			end
		end

		-- Preserve the last regular app while helper UI is active.
		if event ~= hs.application.watcher.activated or not application or application:kind() ~= 1 then
			return
		end

		local bundleID = application:bundleID()
		if not bundleID or bundleID == activeBundleID then
			return
		end
		activeBundleID = bundleID
		if gesture and gesture.bundleID ~= bundleID then
			gesture = nil
		end

		selectSource(application, configuration.rules[appName] or configuration.defaultSource, "application_focus")
	end))

module.watcher:start()
logger:i("watcher_started")

if configuration.rules.Siri then
	watchSiri(hs.application.applicationsForBundleID("com.apple.campo")[1])
end

if configuration.manualSwitch then
	local eventTypes = hs.eventtap.event.types
	local autorepeat = hs.eventtap.event.properties.keyboardEventAutorepeat
	local spaceKey = hs.keycodes.map.space
	local swallowedSpace = false

	module.keyWatcher = hs.eventtap
		.new(
			{ eventTypes.keyDown, eventTypes.keyUp, eventTypes.flagsChanged },
			logger:wrap("manual_switch_event_failed", function(event)
				local eventType = event:getType()
				local flags = event:getFlags()
				local otherModifier = flags.cmd or flags.alt or flags.shift or flags.fn

				if eventType == eventTypes.flagsChanged then
					if otherModifier then
						gesture = nil
					elseif gesture and not flags.ctrl then
						local completed = gesture
						gesture = nil
						local frontmost = hs.application.frontmostApplication()
						if frontmost and frontmost:kind() == 1 and frontmost:bundleID() == completed.bundleID then
							local sourceID
							if completed.count >= 2 then
								sourceID = configuration.manualSwitch.alternateSource
							elseif completed.sourceID == configuration.manualSwitch.primarySource then
								sourceID = configuration.manualSwitch.secondarySource
							else
								sourceID = configuration.manualSwitch.primarySource
							end
							selectSource(frontmost, sourceID, "manual_switch")
						end
					end
					return false
				end

				if event:getKeyCode() ~= spaceKey then
					if eventType == eventTypes.keyDown then
						gesture = nil
					end
					return false
				end

				if eventType == eventTypes.keyUp then
					local consumed = swallowedSpace
					swallowedSpace = false
					return consumed
				end

				-- Consume repeats until Space is released, even after Control release.
				if swallowedSpace then
					return true
				end
				if not flags.ctrl or otherModifier then
					gesture = nil
					return false
				end
				if event:getProperty(autorepeat) ~= 0 then
					return false
				end

				local frontmost = hs.application.frontmostApplication()
				local bundleID = frontmost and frontmost:bundleID()
				if not bundleID or frontmost:kind() ~= 1 then
					gesture = nil
					return false
				end

				swallowedSpace = true
				if gesture and gesture.bundleID == bundleID then
					gesture.count = math.min(2, gesture.count + 1)
				else
					gesture = {
						bundleID = bundleID,
						sourceID = hs.keycodes.currentSourceID(),
						count = 1,
					}
				end
				return true
			end)
		)
		:start()
end

local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
	module.watcher:stop()
	watchSiri(nil)
	if module.keyWatcher then
		module.keyWatcher:stop()
	end
	activeBundleID = nil
	gesture = nil
	if previousShutdown then
		previousShutdown()
	end
end

return module
