local browserURL = dofile((...) .. "/browser.lua")

local function extract(ctx)
	local url = browserURL(ctx)
	if not url then
		ctx.missing("url")
	end
	return { kind = "chrome", url = url }, url or "URL unavailable", url ~= nil
end

return { extract = extract }
