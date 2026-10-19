local log = hs.logger.new("query", "info")
local logger = require("logging").new("stackline-query")
log.i("Loading module: query")

local revision = 0
local active
local pending = false
local forceRedraw = false
local lastSuccess
local retryTimer

local function invalidate(force)
	revision = revision + 1
	forceRedraw = forceRedraw or force or false
	if active then
		pending = true
	end
end

local function groupWindows(yabaiWindows)
	local visibleWindows = {}
	for _, win in ipairs(stackline.wf:getWindows()) do
		visibleWindows[win:id()] = win
	end

	local groups = {}
	for _, win in ipairs(yabaiWindows) do
		if type(win["stack-index"]) == "number" and win["stack-index"] > 0 then
			local key = table.concat({
				win.display,
				win.space,
				win.frame.x,
				win.frame.y,
				win.frame.w,
				win.frame.h,
			}, "|")
			groups[key] = groups[key] or {}
			table.insert(groups[key], win)
		end
	end

	local byStack = {}
	for key, group in pairs(groups) do
		local visible = false
		for _, win in ipairs(group) do
			if win["is-visible"] then
				visible = true
				break
			end
		end

		-- Use visibility for the whole stack, not to discard individual members.
		if visible and #group > 1 then
			table.sort(group, function(a, b)
				return a["stack-index"] < b["stack-index"]
			end)
			local windows = {}
			for _, record in ipairs(group) do
				local hsWin = visibleWindows[record.id] or hs.window.get(record.id)
				local win = hsWin and stackline.window:new(hsWin)
				if not win then
					logger:w("window_unavailable", { window = record.id, stack = key })
					return nil
				end
				win.stackId = key
				win.stackIdx = record["stack-index"]
				table.insert(windows, win)
			end

			if #windows > 1 then
				byStack[key] = windows
			end
		end
	end
	return byStack
end

local run

run = function(opts)
	if retryTimer then
		retryTimer:stop()
		retryTimer = nil
	end
	forceRedraw = forceRedraw or (opts and opts.forceRedraw) or false
	pending = true
	if active then
		return
	end

	pending = false
	local request = {
		attempt = opts and opts.attempt or 0,
		revision = revision,
		focusRevision = stackline.manager.focusRevision,
		started = hs.timer.absoluteTime(),
		stdoutBytes = 0,
		stderrBytes = 0,
	}
	active = request
	local stdoutChunks, stderrChunks = {}, {}

	local function finish(reason)
		if active ~= request then
			return
		end

		request.timeout:stop()
		if reason ~= "applied" and reason ~= "stale" then
			logger:w("query_failed", {
				revision = request.revision,
				current_revision = revision,
				reason = reason,
				elapsed_ms = (hs.timer.absoluteTime() - request.started) / 1e6,
				exit_code = request.exitCode,
				stdout_bytes = request.stdoutBytes,
				stderr_bytes = request.stderrBytes,
				stderr = request.stderr,
				stdout_tail = request.stdoutTail,
				last_success = lastSuccess,
				error = request.error,
			})
		end

		active = nil
		if pending then
			run()
		elseif (reason == "window-unavailable" or reason == "geometry-unavailable") and request.attempt < 5 then
			retryTimer = hs.timer.doAfter(0.1, function()
				run({ attempt = request.attempt + 1 })
			end)
		end
	end

	local function complete()
		if active ~= request then
			return
		end
		local stdout = table.concat(stdoutChunks) .. (request.stdoutEnd or "")
		local stderr = table.concat(stderrChunks) .. (request.stderrEnd or "")
		request.stdoutBytes = #(stdout or "")
		request.stderrBytes = #(stderr or "")
		request.stdoutTail = (stdout or ""):sub(-512)
		request.stderr = (stderr or ""):sub(-1024)
		if request.exitCode == nil then
			return
		end

		if request.timedOut then
			finish("timeout")
			return
		end
		if request.exitCode ~= 0 then
			finish("exit " .. request.exitCode)
			return
		end

		local clean = (stdout or ""):gsub(":inf,", ":0,")
		local ok, windows = pcall(hs.json.decode, clean)
		if not ok or type(windows) ~= "table" then
			return
		end
		if request.revision ~= revision then
			finish("stale")
			return
		end

		local applied, reason = xpcall(function()
			local stacks = groupWindows(windows)
			if not stacks then
				return "window-unavailable"
			end
			stackline.manager:pruneFocusHistory(windows)
			local focusedId
			stackline.manager.visibleWindowIds = {}
			for _, win in ipairs(windows) do
				if win["is-visible"] then
					stackline.manager.visibleWindowIds[win.id] = true
					if win["has-focus"] then
						focusedId = win.id
					end
				end
			end

			-- Preserve focus events received after this asynchronous query began.
			if request.focusRevision == stackline.manager.focusRevision then
				if focusedId and focusedId ~= stackline.manager.focusedWindowId then
					stackline.manager.focusSequence = stackline.manager.focusSequence + 1
					stackline.manager.lastFocusedByWindowId[focusedId] = stackline.manager.focusSequence
				end
				stackline.manager.focusedWindowId = focusedId
			end

			local current = stackline.manager:getSummary()
			local updated = stackline.manager:getSummary(u.values(stacks))
			if forceRedraw or not u.equal(current, updated) then
				stackline.manager:ingest(stacks)
			else
				stackline.manager:syncFocus()
			end
			forceRedraw = false
			if not stackline.manager:completeGeometry(stacks) then
				return "geometry-unavailable"
			end
		end, debug.traceback)
		if applied and not reason then
			lastSuccess = hs.timer.secondsSinceEpoch()
		end
		request.error = not applied and reason or nil
		finish(applied and (reason or "applied") or "apply-error")
	end

	-- Keep the termination tail after streamed chunks, including late callbacks.
	-- https://www.hammerspoon.org/docs/hs.task.html#new
	request.task = hs.task.new(stackline.config:get("paths.yabai"), function(code, stdout, stderr)
		request.exitCode = code
		request.stdoutEnd = stdout
		request.stderrEnd = stderr
		complete()
	end, function(_, stdout, stderr)
		stdoutChunks[#stdoutChunks + 1] = stdout or ""
		stderrChunks[#stderrChunks + 1] = stderr or ""
		complete()
		return true
	end, { "-m", "query", "--windows", "id,display,space,frame,stack-index,is-visible,has-focus" })
	request.timeout = hs.timer.doAfter(5, function()
		if active ~= request then
			return
		end
		request.timedOut = true
		if request.exitCode ~= nil then
			finish("invalid-json")
		else
			log.e("Stackline query --windows timeout after 5s; waiting for termination")
			request.task:terminate()
		end
	end)
	if not request.task or not request.task:start() then
		finish("start-failed")
	end
end

return {
	run = run,
	invalidate = invalidate,
	setLogLevel = log.setLogLevel,
}
