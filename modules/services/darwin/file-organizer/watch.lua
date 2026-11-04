local service = { watchers = {}, task = nil, prepare = 1, prepared = 0, startup = true }
local paths = hs.json.decode([==[@paths@]==])

local function run()
	if service.task then
		return
	end
	local arguments = { hs.processInfo.bundlePath .. "/Contents/Frameworks/hs/hs" }
	local preparation = service.prepare
	local resume = service.startup
	if preparation > service.prepared then
		table.insert(arguments, "--prepare")
	end
	if resume then
		table.insert(arguments, "--resume")
	end
	service.task = hs.task.new("@command@", function(code, stdout, stderr)
		service.task = nil
		for line in stdout:gmatch("[^\r\n]+") do
			local ok, response = pcall(hs.json.decode, line)
			if ok and type(response) == "table" then
				if response.event == "resume-complete" and resume then
					service.startup = false
				elseif response.event == "prepare-complete" then
					service.prepared = math.max(service.prepared, preparation)
				end
			end
		end
		if code ~= 0 or stderr ~= "" then
			hs.printf("file-organizer: %s", stderr)
		end
	end, arguments)
	if not service.task:start() then
		service.task = nil
		hs.printf("file-organizer: worker could not start")
	end
end

for _, path in ipairs(paths) do
	table.insert(service.watchers, hs.pathwatcher.new(path, run):start())
end
service.timer = hs.timer.doEvery(5, run)
service.daily = hs.timer.doAt("00:05", "1d", function()
	service.prepare = service.prepare + 1
	run()
end)
local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
	service.timer:stop()
	service.daily:stop()
	for _, watcher in ipairs(service.watchers) do
		watcher:stop()
	end
	if service.task then
		service.task:terminate()
	end
	if previousShutdown then
		previousShutdown()
	end
end
run()
return service
