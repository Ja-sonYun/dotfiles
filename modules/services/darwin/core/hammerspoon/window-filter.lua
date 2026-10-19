local name = ...
local path = assert(package.searchpath(name, package.path))
local file = assert(io.open(path, "r"))
local source = file:read("*a")
file:close()

-- Unknown Space notifications must respect the documented refresh policy.
-- https://www.hammerspoon.org/docs/hs.window.filter.html#forceRefreshOnSpaceChange
local patched, count = source:gsub(
	"if not spacesDone%[pendingSpace%] or next%(spacesInstances%)",
	"if (pendingSpace ~= -1 and not spacesDone[pendingSpace]) or next(spacesInstances)"
)
assert(count == 1, "Hammerspoon window filter changed; update the Space refresh patch")

return assert(load(patched, "@" .. path, "t"))(...)
