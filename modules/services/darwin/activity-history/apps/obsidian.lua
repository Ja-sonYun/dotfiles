local code = [[
(() => {
    const file = app.workspace.activeLeaf?.view?.file;
    return JSON.stringify({
        file_path: file ? app.vault.adapter.getFullPath(file.path) : null
    });
})()
]]

local function start(app, callback)
	local task, timer, finished
	local function finish(exitCode, stdout)
		if finished then
			return
		end
		finished = true
		if timer then
			timer:stop()
		end
		local path
		if exitCode == 0 then
			local ok, value = pcall(hs.json.decode, (stdout:gsub("^%s*=>%s*", "")))
			if
				ok
				and type(value) == "table"
				and type(value.file_path) == "string"
				and value.file_path:sub(1, 1) == "/"
			then
				path = value.file_path
			end
		end
		callback({
			location = { kind = "obsidian", path = path },
			summary = path or "Path unavailable",
			result = exitCode ~= 0 and "error" or (path and "found" or "unavailable"),
			partial = path == nil,
			missing_fields = not path and { "path" } or nil,
			calls = 0,
			nodes = 0,
			read_errors = 0,
			discovery_limited = false,
			ax_seconds = 0,
			cpu_seconds = 0,
		})
	end
	local function cancel()
		finished = true
		if timer then
			timer:stop()
		end
		if task and task:isRunning() then
			task:terminate()
		end
	end
	task = hs.task.new(app:path() .. "/Contents/MacOS/obsidian-cli", finish, { "eval", "code=" .. code })
	if task then
		task:setWorkingDirectory("/")
	end
	if not task or not task:start() then
		finish(-1, "")
		return cancel
	end
	timer = hs.timer.doAfter(2, function()
		finish(-1, "")
		cancel()
	end)
	return cancel
end

return { start = start }
