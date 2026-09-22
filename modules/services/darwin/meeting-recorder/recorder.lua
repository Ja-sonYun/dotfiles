local config = hs.json.decode([==[@configJson@]==])
local module = {
	calendarRequests = {},
	meetingActive = false,
	calendarEvents = {},
	calendarWaiters = {},
	meetingEvents = {},
	notifiedEvents = {},
	pendingRecordings = {},
	recorderRequests = {},
	restoredStopTimers = {},
	state = "idle",
	task = nil,
	transcriptionProgress = 0,
	transcriptionQueue = {},
	failedTranscriptions = {},
	forcedTranscriptions = {},
	missingTranscripts = {},
}
local logging = require("logging")
local logger = logging.new("meeting-recorder", config.logPath)
local detectionLogger = logging.new("meeting-detection", config.logPath)
local transcriptionLogger = logging.new("transcription", config.logPath)
logger:i("module_starting", { transcription_enabled = config.transcriberPath ~= nil })
local outputDirectory = config.outputDirectory:gsub("/+$", "")
local pendingRecordingsSetting = "meeting-recorder.pending-recordings"
local transcriptionQueueSetting = "meeting-recorder.transcription-queue"
local forcedTranscriptionsSetting = "meeting-recorder.forced-transcriptions"

local browsers = {
	["com.apple.Safari"] = {
		name = "safari",
		ownerBundlePrefixes = {
			"com.apple.Safari",
			"com.apple.WebKit.",
		},
	},
	["com.google.Chrome"] = {
		name = "chrome",
		ownerBundlePrefixes = { "com.google.Chrome" },
	},
}
local browsersByName = {}
for bundleID, browser in pairs(browsers) do
	browser.bundleID = bundleID
	browsersByName[browser.name] = browser
end

local activeOwners = {}
local handleMeetingState
local refreshMeetingSource
local refreshCalendar
local cancelStopDelay
local startRecording
local stopRecording
local recordingMenu
local startNextTranscription
local requestMeetingPrompt
local refreshMissingTranscripts
local scheduleMissingRefresh

local function eventKey(event)
	return event.id .. "@" .. tostring(event.startTimestamp)
end

local function currentCalendarEvents()
	local now = hs.timer.secondsSinceEpoch()
	local events = {}
	local seen = {}
	for _, event in ipairs(module.calendarEvents) do
		if event.startTimestamp <= now and now < event.endTimestamp then
			local key = eventKey(event)
			if not seen[key] then
				seen[key] = true
				table.insert(events, event)
			end
		end
	end
	table.sort(events, function(left, right)
		if left.startTimestamp ~= right.startTimestamp then
			return left.startTimestamp < right.startTimestamp
		end
		return eventKey(left) < eventKey(right)
	end)
	return events
end

local function bundleMatchesBrowser(bundleID, browser)
	for _, prefix in ipairs(browser.ownerBundlePrefixes) do
		if bundleID:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function browserOwnsInput(browser)
	if not browser then
		return false
	end
	for _, bundleID in pairs(activeOwners) do
		if bundleMatchesBrowser(bundleID, browser) then
			return true
		end
	end
	return false
end

local function setMeetingSource(source, events)
	local keys = {}
	for _, event in ipairs(events) do
		table.insert(keys, eventKey(event))
	end
	local key = source and #keys > 0 and (source .. "\0" .. table.concat(keys, "\0")) or nil
	local active = key ~= nil
	if module.meetingCandidateKey ~= key then
		detectionLogger:i("meeting_state_changed", {
			previous_active = module.meetingActive,
			active = active,
			source = source,
			event_count = #events,
		})
		module.meetingGeneration = (module.meetingGeneration or 0) + 1
	end

	module.meetingActive = active
	module.meetingSource = active and source or nil
	module.meetingEvents = active and events or {}
	module.meetingCandidateKey = key
	handleMeetingState(active, module.meetingSource, key, module.meetingGeneration)
end

refreshMeetingSource = function()
	local events = currentCalendarEvents()
	if not next(activeOwners) then
		setMeetingSource(nil, {})
		return
	end
	local browser = browsers[module.recordingBundleID] or browsersByName[module.meetingSource]
	if not browserOwnsInput(browser) then
		local app = hs.application.frontmostApplication()
		browser = app and browsers[app:bundleID()]
	end
	if not browserOwnsInput(browser) then
		browser = nil
		for _, bundleID in ipairs({ "com.apple.Safari", "com.google.Chrome" }) do
			if browserOwnsInput(browsers[bundleID]) then
				browser = browsers[bundleID]
				break
			end
		end
	end
	setMeetingSource(browser and browser.name, events)
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
	local ownersChanged = false
	for id, bundle in pairs(nextOwners) do
		if activeOwners[id] ~= bundle then
			ownersChanged = true
		end
	end
	for id in pairs(activeOwners) do
		if not nextOwners[id] then
			ownersChanged = true
		end
	end
	if ownersChanged then
		detectionLogger:i("audio_owners_changed", { owners = nextOwners })
	end
	activeOwners = nextOwners
	refreshMeetingSource()
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

local panelUI = { sequence = 0 }
local presentPanel
local preparePanelUI

local function failPanelUI(view, message)
	if not rawequal(panelUI.view, view) then
		return
	end
	local panel = panelUI.current
	local controller = panelUI.controller
	if panelUI.closeTimer then
		panelUI.closeTimer:stop()
		panelUI.closeTimer = nil
	end
	panelUI.current = nil
	panelUI.displayed = nil
	panelUI.rendering = nil
	panelUI.closing = nil
	panelUI.ready = nil
	panelUI.reducedMotion = nil
	panelUI.view = nil
	panelUI.controller = nil
	controller:setCallback(nil)
	view:windowCallback(nil):navigationCallback(nil):delete()
	logger:e(message)
	if panel then
		panel.callback("error")
	end
end

local function recordingPanel(options, callback)
	if panelUI.current then
		panelUI.current:delete()
	end
	panelUI.sequence = panelUI.sequence + 1
	local panel = { id = panelUI.sequence, options = options, callback = callback }
	local screen = (options.screen or hs.screen.mainScreen()):frame()
	options.screen = nil
	local height = 330
	panel.frame = { x = screen.x + (screen.w - 420) / 2, y = screen.y + 34, w = 420, h = height + 8 }
	if options.events then
		local height = #options.events > 1 and 238 or 190
		panel.frame =
			{ x = screen.x + (screen.w - 360) / 2, y = screen.y + (screen.h - height) / 2, w = 360, h = height }
	end
	function panel:delete(nativeClosing)
		if panelUI.current ~= self then
			return
		end
		panelUI.current = nil
		panelUI.displayed = nil
		local view = panelUI.view
		if not panelUI.closing and view and (view:isVisible() or nativeClosing) then
			panelUI.closing = true
			if not nativeClosing then
				view:hide(panelUI.reducedMotion and 0 or 0.1)
			end
			panelUI.closeTimer = hs.timer.doEvery(0.02, function()
				if not rawequal(panelUI.view, view) then
					return
				end
				if not view:isVisible() then
					panelUI.closeTimer:stop()
					panelUI.closeTimer = nil
					panelUI.closing = nil
					presentPanel()
				end
			end)
		end
	end
	panelUI.current = panel
	preparePanelUI()
	presentPanel()
	return panel
end

presentPanel = function()
	local panel = panelUI.current
	if not panel or not panelUI.ready or panelUI.closing or panelUI.rendering or panelUI.displayed == panel then
		return
	end
	panelUI.rendering = panel
	local view = panelUI.view
	local data = hs.json.encode(panel.options):gsub("<", "\\u003c")
	view:evaluateJavaScript(string.format("window.renderPanel(%d, %s); true", panel.id, data), function(result, err)
		if not rawequal(panelUI.view, view) then
			return
		end
		panelUI.rendering = nil
		if panelUI.current ~= panel then
			presentPanel()
			return
		end
		if result ~= true then
			failPanelUI(view, "Could not render recording panel: " .. hs.inspect(err))
			return
		end
		panelUI.displayed = panel
		panelUI.view:allowTextEntry(panel.options.focus == true):frame(panel.frame):show():bringToFront(true)
		if panel.options.focus then
			hs.application.launchOrFocusByBundleID("org.hammerspoon.Hammerspoon")
		end
		panelUI.view:evaluateJavaScript(string.format("window.openPanel(%d)", panel.id))
	end)
end

preparePanelUI = function()
	if panelUI.view then
		return
	end
	local view
	panelUI.controller = hs.webview.usercontent.new("meetingRecorderPanel")
	panelUI.controller:setCallback(function(message)
		if not rawequal(panelUI.view, view) then
			return
		end
		local body = message.body
		if type(body) ~= "table" then
			return
		end
		if body.action == "motion" then
			panelUI.reducedMotion = body.reducedMotion == true
			return
		end
		local panel = panelUI.current
		if panel and body.id == panel.id and (body.action == "primary" or body.action == "secondary") then
			panelUI.reducedMotion = body.reducedMotion == true
			panel:delete()
			panel.callback(body.action, body.value)
		end
	end)
	view = hs.webview
		.new({ x = 0, y = 0, w = 420, h = 338 }, { privateBrowsing = true }, panelUI.controller)
		:windowStyle(0)
		:allowTextEntry(true)
		:transparent(true)
		:deleteOnClose(false)
		:windowCallback(function(action)
			if not rawequal(panelUI.view, view) then
				return
			end
			local panel = panelUI.displayed
			if action == "closing" and panel then
				panel:delete(true)
				panel.callback("secondary")
			end
		end)
		:navigationCallback(function(action, _, _, err)
			if not rawequal(panelUI.view, view) then
				return true
			end
			if action == "didFinishNavigation" then
				panelUI.ready = true
				presentPanel()
			elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
				failPanelUI(view, "Could not load recording panel: " .. hs.inspect(err))
				return true
			end
		end)
	panelUI.view = view
	view:html([=[
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; background: transparent; overflow: hidden; }
body { color: #f2f2f2; font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
main { height: calc(100% - 8px); padding: 24px; border: 1px solid #454545; border-radius: 18px; background: linear-gradient(150deg, #282828, #1f1f1f 65%); box-shadow: inset 0 1px 0 #ffffff0a; display: flex; flex-direction: column; opacity: 0; }
h1 { margin: 0; font-size: 20px; font-weight: 600; letter-spacing: -.4px; }
.description { margin: 10px 0 19px; color: #aaa; line-height: 1.5; }
form { display: flex; flex-direction: column; flex: 1; min-height: 0; }
.content { overflow: auto; padding: 3px; margin: -3px; }
label { display: block; margin-bottom: 8px; color: #d1d1d1; font-size: 12px; font-weight: 500; }
input[type="text"] { width: 100%; height: 43px; padding: 0 12px; border: 1px solid #4b4b4b; border-radius: 9px; color: #fff; background: #242424; font: inherit; outline: none; box-shadow: inset 0 1px 3px #00000020; transition: border-color 160ms ease, background 160ms ease, box-shadow 160ms ease; }
input[type="text"]::placeholder { color: #818181; }
input[type="text"]:hover { border-color: #707070; }
input[type="text"]:focus { border-color: #d6a0a3; background: #292627; box-shadow: 0 0 0 3px #d96a731a; }
footer { display: flex; justify-content: flex-end; gap: 10px; margin-top: auto; padding-top: 20px; }
button { height: 35px; padding: 0 15px; border: 1px solid #4b4b4b; border-radius: 8px; color: #eee; background: #343434; font: inherit; font-weight: 500; cursor: pointer; box-shadow: 0 2px 4px #00000020, inset 0 1px 0 #ffffff06; transition: background 150ms ease, border-color 150ms ease, box-shadow 150ms ease, transform 150ms ease; }
body:not(.compact) button:hover { background: #454545; border-color: #666; transform: translateY(-1px); box-shadow: 0 4px 8px #00000035; }
button:focus-visible { outline: 2px solid #edc2c5; outline-offset: 3px; }
button.primary { border-color: #dd5961; background: #ce4249; color: #fff; box-shadow: 0 2px 6px #9b202530, inset 0 1px 0 #ffffff15; }
body:not(.compact) button.primary:hover { background: #e0525a; border-color: #ef737a; box-shadow: 0 4px 12px #c82e3b35; }
button:active { transform: translateY(0) scale(.98); box-shadow: inset 0 2px 4px #00000025; }
body.compact { padding: 10px; user-select: none; }
.compact main { height: 100%; padding: 20px; background: linear-gradient(145deg, #303033, #212123); border-color: #ffffff20; box-shadow: 0 5px 12px #00000035, inset 0 1px #ffffff08; }
.heading { display: none; }
.compact .heading { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; color: #b5b5bb; font-size: 11px; font-weight: 600; letter-spacing: .5px; }
.heading::before { content: ''; width: 7px; height: 7px; border-radius: 50%; background: #f17b83; }
.compact h1 { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 17px; }
.compact .description { margin: 5px 0 0; font-size: 12px; }
.compact footer { gap: 8px; padding-top: 14px; }
.compact button { height: 34px; padding: 0 16px; border-radius: 9px; cursor: default; }
.compact button.primary { background: #bd424b; border-color: #ee717955; }
.compact select { width: 100%; margin-top: 12px; padding: 6px; color: #f4f4f5; background: #303033; border: 1px solid #ffffff35; border-radius: 6px; font: inherit; }
@media (prefers-reduced-motion: reduce) { input, button { transition: none; } body:not(.compact) button:hover, button:active { transform: none; } }
</style>
<main><div class="heading">MEETING DETECTED</div><h1></h1><p class="description"></p><form><div class="content"></div><footer><button type="button" id="secondary"></button><button type="submit" class="primary"></button></footer></form></main>
<script>
let options;
let presentationID;
let sent = true;
const panel = document.querySelector('main');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
let openingAnimation;
const content = document.querySelector('.content');
const primary = document.querySelector('.primary');
function add(tag, text, className, parent = content) {
    const element = document.createElement(tag);
    element.textContent = text || '';
    if (className) element.className = className;
    parent.appendChild(element);
    return element;
}
window.renderPanel = (id, data) => {
    options = data;
    presentationID = id;
    sent = false;
    if (openingAnimation) openingAnimation.cancel();
    openingAnimation = null;
    content.replaceChildren();
    content.removeAttribute('role');
    content.removeAttribute('aria-label');
    panel.querySelectorAll('button').forEach(element => element.disabled = false);
    document.body.classList.toggle('compact', Boolean(options.events));
    document.querySelector('h1').textContent = options.title;
    document.querySelector('h1').title = options.title;
    document.querySelector('.description').textContent = options.description;
    document.querySelector('#secondary').textContent = options.secondary;
    primary.textContent = options.primary;
    if (options.events) {
        if (options.events.length > 1) {
            const select = add('select');
            select.id = 'meeting';
            select.setAttribute('aria-label', 'Meeting to record');
            options.events.forEach(event => add('option', event.text, null, select).value = event.key);
        }
    } else {
        add('label', 'Title').htmlFor = 'title';
        const input = add('input');
        input.type = 'text'; input.id = 'title'; input.required = true;
        input.placeholder = 'e.g. Design sync'; input.autocomplete = 'off';
    }
    panel.style.opacity = '1';
    if (!reducedMotion.matches) {
        openingAnimation = panel.animate([
            { opacity: 0, transform: 'translateY(8px)' },
            { opacity: 1, transform: 'translateY(0)' }
        ], { duration: 180, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'both' });
        openingAnimation.pause();
    }
};
function send(action, value) {
    if (sent) return;
    sent = true;
    panel.querySelectorAll('button, input, select').forEach(element => element.disabled = true);
    window.webkit.messageHandlers.meetingRecorderPanel.postMessage({ id: presentationID, action, value, reducedMotion: reducedMotion.matches });
}
document.querySelector('#secondary').addEventListener('click', () => send('secondary'));
document.addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.preventDefault(); send('secondary'); }
});
document.querySelector('form').addEventListener('submit', event => {
    event.preventDefault();
    if (options.events) {
        const select = document.querySelector('#meeting');
        send('primary', select ? select.value : options.events[0].key);
        return;
    }
    const input = document.querySelector('#title');
    const value = input.value.trim();
    if (!value) { input.value = ''; input.reportValidity(); return; }
    send('primary', value);
});
window.openPanel = id => {
    if (id !== presentationID || sent) return;
    if (openingAnimation && !reducedMotion.matches) openingAnimation.play();
    if (options.focus) (content.querySelector('input') || primary).focus();
};
function updateMotion() {
    if (reducedMotion.matches && openingAnimation) openingAnimation.cancel();
    window.webkit.messageHandlers.meetingRecorderPanel.postMessage({ action: 'motion', reducedMotion: reducedMotion.matches });
}
reducedMotion.addEventListener('change', updateMotion);
updateMotion();
</script></html>
]=])
end

local function notificationActivated(notification)
	local activation = notification:activationType()
	return activation == hs.notify.activationTypes.contentsClicked
		or activation == hs.notify.activationTypes.actionButtonClicked
end

local function dismissStopPrompt()
	if module.stopPrompt then
		module.stopPrompt:withdraw()
		module.stopPrompt = nil
	end
end

local function dismissMeetingPrompt(releaseNotifiedEvents)
	if releaseNotifiedEvents and module.pendingPrompt and module.pendingPrompt.notifiedEventKeys then
		for _, key in ipairs(module.pendingPrompt.notifiedEventKeys) do
			module.notifiedEvents[key] = nil
		end
	end

	module.pendingPrompt = nil
	module.manualStartPending = nil
	if module.meetingPrompt then
		module.meetingPrompt:delete()
		module.meetingPrompt = nil
	end
end

local function dismissCalendarEndPrompt()
	if module.calendarEndNotification then
		module.calendarEndNotification:withdraw()
		module.calendarEndNotification = nil
	end
	if module.calendarEndChooser then
		local chooser = module.calendarEndChooser
		module.calendarEndChooser = nil
		chooser:hide()
	end
end

local function showStopPrompt()
	if module.stopPrompt or module.state ~= "recording" or not module.stopDeadline then
		return
	end

	local requestID = module.recorderRequestID
	module.stopPrompt = hs.notify
		.new(function(notification)
			if
				notificationActivated(notification)
				and module.recorderRequestID == requestID
				and module.stopDeadline
				and module.state == "recording"
			then
				stopRecording("manual")
			end
		end, {
			title = "Microphone no longer in use",
			subTitle = module.sessionEvent and module.sessionEvent.title or "Meeting recording",
			informativeText = "Recording stops after "
				.. tostring(config.stopDelaySeconds)
				.. " seconds unless you reconnect. Click to stop now.",
			hasActionButton = true,
			actionButtonTitle = "Stop Now",
			withdrawAfter = 0,
		})
		:send()
end

local function checkCalendarEnd()
	if module.sessionType ~= "meeting" or not module.task or module.state ~= "recording" then
		return
	end
	local event = module.sessionEvent
	for _, candidate in ipairs(module.calendarEvents) do
		if eventKey(candidate) == eventKey(event) then
			event = candidate
			module.sessionEvent = candidate
			break
		end
	end
	if module.calendarEndPrompted or hs.timer.secondsSinceEpoch() < event.endTimestamp then
		return
	end
	module.calendarEndPrompted = true

	local requestID = module.recorderRequestID
	module.calendarEndNotification = hs.notify
		.new(function(notification)
			if
				not notificationActivated(notification)
				or module.recorderRequestID ~= requestID
				or module.state ~= "recording"
				or module.calendarEndChooser
			then
				return
			end
			local chooser
			chooser = hs.chooser.new(function(choice)
				if module.calendarEndChooser ~= chooser then
					return
				end
				module.calendarEndChooser = nil
				if choice and choice.action == "stop" and module.recorderRequestID == requestID then
					stopRecording("manual")
				end
			end)
			module.calendarEndChooser = chooser
			chooser
				:choices({
					{
						text = "Stop recording",
						subText = event.title,
						action = "stop",
					},
					{
						text = "Continue recording",
						subText = event.title,
						action = "continue",
					},
				})
				:show()
		end, {
			title = "Meeting scheduled to end",
			subTitle = event.title,
			informativeText = "Click to stop or continue recording. Recording continues until you decide.",
			withdrawAfter = 0,
		})
		:send()
end

local statusIcons = {}
for _, name in ipairs({ "recording", "processing", "pending", "failed", "recording-processing" }) do
	statusIcons[name] = hs.image.imageFromPath(config.iconDirectory .. "/" .. name .. ".tiff")
end

local function updateMenuBar()
	local recordingActive = module.state == "starting" or module.state == "recording" or module.state == "stopping"
	local transcriptionActive = module.transcriptionPath ~= nil
	if not recordingActive then
		dismissStopPrompt()
	end
	local failedCount = 0
	for _, path in ipairs(module.transcriptionQueue) do
		if module.failedTranscriptions[path] then
			failedCount = failedCount + 1
		end
	end
	local icon = recordingActive and (transcriptionActive and "recording-processing" or "recording")
		or transcriptionActive and "processing"
		or failedCount > 0 and "failed"
		or (#module.transcriptionQueue > 0 or #module.missingTranscripts > 0) and "pending"
	if not icon then
		if module.menuBar then
			module.menuBar:delete()
			module.menuBar = nil
			module.menuBarIcon = nil
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

	local tooltips = {}
	if module.state == "starting" then
		table.insert(tooltips, "Meeting recording is starting")
	elseif module.state == "stopping" then
		table.insert(tooltips, "Meeting recording is stopping")
	elseif module.stopDeadline then
		table.insert(
			tooltips,
			"Recorded " .. elapsedTime() .. "; waiting for reconnect; automatic stop in " .. stopDelayText()
		)
		showStopPrompt()
	elseif module.state == "recording" then
		table.insert(tooltips, "Meeting recording: " .. elapsedTime())
	end

	if transcriptionActive then
		if module.transcriptionPhase == "preparing" then
			table.insert(tooltips, "Preparing local transcription")
		elseif module.transcriptionPhase == "archiving" then
			table.insert(tooltips, "Compressing meeting audio")
		else
			table.insert(
				tooltips,
				"Transcribing "
					.. (module.transcriptionPhase or "audio")
					.. ": "
					.. tostring(module.transcriptionProgress)
					.. "%"
			)
		end
	end

	if #module.transcriptionQueue > 0 then
		table.insert(
			tooltips,
			tostring(#module.transcriptionQueue - failedCount) .. " waiting; " .. tostring(failedCount) .. " failed"
		)
	end
	if #module.missingTranscripts > 0 then
		table.insert(tooltips, tostring(#module.missingTranscripts) .. " missing transcripts")
	end
	if module.menuBarIcon ~= icon then
		module.menuBar:setTitle(""):setIcon(statusIcons[icon], true)
		module.menuBarIcon = icon
	end
	module.menuBar:setTooltip(table.concat(tooltips, "; "))
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

local function setPendingRecording(requestID, recording)
	if not recording then
		local timer = module.restoredStopTimers[requestID]
		if timer then
			timer:stop()
			module.restoredStopTimers[requestID] = nil
		end
		local pending = module.pendingRecordings[requestID]
		if pending then
			os.remove(pending.statePath)
			os.remove(pending.statePath .. ".stop")
		end
	end
	module.pendingRecordings[requestID] = recording
	hs.settings.set(pendingRecordingsSetting, module.pendingRecordings)
	scheduleMissingRefresh()
end

local function restorePendingRecordings()
	local saved = hs.settings.get(pendingRecordingsSetting)
	if type(saved) ~= "table" then
		return
	end
	for requestID, recording in pairs(saved) do
		if
			type(requestID) == "string"
			and type(recording) == "table"
			and type(recording.path) == "string"
			and type(recording.statePath) == "string"
			and (recording.status == "pending" or recording.status == "finished" or recording.status == "error")
		then
			module.pendingRecordings[requestID] = recording
		end
	end
end

local function readRecordingState(requestID)
	local recording = module.pendingRecordings[requestID]
	if not recording or not hs.fs.attributes(recording.statePath) then
		return nil
	end
	local payload = hs.json.read(recording.statePath)
	if
		type(payload) == "table"
		and payload.requestID == requestID
		and (payload.status == "started" or payload.status == "finished" or payload.status == "error")
	then
		return payload
	end
	return nil
end

local function transcriptOutputPath(path)
	return path:gsub("%.[^./]+$", "") .. ".transcript.md"
end

local function transcriptExists(path)
	local markdownPath = transcriptOutputPath(path)
	return hs.fs.attributes(markdownPath, "mode") == "file"
		and hs.fs.attributes(markdownPath:gsub("%.md$", ".json"), "mode") == "file"
end

local function recordingPending(path)
	if path == module.currentPath then
		return true
	end
	for _, recording in pairs(module.pendingRecordings) do
		if recording.path == path then
			return true
		end
	end
	return false
end

local function transcriptionQueued(path)
	if path == module.transcriptionPath then
		return true
	end
	for _, queuedPath in ipairs(module.transcriptionQueue) do
		if queuedPath == path then
			return true
		end
	end
	return false
end

local function persistTranscriptionQueue()
	local pending = {}
	if module.transcriptionPath then
		table.insert(pending, module.transcriptionPath)
	end
	for _, path in ipairs(module.transcriptionQueue) do
		table.insert(pending, path)
	end
	hs.settings.set(transcriptionQueueSetting, pending)
	local forced = {}
	for _, path in ipairs(pending) do
		if module.forcedTranscriptions[path] then
			forced[path] = true
		end
	end
	hs.settings.set(forcedTranscriptionsSetting, forced)
	scheduleMissingRefresh()
end

local function restoreTranscriptionQueue()
	local saved = hs.settings.get(transcriptionQueueSetting)
	if type(saved) ~= "table" then
		logger:i("queue_restore_skipped", { reason = "no_saved_queue" })
		return
	end

	local seen = {}
	local forced = hs.settings.get(forcedTranscriptionsSetting)
	for _, path in ipairs(saved) do
		if type(path) == "string" and not seen[path] and hs.fs.attributes(path, "mode") == "file" then
			seen[path] = true
			module.forcedTranscriptions[path] = type(forced) == "table" and forced[path] == true or nil
			table.insert(module.transcriptionQueue, path)
			logger:i("queue_item_restored", { source = path })
		else
			logger:w("queue_restore_item_skipped", {
				source = type(path) == "string" and path or nil,
				reason = type(path) ~= "string" and "invalid_path" or seen[path] and "duplicate" or "missing_input",
			})
		end
	end
	persistTranscriptionQueue()
	logger:i("queue_restored", { queue_length = #module.transcriptionQueue })
end

local function transcriptionError(stderr)
	return stderr:match("archive%-audio:%s*([^\n]+)")
		or stderr:match("whisper:%s*([^\n]+)")
		or stderr:match("([^\n]+)\n*$")
		or "Local transcription exited with an error"
end

local function handleTranscriptionOutput(stdout, stderr)
	if (stdout and stdout ~= "") or (stderr and stderr ~= "") then
		module.transcriptionLastOutputAt = hs.timer.secondsSinceEpoch()
	end
	if stderr and stderr ~= "" then
		transcriptionLogger:e("process_stderr", { detail = stderr })
		module.transcriptionStderr = ((module.transcriptionStderr or "") .. stderr):sub(-8192)
	end
	if not stdout or stdout == "" then
		return
	end

	module.transcriptionOutputBuffer = (module.transcriptionOutputBuffer or "") .. stdout
	while true do
		local newline = module.transcriptionOutputBuffer:find("\n", 1, true)
		if not newline then
			return
		end
		local line = module.transcriptionOutputBuffer:sub(1, newline - 1):gsub("\r$", "")
		module.transcriptionOutputBuffer = module.transcriptionOutputBuffer:sub(newline + 1)
		local decoded, payload = pcall(hs.json.decode, line)
		if decoded and type(payload) == "table" then
			if payload.status == "diagnostic" then
				module.transcriptionStage = payload.stage
				transcriptionLogger:write(
					payload.level == "error" and "error" or "info",
					payload.event or "diagnostic",
					payload
				)
			elseif payload.status == "progress" and type(payload.progress) == "number" then
				local bucket = math.floor(payload.progress / 10)
				if module.transcriptionProgressBucket ~= bucket or module.transcriptionPhase ~= payload.phase then
					transcriptionLogger:i("progress", { phase = payload.phase, progress = payload.progress })
					module.transcriptionProgressBucket = bucket
				end
				module.transcriptionProgress = math.max(0, math.min(100, math.floor(payload.progress)))
				module.transcriptionPhase = payload.phase
				updateMenuBar()
			elseif payload.status == "finished" and type(payload.markdown_path) == "string" then
				module.transcriptionOutputPath = payload.markdown_path
				transcriptionLogger:i("result_received", {
					markdown_path = payload.markdown_path,
					json_path = payload.json_path,
				})
			end
		else
			transcriptionLogger:w("event_decode_failed", { bytes = #line })
		end
	end
end

startNextTranscription = function()
	if not config.transcriberPath or module.transcriptionTask or #module.transcriptionQueue == 0 then
		local reason = not config.transcriberPath and "disabled" or module.transcriptionTask and "running" or "empty"
		if module.queueWaitReason ~= reason then
			logger:i("queue_waiting", { reason = reason, queue_length = #module.transcriptionQueue })
			module.queueWaitReason = reason
		end
		return
	end

	local sourcePath
	local index = 1
	while index <= #module.transcriptionQueue and not sourcePath do
		local candidate = module.transcriptionQueue[index]
		if hs.fs.attributes(candidate, "mode") ~= "file" then
			logger:w("queue_item_removed", { source = candidate, reason = "missing_input" })
			table.remove(module.transcriptionQueue, index)
			module.failedTranscriptions[candidate] = nil
			module.forcedTranscriptions[candidate] = nil
		elseif module.failedTranscriptions[candidate] then
			logger:i("queue_item_skipped", { source = candidate, reason = "failed_this_session" })
			index = index + 1
		else
			table.remove(module.transcriptionQueue, index)
			sourcePath = candidate
		end
	end
	if not sourcePath then
		logger:i("queue_waiting", { reason = "no_retryable_items", queue_length = #module.transcriptionQueue })
		persistTranscriptionQueue()
		updateMenuBar()
		return
	end
	local archiveOnly = not module.forcedTranscriptions[sourcePath] and transcriptExists(sourcePath)
	module.transcriptionPath = sourcePath
	module.queueWaitReason = nil
	transcriptionLogger.context = { job_id = hs.host.uuid(), source = sourcePath }
	transcriptionLogger:i("queue_item_selected", {
		queue_length = #module.transcriptionQueue,
		input_bytes = hs.fs.attributes(sourcePath, "size"),
	})
	module.transcriptionOutputPath = nil
	persistTranscriptionQueue()

	local startPhase
	startPhase = function(archiving)
		module.transcriptionStartedAt = hs.timer.secondsSinceEpoch()
		module.transcriptionLastOutputAt = module.transcriptionStartedAt
		module.transcriptionStage = "launching"
		module.transcriptionProgressBucket = nil
		module.transcriptionProgress = 0
		module.transcriptionPhase = archiving and "archiving" or "preparing"
		module.transcriptionOutputBuffer = ""
		module.transcriptionStderr = ""
		local executable = archiving and config.archivePath or config.transcriberPath
		local arguments
		if archiving then
			arguments = { "--progress-json", sourcePath }
		else
			arguments = {
				"--track",
				"0:Remote",
				"--track",
				"1:You",
				"--suppress-echo",
				"1:0",
				"--format",
				"both",
				"--language",
				config.transcription.language,
				"--progress-json",
			}
			if config.transcription.model then
				table.insert(arguments, "--model")
				table.insert(arguments, config.transcription.model)
			end
			table.insert(arguments, sourcePath)
		end
		transcriptionLogger:i("process_start_requested", { executable = executable, arguments = arguments })
		local task
		task = hs.task.new(
			executable,
			transcriptionLogger:wrap("completion_callback_failed", function(exitCode, stdout, stderr)
				if module.transcriptionTask ~= task then
					return
				end
				handleTranscriptionOutput(stdout, stderr)
				if module.transcriptionHeartbeat then
					module.transcriptionHeartbeat:stop()
					module.transcriptionHeartbeat = nil
				end
				if module.transcriptionOutputBuffer ~= "" then
					transcriptionLogger:w("incomplete_event_at_exit", { bytes = #module.transcriptionOutputBuffer })
				end
				local outputPath = module.transcriptionOutputPath or transcriptOutputPath(sourcePath)
				local outputBytes = hs.fs.attributes(outputPath, "size")
				transcriptionLogger:write(exitCode == 0 and "info" or "error", "process_exited", {
					exit_code = exitCode,
					elapsed_seconds = hs.timer.secondsSinceEpoch() - module.transcriptionStartedAt,
					stage = module.transcriptionStage,
					phase = module.transcriptionPhase,
					progress = module.transcriptionProgress,
					output_exists = outputBytes ~= nil,
					output_bytes = outputBytes,
				})
				if exitCode == 0 and not transcriptExists(sourcePath) then
					transcriptionLogger:e("result_missing", { output = outputPath })
					exitCode = 1
					module.transcriptionStderr = "Transcript output is incomplete"
				end
				if exitCode == 0 and not archiving then
					module.forcedTranscriptions[sourcePath] = nil
					persistTranscriptionQueue()
					startPhase(true)
					return
				end
				local taskStderr = module.transcriptionStderr
				module.transcriptionTask = nil
				module.transcriptionPath = nil
				module.transcriptionPhase = nil
				module.transcriptionOutputBuffer = nil
				module.transcriptionOutputPath = nil
				module.transcriptionStderr = nil
				if exitCode == 0 then
					module.forcedTranscriptions[sourcePath] = nil
					notifyStatus("Transcript saved: " .. fileName(outputPath))
				else
					local message = transcriptionError(taskStderr)
					local prefix = archiving and "Audio compression failed: " or "Transcription failed: "
					module.failedTranscriptions[sourcePath] = prefix .. message
					table.insert(module.transcriptionQueue, sourcePath)
					transcriptionLogger:w(
						"requeued",
						{ retry = "deferred_until_reload", queue_length = #module.transcriptionQueue }
					)
					logger:e(message)
					notifyFailure(prefix .. message)
				end
				persistTranscriptionQueue()
				updateMenuBar()
				startNextTranscription()
			end),
			transcriptionLogger:wrap("stream_callback_failed", function(_, stdout, stderr)
				if module.transcriptionTask ~= task then
					return false
				end
				handleTranscriptionOutput(stdout, stderr)
				return true
			end),
			arguments
		)
		module.transcriptionTask = task
		updateMenuBar()
		if not task or not task:start() then
			transcriptionLogger:e("process_start_failed", { executable = executable, retry = "deferred_until_reload" })
			local message = archiving and "Could not start audio compression" or "Could not start local transcription"
			module.failedTranscriptions[sourcePath] = message
			table.insert(module.transcriptionQueue, sourcePath)
			module.transcriptionTask = nil
			module.transcriptionPath = nil
			module.transcriptionPhase = nil
			module.transcriptionOutputBuffer = nil
			module.transcriptionOutputPath = nil
			module.transcriptionStderr = nil
			persistTranscriptionQueue()
			logger:e(message)
			notifyFailure(message)
			updateMenuBar()
			startNextTranscription()
		else
			transcriptionLogger:i("process_started", { pid = task:pid() })
			module.transcriptionHeartbeat = hs.timer.doEvery(
				30,
				transcriptionLogger:wrap("heartbeat_failed", function()
					local now = hs.timer.secondsSinceEpoch()
					transcriptionLogger:i("process_waiting", {
						pid = task:pid(),
						running = task:isRunning(),
						stage = module.transcriptionStage,
						phase = module.transcriptionPhase,
						progress = module.transcriptionProgress,
						elapsed_seconds = now - module.transcriptionStartedAt,
						seconds_since_output = now - module.transcriptionLastOutputAt,
					})
				end)
			)
		end
	end
	startPhase(archiveOnly)
end

local function enqueueTranscription(path, force, deferStart)
	if not config.transcriberPath or not path then
		logger:i("enqueue_skipped", { reason = not path and "missing_path" or "disabled" })
		return false
	end
	if not force and transcriptExists(path) then
		logger:i("enqueue_skipped", { source = path, reason = "transcript_exists" })
		return false
	end
	if transcriptionQueued(path) then
		logger:i("enqueue_skipped", { source = path, reason = "already_queued_or_running" })
		return false
	end
	table.insert(module.transcriptionQueue, path)
	module.forcedTranscriptions[path] = force or nil
	logger:i("enqueued", { source = path, forced = force == true, queue_length = #module.transcriptionQueue })
	if not deferStart then
		persistTranscriptionQueue()
		updateMenuBar()
		startNextTranscription()
	end
	return true
end

local function removeQueuedTranscription(path)
	for index, queuedPath in ipairs(module.transcriptionQueue) do
		if queuedPath == path then
			table.remove(module.transcriptionQueue, index)
			module.failedTranscriptions[path] = nil
			module.forcedTranscriptions[path] = nil
			logger:i("queue_item_removed", { source = path, reason = "manual" })
			persistTranscriptionQueue()
			updateMenuBar()
			return
		end
	end
end

local function transcribeNext(path, force)
	if module.transcriptionPath == path then
		notifyStatus("This recording is already being transcribed.")
		return
	end
	if recordingPending(path) then
		notifyStatus("Wait for this recording to finish before transcribing it.")
		return
	end
	if hs.fs.attributes(path, "mode") ~= "file" then
		notifyFailure("Recording not found: " .. fileName(path))
		return
	end
	local queuedIndex
	for index, queuedPath in ipairs(module.transcriptionQueue) do
		if queuedPath == path then
			queuedIndex = index
			break
		end
	end
	if queuedIndex then
		module.failedTranscriptions[path] = nil
		module.forcedTranscriptions[path] = force or nil
	elseif enqueueTranscription(path, force, true) then
		queuedIndex = #module.transcriptionQueue
	else
		return
	end
	table.remove(module.transcriptionQueue, queuedIndex)
	table.insert(module.transcriptionQueue, 1, path)
	persistTranscriptionQueue()
	updateMenuBar()
	startNextTranscription()
end

local function startAllTranscriptions()
	module.failedTranscriptions = {}
	logger:i("queue_start_requested", { queue_length = #module.transcriptionQueue })
	startNextTranscription()
	updateMenuBar()
end

local function selectRecordingToTranscribe()
	local selected = hs.dialog.chooseFileOrFolder(
		"Select a recording to transcribe again, replacing any existing transcript.",
		outputDirectory,
		true,
		false,
		false,
		{ "mov" },
		true
	)
	if selected and selected[1] then
		transcribeNext(selected[1], true)
	end
end

local function missingTranscript(path)
	return hs.fs.attributes(path, "mode") == "file"
		and not recordingPending(path)
		and not transcriptionQueued(path)
		and not transcriptExists(path)
end

refreshMissingTranscripts = function()
	local paths = {}
	local scanned, scanError = pcall(function()
		if not config.transcriberPath or not hs.fs.attributes(outputDirectory, "mode") then
			return
		end
		for name in hs.fs.dir(outputDirectory) do
			local path = outputDirectory .. "/" .. name
			if name:lower():match("%.mov$") and missingTranscript(path) then
				table.insert(paths, path)
			end
		end
	end)
	if not scanned then
		logger:e("missing_transcript_scan_failed", { message = tostring(scanError) })
		return
	end
	table.sort(paths)
	if #paths ~= #module.missingTranscripts then
		logger:i("missing_transcript_count_changed", { count = #paths })
	end
	module.missingTranscripts = paths
	return paths
end

scheduleMissingRefresh = function()
	if module.missingRefreshTimer then
		return
	end
	module.missingRefreshTimer = hs.timer.doAfter(0.5, function()
		module.missingRefreshTimer = nil
		refreshMissingTranscripts()
		updateMenuBar()
	end)
end

local function showMissingTranscripts()
	if module.transcriptionSelection then
		module.transcriptionSelection:show():bringToFront(true)
		return
	end
	local paths = refreshMissingTranscripts()
	scheduleMissingRefresh()
	if not paths then
		notifyFailure("Could not read the recordings folder.")
		return
	end
	if #paths == 0 then
		notifyStatus("No recordings with missing transcripts outside the queue.")
		return
	end
	local names = {}
	for _, path in ipairs(paths) do
		table.insert(names, fileName(path))
	end
	local controller = hs.webview.usercontent.new("meetingRecorderTranscriptions")
	local view
	local function closeSelection()
		module.transcriptionSelection = nil
		controller:setCallback(nil)
		view:windowCallback(nil):delete()
	end
	controller:setCallback(logger:wrap("transcript_selection_failed", function(message)
		local body = message.body
		if module.transcriptionSelection ~= view or type(body) ~= "table" then
			return
		end
		if body.action == "cancel" then
			closeSelection()
		elseif body.action == "start" and type(body.indices) == "table" then
			local added = 0
			for _, index in ipairs(body.indices) do
				local path = type(index) == "number" and paths[index]
				if path and missingTranscript(path) and enqueueTranscription(path, false, true) then
					added = added + 1
				end
			end
			closeSelection()
			persistTranscriptionQueue()
			logger:i("selected_transcriptions_queued", { count = added })
			updateMenuBar()
			startNextTranscription()
			notifyStatus(tostring(added) .. " recordings added to the transcription queue.")
		end
	end))
	local screen = hs.screen.mainScreen():frame()
	view = hs.webview
		.new(
			{ x = screen.x + (screen.w - 560) / 2, y = screen.y + (screen.h - 500) / 2, w = 560, h = 500 },
			{ privateBrowsing = true },
			controller
		)
		:windowStyle({ "titled", "closable", "resizable" })
		:windowTitle("Missing Transcripts")
		:allowTextEntry(true)
		:deleteOnClose(true)
		:windowCallback(function(action)
			if action == "closing" and module.transcriptionSelection == view then
				module.transcriptionSelection = nil
				controller:setCallback(nil)
			end
		end)
	module.transcriptionSelection = view
	local html = [=[
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root { color-scheme: light dark; font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
* { box-sizing: border-box; }
body { margin: 0; padding: 22px; height: 100vh; display: flex; flex-direction: column; gap: 14px; }
h1 { margin: 0; font-size: 20px; }
p { margin: 0; opacity: .7; line-height: 1.5; }
.actions, footer { display: flex; align-items: center; gap: 10px; }
fieldset { margin: 0; padding: 0; border: 0; flex: 1; min-height: 0; overflow: auto; }
legend { padding: 0 0 10px; font-weight: 600; }
label { display: flex; gap: 10px; padding: 10px 4px; overflow-wrap: anywhere; cursor: pointer; }
input { flex-shrink: 0; }
button { font: inherit; padding: 7px 12px; cursor: pointer; }
button:disabled { cursor: default; }
footer { justify-content: flex-end; }
</style>
<h1>Missing Transcripts</h1>
<p>Select recordings to transcribe. They will run one at a time after the current task.</p>
<div class="actions"><button id="all">Select All</button><button id="none">Clear Selection</button></div>
<fieldset><legend></legend><div id="recordings"></div></fieldset>
<footer><button id="cancel">Cancel</button><button id="start" disabled>Start Selected (0)</button></footer>
<script>
const names = __RECORDINGS__;
const list = document.querySelector('#recordings');
const start = document.querySelector('#start');
document.querySelector('legend').textContent = `${names.length} recordings`;
names.forEach((name, index) => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox'; input.value = index + 1;
    const text = document.createElement('span'); text.textContent = name;
    label.append(input, text); list.append(label);
});
function selected() {
    return Array.from(list.querySelectorAll('input:checked'), input => Number(input.value));
}
function update() {
    const count = selected().length;
    start.textContent = `Start Selected (${count})`; start.disabled = count === 0;
}
list.addEventListener('change', update);
document.querySelector('#all').onclick = () => { list.querySelectorAll('input').forEach(input => input.checked = true); update(); };
document.querySelector('#none').onclick = () => { list.querySelectorAll('input').forEach(input => input.checked = false); update(); };
let sent = false;
function send(action) {
    if (sent) return;
    sent = true;
    document.querySelectorAll('button, input').forEach(element => element.disabled = true);
    window.webkit.messageHandlers.meetingRecorderTranscriptions.postMessage({ action, indices: selected() });
}
start.onclick = () => { if (selected().length) send('start'); };
document.querySelector('#cancel').onclick = () => send('cancel');
document.addEventListener('keydown', event => { if (event.key === 'Escape') send('cancel'); });
</script></html>
]=]
	local renderedHTML = html:gsub("__RECORDINGS__", function()
		return hs.json.encode(names):gsub("<", "\\u003c")
	end)
	view:html(renderedHTML):show():bringToFront(true)
	hs.application.launchOrFocusByBundleID("org.hammerspoon.Hammerspoon")
end

local function completeRestoredRecording(requestID)
	local recording = module.pendingRecordings[requestID]
	if recording.status == "pending" then
		local payload = readRecordingState(requestID)
		if not payload or payload.status == "started" then
			return
		end
		recording.status = payload.status
		recording.message = payload.message
		setPendingRecording(requestID, recording)
	end
	if recording.status == "finished" then
		logger:i("restored_recording_finished", { job_id = requestID, source = recording.path })
		enqueueTranscription(recording.path)
	elseif recording.status == "error" then
		local message = type(recording.message) == "string" and recording.message ~= "" and recording.message
			or "Recording failed"
		logger:e(message)
		notifyFailure(message)
	else
		return
	end
	setPendingRecording(requestID, nil)
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

	local base = outputDirectory .. "/" .. os.date("%Y-%m-%d", math.floor(startTimestamp)) .. "_" .. title
	local path = base .. ".mov"
	local suffix = 2
	while hs.fs.attributes(path) do
		path = string.format("%s-%d.mov", base, suffix)
		suffix = suffix + 1
	end
	return path
end

local function selectCalendarEvent(events)
	local selected
	local seen = {}
	for _, event in ipairs(events or {}) do
		local key = eventKey(event)
		if not seen[key] then
			if selected then
				return nil, "Multiple Calendar events overlap this time."
			end
			seen[key] = true
			selected = event
		end
	end
	return selected, selected == nil and "No matching Calendar event was found." or nil
end

local function promptForRecordingEvent(detectedAt, reason, pending, callback)
	module.pendingPrompt = pending
	module.meetingPrompt = recordingPanel({
		title = "Recording title",
		description = (reason or "Calendar lookup failed.") .. " Enter a title for this recording.",
		primary = "Start Recording",
		secondary = "Cancel",
		focus = true,
	}, function(action, value)
		if module.pendingPrompt ~= pending then
			return
		end
		module.meetingPrompt = nil
		module.pendingPrompt = nil
		local title = action == "primary" and sanitizedEventTitle(value)
		callback(title and { title = title, startTimestamp = detectedAt } or nil)
	end)
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
	table.insert(module.calendarWaiters, callback)
	if module.calendarQueryRunning then
		return
	end
	module.calendarQueryRunning = true
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
		module.calendarQueryRunning = false
		module.calendarEvents = not errorMessage and events or {}
		for _, event in ipairs(module.calendarEvents) do
			local key = eventKey(event)
			if module.notifiedEvents[key] then
				module.notifiedEvents[key] = event.endTimestamp
			end
		end
		local waiters = module.calendarWaiters
		module.calendarWaiters = {}
		for _, waiter in ipairs(waiters) do
			waiter(events, errorMessage)
		end
		refreshMeetingSource()
		if module.calendarRefreshPending then
			module.calendarRefreshPending = nil
			refreshCalendar()
		end
	end
	local function finishFromPayload(payload)
		if type(payload) ~= "table" then
			local message = "Calendar returned an invalid response."
			logger:w(message)
			finish({}, message)
			return
		end
		if payload.status == "ok" then
			local events = {}
			for _, event in ipairs(type(payload.events) == "table" and payload.events or {}) do
				if
					type(event) == "table"
					and type(event.id) == "string"
					and event.id ~= ""
					and type(event.title) == "string"
					and type(event.startTimestamp) == "number"
					and type(event.endTimestamp) == "number"
				then
					table.insert(events, event)
				end
			end
			finish(events, nil)
			return
		end

		local message = payload.message
		if payload.status == "denied" then
			message =
				"Calendar access is denied. Enable Calendar Event Query in System Settings > Privacy & Security > Calendars."
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

refreshCalendar = function()
	if module.calendarQueryRunning then
		module.calendarRefreshPending = true
		return
	end
	queryCalendar(hs.timer.secondsSinceEpoch(), function() end)
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

local function recorderArguments(requestID, bundleID, outputPath, statePath)
	local arguments = {
		"-W",
		"-n",
		"-g",
		"-a",
		config.recorderAppPath,
		"--args",
		"--request-id",
		requestID,
		"--state-path",
		statePath,
	}
	local hammerspoon = hs.application.get("org.hammerspoon.Hammerspoon")
	if hammerspoon then
		table.insert(arguments, "--parent-pid")
		table.insert(arguments, tostring(hammerspoon:pid()))
	end
	if bundleID then
		table.insert(arguments, "--bundle-id")
		table.insert(arguments, bundleID)
	else
		local window = hs.window.focusedWindow()
		local screen = window and window:screen() or hs.screen.mainScreen()
		if screen then
			table.insert(arguments, "--display-id")
			table.insert(arguments, tostring(screen:id()))
		end
	end
	table.insert(arguments, outputPath)
	return arguments
end

local function requestRecorderStop(requestID)
	if not requestID then
		return
	end
	local recording = module.pendingRecordings[requestID]
	if recording then
		local firstRequest = not recording.stopRequested
		if firstRequest then
			logger:i("recorder_stop_requested", { job_id = requestID })
			recording.stopRequested = true
			setPendingRecording(requestID, recording)
		end
		local stopPath = recording.statePath .. ".stop"
		if not hs.fs.attributes(stopPath) then
			local stopFile, message = io.open(stopPath, "w")
			if stopFile then
				stopFile:close()
			elseif firstRequest then
				logger:w("Could not save recorder stop request: " .. tostring(message))
			end
		end
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

		local request = module.recorderRequests[module.recorderRequestID]
		local payload = readRecordingState(module.recorderRequestID)
		if request and payload then
			request(payload)
			return
		end

		module.pendingFailure = "Recorder capture did not start within "
			.. tostring(config.startTimeoutSeconds)
			.. " seconds"
		logger:e(
			"capture_start_timeout",
			{ job_id = module.recorderRequestID, timeout_seconds = config.startTimeoutSeconds }
		)
		stopRecording("failure")
	end)
end

local function beginStopDelay()
	if module.sessionType ~= "meeting" or not module.task or module.state == "stopping" or module.stopDeadline then
		return
	end

	module.stopDeadline = hs.timer.secondsSinceEpoch() + config.stopDelaySeconds
	logger:i("stop_delay_started", { job_id = module.recorderRequestID, delay_seconds = config.stopDelaySeconds })
	module.stopDelayTimer = hs.timer.doAfter(config.stopDelaySeconds, function()
		module.stopDelayTimer = nil
		module.stopDeadline = nil
		dismissStopPrompt()
		if module.sessionType == "meeting" and not browserOwnsInput(browsers[module.recordingBundleID]) then
			stopRecording("grace-timeout")
		end
	end)
	updateMenuBar()
	showStopPrompt()
end

startRecording = function(sessionType, event)
	if module.task then
		logger:i("recording_start_skipped", { reason = "already_running", job_id = module.recorderRequestID })
		return
	end
	cancelStopDelay()
	dismissMeetingPrompt()

	local outputPath = eventOutputPath(event)
	local requestID = nextRecorderRequestID()
	local requestedAt = hs.timer.secondsSinceEpoch()
	local inputDevice = hs.audiodevice.defaultInputDevice()
	logger:i("recording_requested", {
		job_id = requestID,
		session_type = sessionType,
		source = outputPath,
		input_device = inputDevice and inputDevice:name(),
		input_available = inputDevice ~= nil,
	})
	local statePath = outputDirectory .. "/.meeting-recorder-" .. requestID .. ".json"
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

		local completedPath = module.currentPath
		local stopReason = module.stopReason
		local pendingFailure = module.pendingFailure
		logger:i("recording_completed", {
			job_id = requestID,
			status = finalPayload.status,
			exit_code = taskExitCode,
			stop_reason = stopReason,
			failure = pendingFailure,
			elapsed_seconds = hs.timer.secondsSinceEpoch() - requestedAt,
			source = completedPath,
			output_bytes = completedPath and hs.fs.attributes(completedPath, "size"),
			transcription_requested = finalPayload.status == "finished"
				and not pendingFailure
				and config.transcriberPath ~= nil,
		})
		cancelStopDelay()
		stopStartTimeout()
		module.task = nil
		module.sessionType = nil
		module.sessionEvent = nil
		module.calendarEndPrompted = nil
		dismissCalendarEndPrompt()
		module.startedAt = nil
		module.captureStarted = false
		module.currentPath = nil
		module.pendingFailure = nil
		module.recordingBundleID = nil
		module.recorderRequestID = nil
		module.stopReason = nil
		stopDurationTimer()

		if finalPayload.status == "finished" and not pendingFailure then
			module.state = "idle"
			enqueueTranscription(completedPath)
		else
			module.state = "error"
			module.lastError = pendingFailure
				or (type(finalPayload.message) == "string" and finalPayload.message ~= "" and finalPayload.message)
				or recorderError(taskStderr)
			logger:e(module.lastError)
			notifyFailure(module.lastError)
		end
		setPendingRecording(requestID, nil)
		updateMenuBar()
		refreshMeetingSource()
	end
	local function handleRecorderState(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.status == "started" then
			if taskEnded or finalPayload then
				return
			end
			if module.task == task and module.state == "starting" then
				logger:i(
					"capture_started",
					{ job_id = requestID, elapsed_seconds = hs.timer.secondsSinceEpoch() - requestedAt }
				)
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
			logger:write(payload.status == "error" and "error" or "info", "recorder_final_state", {
				job_id = requestID,
				status = payload.status,
				message = payload.message,
			})
			finalPayload = payload
			completeTask()
		end
	end

	task = hs.task.new("/usr/bin/open", function(exitCode, _, stderr)
		logger:write(exitCode == 0 and "info" or "error", "recorder_launcher_exited", {
			job_id = requestID,
			exit_code = exitCode,
			stderr = stderr,
		})
		taskEnded = true
		taskExitCode = exitCode
		taskStderr = stderr or ""
		handleRecorderState(readRecordingState(requestID))
		if finalPayload then
			completeTask()
			return
		end
		completionGraceTimer = hs.timer.doAfter(0.5, function()
			completionGraceTimer = nil
			handleRecorderState(readRecordingState(requestID))
			if finalPayload then
				completeTask()
				return
			end
			local message = taskStderr:match("([^\n]+)")
				or (
					taskExitCode ~= 0 and "Could not launch Meeting Recorder."
					or "Meeting Recorder returned no final status."
				)
			finalPayload = { status = "error", message = message }
			completeTask()
		end)
	end, recorderArguments(requestID, bundleID, outputPath, statePath))

	module.recorderRequests[requestID] = handleRecorderState
	setPendingRecording(requestID, { path = outputPath, statePath = statePath, status = "pending" })
	module.sessionType = sessionType
	module.sessionEvent = event
	module.calendarEndPrompted = nil
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
		logger:e("recorder_launch_failed", { job_id = requestID })
		taskEnded = true
		finalPayload = { status = "error", message = "Could not start Meeting Recorder." }
		completeTask()
		return
	end
	logger:i("recorder_launched", { job_id = requestID, pid = task:pid() })
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
	return string.format(
		"%s  %s–%s",
		event.title,
		os.date("%H:%M", math.floor(startTimestamp)),
		os.date("%H:%M", math.floor(endTimestamp))
	)
end

requestMeetingPrompt = function(source, key, generation)
	if module.task or module.manualStartPending or module.pendingPrompt then
		return
	end
	local candidates = {}
	for _, event in ipairs(module.meetingEvents) do
		if not module.notifiedEvents[eventKey(event)] then
			table.insert(candidates, event)
		end
	end
	if #candidates == 0 then
		return
	end

	local pending = {
		generation = generation,
		notifiedEventKeys = {},
	}
	module.pendingPrompt = pending
	local function isCurrentMeeting()
		return module.pendingPrompt == pending
			and module.meetingActive
			and module.meetingSource == source
			and module.meetingCandidateKey == key
			and module.meetingGeneration == generation
			and browserOwnsInput(browsersByName[source])
			and not module.task
			and not module.manualStartPending
	end
	local function record(selectedKey)
		if not isCurrentMeeting() then
			return
		end
		for _, event in ipairs(currentCalendarEvents()) do
			if eventKey(event) == selectedKey then
				startRecording("meeting", event)
				return
			end
		end
		dismissMeetingPrompt(true)
	end
	local choices = {}
	for _, event in ipairs(candidates) do
		local key = eventKey(event)
		table.insert(choices, {
			text = eventTimeText(event),
			key = key,
		})
		module.notifiedEvents[key] = event.endTimestamp
		table.insert(pending.notifiedEventKeys, key)
	end
	module.meetingPrompt = recordingPanel({
		title = #candidates == 1 and candidates[1].title or "Choose a meeting",
		description = #candidates == 1 and string.format(
			"%s–%s · Ready to record",
			os.date("%H:%M", math.floor(candidates[1].startTimestamp)),
			os.date("%H:%M", math.floor(candidates[1].endTimestamp))
		) or "Multiple Calendar events",
		primary = "Start Recording",
		secondary = "Dismiss",
		events = choices,
	}, function(action, selectedKey)
		if module.pendingPrompt ~= pending then
			return
		end
		module.meetingPrompt = nil
		if action == "primary" then
			record(selectedKey)
		else
			dismissMeetingPrompt()
		end
	end)
end

local function requestManualStart()
	if module.task or module.manualStartPending then
		notifyStatus("A recording is already active or starting.")
		return
	end

	dismissMeetingPrompt()
	local pending = { manual = true }
	module.pendingPrompt = pending
	module.manualStartPending = true
	local detectedAt = hs.timer.secondsSinceEpoch()
	queryCalendar(detectedAt, function(events, calendarError)
		if module.pendingPrompt ~= pending or not module.manualStartPending or module.task then
			return
		end

		local function record(eventToRecord)
			module.manualStartPending = nil
			module.pendingPrompt = nil
			if eventToRecord and not module.task then
				startRecording("manual", eventToRecord)
			end
		end
		local event, selectionError = selectCalendarEvent(events)
		if event then
			record(event)
		else
			promptForRecordingEvent(detectedAt, calendarError or selectionError, pending, record)
		end
	end)
end

stopRecording = function(reason)
	logger:i("recording_stop_decision", { job_id = module.recorderRequestID, reason = reason, state = module.state })
	dismissMeetingPrompt()
	module.manualStartPending = nil
	if not module.task then
		return
	end

	cancelStopDelay()
	dismissCalendarEndPrompt()
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
	refreshMissingTranscripts()
	scheduleMissingRefresh()
	local menu = {}
	local status
	if module.state == "starting" then
		status = "Status: Starting"
	elseif module.state == "stopping" then
		status = "Status: Stopping"
	elseif module.stopDeadline then
		status = "Status: Waiting for reconnect (" .. stopDelayText() .. ")"
	elseif module.state == "recording" then
		status = "Status: Recording (" .. elapsedTime() .. ")"
	end

	if status then
		table.insert(menu, { title = status, disabled = true })
		if module.currentPath then
			table.insert(menu, {
				title = "Recording: " .. fileName(module.currentPath),
				disabled = true,
			})
		end
	end
	if module.transcriptionPath then
		if #menu > 0 then
			table.insert(menu, { title = "-" })
		end
		local transcriptionStatus = "Transcription: " .. tostring(module.transcriptionProgress) .. "%"
		local fileStatus = "Transcribing: "
		if module.transcriptionPhase == "preparing" then
			transcriptionStatus = "Transcription: Preparing…"
		elseif module.transcriptionPhase == "archiving" then
			transcriptionStatus = "Audio: Compressing…"
			fileStatus = "Compressing: "
		elseif module.transcriptionPhase then
			transcriptionStatus = transcriptionStatus .. " (" .. module.transcriptionPhase .. ")"
		end
		table.insert(menu, { title = transcriptionStatus, disabled = true })
		table.insert(menu, {
			title = fileStatus .. fileName(module.transcriptionPath),
			disabled = true,
		})
		if module.transcriptionStage then
			table.insert(menu, { title = "Stage: " .. module.transcriptionStage, disabled = true })
		end
	end
	if #menu > 0 then
		table.insert(menu, { title = "-" })
	end
	if config.transcriberPath then
		local queueMenu = {
			{ title = "Start All Queue", disabled = #module.transcriptionQueue == 0, fn = startAllTranscriptions },
		}
		if #module.transcriptionQueue == 0 then
			table.insert(queueMenu, { title = "No waiting recordings", disabled = true })
		end
		for _, failed in ipairs({ false, true }) do
			local headingAdded = false
			for _, path in ipairs(module.transcriptionQueue) do
				local errorMessage = module.failedTranscriptions[path]
				if (errorMessage ~= nil) == failed then
					if not headingAdded then
						table.insert(queueMenu, { title = "-" })
						table.insert(queueMenu, { title = failed and "Failed" or "Waiting", disabled = true })
						headingAdded = true
					end
					local complete = transcriptExists(path)
					local actions = {
						{
							title = complete and "Archive Next" or failed and "Retry Next" or "Run Next",
							fn = function()
								transcribeNext(path, module.forcedTranscriptions[path] == true)
							end,
						},
					}
					if failed then
						table.insert(actions, {
							title = "Show Error",
							fn = function()
								local screen = hs.screen.mainScreen():frame()
								hs.dialog.alert(
									screen.x + 80,
									screen.y + 80,
									function() end,
									fileName(path),
									errorMessage,
									"OK",
									nil,
									"warning"
								)
							end,
						})
					end
					table.insert(actions, {
						title = "Remove from Queue",
						fn = function()
							removeQueuedTranscription(path)
						end,
					})
					table.insert(queueMenu, { title = fileName(path), menu = actions })
				end
			end
		end
		table.insert(
			menu,
			{ title = "Transcription Queue (" .. tostring(#module.transcriptionQueue) .. ")", menu = queueMenu }
		)
		table.insert(menu, {
			title = "Missing Transcripts (" .. tostring(#module.missingTranscripts) .. ")…",
			fn = showMissingTranscripts,
		})
		table.insert(menu, { title = "Transcribe Recording Again…", fn = selectRecordingToTranscribe })
		table.insert(menu, { title = "-" })
	end
	if module.task then
		table.insert(menu, {
			title = "Stop Recording",
			fn = function()
				stopRecording("manual")
			end,
		})
	else
		table.insert(
			menu,
			{ title = "Start Recording", disabled = module.manualStartPending == true, fn = requestManualStart }
		)
	end
	table.insert(menu, {
		title = "Open Recordings Folder",
		fn = openRecordingsDirectory,
	})
	return menu
end
restorePendingRecordings()
restoreTranscriptionQueue()
startNextTranscription()
refreshMissingTranscripts()
updateMenuBar()

handleMeetingState = function(active, source, key, generation)
	local browser = source and browsersByName[source]
	module.browserBundleID = browser and browser.bundleID or nil
	if module.sessionType == "meeting" and module.task then
		if browserOwnsInput(browsers[module.recordingBundleID]) then
			if module.stopDeadline then
				cancelStopDelay()
			end
		else
			beginStopDelay()
		end
		return
	end
	if module.pendingPrompt and module.pendingPrompt.manual then
		return
	end
	if module.pendingPrompt and module.pendingPrompt.generation ~= generation then
		dismissMeetingPrompt(true)
	end
	if active then
		requestMeetingPrompt(source, key, generation)
	else
		dismissMeetingPrompt(true)
	end
end

hs.urlevent.bind("meeting-recorder-start", logger:wrap("manual_start_failed", requestManualStart))

module.calendarResponseWatcher = hs.distributednotifications.new(
	logger:wrap("calendar_response_failed", function(_, _, userInfo)
		if type(userInfo) ~= "table" or type(userInfo.requestID) ~= "string" then
			return
		end
		local request = module.calendarRequests[userInfo.requestID]
		if request then
			request(userInfo.payload)
		end
	end),
	config.calendarResponseNotification
)
module.calendarResponseWatcher:start()

local function dispatchRecorderState(userInfo)
	if type(userInfo) ~= "table" or type(userInfo.requestID) ~= "string" then
		return
	end
	local request = module.recorderRequests[userInfo.requestID]
	local recording = module.pendingRecordings[userInfo.requestID]
	if recording and (userInfo.status == "finished" or userInfo.status == "error") then
		local pendingFailure = request and module.pendingFailure or nil
		recording.status = pendingFailure and "error" or userInfo.status
		recording.message = pendingFailure or (type(userInfo.message) == "string" and userInfo.message or nil)
		setPendingRecording(userInfo.requestID, recording)
	end
	if request then
		request(userInfo)
	elseif userInfo.status == "finished" or userInfo.status == "error" then
		if recording then
			completeRestoredRecording(userInfo.requestID)
		end
	elseif userInfo.status == "started" then
		requestRecorderStop(userInfo.requestID)
	end
end

module.recorderStateWatcher = hs.distributednotifications.new(
	logger:wrap("recorder_state_failed", function(_, _, userInfo)
		dispatchRecorderState(userInfo)
	end),
	config.recorderStateNotification
)
module.recorderStateWatcher:start()

local hammerspoon = hs.application.get("org.hammerspoon.Hammerspoon")
if hammerspoon then
	hs.distributednotifications.post(
		config.recorderStopNotification,
		"org.hammerspoon.Hammerspoon",
		{ parentPID = hammerspoon:pid() }
	)
end

local function pollRecorderStates()
	local now = hs.timer.secondsSinceEpoch()
	for key, endedAt in pairs(module.notifiedEvents) do
		if endedAt <= now then
			module.notifiedEvents[key] = nil
		end
	end
	refreshMeetingSource()
	checkCalendarEnd()
	local requestIDs = {}
	for requestID in pairs(module.pendingRecordings) do
		table.insert(requestIDs, requestID)
	end
	for _, requestID in ipairs(requestIDs) do
		if module.recorderRequests[requestID] then
			dispatchRecorderState(readRecordingState(requestID))
		elseif module.pendingRecordings[requestID] then
			completeRestoredRecording(requestID)
		end
		local recording = module.pendingRecordings[requestID]
		if recording and (recording.stopRequested or not module.recorderRequests[requestID]) then
			requestRecorderStop(requestID)
			if not module.recorderRequests[requestID] and not module.restoredStopTimers[requestID] then
				module.restoredStopTimers[requestID] = hs.timer.doAfter(45, function()
					module.restoredStopTimers[requestID] = nil
					completeRestoredRecording(requestID)
					local pending = module.pendingRecordings[requestID]
					if not pending then
						return
					end
					module.pendingRecordings[requestID] = nil
					hs.settings.set(pendingRecordingsSetting, module.pendingRecordings)
					scheduleMissingRefresh()
					local message = "Timed out waiting for restored recording to stop: " .. fileName(pending.path)
					logger:e(message)
					notifyFailure(message)
				end)
			end
		end
	end
end
module.recorderPollTimer = hs.timer.doEvery(1, logger:wrap("recorder_poll_failed", pollRecorderStates))
pollRecorderStates()

if config.transcriberPath then
	local watchDirectory = outputDirectory:match("^(.*)/[^/]+$")
	while watchDirectory and hs.fs.attributes(watchDirectory, "mode") ~= "directory" do
		watchDirectory = watchDirectory:match("^(.*)/[^/]+$")
	end
	module.recordingsWatcher = hs.pathwatcher
		.new(watchDirectory ~= "" and watchDirectory or "/", function(paths)
			for _, path in ipairs(paths) do
				path = path:gsub("/+$", "")
				local name = path:sub(#outputDirectory + 2)
				if
					path == outputDirectory
					or outputDirectory:sub(1, #path + 1) == path .. "/"
					or (
						path:sub(1, #outputDirectory + 1) == outputDirectory .. "/"
						and not name:find("/", 1, true)
						and (name:lower():match("%.mov$") or name:match("%.transcript%.json$") or name:match(
							"%.transcript%.md$"
						))
						and not recordingPending(path)
					)
				then
					scheduleMissingRefresh()
					return
				end
			end
		end)
		:start()
end

module.audioProcessWatcher = hs.distributednotifications.new(
	detectionLogger:wrap("audio_event_failed", function(_, _, userInfo)
		updateActiveOwners(userInfo and userInfo.owners)
	end),
	"@stateNotification@"
)
module.audioProcessWatcher:start()

module.calendarRefreshTimer = hs.timer.doEvery(60, logger:wrap("calendar_refresh_failed", refreshCalendar))
module.wakeWatcher = hs.caffeinate.watcher.new(logger:wrap("wake_refresh_failed", function(event)
	if event == hs.caffeinate.watcher.systemDidWake then
		module.calendarEvents = {}
		refreshMeetingSource()
		refreshCalendar()
		hs.distributednotifications.post("@refreshNotification@", "org.hammerspoon.Hammerspoon")
	end
end))
module.wakeWatcher:start()
refreshCalendar()
hs.distributednotifications.post("@refreshNotification@", "org.hammerspoon.Hammerspoon")

logger:i("module_started", { recorder_poll_seconds = 1, queue_length = #module.transcriptionQueue })

return module
