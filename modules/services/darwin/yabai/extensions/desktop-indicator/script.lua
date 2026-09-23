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
	local request = {
		chunks = {},
		tail = "",
	}
	module.query = request

	local function finish(result)
		if module.query ~= request then
			return
		end
		request.timeout:stop()
		module.query = nil
		callback(result)
	end

	local function complete()
		if module.query ~= request or request.code == nil then
			return
		end
		if request.expired or request.code ~= 0 then
			finish(nil)
			return
		end
		local output = (table.concat(request.chunks) .. request.tail):gsub(":inf,", ":0,")
		local ok, result = pcall(hs.json.decode, output)
		if ok and type(result) == "table" then
			finish(result)
		end
	end

	request.task = hs.task.new("@yabai@", function(code, stdout)
		request.code = code
		request.tail = stdout or ""
		complete()
	end, function(_, stdout)
		if module.query ~= request then
			return false
		end
		table.insert(request.chunks, stdout or "")
		complete()
		return true
	end, { "-m", "query", domain })
	request.timeout = hs.timer.doAfter(5, function()
		request.expired = true
		if request.code == nil then
			request.task:terminate()
		else
			finish(nil)
		end
	end)
	if not request.task or not request.task:start() then
		finish(nil)
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

local function updateDisplay(screen, uuid, activeSpace)
	local frame = screen:frame()
	local fullFrame = screen:fullFrame()
	if frame.y - fullFrame.y < height then
		removeDisplay(uuid)
		return
	end
	if not activeSpace then
		return
	end
	local activeSpaceType = hs.spaces.spaceType(activeSpace)
	if not activeSpaceType then
		return
	end
	if activeSpaceType ~= "user" then
		removeDisplay(uuid)
		return
	end

	local spaces = hs.spaces.spacesForScreen(screen)
	if not spaces then
		return
	end

	local desktops = {}
	local currentIndex
	for _, space in ipairs(spaces) do
		local spaceType = hs.spaces.spaceType(space)
		if not spaceType then
			return
		end
		if spaceType == "user" then
			desktops[#desktops + 1] = space
			if space == activeSpace then
				currentIndex = #desktops
			end
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
	if create then
		canvas:show()
	end
end

local function refresh()
	local activeSpaces = hs.spaces.activeSpaces() or {}
	local connected = {}
	for _, screen in ipairs(hs.screen.allScreens()) do
		local uuid = screen:getUUID()
		if uuid then
			connected[uuid] = true
			updateDisplay(screen, uuid, activeSpaces[uuid])
		end
	end
	for uuid in pairs(module.displays) do
		if not connected[uuid] then
			removeDisplay(uuid)
		end
	end
end

local refreshSafely = logger:wrap("refresh_failed", refresh)

local function refreshOccupancy()
	if module.refreshing then
		return
	end
	module.refreshing = true
	local revision = module.revision
	local function finish(occupancy)
		module.refreshing = false
		if revision == module.revision and occupancy then
			module.occupancy = occupancy
			refreshSafely()
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

local function spacesChanged()
	module.revision = module.revision + 1
	refreshAll()
end

module.spaceWatcher = hs.spaces.watcher.new(spacesChanged):start()
module.screenWatcher = hs.screen.watcher.new(spacesChanged):start()
module.refreshTimer = hs.timer.doEvery(1, refreshAll)
refreshAll()

return module
