local Stack = {}

function Stack:new(stackedWindows) -- {{{
	local stack = {
		windows = stackedWindows,
	}
	setmetatable(stack, self)
	self.__index = self
	return stack
end -- }}}

function Stack:get() -- {{{
	return self.windows
end -- }}}

function Stack:getHs() -- {{{
	return u.map(self.windows, function(w)
		return w._win
	end)
end -- }}}

function Stack:frame() -- {{{
	-- All stacked windows have the same dimensions,
	-- so the 1st Hs window's frame is ~= to the stack's frame
	-- TODO: Incorrect when the 1st window has min-size < stack width. See ./query.lua:105
	return self.windows[1]._win:frame()
end -- }}}

function Stack:eachWin(fn) -- {{{
	for _idx, win in pairs(self.windows) do
		fn(win)
	end
end -- }}}

function Stack:getOtherAppWindows(win) -- {{{
	-- NOTE: may not need when HS issue #2400 is closed
	return u.filter(self:get(), function(w)
		return w.app == win.app
	end)
end -- }}}

function Stack:startGeometryWatchers()
	self.geometryWatchers = {}
	self:eachWin(function(win)
		local watcher = win._win:newWatcher(function()
			if self.geometryWatchers then
				stackline.manager:recordGeometryChange(self, win.id)
			end
		end)
		watcher:start({
			hs.uielement.watcher.windowMoved,
			hs.uielement.watcher.windowResized,
		})
		table.insert(self.geometryWatchers, watcher)
	end)
end

function Stack:stopGeometryWatchers()
	for _, watcher in ipairs(self.geometryWatchers or {}) do
		watcher:stop()
	end
	self.geometryWatchers = nil
end

function Stack:setMotionHidden(hidden)
	self.motionHidden = hidden
	local method = hidden and "hide" or "show"
	if self.background then
		self.background[method](self.background, 0)
	end
	self:eachWin(function(win)
		if win.indicator then
			win.indicator[method](win.indicator, 0)
		end
	end)
end

function Stack:updateGeometry(hsWin) -- {{{
	local anchor = hsWin or self.windows[1]._win
	local geometry = {
		screen = anchor:screen(),
		frame = anchor:frame(),
	}
	local top = math.huge
	local bottom = -math.huge
	self:eachWin(function(w)
		w:updateIndicatorGeometry(geometry)
		top = math.min(top, w.indicator_rect.y)
		bottom = math.max(bottom, w.indicator_rect.y + w.indicator_rect.h)
	end)

	local first = self.windows[1]
	local paddingX = first.config.offset.x
	local paddingY = 4
	local width = first.width + paddingX * 2
	local height = bottom - top + paddingY * 2
	self.backgroundFrame = {
		x = first.screenFrame.x + first.indicator_rect.x - paddingX,
		y = first.screenFrame.y + top - paddingY,
		w = width,
		h = height,
	}
	if self.background then
		self.background:frame(self.backgroundFrame)
		self.background[1].frame = { x = 0, y = 0, w = width, h = height }
	end
end -- }}}

function Stack:resetAllIndicators() -- {{{
	if self.background then
		self.background:delete()
		self.background = nil
	end

	self:updateGeometry()
	local width = self.backgroundFrame.w
	local height = self.backgroundFrame.h
	self.background = hs.canvas.new(self.backgroundFrame)
	self.background:insertElement({
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
			xRadius = width / 2,
			yRadius = width / 2,
		},
	})
	self.background:clickActivating(false)
	if not self.motionHidden then
		self.background:show()
	end

	self:eachWin(function(w)
		w:drawIndicator()
	end)
end -- }}}

function Stack:deleteAllIndicators() -- {{{
	if self.background then
		self.background:delete()
		self.background = nil
	end

	self:eachWin(function(win)
		win:deleteIndicator()
	end)
end -- }}}

function Stack:getWindowByPoint(p)
	if self.motionHidden then
		return
	end
	for _, win in ipairs(self.windows) do
		if win.indicator and win.indicator:isShowing() then
			local origin = win.indicator:frame()
			local rect = win.indicator:canvasElements()[win.rectIdx].frame
			local absoluteRect = hs.geometry.rect(origin.x + rect.x, origin.y + rect.y, rect.w, rect.h)
			if p:inside(absoluteRect) then
				return win
			end
		end
	end
end

return Stack
