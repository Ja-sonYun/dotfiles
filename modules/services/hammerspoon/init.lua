hs.autoLaunch(@autoLaunch@)

_nixConfigWatcher = hs.pathwatcher.new(hs.configdir, function(paths)
	for _, path in ipairs(paths) do
		if path == hs.configdir .. "/init.lua" then
			hs.reload()
			return
		end
	end
end):start()

package.path = "@scriptsDir@/?.lua;" .. package.path

@scriptRequires@
