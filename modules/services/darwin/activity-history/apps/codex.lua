local function extract(ctx)
	local main, header, title
	ctx.walk(ctx.window, function(element, role)
		if role == "AXGroup" then
			local subrole = ctx.read(element, "AXSubrole")
			if subrole == "AXLandmarkMain" then
				main = element
				return "stop"
			end
			if subrole == "AXLandmarkComplementary" or subrole == "AXLandmarkRegion" then
				return "skip"
			end
		end
	end, 80)
	if main then
		ctx.walk(main, function(element, role, item)
			if role == "AXGroup" and ctx.read(element, "AXSubrole") == "AXSectionHeader" then
				header = element
				return "stop"
			end
			if item.depth >= 2 then
				return "skip"
			end
		end, 30)
	end
	if header then
		ctx.walk(header, function(element, role)
			if role == "AXButton" then
				local value = ctx.read(element, "AXTitle")
				if type(value) == "string" and value ~= "" then
					title = value
					return "stop"
				end
			end
			if role == "AXPopUpButton" or role == "AXTextArea" then
				return "skip"
			end
		end, 40)
	end
	if not title then
		ctx.missing("title")
	end
	return { kind = "codex", title = title }, title or "Title unavailable", title ~= nil
end

return { extract = extract, manualAccessibility = true }
