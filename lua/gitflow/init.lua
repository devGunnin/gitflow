local config = require("gitflow.config")
local commands = require("gitflow.commands")
local gh = require("gitflow.gh")
local highlights = require("gitflow.highlights")
local signs = require("gitflow.signs")

local M = {}

---@type boolean
M.initialized = false

---@param opts table|nil
---@return GitflowConfig
function M.setup(opts)
	local cfg = config.setup(opts or {})
	highlights.setup(cfg.highlights)
	commands.setup(cfg)
	signs.setup(cfg)
	gh.check_prerequisites({ notify = true })
	M.initialized = true
	return cfg
end

---@return GitflowConfig
function M.get_config()
	return config.get()
end

return M
