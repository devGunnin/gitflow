local utils = require("gitflow.utils")

---@class GitflowSplitConfig
---@field orientation "vertical"|"horizontal"
---@field size integer

---@class GitflowFloatConfig
---@field width number
---@field height number
---@field border string|string[]
---@field title string

---@class GitflowUiConfig
---@field default_layout "split"|"float"
---@field split GitflowSplitConfig
---@field float GitflowFloatConfig

---@class GitflowBehaviorConfig
---@field reuse_named_buffers boolean
---@field close_windows_on_buffer_wipe boolean

---@class GitflowLogConfig
---@field count integer
---@field format string

---@class GitflowGitConfig
---@field log GitflowLogConfig

---@class GitflowConfig
---@field keybindings table<string, string>
---@field ui GitflowUiConfig
---@field behavior GitflowBehaviorConfig
---@field git GitflowGitConfig

local M = {}

---@return GitflowConfig
function M.defaults()
	return {
		keybindings = {
			help = "<leader>gh",
			open = "<leader>go",
			refresh = "<leader>gr",
			close = "<leader>gq",
			status = "gs",
			commit = "gc",
			push = "gp",
			pull = "gP",
			diff = "gd",
			log = "gl",
			stash = "gS",
			branch = "<leader>gb",
		},
		ui = {
			default_layout = "split",
			split = {
				orientation = "vertical",
				size = 50,
			},
			float = {
				width = 0.8,
				height = 0.7,
				border = "rounded",
				title = "Gitflow",
			},
		},
		behavior = {
			reuse_named_buffers = true,
			close_windows_on_buffer_wipe = true,
		},
		git = {
			log = {
				count = 50,
				format = "%h %s",
			},
		},
	}
end

---@type GitflowConfig
M.current = M.defaults()

---@param config GitflowConfig
local function validate_keybindings(config)
	if type(config.keybindings) ~= "table" then
		error("gitflow config error: keybindings must be a table", 3)
	end

	for action, mapping in pairs(config.keybindings) do
		if not utils.is_non_empty_string(action) then
			error("gitflow config error: keybindings keys must be non-empty strings", 3)
		end
		if not utils.is_non_empty_string(mapping) then
			error(
				("gitflow config error: keybinding '%s' must be a non-empty string"):format(action),
				3
			)
		end
	end
end

---@param config GitflowConfig
local function validate_ui(config)
	if type(config.ui) ~= "table" then
		error("gitflow config error: ui must be a table", 3)
	end

	local layout = config.ui.default_layout
	if layout ~= "split" and layout ~= "float" then
		error("gitflow config error: ui.default_layout must be 'split' or 'float'", 3)
	end

	local split = config.ui.split
	if type(split) ~= "table" then
		error("gitflow config error: ui.split must be a table", 3)
	end
	if split.orientation ~= "vertical" and split.orientation ~= "horizontal" then
		error("gitflow config error: ui.split.orientation must be 'vertical' or 'horizontal'", 3)
	end
	if type(split.size) ~= "number" or split.size < 1 then
		error("gitflow config error: ui.split.size must be a positive number", 3)
	end

	local float = config.ui.float
	if type(float) ~= "table" then
		error("gitflow config error: ui.float must be a table", 3)
	end
	if type(float.width) ~= "number" or float.width <= 0 then
		error("gitflow config error: ui.float.width must be a positive number", 3)
	end
	if type(float.height) ~= "number" or float.height <= 0 then
		error("gitflow config error: ui.float.height must be a positive number", 3)
	end
	if type(float.border) ~= "string" and type(float.border) ~= "table" then
		error("gitflow config error: ui.float.border must be a string or string[]", 3)
	end
	if not utils.is_non_empty_string(float.title) then
		error("gitflow config error: ui.float.title must be a non-empty string", 3)
	end
end

---@param config GitflowConfig
local function validate_behavior(config)
	if type(config.behavior) ~= "table" then
		error("gitflow config error: behavior must be a table", 3)
	end
	if type(config.behavior.reuse_named_buffers) ~= "boolean" then
		error("gitflow config error: behavior.reuse_named_buffers must be a boolean", 3)
	end
	if type(config.behavior.close_windows_on_buffer_wipe) ~= "boolean" then
		error("gitflow config error: behavior.close_windows_on_buffer_wipe must be a boolean", 3)
	end
end

---@param config GitflowConfig
local function validate_git(config)
	if type(config.git) ~= "table" then
		error("gitflow config error: git must be a table", 3)
	end
	if type(config.git.log) ~= "table" then
		error("gitflow config error: git.log must be a table", 3)
	end
	if type(config.git.log.count) ~= "number" or config.git.log.count < 1 then
		error("gitflow config error: git.log.count must be a positive number", 3)
	end
	if not utils.is_non_empty_string(config.git.log.format) then
		error("gitflow config error: git.log.format must be a non-empty string", 3)
	end
end

---@param config GitflowConfig
function M.validate(config)
	validate_keybindings(config)
	validate_ui(config)
	validate_behavior(config)
	validate_git(config)
end

---@param opts table|nil
---@return GitflowConfig
function M.setup(opts)
	local merged = utils.deep_merge(M.defaults(), opts or {})
	M.validate(merged)
	M.current = merged
	return M.current
end

---@return GitflowConfig
function M.get()
	return vim.deepcopy(M.current)
end

return M
