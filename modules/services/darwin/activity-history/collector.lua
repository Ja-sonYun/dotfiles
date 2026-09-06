local cfg = assert(hs.json.read("@configFile@"))
local helper = "@helper@"
local ax = require("hs.axuielement")
local axType = hs.getObjectMetatable("hs.axuielement")
local stateFile = cfg.stateDirectory .. "/state.json"
local session = hs.caffeinate.sessionProperties() or {}
local recorder = {
	running = true,
	paused = cfg.startPaused,
	locked = session.CGSSessionScreenIsLocked == true,
	sleeping = false,
	electron = {},
	runID = hs.host.uuid(),
	pid = assert(hs.application.get("org.hammerspoon.Hammerspoon")):pid(),
}
local activityPath, activityDay, context, lastLocation, lastState, state
local schedule, syncContext, restoreAccessibility

local function timestamp(epoch)
	return os.date("!%Y-%m-%dT%H:%M:%S", math.floor(epoch)) .. string.format(".%03dZ", math.floor((epoch % 1) * 1000))
end

local function write(path, text, mode)
	local file = assert(io.open(path, mode or "w"))
	local ok, err = file:write(text)
	local closed, closeError = file:close()
	assert(ok, err)
	assert(closed, closeError)
end

local function writeState(text)
	local temporary = stateFile .. ".tmp"
	local ok, err = pcall(function()
		local quoted = "'" .. temporary:gsub("'", "'\\''") .. "'"
		local _, created = hs.execute("umask 077; : > " .. quoted, false)
		assert(created, "Cannot prepare activity history state file")
		write(temporary, text)
		assert(os.rename(temporary, stateFile))
	end)
	if not ok then
		os.remove(temporary)
		error(err)
	end
end

local function prepare()
	local day = os.date("%Y-%m-%d")
	if activityDay ~= day then
		local output, ok = hs.execute('"' .. helper .. '" _init', false)
		assert(ok, "Cannot prepare activity history directories")
		local prepared = assert(hs.json.decode(output))
		activityPath = assert(prepared.activityPath)
		activityDay = assert(prepared.activityDay)
	end
	if recorder.archiveDay == activityDay or not recorder.running then
		return
	end
	local ok, err = pcall(function()
		if recorder.archiveTask and recorder.archiveTask:isRunning() then
			return
		end
		recorder.archiveDay = activityDay
		recorder.archiveTask = hs.task.new(helper, function(code, _, stderr)
			if code ~= 0 then
				print("activity-history: archive failed: " .. stderr)
			end
		end, { "_archive", "--before", activityDay })
		assert(recorder.archiveTask and recorder.archiveTask:start(), "Cannot start activity history archive")
	end)
	if not ok then
		print("activity-history: archive failed: " .. tostring(err))
	end
end

local function emit(kind, fields)
	prepare()
	fields.type = kind
	fields.schema_version = 1
	fields.event_id = hs.host.uuid()
	fields.at = timestamp(hs.timer.secondsSinceEpoch())
	fields.source = "hammerspoon"
	fields.collector_run_id = recorder.runID
	write(activityPath, hs.json.encode(fields) .. "\n", "a")
end

local function safe(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			recorder.paused = true
			recorder.error = tostring(err)
			if recorder.pending then
				recorder.pending:stop()
			end
			if state then
				state.allowed = false
				state.recording = false
				state.error = recorder.error
				if not pcall(writeState, hs.json.encode(state)) then
					os.remove(stateFile)
				end
			end
			if restoreAccessibility then
				pcall(restoreAccessibility)
			end
		end
	end
end

local function isExcluded(bundle)
	for _, value in ipairs(cfg.excludedApps) do
		if value == bundle then
			return true
		end
	end
	return false
end

local function foreground()
	local app = hs.application.frontmostApplication()
	if not app then
		return nil
	end
	local window = hs.window.frontmostWindow()
	if window and (not window:application() or window:application():pid() ~= app:pid()) then
		window = nil
	end
	return {
		app = app,
		app_id = app:bundleID() or app:name(),
		app_name = app:name(),
		pid = app:pid(),
		window_id = window and window:id() or 0,
		window_title = window and window:title() or "",
	}
end

local function contextKey(current)
	return current and table.concat({ current.app_id, current.pid, current.window_id }, ":")
end

local function saveState(reason, force)
	local now = hs.timer.secondsSinceEpoch()
	local current = foreground()
	local blocked = not recorder.running and "stopped"
		or recorder.paused and "paused"
		or recorder.locked and "locked"
		or recorder.sleeping and "sleeping"
		or not current and "no_application"
		or (current and isExcluded(current.app_id)) and "excluded"
		or hs.eventtap.isSecureInputEnabled() and "secure_input"
		or not hs.accessibilityState(false) and "accessibility_unavailable"
	local allowed = not blocked
	local wasAllowed = state and state.allowed
	state = {
		run_id = recorder.runID,
		pid = recorder.pid,
		running = recorder.running,
		recording = not recorder.paused,
		allowed = allowed,
		reason = blocked or "recording",
		excluded_apps = cfg.excludedApps,
		accept_since = allowed and (wasAllowed and state.accept_since or now) or now,
		heartbeat = now,
		error = recorder.error,
		terminal_front = allowed
				and (current.app_id == "com.mitchellh.ghostty" or current.app_id == "com.apple.Terminal" or current.app_id == "com.googlecode.iterm2")
			or false,
	}
	local identity = hs.json.encode({ state.reason, state.terminal_front, cfg.excludedApps, recorder.running })
	if force or identity ~= lastState then
		prepare()
		writeState(hs.json.encode(state))
		if identity ~= lastState then
			emit("recording_state", { reason = blocked or reason, recording = allowed })
		end
		lastState = identity
	end
	if not allowed then
		if recorder.pending then
			recorder.pending:stop()
		end
		if recorder.pollTask and recorder.pollTask:isRunning() then
			recorder.pollTask:terminate()
		end
		context, lastLocation = nil, nil
		if wasAllowed and restoreAccessibility then
			restoreAccessibility()
		end
	end
	return allowed and current or nil
end

syncContext = function(reason, force)
	local current = saveState(reason, force)
	if not current then
		return nil
	end
	if not context or context.key ~= contextKey(current) or context.day ~= os.date("%Y-%m-%d") then
		context = {
			key = contextKey(current),
			id = hs.host.uuid(),
			title = current.window_title,
			day = os.date("%Y-%m-%d"),
		}
		lastLocation = nil
		emit("context_change", {
			context_id = context.id,
			app_id = current.app_id,
			app_name = current.app_name,
			pid = current.pid,
			window_id = current.window_id,
			window_title = current.window_title,
		})
	elseif context.title ~= current.window_title then
		context.title = current.window_title
		emit("context_update", { context_id = context.id, window_title = current.window_title })
	end
	return current
end

restoreAccessibility = function()
	local writeError
	for pid, entry in pairs(recorder.electron) do
		if entry.restoreRequired then
			local ok, changed = pcall(function()
				return entry.element:setAttributeValue("AXManualAccessibility", entry.original)
			end)
			local recorded, err = pcall(emit, "recording_state", {
				reason = "accessibility_restore_request",
				pid = pid,
				request_accepted = ok and changed ~= nil,
				restoration_verified = false,
			})
			if not recorded then
				writeError = writeError or err
			end
		end
		recorder.electron[pid] = nil
	end
	if writeError then
		error(writeError)
	end
end

local supportedApps = {
	["com.apple.Safari"] = "safari",
	["com.google.Chrome"] = "chrome",
	["notion.id"] = "notion",
	["com.tinyspeck.slackmacgap"] = "slack",
}
local extractors = {}
for _, kind in pairs(supportedApps) do
	extractors[kind] = assert(loadfile("@appsDirectory@/" .. kind .. ".lua"))("@appsDirectory@")
end

local function ready(current)
	if not extractors[supportedApps[current.app_id]].manualAccessibility then
		return true
	end
	local now = hs.timer.secondsSinceEpoch()
	local entry = recorder.electron[current.pid]
	if not entry then
		local element = ax.applicationElement(current.app)
		element:setTimeout(0.1)
		local original = element:attributeValue("AXManualAccessibility")
		local changed
		if original == false then
			changed = element:setAttributeValue("AXManualAccessibility", true)
		end
		entry = { element = element, original = original, restoreRequired = original == false, readyAt = now + 3 }
		recorder.electron[current.pid] = entry
		emit("recording_state", {
			reason = "accessibility_enable_request",
			pid = current.pid,
			original = original,
			request_accepted = changed ~= nil,
		})
	end
	if now < entry.readyAt then
		schedule("accessibility_ready", entry.readyAt - now)
		return false
	end
	return true
end

local function extract(current)
	local started, cpu = hs.timer.absoluteTime(), os.clock()
	local ctx = { calls = 0, errors = 0, missing_fields = {} }
	local elements, values = {}, {}
	local function identify(element)
		if not element or getmetatable(element) ~= axType then
			return nil
		end
		for index, previous in ipairs(elements) do
			if previous == element then
				return index
			end
		end
		element:setTimeout(0.1)
		elements[#elements + 1] = element
		values[#elements] = {}
		return #elements
	end
	function ctx.read(element, attribute)
		local index = identify(element)
		if not index then
			return nil
		end
		if values[index][attribute] then
			return table.unpack(values[index][attribute])
		end
		if ctx.calls >= 600 then
			ctx.limit = "calls"
			return nil
		end
		if (hs.timer.absoluteTime() - started) / 1e9 >= 0.5 then
			ctx.limit = "time"
			return nil
		end
		ctx.calls = ctx.calls + 1
		local ok, value, err = pcall(function()
			return element:attributeValue(attribute)
		end)
		if not ok or err then
			ctx.errors = ctx.errors + 1
		end
		if not ok then
			value = nil
		end
		values[index][attribute] = { value }
		return value
	end
	function ctx.url(element)
		local value = ctx.read(element, "AXURL")
		if type(value) == "table" then
			value = value.url
		end
		return type(value) == "string" and value ~= "" and value or nil
	end
	function ctx.missing(field)
		ctx.missing_fields[#ctx.missing_fields + 1] = field
	end
	function ctx.walk(rootElement, visit, maximum, depthFirst)
		local queue, seen, cursor = { { element = rootElement, depth = 0 } }, {}, 1
		while cursor <= #queue and cursor <= maximum and not ctx.limit do
			local item = queue[cursor]
			cursor = cursor + 1
			local index = identify(item.element)
			if index and not seen[index] then
				seen[index] = true
				local role = ctx.read(item.element, "AXRole")
				if role ~= "AXSecureTextField" then
					local action = visit(item.element, role, item)
					if action == "stop" then
						return
					end
					if
						action ~= "skip"
						and role ~= "AXToolbar"
						and role ~= "AXOutline"
						and role ~= "AXButton"
						and role ~= "AXStaticText"
						and role ~= "AXLink"
						and item.depth < 20
					then
						local children = ctx.read(item.element, "AXChildren")
						if type(children) == "table" then
							for offset = 1, #children do
								if #queue >= maximum * 3 then
									ctx.discovery_limited = true
									break
								end
								local child = children[depthFirst and (#children - offset + 1) or offset]
								local nextItem = { element = child, depth = item.depth + 1, scope = item.scope }
								if depthFirst then
									table.insert(queue, cursor, nextItem)
								else
									queue[#queue + 1] = nextItem
								end
							end
						end
					elseif action ~= "skip" and item.depth >= 20 then
						ctx.discovery_limited = true
					end
				end
			end
		end
		if cursor <= #queue then
			ctx.discovery_limited = true
		end
	end

	local kind = supportedApps[current.app_id]
	local ok, location, summary, found = pcall(function()
		local application = ax.applicationElement(current.app)
		ctx.window = ctx.read(application, "AXFocusedWindow")
		ctx.title = current.window_title
		if not ctx.window then
			ctx.missing("window")
			return { kind = kind }, "Location unavailable", false
		end
		return extractors[kind].extract(ctx)
	end)
	if not ok then
		location, summary = { kind = kind }, "Location unavailable"
	end
	return {
		location = location,
		summary = summary,
		result = not ok and "error" or (found and "found" or "unavailable"),
		partial = not ok or ctx.limit ~= nil or ctx.discovery_limited == true or #ctx.missing_fields > 0,
		missing_fields = #ctx.missing_fields > 0 and ctx.missing_fields or nil,
		calls = ctx.calls,
		nodes = #elements,
		read_errors = ctx.errors,
		limit = ctx.limit,
		discovery_limited = ctx.discovery_limited == true,
		ax_seconds = (hs.timer.absoluteTime() - started) / 1e9,
		cpu_seconds = os.clock() - cpu,
	}
end

local function locationIdentity(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	local keys, parts = {}, {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, key in ipairs(keys) do
		parts[#parts + 1] = locationIdentity(key) .. ":" .. locationIdentity(value[key])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function allowsLocation(current)
	return current ~= nil and supportedApps[current.app_id] ~= nil
end

local function capture(reason)
	local current = syncContext(reason)
	if not allowsLocation(current) or not ready(current) then
		return
	end
	local key, id = context.key, context.id
	local result = extract(current)
	if key ~= contextKey(foreground()) then
		return
	end
	if not saveState(reason) then
		return
	end
	local identity = locationIdentity({ result.location, result.result, result.partial, result.missing_fields or {} })
	if identity == lastLocation then
		return
	end
	result.context_id = id
	result.trigger = reason
	emit("location_snapshot", result)
	lastLocation = identity
end

schedule = function(reason, delay)
	if recorder.pending then
		recorder.pending:stop()
	end
	if not state or not state.allowed then
		return
	end
	if not allowsLocation(foreground()) then
		return
	end
	local seconds = delay or cfg.capture.debounceMilliseconds / 1000
	recorder.pending = hs.timer.doAfter(
		seconds,
		safe(function()
			capture(reason)
		end)
	)
end

local function changed()
	local oldKey, oldTitle = context and context.key, context and context.title
	if
		syncContext("context_change")
		and cfg.capture.onContextChange
		and (context.key ~= oldKey or context.title ~= oldTitle)
	then
		schedule("context_change")
	end
end

function recorder.control(action)
	assert(recorder.running, "Activity history is stopped; reload Hammerspoon")
	assert(action == "start" or action == "pause", "Invalid activity history action")
	safe(function()
		recorder.paused = action == "pause"
		recorder.error = nil
		syncContext(recorder.paused and "paused" or "started", true)
		if not recorder.paused then
			schedule("started")
		end
	end)()
	assert(not recorder.error, recorder.error)
	return state
end

safe(function()
	prepare()
	recorder.appWatcher = hs.application.watcher.new(safe(changed)):start()
	recorder.windowFilter = hs.window.filter.new()
	recorder.windowFilter:subscribe(
		{ hs.window.filter.windowFocused, hs.window.filter.windowTitleChanged },
		safe(changed)
	)
	local types, events = hs.eventtap.event.types, {}
	if cfg.capture.onClick then
		events = { types.leftMouseUp, types.rightMouseUp, types.otherMouseUp }
	end
	if cfg.capture.onEnter then
		events[#events + 1] = types.keyDown
	end
	if #events > 0 then
		recorder.tap = hs.eventtap
			.new(events, function(event)
				safe(function()
					local reason = "click"
					if event:getType() == types.keyDown then
						local code = event:getKeyCode()
						if code ~= hs.keycodes.map["return"] and code ~= hs.keycodes.map["padenter"] then
							return
						end
						reason = "enter"
					end
					if syncContext(reason) then
						schedule(reason)
					end
				end)()
				return false
			end)
			:start()
	end
	recorder.powerWatcher = hs.caffeinate.watcher
		.new(safe(function(event)
			local power = hs.caffeinate.watcher
			if event == power.screensDidLock then
				recorder.locked = true
			elseif event == power.screensDidUnlock then
				recorder.locked = false
			elseif event == power.systemWillSleep then
				recorder.sleeping = true
			elseif event == power.systemDidWake then
				recorder.sleeping = false
			else
				return
			end
			syncContext("session_state", true)
			schedule("session_state")
		end))
		:start()
	recorder.timer = hs.timer.doEvery(
		cfg.capture.intervalSeconds,
		safe(function()
			if recorder.tap and not recorder.tap:isEnabled() then
				recorder.tap:start()
			end
			if syncContext("periodic", true) then
				if recorder.pending then
					recorder.pending:stop()
				end
				capture("periodic")
				if
					cfg.integrations.tmux.enable
					and state.terminal_front
					and (not recorder.pollTask or not recorder.pollTask:isRunning())
				then
					recorder.pollTask = hs.task.new(helper, nil, { "_tmux-poll" })
					recorder.pollTask:start()
				end
			end
		end)
	)
	syncContext("startup", true)
	schedule("startup")
end)()

local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
	recorder.running = false
	if recorder.pending then
		recorder.pending:stop()
	end
	if recorder.timer then
		recorder.timer:stop()
	end
	if recorder.tap then
		recorder.tap:stop()
	end
	if recorder.appWatcher then
		recorder.appWatcher:stop()
	end
	if recorder.windowFilter then
		recorder.windowFilter:unsubscribeAll()
	end
	if recorder.powerWatcher then
		recorder.powerWatcher:stop()
	end
	local ok = pcall(saveState, "stopped", true)
	if not ok then
		os.remove(stateFile)
	end
	pcall(restoreAccessibility)
	if previousShutdown then
		previousShutdown()
	end
end

return recorder
