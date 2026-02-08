local config = require("gitflow.config")
local commands = require("gitflow.commands")
local gh = require("gitflow.gh")

local M = {}

---@type boolean
M.initialized = false

---@param opts table|nil
---@return GitflowConfig
function M.setup(opts)
	local cfg = config.setup(opts or {})
	commands.setup(cfg)
	gh.check_prerequisites({ notify = true })
	M.initialized = true
	return cfg
end

---@return GitflowConfig
function M.get_config()
	return config.get()
end

return M
