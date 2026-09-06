local function extract(ctx)
	local channel, kind, workspace = ctx.title:match("^(.-) %((.-)%) %- (.-) %- Slack$")
	local view = kind == "DM" and "dm" or (kind == "Channel" and "channel" or "unknown")
	local result = { kind = "slack", workspace = workspace, channel = channel, view = view }
	local threads = {}
	ctx.walk(ctx.window, function(element, role)
		if role == "AXWebArea" then
			result.url = ctx.url(element)
		end
		if role == "AXRadioButton" and ctx.read(element, "AXValue") == 1 then
			local title = ctx.read(element, "AXTitle")
			if title == "Workflows" then
				result.view = "workflows"
			elseif title == "Files & links" then
				result.view = "files_links"
			end
		end
		if role == "AXList" then
			local description = ctx.read(element, "AXDescription")
			if type(description) == "string" and description:lower():find("thread", 1, true) then
				threads[#threads + 1] = element
			end
			return "skip"
		end
	end, 150)
	if #threads > 0 then
		result.thread = { preview = "", truncated = false }
		local children = ctx.read(threads[1], "AXChildren") or {}
		if children[1] then
			local parts, count = {}, 0
			ctx.walk(children[1], function(element, role)
				if role == "AXLink" then
					local url = ctx.url(element)
					if url and url:find("/archives/", 1, true) and not result.thread.url then
						result.thread.url = url
					end
				end
				if role == "AXStaticText" then
					local value = ctx.read(element, "AXValue")
					if type(value) == "string" and value:match("%S") then
						local length = utf8.len(value) or 0
						local separator = #parts > 0 and 1 or 0
						local remaining = 300 - count - separator
						if remaining <= 0 then
							result.thread.truncated = true
							return "stop"
						end
						if length > remaining then
							value = value:sub(1, utf8.offset(value, remaining + 1) - 1)
						end
						parts[#parts + 1] = value
						count = count + math.min(length, remaining) + separator
						if length >= remaining then
							result.thread.truncated = true
							return "stop"
						end
					end
				end
			end, 60, true)
			result.thread.preview = table.concat(parts, " ")
		end
		if result.thread.preview == "" then
			ctx.missing("thread.preview")
		end
		if not result.thread.url then
			ctx.missing("thread.url")
		end
	end
	if not channel then
		ctx.missing("channel")
	end
	if not workspace then
		ctx.missing("workspace")
	end
	if not result.url then
		ctx.missing("url")
	end
	if result.view == "unknown" then
		ctx.missing("view")
	end
	local summary = (workspace or "?")
		.. " / "
		.. (channel or "?")
		.. " · "
		.. result.view
		.. " · "
		.. (result.url or "?")
	if result.thread then
		summary = summary .. " · thread: " .. (result.thread.url or "?") .. " · " .. result.thread.preview
		if result.thread.truncated then
			summary = summary .. "…"
		end
	end
	return result, summary, result.url ~= nil or channel ~= nil
end

return { extract = extract, manualAccessibility = true }
