local config = require("gitflow.config")
local commands = require("gitflow.commands")
local highlights = require("gitflow.highlights")
local icon_mod = require("gitflow.icons")

local M = {}

---@type boolean
M.initialized = false

---@param opts table|nil
---@return GitflowConfig
function M.setup(opts)
	local cfg = config.setup(opts or {})
	highlights.setup(cfg.highlights)
	icon_mod.setup(cfg.icons)
	commands.setup(cfg)
	M.initialized = true
	return cfg
end

---@return GitflowConfig
function M.get_config()
	return config.get()
end

return M
