local module = {}
local uidOutput, uidRead = hs.execute("/usr/bin/id -u", false)
local uid = uidRead and tonumber(uidOutput)

local function secureLog(path)
	if not uid then
		hs.printf("Cannot determine the log file owner")
		return false
	end
	local quoted = "'" .. path:gsub("'", "'\\''") .. "'"
	local attributes = hs.fs.symlinkAttributes(path)
	if not attributes then
		local command = "log_tmp=$(/usr/bin/mktemp "
			.. quoted
			.. '.XXXXXX) || exit 1; /bin/link "$log_tmp" '
			.. quoted
			.. '; log_status=$?; /bin/rm -f "$log_tmp"; exit "$log_status"'
		local output, created = hs.execute(command, false)
		attributes = hs.fs.symlinkAttributes(path)
		if not created and not attributes then
			hs.printf("File log creation failed (%s): %s", path, tostring(output))
			return false
		end
	end
	-- The sticky /tmp directory prevents other users replacing an owned file.
	if not attributes or attributes.mode ~= "file" or attributes.uid ~= uid or attributes.nlink ~= 1 then
		hs.printf("Unsafe log file rejected: %s", path)
		return false
	end
	if attributes.permissions == "rw-------" then
		return true
	end
	local output, secured = hs.execute("/bin/chmod 600 " .. quoted, false)
	if not secured then
		hs.printf("File log permissions failed (%s): %s", path, tostring(output))
	end
	return secured
end

function module.new(name, destination)
	local logger = { context = {}, destination = destination or "/tmp/hammerspoon", name = name }
	secureLog(logger.destination .. ".out.log")
	secureLog(logger.destination .. ".err.log")
	function logger:write(level, event, fields)
		local record = {}
		for key, value in pairs(self.context) do
			record[key] = value
		end
		for key, value in pairs(fields or {}) do
			record[key] = value
		end
		record.time = os.date("!%Y-%m-%dT%H:%M:%SZ")
		record.module = self.name
		record.level = level
		record.event = tostring(event)
		local encoded, line = pcall(hs.json.encode, record)
		if not encoded then
			hs.printf("File log encoding failed (%s): %s", self.name, tostring(line))
			return
		end
		local suffix = (level == "error" or level == "warning") and ".err.log" or ".out.log"
		local path = self.destination .. suffix
		if not secureLog(path) then
			return
		end
		local file, err = io.open(path, "a")
		if file then
			local written, writeError = file:write(line .. "\n")
			local closed, closeError = file:close()
			if written and closed then
				return
			end
			err = writeError or closeError
		end
		hs.printf("File logging failed (%s): %s", self.name, tostring(err))
	end
	function logger:i(event, fields)
		self:write("info", event, fields)
	end
	function logger:w(event, fields)
		self:write("warning", event, fields)
	end
	function logger:e(event, fields)
		self:write("error", event, fields)
	end
	function logger:wrap(event, callback)
		return function(...)
			local result = table.pack(xpcall(callback, debug.traceback, ...))
			if not result[1] then
				self:e(event, { traceback = result[2] })
				error(result[2], 0)
			end
			return table.unpack(result, 2, result.n)
		end
	end
	return logger
end

return module
