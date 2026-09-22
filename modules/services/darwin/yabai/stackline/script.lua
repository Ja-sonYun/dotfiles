package.path = "@sourceDirectory@/?.lua;@sourceDirectory@/?/init.lua;@sourceDirectory@/stackline/?.lua;" .. package.path

local config = require("stackline.conf")
config.paths.yabai = "@yabai@"

require("stackline"):init(config)
