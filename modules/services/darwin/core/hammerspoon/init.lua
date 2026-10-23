package.path = "@scriptsDir@/?.lua;" .. package.path
local logger = require("logging").new("hammerspoon")
logger:i("initialization_started")
local showError = hs.showError
hs.showError = function(message)
	logger:e("unhandled_error", { message = tostring(message) })
	return showError(message)
end

assert(not package.loaded["hs.window_filter"], "Window filter loaded before its Space refresh patch")
package.preload["hs.window_filter"] = assert(loadfile("@windowFilterLoader@"))

local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
	logger:i("shutdown_started")
	if previousShutdown then
		previousShutdown()
	end
	require("logging").close()
end

require("hs.ipc")

hs.autoLaunch(@autoLaunch@)

_nixConfigWatcher = hs.pathwatcher.new(hs.configdir, function(paths)
	for _, path in ipairs(paths) do
		if path == hs.configdir .. "/init.lua" then
			logger:i("configuration_reload_requested")
			hs.reload()
			return
		end
	end
end):start()

logger:i("config_watcher_started")

local function loadModule(name)
	logger:wrap("module_load_failed", function()
		require(name)
	end)()
	logger:i("module_loaded", { target = name })
end

@scriptRequires@

logger:i("initialization_finished")
