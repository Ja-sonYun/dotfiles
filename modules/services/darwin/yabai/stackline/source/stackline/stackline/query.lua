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
			"Stackline query --windows %s after %.3fs (exit=%s, stdout=%d bytes, stderr=%d bytes)",
			reason,
			elapsed,
			tostring(request.exitCode),
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

	request.task = hs.task.new(stackline.config:get("paths.yabai"), function(code, stdout, stderr)
		if active ~= request then
			return
		end
		request.exitCode = code
		request.stdoutBytes = #(stdout or "")
		request.stderrBytes = #(stderr or "")

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
			finish("invalid-json")
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
	end, { "-m", "query", "--windows" })
	request.timeout = hs.timer.doAfter(5, function()
		if active ~= request then
			return
		end
		request.timedOut = true
		log.e("Stackline query --windows timeout after 5s; waiting for termination")
		request.task:terminate()
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
