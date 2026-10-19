local module = {
	displays = {},
	occupancy = {},
	revision = 0,
}
local logger = require("logging").new("yabai-desktop-indicator")
local barWidth = 20
local barHeight = 3
local gap = 4
local paddingX = 6
local paddingY = 2
local height = barHeight + paddingY * 2
local outlineWidth = 0.5

local function query(domain, callback)
	local properties = domain == "--spaces" and "id,index,display"
		or "role,subrole,display,space,is-hidden,is-minimized,is-sticky"
	local request = {
		started = hs.timer.absoluteTime(),
		stdoutBytes = 0,
		stderrBytes = 0,
	}
	module.query = request
	local stdoutChunks, stderrChunks = {}, {}

	local function finish(result, reason)
		if module.query ~= request then
			return
		end
		request.timeout:stop()
		if reason then
			logger:e("query_failed", {
				revision = module.revision,
				elapsed_ms = (hs.timer.absoluteTime() - request.started) / 1e6,
				stdout_tail = request.stdoutTail,
				stderr = request.stderr,
				last_success = module.lastSuccess,
				domain = domain,
				reason = reason,
				exit_code = request.code,
				stdout_bytes = request.stdoutBytes,
				stderr_bytes = request.stderrBytes,
			})
		end
		module.query = nil
		callback(result)
	end

	local function complete()
		if module.query ~= request then
			return
		end
		local stdout = table.concat(stdoutChunks) .. (request.stdoutEnd or "")
		local stderr = table.concat(stderrChunks) .. (request.stderrEnd or "")
		request.stdoutBytes = #(stdout or "")
		request.stderrBytes = #(stderr or "")
		request.stdoutTail = (stdout or ""):sub(-512)
		request.stderr = (stderr or ""):sub(-1024)
		if request.code == nil then
			return
		end

		if request.expired then
			finish(nil, "timeout")
			return
		end
		if request.code ~= 0 then
			finish(nil, "exit")
			return
		end
		local output = (stdout or ""):gsub(":inf,", ":0,")
		local ok, result = pcall(hs.json.decode, output)
		if ok and type(result) == "table" then
			finish(result)
		end
	end

	-- Drain pipes while running; stream callbacks may arrive after termination.
	-- https://www.hammerspoon.org/docs/hs.task.html#new
	request.task = hs.task.new("@yabai@", function(code, stdout, stderr)
		request.code = code
		request.stdoutEnd = stdout
		request.stderrEnd = stderr
		complete()
	end, function(_, stdout, stderr)
		stdoutChunks[#stdoutChunks + 1] = stdout or ""
		stderrChunks[#stderrChunks + 1] = stderr or ""
		complete()
		return true
	end, { "-m", "query", domain, properties })
	request.timeout = hs.timer.doAfter(5, function()
		if module.query ~= request then
			return
		end
		request.expired = true
		if request.code ~= nil then
			finish(nil, "invalid-json")
		else
			request.task:terminate()
		end
	end)
	if not request.task or not request.task:start() then
		finish(nil, "start-failed")
	end
end

local function getOccupancy(spaces, windows, confirmedSpaces)
	if #spaces ~= #confirmedSpaces then
		return nil
	end
	local byIndex = {}
	local occupancy = {}
	for _, space in ipairs(spaces) do
		if
			type(space) ~= "table"
			or type(space.index) ~= "number"
			or type(space.id) ~= "number"
			or type(space.display) ~= "number"
		then
			return nil
		end
		byIndex[space.index] = space
		occupancy[space.id] = false
	end
	-- Reject window results if the Space mapping changed during the query.
	for _, confirmed in ipairs(confirmedSpaces) do
		if type(confirmed) ~= "table" then
			return nil
		end
		local original = byIndex[confirmed.index]
		if not original or original.id ~= confirmed.id or original.display ~= confirmed.display then
			return nil
		end
	end
	for _, window in ipairs(windows) do
		if type(window) ~= "table" then
			return nil
		end
		local appWindow = window.role == "AXDialog"
			or (window.role == "AXWindow" and (window.subrole == "AXStandardWindow" or window.subrole == "AXDialog"))
		if appWindow then
			if type(window["is-hidden"]) ~= "boolean" or type(window["is-minimized"]) ~= "boolean" then
				return nil
			end
			-- Off-space windows still occupy their desktops; visibility is not an occupancy test.
			if not window["is-hidden"] and not window["is-minimized"] then
				local space = byIndex[window.space]
				if not space then
					return nil
				end
				if window["is-sticky"] then
					for _, candidate in ipairs(spaces) do
						if candidate.display == window.display then
							occupancy[candidate.id] = true
						end
					end
				else
					-- Map the yabai Space index to the ID used by Hammerspoon.
					occupancy[space.id] = true
				end
			end
		end
	end
	return occupancy
end

local function removeDisplay(uuid)
	if module.displays[uuid] then
		module.displays[uuid].canvas:delete()
		module.displays[uuid] = nil
	end
end

local function updateDisplay(screen, uuid, managedDisplay)
	local frame = screen:frame()
	local fullFrame = screen:fullFrame()
	if frame.y - fullFrame.y < height then
		removeDisplay(uuid)
		return
	end
	if not managedDisplay then
		return
	end
	local activeSpace = managedDisplay["Current Space"].ManagedSpaceID

	local desktops = {}
	local currentIndex
	for _, space in ipairs(managedDisplay.Spaces) do
		if space.type == 0 then
			desktops[#desktops + 1] = space.ManagedSpaceID
			if space.ManagedSpaceID == activeSpace then
				currentIndex = #desktops
			end
		elseif space.ManagedSpaceID == activeSpace then
			removeDisplay(uuid)
			return
		end
	end
	if not currentIndex then
		return
	end

	local width = #desktops * barWidth + (#desktops - 1) * gap + paddingX * 2
	local x = fullFrame.x + fullFrame.w - width - 24
	local y = frame.y - height + 4
	local contents = {}
	for _, space in ipairs(desktops) do
		contents[#contents + 1] = module.occupancy[space] == false and "empty" or "filled"
	end
	local state = table.concat({ table.concat(desktops, ","), table.concat(contents, ","), activeSpace, x, y }, ":")
	local display = module.displays[uuid]
	if display and display.state == state then
		if not display.canvas:isShowing() then
			display.canvas:show()
		end
		return
	end

	local canvasFrame = {
		x = x,
		y = y,
		w = width,
		h = height,
	}
	local create = not display or display.count ~= #desktops
	local canvas
	if create then
		removeDisplay(uuid)
		canvas = hs.canvas.new(canvasFrame)
		canvas:level("status")
		canvas:behavior({ "canJoinAllSpaces" })
		canvas:clickActivating(false)
		canvas:appendElements({
			type = "rectangle",
			action = "fill",
			fillColor = {
				white = 0.1,
				alpha = 0.65,
			},
			frame = {
				x = 0,
				y = 0,
				w = width,
				h = height,
			},
			roundedRectRadii = {
				xRadius = height / 2,
				yRadius = height / 2,
			},
		})
	else
		canvas = display.canvas
		canvas:frame(canvasFrame)
		canvas[1].frame = {
			x = 0,
			y = 0,
			w = width,
			h = height,
		}
	end

	for index = 1, #desktops do
		local empty = module.occupancy[desktops[index]] == false
		local inset = empty and outlineWidth / 2 or 0
		local color = {
			white = 1,
			alpha = index == currentIndex and 1 or 0.4,
		}
		local element = {
			type = "rectangle",
			action = empty and "stroke" or "fill",
			fillColor = color,
			strokeColor = color,
			strokeWidth = outlineWidth,
			frame = {
				x = paddingX + (index - 1) * (barWidth + gap) + inset,
				y = paddingY + inset,
				w = barWidth - inset * 2,
				h = barHeight - inset * 2,
			},
			roundedRectRadii = {
				xRadius = barHeight / 2 - inset,
				yRadius = barHeight / 2 - inset,
			},
		}
		if create then
			canvas:appendElements(element)
		else
			canvas[index + 1].action = element.action
			canvas[index + 1].fillColor = element.fillColor
			canvas[index + 1].strokeColor = element.strokeColor
			canvas[index + 1].frame = element.frame
			canvas[index + 1].roundedRectRadii = element.roundedRectRadii
		end
	end
	module.displays[uuid] = {
		canvas = canvas,
		state = state,
		count = #desktops,
	}
	canvas:show()
end

local function refresh(snapshot)
	-- Share one snapshot: the convenience getters each repeat this native query.
	-- https://www.hammerspoon.org/docs/hs.spaces.html#data_managedDisplaySpaces
	snapshot = snapshot or hs.spaces.data_managedDisplaySpaces()
	local displays = {}
	for _, display in ipairs(snapshot) do
		displays[display["Display Identifier"]] = display
	end
	local connected = {}
	for _, screen in ipairs(hs.screen.allScreens()) do
		local uuid = screen:getUUID()
		if uuid then
			connected[uuid] = true
			updateDisplay(screen, uuid, displays[uuid] or displays.Main)
		end
	end
	for uuid in pairs(module.displays) do
		if not connected[uuid] then
			removeDisplay(uuid)
		end
	end
	return snapshot
end

local refreshSafely = logger:wrap("refresh_failed", refresh)

local function refreshOccupancy()
	if module.refreshing then
		module.pending = true
		return
	end
	module.pending = false
	module.refreshing = true
	local revision = module.revision
	local function finish(occupancy)
		module.refreshing = false
		if revision == module.revision and occupancy then
			module.lastSuccess = hs.timer.secondsSinceEpoch()
			local changed = false
			for space, occupied in pairs(occupancy) do
				if module.occupancy[space] ~= occupied then
					changed = true
					break
				end
			end
			if not changed then
				for space, occupied in pairs(module.occupancy) do
					if occupancy[space] ~= occupied then
						changed = true
						break
					end
				end
			end

			module.occupancy = occupancy
			if changed then
				refreshSafely()
			end
		end
		if module.pending then
			refreshOccupancy()
		end
	end
	query("--spaces", function(spaces)
		if not spaces or revision ~= module.revision then
			finish(nil)
			return
		end
		query("--windows", function(windows)
			if not windows or revision ~= module.revision then
				finish(nil)
				return
			end
			query("--spaces", function(confirmedSpaces)
				finish(confirmedSpaces and getOccupancy(spaces, windows, confirmedSpaces))
			end)
		end)
	end)
end

local refreshOccupancySafely = logger:wrap("occupancy_refresh_failed", refreshOccupancy)

local function refreshAll()
	refreshSafely()
	refreshOccupancySafely()
end

local function spacesChanged(event)
	local snapshot = hs.spaces.data_managedDisplaySpaces()
	-- Selecting a desktop does not change which desktops contain windows.
	local selectionOnly = event == "space_changed"
	local selectionState
	if selectionOnly then
		local selection = {}
		for _, display in ipairs(snapshot) do
			selection[#selection + 1] = display["Display Identifier"] .. ":" .. display["Current Space"].ManagedSpaceID
		end
		table.sort(selection)
		local state = table.concat(selection, ",")
		if module.selection == state then
			return
		end
		selectionState = state
	else
		module.selection = nil
		module.revision = module.revision + 1
	end
	refreshSafely(snapshot)
	module.selection = selectionState
	if not selectionOnly then
		refreshOccupancySafely()
	end
end

module.spaceWatcher = hs.spaces.watcher
	.new(function()
		spacesChanged("space_changed")
	end)
	:start()
module.screenWatcher = hs.screen.watcher
	.new(function()
		spacesChanged("display_changed")
	end)
	:start()
module.eventRefreshTimer = hs.timer.delayed.new(0.1, function()
	spacesChanged("window-state")
end)
require("yabai-events").subscribe("desktop-indicator", function(event)
	if event == "window_focused" or event == "window_moved" or event == "window_resized" then
		return
	end
	if event:match("^space_") or event:match("^display_") then
		if event ~= "space_changed" then
			module.eventRefreshTimer:stop()
		end
		spacesChanged(event)
	elseif not module.eventRefreshTimer:running() then
		module.eventRefreshTimer:start()
	end
end)
-- Start query deadlines after synchronous module initialization finishes.
module.startupTimer = hs.timer.doAfter(0, function()
	module.refreshTimer = hs.timer.doEvery(3, refreshAll)
	refreshAll()
end)

local controllerSocket = "@controllerSocket@"
if controllerSocket ~= "" then
	require("keybindings").subscribeSocket(controllerSocket, "desktop-indicator", function(reply, request)
		local payload = request.payload
		local args = payload.args or {}
		local changesSpace = payload.action == "focus-space"
			or payload.action == "move-space"
			or (payload.action == "command" and args[1] == "display" and args[2] == "--space")
		if not changesSpace then
			return
		end
		if module.transitionTimer then
			module.transitionTimer:stop()
			module.transitionTimer = nil
		end
		if not reply.ok or not reply.target_space_id then
			return
		end

		-- Read actual state without waiting for the later Space notification.
		local started = hs.timer.absoluteTime()
		local function observe()
			local snapshot = refreshSafely()
			local arrived = false
			for _, display in ipairs(snapshot) do
				if display["Current Space"].ManagedSpaceID == reply.target_space_id then
					arrived = true
					break
				end
			end
			if arrived or hs.timer.absoluteTime() - started >= 250e6 then
				module.transitionTimer:stop()
				module.transitionTimer = nil
			end
		end
		module.transitionTimer = hs.timer.new(0.02, observe):start()
		observe()
	end)
end

return module
