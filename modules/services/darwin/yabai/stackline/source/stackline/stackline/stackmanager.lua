local log = hs.logger.new("stackmanager", "info")

local Stackmanager = {}

Stackmanager.query = require("stackline.stackline.query")

local function mouseButtonsDown(releasedButton)
	-- Trust the release event over polling, using one-based button indices.
	for button, pressed in pairs(hs.eventtap.checkMouseButtons()) do
		if type(button) == "number" and button ~= releasedButton and pressed then
			return true
		end
	end
	return false
end

function Stackmanager:init() -- {{{
	self.tabStacks = {}
	self.motionByWindowId = {}
	self.geometryTimer = hs.timer.new(0.2, function()
		self:settleGeometry()
	end)
	self.focusSequence = 0
	self.lastFocusedByWindowId = {}
	self.focusedWindowId = nil
	self.__index = self
	self:syncFocus()
	return self
end -- }}}

function Stackmanager:update(opts) -- {{{
	log.i("Running update()")
	self.query.run(opts) -- calls Stack:ingest when ready
	return self
end -- }}}

function Stackmanager:ingest(stacks) -- {{{
	self:cleanup()

	for stackId, groupedWindows in pairs(stacks) do
		local stack = require("stackline.stackline.stack"):new(groupedWindows)
		stack.id = stackId
		u.each(stack.windows, function(win)
			win.stack = stack
		end)
		stack.motionHidden = self:isStackMoving(stack)
		table.insert(self.tabStacks, stack)
	end
	self:resetAllIndicators()
	self:eachStack(function(stack)
		stack:startGeometryWatchers()
	end)
end -- }}}

function Stackmanager:get() -- {{{
	return self.tabStacks
end -- }}}

function Stackmanager:eachStack(fn) -- {{{
	for _stackId, stack in pairs(self.tabStacks) do
		fn(stack)
	end
end -- }}}

function Stackmanager:cleanup() -- {{{
	self:eachStack(function(stack)
		stack:stopGeometryWatchers()
		stack:deleteAllIndicators()
	end)
	self.tabStacks = {}
end -- }}}

function Stackmanager:forgetWindow(id)
	self.lastFocusedByWindowId[id] = nil
	self.motionByWindowId[id] = nil
end

function Stackmanager:isStackMoving(stack)
	for _, win in ipairs(stack.windows) do
		if self.motionByWindowId[win.id] then
			return true
		end
	end
	return false
end

function Stackmanager:scheduleGeometry()
	self.geometryTimer:stop()
	local deadline
	for _, motion in pairs(self.motionByWindowId) do
		if motion.deadline and (not deadline or motion.deadline < deadline) then
			deadline = motion.deadline
		end
	end
	if deadline then
		self.geometryTimer:setNextTrigger(math.max(0.001, deadline - hs.timer.absoluteTime() / 1e9))
	end
end

function Stackmanager:recordGeometryChange(stack, anchorId)
	self.query.invalidate(false)
	local motion = {
		anchorId = anchorId,
		ready = false,
	}
	if not mouseButtonsDown() then
		motion.deadline = hs.timer.absoluteTime() / 1e9 + 0.2
	end
	for _, win in ipairs(stack.windows) do
		self.motionByWindowId[win.id] = motion
	end
	if not stack.motionHidden then
		stack:setMotionHidden(true)
	end
	self:scheduleGeometry()
end

function Stackmanager:releaseGeometry(releasedButton)
	if not next(self.motionByWindowId) or mouseButtonsDown(releasedButton) then
		return
	end
	self.query.invalidate(false)
	local deadline = hs.timer.absoluteTime() / 1e9 + 0.2
	for _, motion in pairs(self.motionByWindowId) do
		motion.ready = false
		motion.deadline = deadline
	end
	self:scheduleGeometry()
end

function Stackmanager:settleGeometry()
	self.geometryTimer:stop()
	local now = hs.timer.absoluteTime() / 1e9
	local held = mouseButtonsDown()
	local ready = false
	for _, motion in pairs(self.motionByWindowId) do
		if motion.deadline and motion.deadline <= now then
			motion.deadline = nil
			motion.ready = not held
			ready = ready or motion.ready
		end
	end
	self:scheduleGeometry()
	if ready then
		-- Keep indicators hidden until a post-settle query applies current membership.
		self.query.invalidate(false)
		self:update()
	end
end

function Stackmanager:completeGeometry()
	if mouseButtonsDown() then
		return
	end
	local settled = {}
	for id, motion in pairs(self.motionByWindowId) do
		if motion.ready then
			settled[id] = motion.anchorId
			self.motionByWindowId[id] = nil
		end
	end

	local visible = {}
	for _, win in ipairs(stackline.wf:getWindows()) do
		visible[win:id()] = win
	end
	self:eachStack(function(stack)
		if not stack.motionHidden or self:isStackMoving(stack) then
			return
		end
		local anchor
		local complete = true
		for _, win in ipairs(stack.windows) do
			complete = complete and hs.window.get(win.id) ~= nil
			if visible[win.id] and (not anchor or settled[win.id] == win.id) then
				anchor = visible[win.id]
			end
		end
		if complete and anchor and anchor:screen() then
			stack:updateGeometry(anchor)
			stack:setMotionHidden(false)
		end
	end)
end

function Stackmanager:pruneFocusHistory(windows)
	-- Use a current full yabai snapshot, including hidden windows and other spaces.
	local live = {}
	for _, win in ipairs(windows) do
		live[win.id] = true
	end
	for id in pairs(self.lastFocusedByWindowId) do
		if not live[id] then
			self:forgetWindow(id)
		end
	end
end

function Stackmanager:syncFocus()
	local focusedWindow = hs.window.focusedWindow()
	local focusedId = focusedWindow and focusedWindow:id()
	if focusedId and (focusedId ~= self.focusedWindowId or not self.lastFocusedByWindowId[focusedId]) then
		self.focusSequence = self.focusSequence + 1
		self.lastFocusedByWindowId[focusedId] = self.focusSequence
	end
	self.focusedWindowId = focusedId

	self:eachStack(function(stack)
		local stackFocused = false
		local lastActiveId
		local lastSequence = 0
		for _, win in ipairs(stack.windows) do
			stackFocused = stackFocused or win.id == focusedId
			local sequence = self.lastFocusedByWindowId[win.id] or 0
			if sequence > lastSequence then
				lastActiveId = win.id
				lastSequence = sequence
			end
		end
		for _, win in ipairs(stack.windows) do
			local highlighted = (stackFocused and win.id == focusedId) or (not stackFocused and win.id == lastActiveId)
			win:setFocusState(stackFocused, highlighted)
		end
	end)
end

function Stackmanager:getSummary(external) -- {{{
	local stacks = external or self.tabStacks
	local summary = {}
	for _, stack in pairs(stacks) do
		local windows = external and stack or stack.windows
		local members = {}
		for _, win in ipairs(windows) do
			table.insert(members, win.id .. ":" .. win.stackIdx)
		end
		table.sort(members)
		table.insert(summary, windows[1].stackId .. ":" .. table.concat(members, ","))
	end
	table.sort(summary)
	return summary
end -- }}}

function Stackmanager:resetAllIndicators() -- {{{
	self:syncFocus()
	self:eachStack(function(stack)
		stack:resetAllIndicators()
	end)
end -- }}}

function Stackmanager:findWindow(wid) -- {{{
	-- NOTE: A window must be *in* a stack to be found with this method!
	for _stackId, stack in pairs(self.tabStacks) do
		for _idx, win in pairs(stack.windows) do
			if win.id == wid then
				return win
			end
		end
	end
end -- }}}

function Stackmanager:findStackByWindow(win) -- {{{
	for _stackId, stack in pairs(self.tabStacks) do
		if stack.id == win.stackId then
			return stack
		end
	end
end -- }}}

function Stackmanager:getClickedWindow(point) -- {{{
	-- given the coordinates of a mouse click, return the first window whose
	-- indicator element encompasses the point, or nil if none.
	for _stackId, stack in pairs(self.tabStacks) do
		local clickedWindow = stack:getWindowByPoint(point)
		if clickedWindow then
			return clickedWindow
		end
	end
end -- }}}

function Stackmanager:setLogLevel(lvl) -- {{{
	log.setLogLevel(lvl)
	log.i(("Window.log level set to %s"):format(lvl))
end -- }}}

return Stackmanager
