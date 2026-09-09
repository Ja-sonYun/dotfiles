local module = {}
local cpu
local memoryUsed, memoryTotal
local diskUsed, diskTotal

module.menubar = hs.menubar.new(true, "system-monitor")

local function capacity(title, used, total)
	if not used then
		return { title = title .. ": unavailable", disabled = true }
	end
	return {
		title = string.format(
			"%s: %.1f / %.1f GiB (%.1f GiB remaining)",
			title,
			used / 2 ^ 30,
			total / 2 ^ 30,
			(total - used) / 2 ^ 30
		),
		disabled = true,
	}
end

local function render()
	local cpuText = cpu and string.format("%.0f%%", cpu) or "--"
	local memoryText = memoryUsed and string.format("%.0f%%", memoryUsed / memoryTotal * 100) or "--"
	local diskText = diskUsed and string.format("%.0f%%", diskUsed / diskTotal * 100) or "--"
	module.menubar:setTitle("C " .. cpuText .. " · M " .. memoryText .. " · D " .. diskText)
	module.menubar:setMenu({
		{ title = "CPU: " .. cpuText, disabled = true },
		capacity("RAM (active + wired + compressed)", memoryUsed, memoryTotal),
		capacity("Storage", diskUsed, diskTotal),
	})
end

local function updateStorage()
	local volume = hs.fs.volume.allVolumes(true)["/"]
	diskUsed, diskTotal = nil, nil
	if volume and volume.NSURLVolumeTotalCapacityKey and volume.NSURLVolumeAvailableCapacityKey then
		diskTotal = volume.NSURLVolumeTotalCapacityKey
		if diskTotal > 0 then
			diskUsed = diskTotal - volume.NSURLVolumeAvailableCapacityKey
		end
	end
	render()
end

local function updateUsage()
	local vm = hs.host.vmStat()
	memoryTotal = vm.memSize
	memoryUsed = (vm.pagesActive + vm.pagesWiredDown + vm.pagesUsedByVMCompressor) * vm.pageSize
	render()
	module.cpuSample = hs.host.cpuUsage(1, function(usage)
		cpu = usage.overall.active
		render()
	end)
end

updateStorage()
updateUsage()
module.usageTimer = hs.timer.doEvery(3, updateUsage)
module.storageTimer = hs.timer.doEvery(60, updateStorage)

return module
