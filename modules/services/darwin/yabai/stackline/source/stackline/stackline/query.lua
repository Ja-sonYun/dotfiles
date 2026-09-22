local log = hs.logger.new("query", "info")
log.i("Loading module: query")

local revision = 0
local active
local pending = false
local forceRedraw = false

local function invalidate(force)
	revision = revision + 1
	forceRedraw = forceRedraw or force or false
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
			if visibleWindows[win.id] then
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
				if hsWin then
					local win = stackline.window:new(hsWin)
					win.stackId = key
					win.stackIdx = record["stack-index"]
					table.insert(windows, win)
				else
					log.w("Stack window unavailable:", record.id)
				end
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
	forceRedraw = forceRedraw or (opts and opts.forceRedraw) or false
	pending = true
	if active then
		return
	end

	pending = false
	local request = {
		revision = revision,
		started = hs.timer.absoluteTime(),
		stdout = {},
		stdoutTail = "",
		stdoutBytes = 0,
		stderrBytes = 0,
	}
	active = request

	local function finish(reason)
		if active ~= request then
			return
		end

		request.timeout:stop()
		local elapsed = (hs.timer.absoluteTime() - request.started) / 1e9
		local message = string.format(
			"Query %s after %.3fs (stdout=%d bytes, stderr=%d bytes)",
			reason,
			elapsed,
			request.stdoutBytes,
			request.stderrBytes
		)
		if reason == "applied" or reason == "stale" then
			log.d(message)
		else
			log.e(message)
		end

		active = nil
		if pending then
			run()
		end
	end

	local function complete()
		if active ~= request or request.exitCode == nil then
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

		-- A final streaming callback can arrive after the termination callback.
		-- Its bytes precede the tail read by the termination callback.
		local output = table.concat(request.stdout) .. request.stdoutTail
		local clean = output:gsub(":inf,", ":0,")
		local ok, windows = pcall(hs.json.decode, clean)
		if not ok or type(windows) ~= "table" then
			return
		end
		if request.revision ~= revision then
			finish("stale")
			return
		end

		local applied = pcall(function()
			local stacks = groupWindows(windows)
			stackline.manager:pruneFocusHistory(windows)
			local current = stackline.manager:getSummary()
			local updated = stackline.manager:getSummary(u.values(stacks))
			if forceRedraw or not u.equal(current, updated) then
				stackline.manager:ingest(stacks)
			else
				stackline.manager:syncFocus()
			end
			stackline.manager:completeGeometry()
		end)
		if applied then
			forceRedraw = false
		end
		finish(applied and "applied" or "apply-error")
	end

	request.task = hs.task.new(stackline.config:get("paths.yabai"), function(code, stdout, stderr)
		if active ~= request then
			return
		end
		request.exitCode = code
		request.stdoutTail = stdout or ""
		request.stdoutBytes = request.stdoutBytes + #request.stdoutTail
		request.stderrBytes = request.stderrBytes + #(stderr or "")
		complete()
	end, function(_, stdout, stderr)
		if active ~= request then
			return false
		end
		table.insert(request.stdout, stdout or "")
		request.stdoutBytes = request.stdoutBytes + #(stdout or "")
		request.stderrBytes = request.stderrBytes + #(stderr or "")
		complete()
		return true
	end, { "-m", "query", "--windows" })
	request.timeout = hs.timer.doAfter(5, function()
		if active ~= request then
			return
		end
		if request.exitCode ~= nil then
			finish("invalid-json")
		else
			request.timedOut = true
			log.e(
				string.format(
					"Query timeout after 5s; waiting for termination (stdout=%d bytes, stderr=%d bytes)",
					request.stdoutBytes,
					request.stderrBytes
				)
			)
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
