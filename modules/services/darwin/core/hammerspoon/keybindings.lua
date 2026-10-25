local module = {}
local logger = require("logging").new("keybindings")
local bindings = assert(hs.json.read("@bindings@"), "Cannot read Hammerspoon keybindings")
local activeTasks = {}
local sockets = {}
local socketSubscribers = {}
local requestID = 0
local pressed = {}
local stopping = false
local properties = hs.eventtap.event.properties
local eventTypes = hs.eventtap.event.types
local rawMasks = hs.eventtap.event.rawFlagMasks
local syntheticTag = 0x484B4253
local keyAliases = {
	enter = "return",
	esc = "escape",
	backspace = "delete",
	minus = "-",
	equal = "=",
	slash = "/",
	comma = ",",
	period = ".",
	semicolon = ";",
}

function module.subscribeSocket(path, name, callback)
	socketSubscribers[path] = socketSubscribers[path] or {}
	socketSubscribers[path][name] = callback
end

local function keyCode(key)
	if key:match("^0x[%da-fA-F]+$") then
		return tonumber(key:sub(3), 16)
	end
	return assert(hs.keycodes.map[keyAliases[key] or key], "Unknown Hammerspoon key: " .. key)
end

for _, binding in ipairs(bindings) do
	binding.keyCode = keyCode(binding.key)
	local modifiers = {}
	for _, modifier in ipairs(binding.modifiers) do
		modifiers[modifier] = true
	end
	binding.modifiers = modifiers
	if type(binding.command) == "table" then
		binding.executable = binding.command[1]
		binding.arguments = { table.unpack(binding.command, 2) }
	elseif binding.command then
		binding.executable = "@bash@"
		binding.arguments = { "-c", binding.command }
	elseif binding.lua then
		binding.callback =
			logger:wrap("lua_action_failed", assert(load(binding.lua, "keybinding:" .. binding.name, "t")))
	elseif binding.sendKey then
		binding.sendKey.keyCode = keyCode(binding.sendKey.key)
	elseif binding.socket then
		local path = binding.socket.path
		sockets[path] = sockets[path] or { path = path, queue = {} }
		binding.socketState = sockets[path]
	end
end

local function matches(binding, event)
	if binding.keyCode ~= event:getKeyCode() then
		return false
	end
	local flags = event:getFlags()
	local modifiers = binding.modifiers
	if
		flags.fn
		or (not not flags.cmd) ~= not not (modifiers.cmd or modifiers.rcmd)
		or (not not flags.alt) ~= not not (modifiers.alt or modifiers.lalt)
		or (not not flags.ctrl) ~= not not modifiers.ctrl
		or (not not flags.shift) ~= not not modifiers.shift
	then
		return false
	end

	local rawFlags = event:rawFlags()
	return (not modifiers.rcmd or (rawFlags & rawMasks.deviceRightCommand) ~= 0)
		and (not modifiers.lalt or (rawFlags & rawMasks.deviceLeftAlternate) ~= 0)
end

local function runCommand(binding)
	local task
	task = hs.task.new(binding.executable, function(code, _, stderr)
		activeTasks[task] = nil
		if code ~= 0 then
			logger:e("command_failed", { binding = binding.name, exit_code = code, stderr = stderr })
		end
	end, binding.arguments)
	if not task then
		logger:e("command_task_creation_failed", { binding = binding.name })
		return
	end

	activeTasks[task] = true
	if not task:start() then
		activeTasks[task] = nil
		logger:e("command_task_start_failed", { binding = binding.name })
	end
end

local function stopSocketTimer(state)
	if state.timer then
		state.timer:stop()
		state.timer = nil
	end
end

local function failSocket(state, message)
	local request = state.active or state.queue[1]
	local binding = request and request.binding
	local dropped = {}
	for _, queued in ipairs(state.queue) do
		dropped[#dropped + 1] = queued.id
	end
	logger:e("socket_requests_aborted", {
		request = request and request.id,
		queued = dropped,
		error = message,
	})
	stopSocketTimer(state)
	local socket = state.socket
	state.socket = nil
	state.connecting = false
	state.active = nil
	state.queue = {}
	if socket then
		socket:disconnect()
	end
	if binding then
		logger:e("socket_action_failed", { binding = binding.name, error = message })
		hs.alert.show("Shortcut connection failed. See Hammerspoon log.", 3)
	else
		logger:e("socket_connection_failed", { path = state.path, error = message })
	end
end

local pumpSocket

local function connectSocket(state)
	if state.connecting or stopping then
		return
	end
	if state.socket then
		state.socket:disconnect()
	end
	local socket
	socket = hs.socket.new(function(data)
		if stopping or state.socket ~= socket then
			return
		end
		local active = state.active
		local decoded, reply = pcall(hs.json.decode, data)
		if
			not decoded
			or type(reply) ~= "table"
			or not active
			or reply.id ~= active.id
			or type(reply.ok) ~= "boolean"
		then
			failSocket(state, "Invalid socket response; execution is unknown")
			return
		end

		stopSocketTimer(state)
		state.active = nil
		if not reply.ok then
			logger:e("socket_action_failed", {
				request = active.id,
				binding = active.binding.name,
				error = reply.error,
			})
		end
		pumpSocket(state)
		for name, callback in pairs(socketSubscribers[state.path] or {}) do
			local ok, err = xpcall(callback, debug.traceback, reply, {
				id = active.id,
				payload = active.binding.socket.payload,
			})
			if not ok then
				logger:e("socket_subscriber_failed", { subscriber = name, request = active.id, error = err })
			end
		end
	end)
	state.socket = socket
	state.connecting = true
	state.timer = hs.timer.doAfter(3, function()
		if state.socket == socket then
			failSocket(state, "Socket connection timed out; pending shortcuts were not sent")
		end
	end)
	local ok, result = pcall(function()
		return socket:connect(state.path, function()
			if stopping or state.socket ~= socket then
				return
			end
			stopSocketTimer(state)
			state.connecting = false
			pumpSocket(state)
		end)
	end)
	if not ok or not result then
		failSocket(state, "Cannot connect to shortcut socket")
	end
end

pumpSocket = function(state)
	if stopping or state.active or state.connecting or #state.queue == 0 then
		return
	end
	if not state.socket or not state.socket:connected() then
		connectSocket(state)
		return
	end

	local request = table.remove(state.queue, 1)
	local binding = request.binding
	state.active = request
	state.timer = hs.timer.doAfter(15, function()
		failSocket(state, "Socket response timed out; execution is unknown")
	end)
	-- Frame replies explicitly because hs.socket does not expose EOF to Lua.
	-- https://www.hammerspoon.org/docs/hs.socket.html#read
	local ok, result = pcall(function()
		if not state.socket:read("\n") then
			return false
		end
		return state.socket:write(hs.json.encode({ id = request.id, payload = binding.socket.payload }) .. "\n")
	end)
	if not ok or not result then
		failSocket(state, "Socket write failed; execution is unknown")
	end
end

for _, state in pairs(sockets) do
	connectSocket(state)
end

module.keyWatcher = hs.eventtap
	.new({ eventTypes.keyDown, eventTypes.keyUp }, function(event)
		if stopping or event:getProperty(properties.eventSourceUserData) == syntheticTag then
			return false
		end

		local code = event:getKeyCode()
		local binding = pressed[code]
		if event:getType() == eventTypes.keyUp then
			pressed[code] = nil
			return binding ~= nil and not binding.passthrough
		end

		-- Keep repeats and releases paired with the original key-down binding.
		if event:getProperty(properties.keyboardEventAutorepeat) == 0 then
			binding = nil
			for _, candidate in ipairs(bindings) do
				if matches(candidate, event) then
					binding = candidate
					break
				end
			end
			pressed[code] = binding
		end
		if not binding then
			return false
		end
		if not matches(binding, event) then
			return not binding.passthrough
		end

		if binding.command then
			runCommand(binding)
			return not binding.passthrough
		elseif binding.lua then
			binding.callback()
			return not binding.passthrough
		elseif binding.socket then
			requestID = requestID + 1
			table.insert(binding.socketState.queue, {
				id = requestID,
				binding = binding,
			})
			pumpSocket(binding.socketState)
			return not binding.passthrough
		end

		-- Tag both events so synthesized shortcuts cannot trigger this dispatcher again.
		local down = hs.eventtap.event.newKeyEvent(binding.sendKey.modifiers, binding.sendKey.keyCode, true)
		local up = hs.eventtap.event.newKeyEvent(binding.sendKey.modifiers, binding.sendKey.keyCode, false)
		down:setProperty(properties.eventSourceUserData, syntheticTag)
		up:setProperty(properties.eventSourceUserData, syntheticTag)
		return not binding.passthrough, { down, up }
	end)
	:start()

local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
	stopping = true
	module.keyWatcher:stop()
	for task in pairs(activeTasks) do
		task:terminate()
	end
	for _, state in pairs(sockets) do
		stopSocketTimer(state)
		if state.socket then
			state.socket:disconnect()
		end
	end
	if previousShutdown then
		previousShutdown()
	end
end

return module
