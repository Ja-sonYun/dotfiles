-- default stackline config
-- TODO: Experiment with setting __index() metatable to leverage autosuggest when keys not found

c = {}
c.paths = {}
c.appearance = {}
c.features = {}
c.advanced = {}

-- Paths
c.paths.yabai = "/usr/local/bin/yabai"

-- Appearance
c.appearance.color = { white = 1 }
c.appearance.alpha = 1 -- Opacity of active indicators
c.appearance.dimmer = 2.5 -- Higher numbers increase contrast b/n focused & unfocused state
-- Set pill height in logical points.
c.appearance.size = 24
c.appearance.radius = 1.5
-- Pill width is size divided by pillThinness.
c.appearance.pillThinness = 8

-- Indicator starts are separated by size multiplied by vertSpacing.
c.appearance.vertSpacing = 1.25

c.appearance.offset = {} -- Offset controls position of stack indicators relative to the window
c.appearance.offset.y = 12 -- Distance from top of the window to render indicators
-- Inset indicators from the window edge and pad the background horizontally.
c.appearance.offset.x = 2

c.appearance.shouldFade = false -- Enable/disable fade animations
c.appearance.fadeDuration = 0 -- Duration of fade animations (seconds)

-- Features
c.features.clickToFocus = false -- Click indicator to focus window. Mouse clicks are tracked when enabled

c.features.fzyFrameDetect = {} -- Round window frame dimensions by fuzzFactor before identifying stacked windows
c.features.fzyFrameDetect.enabled = true -- Enable/disable fuzzy frame detection
c.features.fzyFrameDetect.fuzzFactor = 30 -- Window frame dimensions will be rounded to nearest fuzzFactor

c.features.winTitles = false -- Valid options: false, true, 'when_switching', 'not_implemented'
c.features.dynamicLuminosity = "not_implemented" -- Valid options: false, true, 'not_implemented'

c.advanced.maxRefreshRate = 0.5 -- How aggressively to refresh Stackline. Higher = slower response time + less battery drain

return c
