-- luacheck: globals table.merge
-- luacheck: globals u
-- luacheck: ignore 112
local wf = hs.window.filter
local timer = hs.timer.delayed
local log = hs.logger.new("stackline", "info")
local click = hs.eventtap.event.types["leftMouseDown"] -- fyi, print hs.eventtap.event.types to see all event types

log.i("Loading module: stackline")
_G.u = require("lib.utils")
_G.stackline = {} -- access stackline under global 'stackline'
stackline.config = require("stackline.configmanager")
stackline.window = require("stackline.window")

function stackline:init(userConfig) -- {{{
	log.i("Initializing stackline")
	if stackline.manager then -- re-initializtion guard https://github.com/AdamWagner/stackline/issues/46
		return log.i("stackline already initialized")
	end

	-- init config with default settings + user overrides
	self.config:init(u.extend(require("stackline.conf"), userConfig or {}))

	-- init stackmanager, & run update right away
	-- NOTE: Requires self.config to be initialized first
	self.manager = require("stackline.stackmanager"):init()
	self.manager:update({ forceRedraw = true })

	-- Debounce membership queries independently of geometry settling.
	self.queryWindowState = timer.new(
		self.config:get("advanced.maxRefreshRate"),
		function()
			self.manager:update()
		end,
		true -- continue on error
	)

	self:setupListeners()

	self:setupClickTracker()
	return self
end -- }}}

stackline.wf = wf.new():setOverrideFilter({ -- {{{
	-- Default window filter controls what hs.window 'sees'
	visible = true, -- i.e., neither hidden nor minimized
	fullscreen = false,
	currentSpace = true,
	allowRoles = "AXStandardWindow",
}) -- }}}

stackline.events = { -- {{{
	checkOn = {
		wf.windowCreated,
		wf.windowUnhidden,

		wf.windowMoved, -- NOTE: winMoved includes move AND resize evts
		wf.windowUnminimized,

		wf.windowFullscreened,
		wf.windowUnfullscreened,

		wf.windowDestroyed,
		wf.windowHidden,
		wf.windowMinimized,
		wf.windowsChanged, -- NOTE: pseudo-event for any change in list of windows. Addresses missing windowCreated events :/
	},
	forceCheckOn = {
		wf.windowCreated,
		wf.windowsChanged,
		wf.windowMoved,
	},
	redrawOn = {
		wf.windowFocused,
		wf.windowNotVisible,
		wf.windowUnfocused,
		wf.windowDestroyed,
	},
} -- }}}

function stackline:setupListeners() -- {{{
	-- On each win evt above, run update at most once every maxRefreshRate (defaults to 0.3s))
	-- update = query window state & check if redraw needed
	self.wf:subscribe(self.events.checkOn, function(hsWin, _app, evt)
		local forceRedraw = u.contains(self.events.forceCheckOn, evt)
		self.manager.query.invalidate(forceRedraw)

		if evt == wf.windowMoved then
			local win = self.manager:findWindow(hsWin:id())
			if win and not win.stack.motionHidden then
				win.stack:updateGeometry(hsWin)
			end
		end

		log.i("Window event:", evt, "force:", forceRedraw)
		self.queryWindowState:start()
	end)

	-- Focus outside the displayed stacks must also update their inactive colors.
	self.focusFilter = wf.new(true)
	self.focusFilter:subscribe(self.events.redrawOn, self.redrawWinIndicator)
end -- }}}

function stackline:setupClickTracker() -- {{{
	-- Observe releases even when indicator clicks are disabled.
	self.clickTracker = hs.eventtap.new({
		click,
		hs.eventtap.event.types.leftMouseUp,
		hs.eventtap.event.types.rightMouseUp,
		hs.eventtap.event.types.otherMouseUp,
	}, function(e)
		if e:getType() ~= click then
			local releasedButton = e:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber) + 1
			self.manager:releaseGeometry(releasedButton)
			return false
		end
		if not self.config:get("features.clickToFocus") then
			return false
		end
		local clickAt = hs.geometry.point(e:location().x, e:location().y)
		local clickedWin = self.manager:getClickedWindow(clickAt)
		if clickedWin then
			log.i("Clicked window at", clickAt)
			clickedWin._win:focus()
			return true -- stop propogation
		end
	end)

	self.clickTracker:start()
end -- }}}

function stackline:refreshClickTracker() -- {{{
	self.clickTracker:stop()
	self.clickTracker:start()
end -- }}}

function stackline.redrawWinIndicator(hsWin, _app, evt) -- {{{
	if evt == wf.windowDestroyed then
		local id = hsWin:id()
		if id then
			stackline.manager:forgetWindow(id)
		end
	end
	stackline.manager:syncFocus()
end -- }}}

function stackline:setLogLevel(lvl) -- {{{
	log.setLogLevel(lvl)
	log.i(("Window.log level set to %s"):format(lvl))
end -- }}}

stackline.spaceWatcher = hs.spaces.watcher
	.new( -- {{{
		function(spaceIdx)
			-- QUESTION: do I need to clean this up? If so, how?
			-- Update stackline when switching spaces
			-- NOTE: hs.spaces.watcher uses deprecated macos APIs, so this may break in an upcoming macos release
			log.i(("hs.spaces.watcher -> changed to space %d"):format(spaceIdx))
			stackline.manager.query.invalidate(true)
			stackline.queryWindowState:start()
			stackline:refreshClickTracker()
		end
	)
	:start() -- }}}

return stackline
