local log = hs.logger.new("window", "info")
log.i("Loading module: window")

local Window = {}

function Window:new(hsWin) -- {{{
	local stackIdResult = self:makeStackId(hsWin)
	local ws = {
		title = hsWin:title(), -- window title
		app = hsWin:application():name(), -- app name (string)
		id = hsWin:id(), -- window id (string) NOTE: HS win.id == yabai win.id
		frame = hsWin:frame(), -- x,y,w,h of window (table)
		stackId = stackIdResult.stackId, -- "{{x}|{y}|{w}|{h}" e.g., "35|63|1185|741" (string)
		topLeft = stackIdResult.topLeft, -- "{{x}|{y}" e.g., "35|63" (string)
		stackIdFzy = stackIdResult.fzyFrame, -- "{{x}|{y}" e.g., "35|63" (string)
		_win = hsWin, -- hs.window object (table)
		screen = hsWin:screen():id(),
		indicator = nil, -- the canvas element (table)
	}
	setmetatable(ws, self)
	self.__index = self

	log.i(("Window:new(%s)"):format(ws.id))

	return ws
end -- }}}

function Window:setupIndicator(geometry) -- {{{
	log.d("setupIndicator for", self.id)
	self.config = stackline.config:get("appearance")
	local c = self.config

	-- computed from config
	self.width = c.size / c.pillThinness

	-- Set canvas to fill entire screen
	self.screen = geometry and geometry.screen or self._win:screen()
	self.frame = self.screen:absoluteToLocal(hs.geometry(geometry and geometry.frame or self._win:frame()))

	local xval = self:getIndicatorPosition()

	-- Store  canvas elements indexes to reference via :elementAttribute()
	-- https://www.hammerspoon.org/docs/hs.canvas.html#elementAttribute
	self.rectIdx = 1

	-- NOTE: self.stackIdx comes from yabai. Window is stacked if stackIdx > 0
	self.indicator_rect = {
		x = xval,
		y = self.frame.y + c.offset.y + ((self.stackIdx - 1) * c.size * c.vertSpacing),
		w = self.width,
		h = c.size,
	}

	return self
end -- }}}

function Window:updateIndicatorGeometry(geometry) -- {{{
	self:setupIndicator(geometry)
	if self.indicator then
		self.indicator:frame(self.screenFrame)
		self.indicator[self.rectIdx].frame = self.indicator_rect
	end
end -- }}}

function Window:drawIndicator(overrideOpts) -- {{{
	log.i("drawIndicator for", self.id)
	-- should there be a dedicated "Indicator" class to perform the actual drawing?
	local opts = u.extend(self.config, overrideOpts or {})
	local fadeDuration = opts.shouldFade and opts.fadeDuration or 0

	if self.indicator then
		self.indicator:delete()
	end

	-- TODO: Should we really create a new canvas for each window? Or should
	-- there be one canvas per screen/space into which each window's indicator element is appended?
	self.indicator = hs.canvas.new(self.screenFrame)

	self.indicator:insertElement({
		type = "rectangle",
		action = "fill", -- options: strokeAndFill, stroke, fill
		fillColor = self:getColorAttrs(self.stackFocused, self.highlighted).bg,
		frame = self.indicator_rect,
		roundedRectRadii = { xRadius = opts.radius, yRadius = opts.radius },
		withShadow = false,
		shadow = self:getShadowAttrs(),
		-- trackMouseEnterExit = true,
		-- trackMouseByBounds = true,
		-- trackMouseDown = true,
	}, self.rectIdx)

	self.indicator:clickActivating(false) -- clicking on a canvas elment should NOT bring Hammerspoon wins to front
	if not self.stack.motionHidden then
		self.indicator:show(fadeDuration)
	end
	return self
end -- }}}

function Window:setFocusState(stackFocused, highlighted)
	local changed = self.stackFocused ~= stackFocused or self.highlighted ~= highlighted
	self.stackFocused = stackFocused
	self.highlighted = highlighted
	if changed and self.indicator then
		self.indicator[self.rectIdx].fillColor = self:getColorAttrs(stackFocused, highlighted).bg
		self.indicator[self.rectIdx].shadow = self:getShadowAttrs()
	end
end

function Window:getIndicatorPosition() -- {{{
	self.screenFrame = self.screen:fullFrame()
	self.side = "right"
	return self.frame.x + self.frame.w - self.width - self.config.offset.x
end -- }}}

function Window:getColorAttrs(isStackFocused, isHighlighted) -- {{{
	local opts = self.config
	-- Choose indicator color based on stack and window focus.
	local colorLookup = {
		stack = {
			["true"] = {
				window = {
					["true"] = {
						bg = u.extend(opts.color, { alpha = opts.alpha }),
					},
					["false"] = {
						bg = u.extend(u.copy(opts.color), { alpha = opts.alpha / opts.dimmer }),
					},
				},
			},
			["false"] = {
				window = {
					["true"] = {
						bg = u.extend(u.copy(opts.color), {
							alpha = opts.alpha / (opts.dimmer / 1.2),
						}),
					},
					["false"] = {
						bg = u.extend(u.copy(opts.color), {
							alpha = 0.2,
						}),
					},
				},
			},
		},
	}
	-- end

	local isStackFocusedKey = tostring(isStackFocused)
	local isHighlightedKey = tostring(isHighlighted)
	return colorLookup.stack[isStackFocusedKey].window[isHighlightedKey]
end -- }}}

function Window:getShadowAttrs() -- {{{
	local alphaDimmer = (self.highlighted and 6 or 7) * 5
	local blurDimmer = (self.highlighted and 15.0 or 7.0) / 5

	-- Shadows should cast outwards toward the screen edges as if due to the glow of onscreen windows…
	-- …or, if you prefer, from a light source originating from the center of the screen.
	local xDirection = (self.side == "left") and -1 or 1
	local offset = {
		h = (self.highlighted and 3.0 or 2.0) * -1.0,
		w = ((self.highlighted and 7.0 or 6.0) * xDirection) / 5,
	}

	-- TODO [just for fun]: Dust off an old Geometry textbook and try get the shadow's angle to rotate around a point at the center of the screen (aka, 'light source')
	-- Here's a super crude POC that uses the indicator's stack index such that
	-- higher indicators have a negative Y offset and lower indicators have a positive Y offset
	--   h = (self.highlighted and 3.0 or 2.0 - (2 + (self.stackIdx * 5))) * -1.0,

	return {
		blurRadius = blurDimmer,
		color = { alpha = 1 / alphaDimmer }, -- TODO align all alpha values to be defined like this (1/X)
		offset = offset,
	}
end -- }}}

function Window:makeStackId(hsWin) -- {{{
	local frame = hsWin:frame():floor()

	local x = frame.x
	local y = frame.y
	local w = frame.w
	local h = frame.h

	local fuzzFactor = stackline.config:get("features.fzyFrameDetect.fuzzFactor")
	local roundToFuzzFactor = u.partial(u.roundToNearest, fuzzFactor)
	local ff = u.map({ x, y, w, h }, roundToFuzzFactor)

	return {
		topLeft = table.concat({ x, y }, "|"),
		stackId = table.concat({ x, y, w, h }, "|"),
		fzyFrame = table.concat(ff, "|"),
	}
end -- }}}

function Window:deleteIndicator() -- {{{
	log.d("deleteIndicator for", self.id)
	if self.indicator then
		self.indicator:delete(self.config.fadeDuration)
		self.indicator = nil
	end
end -- }}}

function Window:setLogLevel(lvl) -- {{{
	log.setLogLevel(lvl)
	log.i(("Window.log level set to %s"):format(lvl))
end -- }}}

return Window
