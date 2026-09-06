local function extract(ctx)
	local result = { kind = "notion" }
	local pages, mainURL, peekURL = {}, nil, nil
	ctx.walk(ctx.window, function(element, role, item)
		if role == "AXWebArea" then
			local url = ctx.url(element)
			if url and not url:match("^file:") then
				mainURL = url
			end
		end
		if role == "AXGroup" and ctx.read(element, "AXDescription") == "Side Peek" then
			item.scope = "side_peek"
		end
		if
			role == "AXLink"
			and item.scope == "side_peek"
			and ctx.read(element, "AXDescription") == "Open in full page"
		then
			peekURL = ctx.url(element)
		end
		if role == "AXTextArea" and ctx.read(element, "AXSubrole") == "AXApplicationGroup" then
			local title
			ctx.walk(element, function(field, fieldRole, fieldItem)
				if fieldRole == "AXTextArea" and ctx.read(field, "AXRoleDescription") == "page title" then
					local value = ctx.read(field, "AXValue")
					if type(value) == "string" and value ~= "" then
						title = value
						return "stop"
					end
				end
				if fieldItem.depth >= 4 or fieldRole == "AXTable" then
					return "skip"
				end
			end, 60)
			pages[#pages + 1] = { scope = item.scope or "main", title = title }
			return "skip"
		end
	end, 150)
	for _, page in ipairs(pages) do
		if page.scope == "side_peek" then
			page.url = peekURL
		else
			page.url = mainURL
		end
		if page.scope == "main" and page.url then
			page.url = page.url:match("^[^?]+")
		end
		if not page.title then
			ctx.missing("pages." .. page.scope .. ".title")
		end
		if not page.url then
			ctx.missing("pages." .. page.scope .. ".url")
		end
	end
	if #pages > 0 then
		result.pages = pages
	else
		ctx.missing("pages")
	end
	local summaries = {}
	for _, page in ipairs(pages) do
		summaries[#summaries + 1] = page.scope .. ": " .. (page.title or "?") .. " · " .. (page.url or "?")
	end
	return result, #pages > 0 and table.concat(summaries, " | ") or "Page unavailable", #pages > 0
end

return { extract = extract, manualAccessibility = true }
