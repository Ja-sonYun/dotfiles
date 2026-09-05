local module = {}
local rules = hs.json.decode([==[@rulesJson@]==])

module.watcher = hs.application.watcher.new(function(appName, event)
	if event ~= hs.application.watcher.activated then
		return
	end

	local sourceID = rules[appName]
	if sourceID then
		hs.keycodes.currentSourceID(sourceID)
	end
end)

module.watcher:start()

return module
