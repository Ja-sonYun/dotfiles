local config = hs.json.decode([==[@configJson@]==])
local module = {
	calendarRequests = {},
	meetingActive = false,
	meetingURLs = {},
	recorderRequests = {},
	state = "idle",
	task = nil,
}
local logger = hs.logger.new("meeting-recorder")
local detectionLogger = hs.logger.new("meeting-detection")
local outputDirectory = config.outputDirectory:gsub("/+$", "")

local browsers = {
	["com.apple.Safari"] = {
		name = "safari",
		appName = "Safari",
		ownerBundlePrefixes = {
			"com.apple.Safari",
			"com.apple.WebKit.",
		},
		script = [[
	tell application "Safari"
		set tabURLs to {}
		repeat with browserWindow in windows
			repeat with browserTab in tabs of browserWindow
				try
					set tabURL to URL of browserTab
					if tabURL is not missing value then set end of tabURLs to tabURL
				end try
			end repeat
		end repeat
	end tell
	set AppleScript's text item delimiters to linefeed
	return tabURLs as text
		]],
	},
	["com.google.Chrome"] = {
		name = "chrome",
		appName = "Google Chrome",
		ownerBundlePrefixes = { "com.google.Chrome" },
		script = [[
	tell application "Google Chrome"
		set tabURLs to {}
		repeat with browserWindow in windows
			repeat with browserTab in tabs of browserWindow
				try
					set tabURL to URL of browserTab
					if tabURL is not missing value then set end of tabURLs to tabURL
				end try
			end repeat
		end repeat
	end tell
	set AppleScript's text item delimiters to linefeed
	return tabURLs as text
		]],
	},
}
local browsersByName = {}
for bundleID, browser in pairs(browsers) do
	browser.bundleID = bundleID
	browsersByName[browser.name] = browser
end

local activeOwners = {}
local reportedDetectionErrors = {}
local handleMeetingState
local refreshMeetingSource
local updateBrowserPolling
local cancelStopDelay
local startRecording
local stopRecording
local recordingMenu

local function reportDetectionError(key, message)
	if reportedDetectionErrors[key] then
		return
	end

	reportedDetectionErrors[key] = true
	detectionLogger:w(message)
end

local function clearDetectionError(key)
	reportedDetectionErrors[key] = nil
end

local function matchesBrowserRule(host, path, rule)
	local configuredHost = rule.host:lower()
	if host ~= configuredHost then
		local suffix = "." .. configuredHost
		if not rule.includeSubdomains or host:sub(-#suffix) ~= suffix then
			return false
		end
	end

	for _, pattern in ipairs(rule.pathPatterns) do
		if path:match(pattern) then
			return true
		end
	end

	return false
end

local function normalizeMeetingURL(url)
	if type(url) ~= "string" then
		return nil
	end

	local host, path = url:match("^[%a][%w+.-]*://([^/:?#]+)([^?#]*)")
	if not host then
		return nil
	end

	host = host:lower()
	for _, rule in ipairs(config.browserRules) do
		if matchesBrowserRule(host, path, rule) then
			path = path:gsub("/+$", "")
			if path == "" then
				path = "/"
			end
			return host .. path
		end
	end

	return nil
end

local function collectMeetingURLs(value, result)
	if type(value) == "string" then
		local normalized = normalizeMeetingURL(value)
		if normalized then
			result[normalized] = true
		end
		return
	end
	if type(value) ~= "table" then
		return
	end

	for _, item in pairs(value) do
		collectMeetingURLs(item, result)
	end
end

local function meetingURLs(value)
	local result = {}
	collectMeetingURLs(value, result)

	local urls = {}
	for url in pairs(result) do
		table.insert(urls, url)
	end
	table.sort(urls)
	return urls
end

local function bundleMatchesBrowser(bundleID, browser)
	for _, prefix in ipairs(browser.ownerBundlePrefixes) do
		if bundleID:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function browserOwnerIDs(browser)
	local result = {}
	if not browser then
		return result
	end
	for objectID, bundleID in pairs(activeOwners) do
		if bundleMatchesBrowser(bundleID, browser) then
			result[objectID] = true
		end
	end
	return result
end

local function browserOwnsInput(browser)
	return next(browserOwnerIDs(browser)) ~= nil
end

local function browserOwnerKey(browser)
	local objectIDs = {}
	for objectID in pairs(browserOwnerIDs(browser)) do
		table.insert(objectIDs, objectID)
	end
	table.sort(objectIDs)
	return table.concat(objectIDs, "\0")
end

local function candidateKey(source, urls)
	if not source or #urls == 0 then
		return nil
	end

	local ownerKey = browserOwnerKey(browsersByName[source])
	if ownerKey == "" then
		return nil
	end
	return source .. "\0" .. ownerKey .. "\0" .. table.concat(urls, "\0")
end

local function setMeetingSource(source, urls)
	urls = urls or {}
	local key = candidateKey(source, urls)
	local active = key ~= nil
	if module.meetingCandidateKey == key then
		return
	end

	module.meetingActive = active
	module.meetingSource = active and source or nil
	module.meetingURLs = active and urls or {}
	module.meetingCandidateKey = key
	module.meetingGeneration = (module.meetingGeneration or 0) + 1
	handleMeetingState(active, module.meetingSource, key, module.meetingGeneration)
end

local function hasActiveOwner()
	return next(activeOwners) ~= nil
end

local function hasActiveBrowserOwner()
	for _, browser in pairs(browsers) do
		if browserOwnsInput(browser) then
			return true
		end
	end
	return false
end

local function parseBrowserURLs(output)
	local urls = {}
	for url in (output or ""):gmatch("[^\r\n]+") do
		table.insert(urls, url)
	end
	return meetingURLs(urls)
end

local function browserMeetingURLs(browser, callback)
	if not hs.application.get(browser.bundleID) then
		callback({})
		return
	end

	local completed = false
	local timeoutTimer
	local task
	local function finish(urls)
		if completed then
			return
		end
		completed = true
		if timeoutTimer then
			timeoutTimer:stop()
			timeoutTimer = nil
		end
		if module.browserURLTask == task then
			module.browserURLTask = nil
		end
		callback(urls)
	end

	task = hs.task.new("/usr/bin/osascript", function(exitCode, stdout)
		if completed then
			return
		end
		if exitCode ~= 0 then
			reportDetectionError(browser.name, "Could not read " .. browser.appName .. " tabs")
			finish(nil)
			return
		end
		clearDetectionError(browser.name)
		finish(parseBrowserURLs(stdout))
	end, { "-e", browser.script })
	if not task then
		reportDetectionError(browser.name, "Could not read " .. browser.appName .. " tabs")
		finish(nil)
		return
	end

	module.browserURLTask = task
	timeoutTimer = hs.timer.doAfter(config.browserQueryTimeoutSeconds, function()
		reportDetectionError(browser.name, "Timed out reading " .. browser.appName .. " tabs")
		if task:isRunning() then
			task:terminate()
		end
		finish(nil)
	end)
	if not task:start() then
		reportDetectionError(browser.name, "Could not read " .. browser.appName .. " tabs")
		finish(nil)
	end
end

refreshMeetingSource = function()
	if module.browserRefreshRunning then
		module.browserRefreshPending = true
		return
	end

	module.browserRefreshRunning = true
	local generation = module.browserRefreshGeneration or 0
	local function finishRefresh()
		module.browserRefreshRunning = false
		if module.browserRefreshPending then
			module.browserRefreshPending = false
			refreshMeetingSource()
		end
	end
	local activeBrowser = browsersByName[module.meetingSource]
	if activeBrowser and not browserOwnsInput(activeBrowser) then
		setMeetingSource(nil, {})
		activeBrowser = nil
	end

	local candidates = {}
	local seen = {}
	local function addCandidate(browser)
		if browser and not seen[browser.name] and browserOwnsInput(browser) then
			seen[browser.name] = true
			table.insert(candidates, browser)
		end
	end

	addCandidate(activeBrowser)
	local app = hs.application.frontmostApplication()
	local frontmostBrowser = app and browsers[app:bundleID()]
	addCandidate(frontmostBrowser)
	for _, browser in pairs(browsers) do
		addCandidate(browser)
	end

	local function checkCandidate(index)
		if module.browserRefreshGeneration ~= generation then
			finishRefresh()
			return
		end

		local browser = candidates[index]
		if not browser then
			setMeetingSource(nil, {})
			finishRefresh()
			return
		end

		browserMeetingURLs(browser, function(urls)
			if module.browserRefreshGeneration ~= generation then
				finishRefresh()
				return
			end
			if not browserOwnsInput(browser) then
				checkCandidate(index + 1)
				return
			end
			if urls == nil then
				if module.meetingSource == browser.name then
					finishRefresh()
					return
				end
				checkCandidate(index + 1)
				return
			end
			if #urls > 0 then
				setMeetingSource(browser.name, urls)
				finishRefresh()
				return
			end
			checkCandidate(index + 1)
		end)
	end

	checkCandidate(1)
end

local function updateActiveOwners(owners)
	local nextOwners = {}
	if type(owners) == "table" then
		for _, owner in ipairs(owners) do
			if type(owner) == "table" and type(owner.objectID) == "number" and type(owner.bundleID) == "string" then
				nextOwners[tostring(owner.objectID)] = owner.bundleID
			end
		end
	end
	activeOwners = nextOwners
	module.browserRefreshGeneration = (module.browserRefreshGeneration or 0) + 1
	updateBrowserPolling()

	if hasActiveOwner() then
		refreshMeetingSource()
	elseif module.meetingActive then
		setMeetingSource(nil, {})
	end
end

local function scheduleBrowserCheck()
	if not hasActiveOwner() then
		return
	end
	module.browserRefreshGeneration = (module.browserRefreshGeneration or 0) + 1

	if module.browserTimer then
		module.browserTimer:stop()
	end

	module.browserTimer = hs.timer.doAfter(0.3, function()
		module.browserTimer = nil
		refreshMeetingSource()
	end)
end

updateBrowserPolling = function()
	if hasActiveBrowserOwner() then
		if not module.browserPollTimer then
			module.browserPollTimer = hs.timer.doEvery(1, refreshMeetingSource)
		end
	elseif module.browserPollTimer then
		module.browserPollTimer:stop()
		module.browserPollTimer = nil
	end
end

local function elapsedTime()
	if not module.startedAt then
		return "00:00"
	end

	local elapsed = math.max(0, math.floor(hs.timer.secondsSinceEpoch() - module.startedAt))
	return string.format("%02d:%02d", math.floor(elapsed / 60), elapsed % 60)
end

local function stopDelayRemaining()
	if not module.stopDeadline then
		return 0
	end

	return math.max(0, math.ceil(module.stopDeadline - hs.timer.secondsSinceEpoch()))
end

local function stopDelayText()
	local remaining = stopDelayRemaining()
	return string.format("%02d:%02d", math.floor(remaining / 60), remaining % 60)
end

local function dismissStopPrompt()
	if module.stopPrompt then
		module.stopPrompt:delete(0.1)
		module.stopPrompt = nil
	end
end

local function dismissMeetingPrompt()
	if module.meetingPrompt then
		module.meetingPrompt:delete(0.1)
		module.meetingPrompt = nil
	end
	module.pendingPrompt = nil
end

local function updateStopPrompt()
	if module.stopPrompt and module.stopDeadline then
		module.stopPrompt[3].text = "Automatic stop in " .. stopDelayText() .. " unless you reconnect."
	end
end

local function showStopPrompt()
	if module.stopPrompt or module.state ~= "recording" or not module.stopDeadline or not module.menuBar then
		return
	end

	local iconFrame = module.menuBar:frame()
	if not iconFrame then
		return
	end

	local width = 360
	local height = 126
	local screenFrame = hs.screen.mainScreen():fullFrame()
	local x = iconFrame.x + iconFrame.w / 2 - width / 2
	x = math.max(screenFrame.x + 8, math.min(x, screenFrame.x + screenFrame.w - width - 8))
	local prompt = hs.canvas.new({
		x = x,
		y = iconFrame.y + iconFrame.h + 4,
		w = width,
		h = height,
	})
	prompt[1] = {
		type = "rectangle",
		action = "fill",
		fillColor = { white = 0.12, alpha = 0.98 },
		withShadow = true,
	}
	prompt[2] = {
		type = "text",
		frame = { x = 16, y = 12, w = 328, h = 22 },
		text = "Meeting ended",
		textColor = { white = 1 },
		textSize = 15,
	}
	prompt[3] = {
		type = "text",
		frame = { x = 16, y = 38, w = 328, h = 22 },
		text = "",
		textColor = { white = 0.82 },
		textSize = 12,
	}
	prompt[4] = {
		id = "keep",
		type = "rectangle",
		frame = { x = 16, y = 76, w = 158, h = 34 },
		action = "fill",
		fillColor = { white = 0.28 },
		trackMouseUp = true,
	}
	prompt[5] = {
		type = "text",
		frame = { x = 16, y = 84, w = 158, h = 20 },
		text = "Keep Recording",
		textAlignment = "center",
		textColor = { white = 1 },
		textSize = 12,
	}
	prompt[6] = {
		id = "stop",
		type = "rectangle",
		frame = { x = 186, y = 76, w = 158, h = 34 },
		action = "fill",
		fillColor = { red = 0.82, green = 0.16, blue = 0.16 },
		trackMouseUp = true,
	}
	prompt[7] = {
		type = "text",
		frame = { x = 186, y = 84, w = 158, h = 20 },
		text = "Stop Now",
		textAlignment = "center",
		textColor = { white = 1 },
		textSize = 12,
	}
	prompt:clickActivating(false)
	prompt:level("floating")
	prompt:mouseCallback(function(_, event, element)
		if event ~= "mouseUp" then
			return
		end
		if element == "keep" then
			cancelStopDelay()
		elseif element == "stop" then
			stopRecording("manual")
		end
	end)
	module.stopPrompt = prompt
	updateStopPrompt()
	prompt:show()
end

local function menuBarTitle(text)
	local mode = hs.screen.mainScreen():currentMode()
	local scale = mode and mode.scale or 1
	return hs.styledtext.new(text, {
		font = hs.styledtext.defaultFonts.menuBar,
		baselineOffset = -1 / scale,
	})
end

local function updateMenuBar()
	if module.state ~= "starting" and module.state ~= "recording" and module.state ~= "stopping" then
		dismissStopPrompt()
		if module.menuBar then
			module.menuBar:delete()
			module.menuBar = nil
		end
		return
	end

	if not module.menuBar then
		module.menuBar = hs.menubar.new(true, "meeting-recorder")
		if not module.menuBar then
			return
		end
		module.menuBar:setMenu(recordingMenu)
	end
	if module.state == "starting" then
		module.menuBar:setTitle(menuBarTitle("REC Starting…"))
		module.menuBar:setTooltip("Meeting recording is starting")
	elseif module.state == "stopping" then
		module.menuBar:setTitle(menuBarTitle("REC Stopping…"))
		module.menuBar:setTooltip("Meeting recording is stopping")
	elseif module.stopDeadline then
		module.menuBar:setTitle(menuBarTitle("● REC " .. elapsedTime()))
		module.menuBar:setTooltip("Waiting for reconnect; automatic stop in " .. stopDelayText())
		if module.stopPrompt then
			updateStopPrompt()
		else
			showStopPrompt()
		end
	else
		module.menuBar:setTitle(menuBarTitle("● REC " .. elapsedTime()))
		module.menuBar:setTooltip("Meeting recording in progress")
	end
end

local function stopDurationTimer()
	if module.durationTimer then
		module.durationTimer:stop()
		module.durationTimer = nil
	end
end

local function startDurationTimer()
	stopDurationTimer()
	module.durationTimer = hs.timer.doEvery(1, updateMenuBar)
end

local function stopStartTimeout()
	if module.startTimeoutTimer then
		module.startTimeoutTimer:stop()
		module.startTimeoutTimer = nil
	end
end

local function notifyFailure(message)
	module.failureNotification = hs.notify.new({
		title = "Meeting Recorder",
		informativeText = message,
	})
	module.failureNotification:send()
end

local function notifyStatus(message)
	module.statusNotification = hs.notify.new({
		title = "Meeting Recorder",
		informativeText = message,
	})
	module.statusNotification:send()
end

local function recorderError(stderr)
	return stderr:match("meeting%-recorder:%s*([^\n]+)")
		or stderr:match("([^\n]+)\n*$")
		or "Meeting recorder exited with an error"
end

local function fileName(path)
	return path and path:match("([^/]+)$") or nil
end

local function truncateUTF8(value, maximumBytes)
	if #value <= maximumBytes then
		return value
	end

	local offset = utf8.offset(value, 0, maximumBytes + 1)
	if offset then
		return value:sub(1, offset - 1)
	end
	return value
end

local function sanitizedEventTitle(title)
	if type(title) ~= "string" then
		return nil
	end

	title = title:gsub("[%z\1-\31/:\\]", " ")
	title = title:gsub("%s+", " "):match("^%s*(.-)%s*$")
	title = truncateUTF8(title, 180)
	if title == "" then
		return nil
	end
	return title
end

local function timestampOutputPath()
	return string.format(
		"%s/%s-%03d.mov",
		outputDirectory,
		os.date("%Y-%m-%d_%H-%M-%S"),
		math.floor(hs.timer.secondsSinceEpoch() * 1000) % 1000
	)
end

local function eventOutputPath(event)
	local title = event and sanitizedEventTitle(event.title)
	local startTimestamp = event and tonumber(event.startTimestamp)
	if not title or not startTimestamp then
		return timestampOutputPath()
	end

	local base = outputDirectory .. "/" .. os.date("%Y-%m-%d", startTimestamp) .. "_" .. title
	local path = base .. ".mov"
	local suffix = 2
	while hs.fs.attributes(path) do
		path = string.format("%s-%d.mov", base, suffix)
		suffix = suffix + 1
	end
	return path
end

local function eventFingerprint(event, urls)
	return table.concat({
		tostring(event.title or ""),
		tostring(event.startTimestamp or ""),
		tostring(event.endTimestamp or ""),
		table.concat(urls, "\0"),
	}, "\0")
end

local function singleValue(values)
	local result = nil
	for _, value in pairs(values) do
		if result then
			return nil, false
		end
		result = value
	end
	return result, result ~= nil
end

local function selectCalendarEvent(events, browserURLs)
	local browserURLSet = {}
	for _, url in ipairs(browserURLs or {}) do
		browserURLSet[url] = true
	end

	local exactMatches = {}
	local calendarEvents = {}
	for _, event in ipairs(events or {}) do
		if type(event) == "table" and type(event.title) == "string" then
			local urls = meetingURLs(event.urls)
			local fingerprint = eventFingerprint(event, urls)
			calendarEvents[fingerprint] = event
			for _, url in ipairs(urls) do
				if browserURLSet[url] then
					exactMatches[fingerprint] = event
					break
				end
			end
		end
	end

	local exactEvent, hasExactEvent = singleValue(exactMatches)
	if hasExactEvent then
		return exactEvent, nil
	end
	if next(exactMatches) then
		return nil, "Multiple matching Calendar events were found."
	end

	local calendarEvent, hasCalendarEvent = singleValue(calendarEvents)
	if hasCalendarEvent then
		return calendarEvent, nil
	end
	if next(calendarEvents) then
		return nil, "Multiple Calendar events overlap this time."
	end
	return nil, "No matching Calendar event was found."
end

local function promptForRecordingEvent(detectedAt, reason)
	local button, title = hs.dialog.textPrompt(
		"Meeting Recorder",
		(reason or "Calendar lookup failed.") .. " Enter a recording title.",
		"",
		"Use Title",
		"Cancel"
	)
	if button ~= "Use Title" then
		return nil
	end

	title = sanitizedEventTitle(title)
	if not title then
		notifyStatus("A recording title is required.")
		return nil
	end
	return {
		title = title,
		startTimestamp = detectedAt,
	}
end

local function nextCalendarRequestID()
	module.calendarRequestSequence = (module.calendarRequestSequence or 0) + 1
	return string.format("%.0f-%d", hs.timer.secondsSinceEpoch() * 1000, module.calendarRequestSequence)
end

local function nextRecorderRequestID()
	module.recorderRequestSequence = (module.recorderRequestSequence or 0) + 1
	return string.format("%.0f-%d", hs.timer.secondsSinceEpoch() * 1000, module.recorderRequestSequence)
end

local function queryCalendar(detectedAt, callback)
	local requestID = nextCalendarRequestID()
	local bufferSeconds = config.calendarEventBufferMinutes * 60
	local arguments = {
		"-W",
		"-n",
		"-g",
		"-a",
		config.calendarQueryAppPath,
		"--args",
		"--request-id",
		requestID,
		"--from",
		tostring(math.floor(detectedAt - bufferSeconds)),
		"--to",
		tostring(math.ceil(detectedAt + bufferSeconds)),
		"--authorization-timeout",
		tostring(config.calendarQueryTimeoutSeconds),
	}
	local completed = false
	local timeoutTimer
	local responseGraceTimer
	local task
	local function finish(events, errorMessage)
		if completed then
			return
		end
		completed = true
		module.calendarRequests[requestID] = nil
		if timeoutTimer then
			timeoutTimer:stop()
			timeoutTimer = nil
		end
		if responseGraceTimer then
			responseGraceTimer:stop()
			responseGraceTimer = nil
		end
		callback(events, errorMessage)
	end
	local function finishFromPayload(payload)
		if type(payload) ~= "table" then
			local message = "Calendar returned an invalid response."
			logger:w(message)
			finish({}, message)
			return
		end
		if payload.status == "ok" then
			finish(type(payload.events) == "table" and payload.events or {}, nil)
			return
		end

		local message = payload.message
		if payload.status == "denied" then
			message = "Calendar access is denied. Enable Calendar Event Query in System Settings > Privacy & Security > Calendars."
		elseif type(message) ~= "string" or message == "" then
			message = "Calendar lookup failed."
		end
		logger:w(message)
		finish({}, message)
	end

	module.calendarRequests[requestID] = finishFromPayload
	task = hs.task.new("/usr/bin/open", function(exitCode, _, stderr)
		module.calendarTasks[task] = nil
		if completed then
			return
		end
		responseGraceTimer = hs.timer.doAfter(0.5, function()
			responseGraceTimer = nil
			if completed then
				return
			end
			local message = (stderr or ""):match("([^\n]+)")
				or (exitCode ~= 0 and "Calendar lookup failed." or "Calendar returned no response.")
			logger:w(message)
			finish({}, message)
		end)
	end, arguments)
	if not task then
		local message = "Could not start Calendar lookup."
		logger:w(message)
		finish({}, message)
		return
	end

	module.calendarTasks = module.calendarTasks or {}
	module.calendarTasks[task] = true
	timeoutTimer = hs.timer.doAfter(config.calendarQueryTimeoutSeconds + 2, function()
		timeoutTimer = nil
		module.calendarTasks[task] = nil
		if task:isRunning() then
			task:terminate()
		end
		finish({}, "Calendar lookup timed out.")
	end)
	if not task:start() then
		module.calendarTasks[task] = nil
		local message = "Could not start Calendar lookup."
		logger:w(message)
		finish({}, message)
	end
end

local function openRecordingsDirectory()
	if module.openTask and module.openTask:isRunning() then
		return
	end

	local task
	task = hs.task.new("/usr/bin/open", function()
		if module.openTask == task then
			module.openTask = nil
		end
	end, { outputDirectory })
	module.openTask = task
	if not task or not task:start() then
		module.openTask = nil
		logger:e("Could not open recordings directory")
	end
end

local function recorderArguments(requestID, bundleID, outputPath)
	local arguments = {
		"-W",
		"-n",
		"-g",
		"-a",
		config.recorderAppPath,
		"--args",
		"--request-id",
		requestID,
	}
	local hammerspoon = hs.application.get("org.hammerspoon.Hammerspoon")
	if hammerspoon then
		table.insert(arguments, "--parent-pid")
		table.insert(arguments, tostring(hammerspoon:pid()))
	end
	local application = bundleID and hs.application.get(bundleID)
	local window = hs.window.focusedWindow()
	if application then
		window = application:focusedWindow() or application:mainWindow()
	end
	local screen = window and window:screen() or hs.screen.mainScreen()
	if screen then
		table.insert(arguments, "--display-id")
		table.insert(arguments, tostring(screen:id()))
	end
	if bundleID then
		table.insert(arguments, "--bundle-id")
		table.insert(arguments, bundleID)
	end
	table.insert(arguments, outputPath)
	return arguments
end

local function requestRecorderStop(requestID)
	if not requestID then
		return
	end
	hs.distributednotifications.post(
		config.recorderStopNotification,
		"org.hammerspoon.Hammerspoon",
		{ requestID = requestID }
	)
end

cancelStopDelay = function()
	if module.stopDelayTimer then
		module.stopDelayTimer:stop()
		module.stopDelayTimer = nil
	end
	module.stopDeadline = nil
	dismissStopPrompt()
	updateMenuBar()
end

local function startCaptureTimeout(task)
	stopStartTimeout()
	module.startTimeoutTimer = hs.timer.doAfter(config.startTimeoutSeconds, function()
		module.startTimeoutTimer = nil
		if module.task ~= task or module.state ~= "starting" then
			return
		end

		module.pendingFailure = "Recorder capture did not start within "
			.. tostring(config.startTimeoutSeconds)
			.. " seconds"
		stopRecording("failure")
	end)
end

local function beginStopDelay()
	if module.sessionType ~= "meeting" or not module.task or module.state == "stopping" or module.stopDeadline then
		return
	end

	module.stopDeadline = hs.timer.secondsSinceEpoch() + config.stopDelaySeconds
	module.stopDelayTimer = hs.timer.doAfter(config.stopDelaySeconds, function()
		module.stopDelayTimer = nil
		module.stopDeadline = nil
		dismissStopPrompt()
		if not module.meetingActive and module.sessionType == "meeting" then
			stopRecording("grace-timeout")
		end
	end)
	updateMenuBar()
	showStopPrompt()
end

startRecording = function(sessionType, event)
	if module.task then
		return
	end
	cancelStopDelay()
	dismissMeetingPrompt()

	local outputPath = eventOutputPath(event)
	local requestID = nextRecorderRequestID()
	local task
	local taskEnded = false
	local taskExitCode
	local taskStderr = ""
	local finalPayload
	local completionGraceTimer
	local completed = false
	local bundleID = sessionType == "meeting" and module.browserBundleID or nil
	local function completeTask()
		if completed or not taskEnded or not finalPayload then
			return
		end
		completed = true
		module.recorderRequests[requestID] = nil
		if completionGraceTimer then
			completionGraceTimer:stop()
			completionGraceTimer = nil
		end
		if module.task ~= task then
			return
		end

		local previousSessionType = module.sessionType
		local stopReason = module.stopReason
		local restartEvent = module.sessionEvent
		local restartMeeting = previousSessionType == "meeting"
			and module.state == "stopping"
			and module.meetingActive
			and (stopReason == "browser-switch" or stopReason == "grace-timeout")
		local pendingFailure = module.pendingFailure
		cancelStopDelay()
		stopStartTimeout()
		module.task = nil
		module.sessionType = nil
		module.sessionEvent = nil
		module.startedAt = nil
		module.captureStarted = false
		module.pendingFailure = nil
		module.recordingBundleID = nil
		module.recorderRequestID = nil
		module.stopReason = nil
		stopDurationTimer()

		if finalPayload.status == "finished" and not pendingFailure then
			module.state = "idle"
		else
			module.state = "error"
			module.lastError = pendingFailure
				or (type(finalPayload.message) == "string" and finalPayload.message ~= "" and finalPayload.message)
				or recorderError(taskStderr)
			logger:e(module.lastError)
			notifyFailure(module.lastError)
		end
		updateMenuBar()
		if restartMeeting then
			startRecording("meeting", restartEvent)
		end
	end
	local function handleRecorderState(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.status == "started" then
			if module.task == task and module.state == "starting" then
				module.captureStarted = true
				stopStartTimeout()
				module.state = "recording"
				module.startedAt = hs.timer.secondsSinceEpoch()
				startDurationTimer()
				updateMenuBar()
				showStopPrompt()
			elseif module.task == task and module.state == "stopping" then
				requestRecorderStop(requestID)
			end
			return
		end
		if payload.status == "finished" or payload.status == "error" then
			finalPayload = payload
			completeTask()
		end
	end

	task = hs.task.new("/usr/bin/open", function(exitCode, _, stderr)
		taskEnded = true
		taskExitCode = exitCode
		taskStderr = stderr or ""
		if finalPayload then
			completeTask()
			return
		end
		completionGraceTimer = hs.timer.doAfter(0.5, function()
			completionGraceTimer = nil
			if finalPayload then
				completeTask()
				return
			end
			local message = taskStderr:match("([^\n]+)")
				or (taskExitCode ~= 0 and "Could not launch Meeting Recorder." or "Meeting Recorder returned no final status.")
			finalPayload = { status = "error", message = message }
			completeTask()
		end)
	end, recorderArguments(requestID, bundleID, outputPath))

	module.recorderRequests[requestID] = handleRecorderState
	module.sessionType = sessionType
	module.sessionEvent = event
	module.state = "starting"
	module.currentPath = outputPath
	module.lastError = nil
	module.captureStarted = false
	module.pendingFailure = nil
	module.recordingBundleID = bundleID
	module.recorderRequestID = requestID
	module.stopReason = nil
	updateMenuBar()

	module.task = task
	if not task or not task:start() then
		completed = true
		module.recorderRequests[requestID] = nil
		module.task = nil
		module.sessionType = nil
		module.sessionEvent = nil
		module.captureStarted = false
		module.recordingBundleID = nil
		module.recorderRequestID = nil
		module.state = "error"
		module.lastError = "Could not start Meeting Recorder."
		logger:e(module.lastError)
		notifyFailure(module.lastError)
		updateMenuBar()
		return
	end
	startCaptureTimeout(task)
end

local function eventTimeText(event)
	if not event then
		return "A browser meeting is using your microphone."
	end

	local startTimestamp = tonumber(event.startTimestamp)
	local endTimestamp = tonumber(event.endTimestamp)
	if not startTimestamp or not endTimestamp then
		return event.title
	end
	return string.format("%s  %s–%s", event.title, os.date("%H:%M", startTimestamp), os.date("%H:%M", endTimestamp))
end

local function meetingPromptScreen(source)
	local browser = source and browsersByName[source]
	local application = browser and hs.application.get(browser.bundleID)
	local window = application and (application:focusedWindow() or application:mainWindow())
	return window and window:screen() or hs.screen.mainScreen()
end

local function showMeetingPrompt(source, key, generation, event, fallbackReason, detectedAt)
	if not module.meetingActive
		or module.meetingSource ~= source
		or module.meetingCandidateKey ~= key
		or module.meetingGeneration ~= generation
		or module.task
	then
		return
	end
	dismissMeetingPrompt()

	local width = 420
	local height = 132
	local screenFrame = meetingPromptScreen(source):fullFrame()
	local prompt = hs.canvas.new({
		x = screenFrame.x + (screenFrame.w - width) / 2,
		y = screenFrame.y + 34,
		w = width,
		h = height,
	})
	prompt[1] = {
		type = "rectangle",
		action = "fill",
		fillColor = { white = 0.12, alpha = 0.98 },
		withShadow = true,
	}
	prompt[2] = {
		type = "text",
		frame = { x = 16, y = 12, w = 388, h = 22 },
		text = "Meeting detected",
		textColor = { white = 1 },
		textSize = 15,
	}
	prompt[3] = {
		type = "text",
		frame = { x = 16, y = 39, w = 388, h = 22 },
		text = eventTimeText(event),
		textColor = { white = 0.82 },
		textSize = 12,
	}
	prompt[4] = {
		id = "ignore",
		type = "rectangle",
		frame = { x = 16, y = 82, w = 188, h = 34 },
		action = "fill",
		fillColor = { white = 0.28 },
		trackMouseUp = true,
	}
	prompt[5] = {
		type = "text",
		frame = { x = 16, y = 90, w = 188, h = 20 },
		text = "Not Now",
		textAlignment = "center",
		textColor = { white = 1 },
		textSize = 12,
	}
	prompt[6] = {
		id = "start",
		type = "rectangle",
		frame = { x = 216, y = 82, w = 188, h = 34 },
		action = "fill",
		fillColor = { red = 0.82, green = 0.16, blue = 0.16 },
		trackMouseUp = true,
	}
	prompt[7] = {
		type = "text",
		frame = { x = 216, y = 90, w = 188, h = 20 },
		text = "Start Recording",
		textAlignment = "center",
		textColor = { white = 1 },
		textSize = 12,
	}
	prompt:clickActivating(false)
	prompt:level("floating")
	prompt:mouseCallback(function(_, mouseEvent, element)
		if mouseEvent ~= "mouseUp" then
			return
		end

		local pending = module.pendingPrompt
		if not pending or pending.generation ~= generation then
			return
		end
		dismissMeetingPrompt()
		if element ~= "start" then
			module.handledGeneration = generation
			return
		end
		if not module.meetingActive
			or module.meetingCandidateKey ~= key
			or module.meetingGeneration ~= generation
			or module.task
		then
			return
		end

		local recordingEvent = event
		if not recordingEvent then
			recordingEvent = promptForRecordingEvent(detectedAt, fallbackReason)
		end
		if recordingEvent
			and module.meetingActive
			and module.meetingCandidateKey == key
			and module.meetingGeneration == generation
			and not module.task
		then
			module.handledGeneration = generation
			startRecording("meeting", recordingEvent)
		end
	end)
	module.pendingPrompt = { generation = generation, event = event }
	module.meetingPrompt = prompt
	prompt:show()
end

local function requestMeetingPrompt(source, key, generation)
	if module.task or module.manualStartPending or module.handledGeneration == generation then
		return
	end

	local detectedAt = hs.timer.secondsSinceEpoch()
	local browserURLs = module.meetingURLs
	queryCalendar(detectedAt, function(events, calendarError)
		if not module.meetingActive
			or module.meetingSource ~= source
			or module.meetingCandidateKey ~= key
			or module.meetingGeneration ~= generation
			or module.task
			or module.manualStartPending
			or module.handledGeneration == generation
		then
			return
		end

		local event, selectionError = selectCalendarEvent(events, browserURLs)
		showMeetingPrompt(source, key, generation, event, calendarError or selectionError, detectedAt)
	end)
end

local function requestManualStart()
	if module.task or module.manualStartPending then
		notifyStatus("A recording is already active or starting.")
		return
	end

	module.manualStartPending = true
	module.handledGeneration = module.meetingGeneration
	dismissMeetingPrompt()
	local detectedAt = hs.timer.secondsSinceEpoch()
	queryCalendar(detectedAt, function(events, calendarError)
		module.manualStartPending = false
		if module.task then
			return
		end

		local event, selectionError = selectCalendarEvent(events, {})
		if not event then
			event = promptForRecordingEvent(detectedAt, calendarError or selectionError)
			if not event then
				return
			end
		end
		startRecording("manual", event)
	end)
end

stopRecording = function(reason)
	if not module.task then
		return
	end

	cancelStopDelay()
	stopStartTimeout()
	module.stopReason = reason
	module.state = "stopping"
	stopDurationTimer()
	updateMenuBar()
	if module.recorderRequestID then
		requestRecorderStop(module.recorderRequestID)
	else
		module.task:terminate()
	end
end

recordingMenu = function()
	local status
	if module.state == "starting" then
		status = "Status: Starting"
	elseif module.state == "stopping" then
		status = "Status: Stopping"
	elseif module.stopDeadline then
		status = "Status: Waiting for reconnect (" .. stopDelayText() .. ")"
	else
		status = "Status: Recording (" .. elapsedTime() .. ")"
	end

	local menu = {
		{ title = status, disabled = true },
	}
	if module.currentPath then
		table.insert(menu, { title = "File: " .. fileName(module.currentPath), disabled = true })
	end
	table.insert(menu, { title = "-" })
	table.insert(menu, {
		title = "Stop Recording",
		fn = function()
			stopRecording("manual")
		end,
	})
	table.insert(menu, {
		title = "Open Recordings Folder",
		fn = openRecordingsDirectory,
	})
	return menu
end
updateMenuBar()

handleMeetingState = function(active, source, key, generation)
	local browser = source and browsersByName[source]
	local browserBundleID = browser and browser.bundleID or nil
	module.browserBundleID = browserBundleID
	if active then
		if module.sessionType == "meeting" then
			cancelStopDelay()
		end
		if module.sessionType == "meeting"
			and module.task
			and module.recordingBundleID
			and browserBundleID
			and module.recordingBundleID ~= browserBundleID
		then
			stopRecording("browser-switch")
			return
		end
		if module.pendingPrompt and module.pendingPrompt.generation ~= generation then
			dismissMeetingPrompt()
		end
		if not module.task then
			requestMeetingPrompt(source, key, generation)
		end
		return
	end

	dismissMeetingPrompt()
	module.handledGeneration = nil
	if module.sessionType == "meeting" then
		beginStopDelay()
	end
end

hs.urlevent.bind("meeting-recorder-start", requestManualStart)

module.calendarResponseWatcher = hs.distributednotifications.new(function(_, _, userInfo)
	if type(userInfo) ~= "table" or type(userInfo.requestID) ~= "string" then
		return
	end
	local request = module.calendarRequests[userInfo.requestID]
	if request then
		request(userInfo.payload)
	end
end, config.calendarResponseNotification)
module.calendarResponseWatcher:start()

module.recorderStateWatcher = hs.distributednotifications.new(function(_, _, userInfo)
	if type(userInfo) ~= "table" or type(userInfo.requestID) ~= "string" then
		return
	end
	local request = module.recorderRequests[userInfo.requestID]
	if request then
		request(userInfo)
	elseif userInfo.status == "started" then
		requestRecorderStop(userInfo.requestID)
	end
end, config.recorderStateNotification)
module.recorderStateWatcher:start()

local hammerspoon = hs.application.get("org.hammerspoon.Hammerspoon")
if hammerspoon then
	hs.distributednotifications.post(
		config.recorderStopNotification,
		"org.hammerspoon.Hammerspoon",
		{ parentPID = hammerspoon:pid() }
	)
end

module.audioProcessWatcher = hs.distributednotifications.new(function(_, _, userInfo)
	updateActiveOwners(userInfo and userInfo.owners)
end, "@stateNotification@")
module.audioProcessWatcher:start()

module.applicationWatcher = hs.application.watcher.new(function(_, event)
	if event == hs.application.watcher.activated then
		scheduleBrowserCheck()
	end
end)
module.applicationWatcher:start()

hs.distributednotifications.post(
	"@refreshNotification@",
	"org.hammerspoon.Hammerspoon"
)

return module
