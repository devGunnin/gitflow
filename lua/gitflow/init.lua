local config = require("gitflow.config")
local commands = require("gitflow.commands")
local gh = require("gitflow.gh")
local highlights = require("gitflow.highlights")
local signs = require("gitflow.signs")
local icons = require("gitflow.icons")
local notifications = require("gitflow.notifications")

local M = {}
local statusline_module = nil

---@return table|nil
local function load_statusline_module()
	if statusline_module ~= nil then
		return statusline_module
	end

	local ok, module = pcall(require, "gitflow.statusline")
	if not ok or type(module) ~= "table" then
		return nil
	end

	statusline_module = module
	return statusline_module
end

---@type boolean
M.initialized = false

---@return string
function M.statusline()
	local statusline = load_statusline_module()
	if statusline == nil or type(statusline.get) ~= "function" then
		return ""
	end
	return statusline.get()
end

---@param opts table|nil
---@return GitflowConfig
function M.setup(opts)
	local cfg = config.setup(opts or {})
	notifications.setup(cfg.notifications.max_entries)
	highlights.setup(cfg.highlights)
	commands.setup(cfg)
	signs.setup(cfg)
	icons.setup(cfg)
	local statusline = load_statusline_module()
	if statusline ~= nil and type(statusline.setup) == "function" then
		statusline.setup()
	end
	if statusline ~= nil and type(statusline.refresh) == "function" then
		statusline.refresh()
	end
	gh.check_prerequisites({ notify = true })
	M.initialized = true
	return cfg
end

---@return GitflowConfig
function M.get_config()
	return config.get()
end

return M
