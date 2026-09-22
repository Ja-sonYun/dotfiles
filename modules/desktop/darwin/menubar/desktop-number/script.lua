local module = {}
local logger = require("logging").new("desktop-number")

module.menuBar = hs.menubar.new(false, "desktop-number")
if not module.menuBar then
	logger:e("menubar_creation_failed")
	return module
end

local function setNumber(number)
	if module.number == number then
		return
	end

	module.number = number
	logger:i("desktop_display_changed", { number = number, visible = number ~= nil })
	if number then
		module.menuBar:setTitle(tostring(number))
		module.menuBar:returnToMenuBar()
	else
		module.menuBar:removeFromMenuBar()
	end
end

local function refresh()
	local focused = hs.spaces.focusedSpace()
	local display = focused and hs.spaces.spaceDisplay(focused)
	local spaces = display and hs.spaces.spacesForScreen(display)
	if not spaces then
		setNumber(nil)
		return
	end

	local number = 0
	for _, space in ipairs(spaces) do
		if hs.spaces.spaceType(space) == "user" then
			number = number + 1
			if space == focused then
				setNumber(number)
				return
			end
		end
	end
	setNumber(nil)
end

module.spaceWatcher = hs.spaces.watcher
	.new(logger:wrap("space_refresh_failed", function()
		logger:i("space_changed")
		refresh()
	end))
	:start()
module.screenWatcher = hs.screen.watcher
	.newWithActiveScreen(logger:wrap("screen_refresh_failed", function()
		logger:i("screen_changed")
		refresh()
	end))
	:start()
logger:i("watchers_started")
refresh()

return module
