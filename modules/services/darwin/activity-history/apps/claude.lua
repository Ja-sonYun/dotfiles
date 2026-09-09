local function extract(ctx)
	local title
	ctx.walk(ctx.window, function(element, role)
		if role == "AXWebArea" then
			local value = ctx.read(element, "AXTitle")
			if type(value) == "string" then
				title = value:match("^(.+) %- Claude$")
				if title then
					return "stop"
				end
			end
		end
	end, 60)
	if not title then
		ctx.missing("title")
	end
	return { kind = "claude", title = title }, title or "Title unavailable", title ~= nil
end

return { extract = extract, manualAccessibility = true }
