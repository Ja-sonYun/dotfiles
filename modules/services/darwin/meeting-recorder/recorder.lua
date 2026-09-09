local config = hs.json.decode([==[@configJson@]==])
local module = {
	calendarRequests = {},
	meetingActive = false,
	meetingURLs = {},
	pendingRecordings = {},
	recorderRequests = {},
	restoredStopTimers = {},
	state = "idle",
	task = nil,
	transcriptionProgress = 0,
	transcriptionQueue = {},
	failedTranscriptions = {},
}
local logger = hs.logger.new("meeting-recorder")
local detectionLogger = hs.logger.new("meeting-detection")
local outputDirectory = config.outputDirectory:gsub("/+$", "")
local pendingRecordingsSetting = "meeting-recorder.pending-recordings"
local transcriptionQueueSetting = "meeting-recorder.transcription-queue"

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
local startNextTranscription
local requestMeetingPrompt

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

local function sessionMatchesMeeting()
	if #module.meetingURLs > 1 and module.sessionMeetingGeneration ~= module.meetingGeneration then
		return false
	end
	for _, currentURL in ipairs(module.meetingURLs) do
		if module.sessionMeetingURL == currentURL then
			return true
		end
	end
	return false
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
	local height = options.mode == "selection" and 400 or 330
	panel.frame = { x = screen.x + (screen.w - 420) / 2, y = screen.y + 34, w = 420, h = height + 8 }
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
	function panel:updateCountdown(remaining, maximum)
		self.options.remaining = remaining
		self.options.maximum = maximum
		if panelUI.current == self and panelUI.displayed == self then
			panelUI.view:evaluateJavaScript(
				string.format("window.updateCountdown(%d, %d, %d)", self.id, remaining, maximum)
			)
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
	if panel.options.mode == "ended" then
		panel.options.remaining = stopDelayRemaining()
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
		panelUI.view:frame(panel.frame):show():bringToFront(true)
		if panel.options.focus then
			hs.application.launchOrFocusByBundleID("org.hammerspoon.Hammerspoon")
		end
		if panel.options.mode == "ended" then
			panel:updateCountdown(stopDelayRemaining(), panel.options.maximum)
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
.event, .option { padding: 13px; border: 1px solid #434343; border-radius: 10px; background: #ffffff04; overflow-wrap: anywhere; }
.event strong { font-weight: 500; }
.url { color: #bb9397; font-size: 11px; line-height: 1.5; margin-top: 7px; }
.option { display: flex; gap: 10px; align-items: center; cursor: pointer; transition: background 150ms ease, border-color 150ms ease; }
.option:hover { background: #ffffff09; border-color: #777; }
.option:has(input:checked) { background: #ce42490d; border-color: #a36267; }
.option:focus-within { outline: 2px solid #edc2c5; outline-offset: 1px; }
input[type="radio"] { margin: 0; accent-color: #dd6770; flex-shrink: 0; }
.countdown { margin-top: 15px; color: #e99a9f; font-size: 12px; font-variant-numeric: tabular-nums; }
progress { width: 100%; height: 4px; border: none; margin-top: 10px; accent-color: #ce4249; }
progress::-webkit-progress-bar { background: #3e3334; border-radius: 3px; }
progress::-webkit-progress-value { background: #ce4249; border-radius: 3px; }
footer { display: flex; justify-content: flex-end; gap: 10px; margin-top: auto; padding-top: 20px; }
button { height: 35px; padding: 0 15px; border: 1px solid #4b4b4b; border-radius: 8px; color: #eee; background: #343434; font: inherit; font-weight: 500; cursor: pointer; box-shadow: 0 2px 4px #00000020, inset 0 1px 0 #ffffff06; transition: background 150ms ease, border-color 150ms ease, box-shadow 150ms ease, transform 150ms ease; }
button:hover { background: #454545; border-color: #666; transform: translateY(-1px); box-shadow: 0 4px 8px #00000035; }
button:focus-visible { outline: 2px solid #edc2c5; outline-offset: 3px; }
button.primary { border-color: #dd5961; background: #ce4249; color: #fff; box-shadow: 0 2px 6px #9b202530, inset 0 1px 0 #ffffff15; }
button.primary:hover { background: #e0525a; border-color: #ef737a; box-shadow: 0 4px 12px #c82e3b35; }
button:active { transform: translateY(0) scale(.98); box-shadow: inset 0 2px 4px #00000025; }
@media (prefers-reduced-motion: reduce) { input, button, .option { transition: none; } button:hover, button:active { transform: none; } }
</style>
<main><h1></h1><p class="description"></p><form><div class="content"></div><footer><button type="button" id="secondary"></button><button type="submit" class="primary"></button></footer></form></main>
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
    document.querySelector('h1').textContent = options.title;
    document.querySelector('.description').textContent = options.description;
    document.querySelector('#secondary').textContent = options.secondary;
    primary.textContent = options.primary;
    if (options.mode === 'title') {
        add('label', 'Title').htmlFor = 'title';
        const input = add('input');
        input.type = 'text'; input.id = 'title'; input.required = true;
        input.placeholder = 'e.g. Design sync'; input.autocomplete = 'off';
    } else if (options.mode === 'selection') {
        content.setAttribute('role', 'radiogroup');
        content.setAttribute('aria-label', 'Meetings');
        options.urls.forEach((url, index) => {
            const label = add('label', '', 'option');
            const input = add('input', '', '', label);
            input.type = 'radio'; input.name = 'meeting'; input.value = index + 1; input.checked = index === 0;
            add('span', url, '', label);
        });
    } else {
        const event = add('div', '', 'event');
        add('strong', options.eventText, '', event);
        if (options.url) add('div', options.url, 'url', event);
    }
    if (options.mode === 'ended') window.updateCountdown(id, options.remaining, options.maximum);
    panel.style.opacity = '1';
    if (!reducedMotion.matches) {
        openingAnimation = panel.animate([
            { opacity: 0, transform: 'translateY(8px)' },
            { opacity: 1, transform: 'translateY(0)' }
        ], { duration: 180, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'both' });
        openingAnimation.pause();
    }
};
window.updateCountdown = (id, remaining, maximum) => {
    if (id !== presentationID || options.mode !== 'ended') return;
    let label = document.querySelector('.countdown');
    let progress = document.querySelector('progress');
    if (!label) { label = add('div', '', 'countdown'); progress = add('progress'); progress.setAttribute('aria-label', 'Seconds until automatic stop'); }
    label.textContent = `Automatic stop in ${remaining}s unless you reconnect.`;
    progress.max = Math.max(1, maximum); progress.value = remaining;
};
function send(action, value) {
    if (sent) return;
    sent = true;
    panel.querySelectorAll('button, input').forEach(element => element.disabled = true);
    window.webkit.messageHandlers.meetingRecorderPanel.postMessage({ id: presentationID, action, value, reducedMotion: reducedMotion.matches });
}
document.querySelector('#secondary').addEventListener('click', () => send('secondary'));
document.addEventListener('keydown', event => {
    if (event.key === 'Escape') { event.preventDefault(); send('secondary'); }
    if (event.key === 'Enter' && event.target.matches('input[type="radio"]')) {
        event.preventDefault(); document.querySelector('form').requestSubmit();
    }
});
document.querySelector('form').addEventListener('submit', event => {
    event.preventDefault();
    let value;
    if (options.mode === 'title') {
        const input = document.querySelector('#title'); value = input.value.trim();
        if (!value) { input.value = ''; input.reportValidity(); return; }
    }
    if (options.mode === 'selection') value = Number(document.querySelector('input:checked').value);
    send('primary', value);
});
window.openPanel = id => {
    if (id !== presentationID || sent) return;
    if (openingAnimation && !reducedMotion.matches) openingAnimation.play();
    (content.querySelector('input') || primary).focus();
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

local function dismissStopPrompt()
	if module.stopPrompt then
		module.stopPrompt:delete()
		module.stopPrompt = nil
	end
end

local function dismissMeetingPrompt()
	if module.meetingPrompt then
		module.meetingPrompt:delete()
		module.meetingPrompt = nil
	end
	if module.pendingPrompt and module.pendingPrompt.manual then
		module.manualStartPending = nil
	end
	module.pendingPrompt = nil
end

local function updateStopPrompt()
	if module.stopPrompt and module.stopDeadline then
		module.stopPrompt:updateCountdown(stopDelayRemaining(), config.stopDelaySeconds)
	end
end

local function showStopPrompt()
	if module.stopPrompt or module.state ~= "recording" or not module.stopDeadline or not module.menuBar then
		return
	end

	module.stopPrompt = recordingPanel({
		mode = "ended",
		title = "Meeting ended",
		description = "The meeting is no longer using your microphone.",
		eventText = module.sessionEvent and module.sessionEvent.title or "Meeting recording",
		url = module.sessionMeetingURL,
		remaining = stopDelayRemaining(),
		maximum = config.stopDelaySeconds,
		primary = "Stop Now",
		secondary = "Keep Recording",
	}, function(action)
		if action == "error" then
			return
		end
		module.stopPrompt = nil
		if action == "primary" then
			stopRecording("manual")
		elseif action == "secondary" then
			cancelStopDelay()
		end
	end)
end

local function menuBarTitle(text)
	return hs.styledtext.new(text, {
		font = hs.styledtext.defaultFonts.menuBar,
	})
end

local function updateMenuBar()
	local recordingActive = module.state == "starting" or module.state == "recording" or module.state == "stopping"
	local transcriptionActive = module.transcriptionPath ~= nil
	if not recordingActive then
		dismissStopPrompt()
	end
	if not recordingActive and not transcriptionActive then
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

	local titles = {}
	local tooltips = {}
	if module.state == "starting" then
		table.insert(titles, "REC Starting…")
		table.insert(tooltips, "Meeting recording is starting")
	elseif module.state == "stopping" then
		table.insert(titles, "REC Stopping…")
		table.insert(tooltips, "Meeting recording is stopping")
	elseif module.stopDeadline then
		table.insert(titles, "● REC " .. elapsedTime())
		table.insert(tooltips, "Waiting for reconnect; automatic stop in " .. stopDelayText())
		if module.stopPrompt then
			updateStopPrompt()
		else
			showStopPrompt()
		end
	elseif module.state == "recording" then
		table.insert(titles, "● REC " .. elapsedTime())
		table.insert(tooltips, "Meeting recording in progress")
	end

	if transcriptionActive then
		if module.transcriptionPhase == "preparing" then
			table.insert(titles, "TXT Preparing…")
			table.insert(tooltips, "Preparing local transcription")
		elseif module.transcriptionPhase == "archiving" then
			table.insert(titles, "Compressing…")
			table.insert(tooltips, "Compressing meeting audio")
		else
			table.insert(titles, "TXT " .. tostring(module.transcriptionProgress) .. "%")
			table.insert(tooltips, "Transcribing " .. (module.transcriptionPhase or "audio") .. " locally")
		end
	end

	module.menuBar:setTitle(menuBarTitle(table.concat(titles, " · ")))
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

local function persistTranscriptionQueue()
	local pending = {}
	if module.transcriptionPath then
		table.insert(pending, module.transcriptionPath)
	end
	for _, path in ipairs(module.transcriptionQueue) do
		table.insert(pending, path)
	end
	hs.settings.set(transcriptionQueueSetting, pending)
end

local function restoreTranscriptionQueue()
	local saved = hs.settings.get(transcriptionQueueSetting)
	if type(saved) ~= "table" then
		return
	end

	local seen = {}
	for _, path in ipairs(saved) do
		if type(path) == "string" and not seen[path] and hs.fs.attributes(path) then
			seen[path] = true
			table.insert(module.transcriptionQueue, path)
		end
	end
	persistTranscriptionQueue()
end

local function transcriptionError(stderr)
	return stderr:match("whisper:%s*([^\n]+)")
		or stderr:match("([^\n]+)\n*$")
		or "Local transcription exited with an error"
end

local function handleTranscriptionOutput(stdout, stderr)
	if stderr and stderr ~= "" then
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
			if payload.status == "progress" and type(payload.progress) == "number" then
				module.transcriptionProgress = math.max(0, math.min(100, math.floor(payload.progress)))
				module.transcriptionPhase = payload.phase
				updateMenuBar()
			elseif payload.status == "finished" and type(payload.markdown_path) == "string" then
				module.transcriptionOutputPath = payload.markdown_path
			end
		end
	end
end

startNextTranscription = function()
	if not config.transcriberPath or module.transcriptionTask or #module.transcriptionQueue == 0 then
		return
	end

	local sourcePath
	local index = 1
	while index <= #module.transcriptionQueue and not sourcePath do
		local candidate = module.transcriptionQueue[index]
		if not hs.fs.attributes(candidate) then
			table.remove(module.transcriptionQueue, index)
		elseif module.failedTranscriptions[candidate] then
			index = index + 1
		else
			table.remove(module.transcriptionQueue, index)
			sourcePath = candidate
		end
	end
	if not sourcePath then
		persistTranscriptionQueue()
		return
	end
	module.transcriptionPath = sourcePath
	module.transcriptionProgress = 0
	module.transcriptionPhase = "preparing"
	module.transcriptionOutputBuffer = ""
	module.transcriptionOutputPath = nil
	module.transcriptionStderr = ""
	persistTranscriptionQueue()
	local task
	task = hs.task.new(config.transcriberPath, function(exitCode, stdout, stderr)
		if module.transcriptionTask ~= task then
			return
		end
		handleTranscriptionOutput(stdout, stderr)
		local outputPath = module.transcriptionOutputPath or transcriptOutputPath(sourcePath)
		local taskStderr = module.transcriptionStderr
		local failedPhase = module.transcriptionPhase
		module.transcriptionTask = nil
		module.transcriptionPath = nil
		module.transcriptionPhase = nil
		module.transcriptionOutputBuffer = nil
		module.transcriptionOutputPath = nil
		module.transcriptionStderr = nil
		if exitCode == 0 then
			notifyStatus("Transcript saved: " .. fileName(outputPath))
		else
			module.failedTranscriptions[sourcePath] = true
			table.insert(module.transcriptionQueue, sourcePath)
			local message = transcriptionError(taskStderr)
			logger:e(message)
			local prefix = failedPhase == "archiving" and "Audio compression failed: " or "Transcription failed: "
			notifyFailure(prefix .. message)
		end
		persistTranscriptionQueue()
		updateMenuBar()
		startNextTranscription()
	end, function(_, stdout, stderr)
		if module.transcriptionTask ~= task then
			return false
		end
		handleTranscriptionOutput(stdout, stderr)
		return true
	end, { "--meeting", "--archive-audio", "--progress-json", sourcePath })
	module.transcriptionTask = task
	updateMenuBar()
	if not task or not task:start() then
		module.failedTranscriptions[sourcePath] = true
		table.insert(module.transcriptionQueue, sourcePath)
		module.transcriptionTask = nil
		module.transcriptionPath = nil
		module.transcriptionPhase = nil
		persistTranscriptionQueue()
		logger:e("Could not start local transcription")
		notifyFailure("Could not start local transcription")
		updateMenuBar()
		startNextTranscription()
	end
end

local function enqueueTranscription(path)
	if not config.transcriberPath or not path then
		return
	end
	if module.transcriptionPath == path then
		return
	end
	for _, queuedPath in ipairs(module.transcriptionQueue) do
		if queuedPath == path then
			return
		end
	end
	table.insert(module.transcriptionQueue, path)
	persistTranscriptionQueue()
	startNextTranscription()
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
			if #urls == 0 or next(browserURLSet) == nil then
				calendarEvents[fingerprint] = event
			end
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

local function promptForRecordingEvent(detectedAt, reason, pending, callback)
	module.pendingPrompt = pending
	module.meetingPrompt = recordingPanel({
		mode = "title",
		screen = pending.screen,
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

local function selectMeetingURL(generation, callback)
	local candidates = module.meetingURLs
	if #candidates == 1 then
		callback(candidates[1])
		return
	end

	dismissMeetingPrompt()
	local pending = { generation = generation }
	module.pendingPrompt = pending
	module.meetingPrompt = recordingPanel({
		mode = "selection",
		title = "Choose a meeting",
		description = "More than one meeting is open. Choose the meeting to record.",
		urls = candidates,
		primary = "Continue",
		secondary = "Cancel",
		focus = true,
	}, function(action, value)
		if module.pendingPrompt ~= pending then
			return
		end
		module.meetingPrompt = nil
		module.pendingPrompt = nil
		if action == "primary" and type(value) == "number" and candidates[value] then
			callback(candidates[value])
		else
			module.handledGeneration = generation
		end
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
	local recording = module.pendingRecordings[requestID]
	if recording then
		local firstRequest = not recording.stopRequested
		if firstRequest then
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

startRecording = function(sessionType, event, meetingURL)
	if module.task then
		return
	end
	cancelStopDelay()
	dismissMeetingPrompt()

	local outputPath = eventOutputPath(event)
	local requestID = nextRecorderRequestID()
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

		local previousSessionType = module.sessionType
		local completedPath = module.currentPath
		local stopReason = module.stopReason
		local restartEvent = module.sessionEvent
		local restartMeetingURL = module.sessionMeetingURL
		local sameMeeting = sessionMatchesMeeting()
		local restartMeeting = previousSessionType == "meeting"
			and module.state == "stopping"
			and module.meetingActive
			and sameMeeting
			and (stopReason == "browser-switch" or stopReason == "grace-timeout")
		local promptNextMeeting = previousSessionType == "meeting"
			and module.meetingActive
			and (stopReason == "meeting-switch" or not sameMeeting)
		local pendingFailure = module.pendingFailure
		local retryMeeting = not module.captureStarted
			and stopReason ~= "manual"
			and (finalPayload.status == "error" or pendingFailure ~= nil)
		cancelStopDelay()
		stopStartTimeout()
		module.task = nil
		module.sessionType = nil
		module.sessionEvent = nil
		module.sessionMeetingURL = nil
		module.sessionMeetingGeneration = nil
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
		if retryMeeting then
			module.handledGeneration = nil
			if module.meetingActive then
				requestMeetingPrompt(module.meetingSource, module.meetingCandidateKey, module.meetingGeneration)
			end
		elseif restartMeeting then
			startRecording("meeting", restartEvent, restartMeetingURL)
		elseif promptNextMeeting then
			requestMeetingPrompt(module.meetingSource, module.meetingCandidateKey, module.meetingGeneration)
		end
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
	module.sessionMeetingURL = meetingURL
	module.sessionMeetingGeneration = module.meetingGeneration
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
		taskEnded = true
		finalPayload = { status = "error", message = "Could not start Meeting Recorder." }
		completeTask()
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
	return string.format(
		"%s  %s–%s",
		event.title,
		os.date("%H:%M", math.floor(startTimestamp)),
		os.date("%H:%M", math.floor(endTimestamp))
	)
end

local function meetingPromptScreen(source)
	local browser = source and browsersByName[source]
	local application = browser and hs.application.get(browser.bundleID)
	local window = application and (application:focusedWindow() or application:mainWindow())
	return window and window:screen() or hs.screen.mainScreen()
end

local function showMeetingPrompt(source, key, generation, event, fallbackReason, detectedAt, meetingURL)
	if
		not module.meetingActive
		or module.meetingSource ~= source
		or module.meetingCandidateKey ~= key
		or module.meetingGeneration ~= generation
		or module.task
	then
		return
	end
	dismissMeetingPrompt()

	local pending = { generation = generation, screen = meetingPromptScreen(source) }
	local function isCurrentMeeting()
		return module.meetingActive
			and module.meetingSource == source
			and module.meetingCandidateKey == key
			and module.meetingGeneration == generation
			and not module.task
			and not module.manualStartPending
	end
	local function record(eventToRecord)
		if not isCurrentMeeting() then
			return
		end
		module.handledGeneration = generation
		if eventToRecord then
			startRecording("meeting", eventToRecord, meetingURL)
		end
	end
	module.pendingPrompt = pending
	module.meetingPrompt = recordingPanel({
		mode = "detected",
		screen = pending.screen,
		title = "Meeting detected",
		description = "Record this meeting?",
		eventText = eventTimeText(event),
		url = meetingURL,
		primary = "Start Recording",
		secondary = "Not Now",
	}, function(action)
		if module.pendingPrompt ~= pending then
			return
		end
		module.meetingPrompt = nil
		module.pendingPrompt = nil
		if action ~= "primary" then
			module.handledGeneration = generation
			return
		end
		if not isCurrentMeeting() then
			return
		end
		if event then
			record(event)
		else
			promptForRecordingEvent(detectedAt, fallbackReason, pending, record)
		end
	end)
end

requestMeetingPrompt = function(source, key, generation)
	if
		module.task
		or module.manualStartPending
		or module.handledGeneration == generation
		or (module.pendingPrompt and module.pendingPrompt.generation == generation)
	then
		return
	end

	local detectedAt = hs.timer.secondsSinceEpoch()
	local function isCurrentMeeting()
		return module.meetingActive
			and module.meetingSource == source
			and module.meetingCandidateKey == key
			and module.meetingGeneration == generation
			and not module.task
			and not module.manualStartPending
			and module.handledGeneration ~= generation
	end
	selectMeetingURL(generation, function(meetingURL)
		if not isCurrentMeeting() then
			return
		end

		queryCalendar(detectedAt, function(events, calendarError)
			if not isCurrentMeeting() then
				return
			end
			local event, selectionError = selectCalendarEvent(events, { meetingURL })
			showMeetingPrompt(source, key, generation, event, calendarError or selectionError, detectedAt, meetingURL)
		end)
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
	module.handledGeneration = module.meetingGeneration
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
		local event, selectionError = selectCalendarEvent(events, {})
		if event then
			record(event)
		else
			promptForRecordingEvent(detectedAt, calendarError or selectionError, pending, record)
		end
	end)
end

stopRecording = function(reason)
	dismissMeetingPrompt()
	module.manualStartPending = nil
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
	end
	if #menu > 0 then
		table.insert(menu, { title = "-" })
	end
	if module.task then
		table.insert(menu, {
			title = "Stop Recording",
			fn = function()
				stopRecording("manual")
			end,
		})
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
updateMenuBar()

handleMeetingState = function(active, source, key, generation)
	local browser = source and browsersByName[source]
	local browserBundleID = browser and browser.bundleID or nil
	module.browserBundleID = browserBundleID
	if active then
		if module.sessionType == "meeting" and module.task then
			if module.state == "stopping" then
				return
			end
			if not sessionMatchesMeeting() then
				stopRecording("meeting-switch")
				return
			end
			module.sessionMeetingGeneration = generation
			cancelStopDelay()
		end
		if
			module.sessionType == "meeting"
			and module.task
			and module.recordingBundleID
			and browserBundleID
			and module.recordingBundleID ~= browserBundleID
		then
			stopRecording("browser-switch")
			return
		end
		if
			module.pendingPrompt
			and not module.pendingPrompt.manual
			and module.pendingPrompt.generation ~= generation
		then
			dismissMeetingPrompt()
		end
		if not module.task then
			requestMeetingPrompt(source, key, generation)
		end
		return
	end

	if not (module.pendingPrompt and module.pendingPrompt.manual) then
		dismissMeetingPrompt()
	end
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

module.recorderStateWatcher = hs.distributednotifications.new(function(_, _, userInfo)
	dispatchRecorderState(userInfo)
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

local function pollRecorderStates()
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
					local message = "Timed out waiting for restored recording to stop: " .. fileName(pending.path)
					logger:e(message)
					notifyFailure(message)
				end)
			end
		end
	end
end
module.recorderPollTimer = hs.timer.doEvery(1, pollRecorderStates)
pollRecorderStates()

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

hs.distributednotifications.post("@refreshNotification@", "org.hammerspoon.Hammerspoon")

module.panelWarmupTimer = hs.timer.doAfter(0, preparePanelUI)

return module
