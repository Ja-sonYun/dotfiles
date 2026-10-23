local config = hs.json.decode([==[@configJson@]==])
local module = { runID = hs.host.uuid() }
local levels = { debug = 10, info = 20, warning = 30, error = 40 }
local application = hs.application.get("org.hammerspoon.Hammerspoon")
local pid = application and application:pid() or 0
local connection
local pending

local function finish(token, disconnect)
	if pending ~= token then
		return
	end
	pending = nil
	if token.timer then
		token.timer:stop()
	end
	if disconnect then
		pcall(function()
			token.socket:disconnect()
		end)
		if connection == token.socket then
			connection = nil
		end
	end
end

local function send(packet)
	if pending then
		return
	end
	if not connection then
		local ok, socket = pcall(hs.socket.new)
		if not ok or not socket then
			return
		end
		connection = socket
	end
	local token = { socket = connection }
	pending = token
	-- Bound pending state even when a failed operation has no completion callback.
	token.timer = hs.timer.doAfter(1, function()
		finish(token, true)
	end)

	local function write()
		if pending ~= token then
			return
		end
		local ok = pcall(function()
			token.socket:write(packet, 0, function()
				finish(token, false)
			end)
		end)
		if not ok then
			finish(token, true)
		end
	end

	local ok = pcall(function()
		token.socket:setTimeout(1)
		if token.socket:connected() then
			write()
		elseif not token.socket:connect(config.socketPath, write) then
			finish(token, true)
		end
	end)
	if not ok then
		finish(token, true)
	end
end

function module.close()
	if pending then
		finish(pending, true)
	elseif connection then
		pcall(function()
			connection:disconnect()
		end)
		connection = nil
	end
end

function module.new(name)
	local logger = { context = {}, name = name }
	function logger:write(level, event, fields)
		if config.socketPath == "" or pending or not levels[level] or levels[level] < levels[config.level] then
			return
		end
		local encoded, line = pcall(function()
			local context = {}
			for key, value in pairs(self.context) do
				context[key] = value
			end
			for key, value in pairs(fields or {}) do
				context[key] = value
			end
			event = tostring(event)
			if #event > 64 then
				if context.message == nil then
					context.message = event
				else
					context.event_message = event
				end
				event = "message"
			end
			context.hammerspoon_run_id = module.runID
			context.time_unix = hs.timer.secondsSinceEpoch()
			for key, value in pairs(context) do
				context[key] = type(value) == "table" and hs.json.encode(value) or tostring(value)
			end
			return hs.json.encode({
				time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
				component = "hammerspoon." .. self.name,
				level = level,
				event = event,
				pid = pid,
				fields = context,
			})
		end)
		if not encoded or type(line) ~= "string" or #line + 1 > 32768 then
			return
		end
		send(line .. "\n")
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
