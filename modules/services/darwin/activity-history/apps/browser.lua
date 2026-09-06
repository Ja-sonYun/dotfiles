return function(ctx)
	local urls, count, selected = {}, 0, nil
	ctx.walk(ctx.window, function(element, role)
		if role == "AXWebArea" then
			local url = ctx.url(element)
			if url and ctx.read(element, "AXHidden") ~= true and not urls[url] then
				urls[url], count, selected = true, count + 1, url
			end
			return "skip"
		end
		if role == "AXTextArea" or role == "AXTextField" or role == "AXList" then
			return "skip"
		end
	end, 150)
	if count > 1 then
		ctx.missing("url.ambiguous")
	end
	if count == 1 and not ctx.limit and not ctx.discovery_limited then
		return selected
	end
end
