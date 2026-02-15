local utils = require("gitflow.utils")

---@class GitflowSplitConfig
---@field orientation "vertical"|"horizontal"
---@field size integer

---@class GitflowFloatConfig
---@field width number
---@field height number
---@field border string|string[]
---@field title string
---@field title_pos "left"|"center"|"right"
---@field footer boolean
---@field footer_pos "left"|"center"|"right"

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

---@class GitflowSyncConfig
---@field pull_strategy "rebase"|"merge"

---@alias GitflowQuickActionStep "commit"|"push"

---@class GitflowQuickActionsConfig
---@field quick_commit GitflowQuickActionStep[]
---@field quick_push GitflowQuickActionStep[]

---@class GitflowHighlightConfig
---@field [string] table

---@class GitflowSignsConfig
---@field enable boolean
---@field added string
---@field modified string
---@field deleted string
---@field conflict string

---@class GitflowIconsConfig
---@field enable boolean

---@class GitflowConfig
---@field keybindings table<string, string>
---@field ui GitflowUiConfig
---@field behavior GitflowBehaviorConfig
---@field git GitflowGitConfig
---@field sync GitflowSyncConfig
---@field quick_actions GitflowQuickActionsConfig
---@field highlights GitflowHighlightConfig
---@field signs GitflowSignsConfig
---@field icons GitflowIconsConfig

local M = {}

---@return GitflowConfig
function M.defaults()
	return {
		keybindings = {
			help = "<leader>gh",
			refresh = "<leader>gg",
			close = "<leader>gq",
			status = "gs",
			commit = "gc",
			push = "<leader>gP",
			pull = "<leader>gp",
			fetch = "<leader>gf",
			diff = "gd",
			log = "gl",
			stash = "gS",
			stash_push = "gZ",
			stash_pop = "gX",
			branch = "<leader>gb",
			issue = "<leader>gi",
			pr = "<leader>gr",
			reset = "gR",
			conflict = "<leader>gm",
			palette = "<leader>go",
		},
		ui = {
			default_layout = "float",
			split = {
				orientation = "vertical",
				size = 50,
			},
			float = {
				width = 0.8,
				height = 0.7,
				border = "rounded",
				title = "Gitflow",
				title_pos = "center",
				footer = true,
				footer_pos = "center",
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
		sync = {
			pull_strategy = "merge",
		},
		quick_actions = {
			quick_commit = { "commit" },
			quick_push = { "commit", "push" },
		},
		highlights = {},
		signs = {
			enable = true,
			added = "+",
			modified = "~",
			deleted = "−",
			conflict = "!",
		},
		icons = {
			enable = true,
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
			error(("gitflow config error: keybinding '%s' must be a non-empty string"):format(action), 3)
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
	local valid_border_styles = {
		none = true,
		single = true,
		double = true,
		rounded = true,
		solid = true,
		shadow = true,
	}
	if type(float.border) == "string" then
		if not valid_border_styles[float.border] then
			error(
				"gitflow config error: ui.float.border must be one of "
					.. "'none', 'single', 'double', 'rounded', 'solid', or 'shadow'",
				3
			)
		end
	elseif type(float.border) == "table" then
		for key, value in pairs(float.border) do
			if type(value) ~= "string" then
				error(("gitflow config error: ui.float.border[%s] must be a string"):format(vim.inspect(key)), 3)
			end
		end
	else
		error("gitflow config error: ui.float.border must be a string or string[]", 3)
	end
	if not utils.is_non_empty_string(float.title) then
		error("gitflow config error: ui.float.title must be a non-empty string", 3)
	end
	local valid_positions = {
		left = true,
		center = true,
		right = true,
	}
	if not valid_positions[float.title_pos] then
		error("gitflow config error: ui.float.title_pos must be 'left', 'center', or 'right'", 3)
	end
	if type(float.footer) ~= "boolean" then
		error("gitflow config error: ui.float.footer must be a boolean", 3)
	end
	if not valid_positions[float.footer_pos] then
		error("gitflow config error: ui.float.footer_pos must be 'left', 'center', or 'right'", 3)
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
local function validate_sync(config)
	if type(config.sync) ~= "table" then
		error("gitflow config error: sync must be a table", 3)
	end

	local strategy = config.sync.pull_strategy
	if strategy ~= "rebase" and strategy ~= "merge" then
		error("gitflow config error: sync.pull_strategy must be 'rebase' or 'merge'", 3)
	end
end

local valid_quick_action_steps = {
	commit = true,
	push = true,
}

---@param name string
---@param sequence GitflowQuickActionStep[]|unknown
local function validate_quick_action_sequence(name, sequence)
	if type(sequence) ~= "table" or #sequence == 0 then
		error(("gitflow config error: quick_actions.%s must be a non-empty list"):format(name), 3)
	end

	for index, step in ipairs(sequence) do
		if not valid_quick_action_steps[step] then
			error(("gitflow config error: quick_actions.%s[%d] must be 'commit' or 'push'"):format(name, index), 3)
		end
	end
end

---@param config GitflowConfig
local function validate_quick_actions(config)
	if type(config.quick_actions) ~= "table" then
		error("gitflow config error: quick_actions must be a table", 3)
	end

	validate_quick_action_sequence("quick_commit", config.quick_actions.quick_commit)
	validate_quick_action_sequence("quick_push", config.quick_actions.quick_push)
end

---@param config GitflowConfig
local function validate_highlights(config)
	if type(config.highlights) ~= "table" then
		error("gitflow config error: highlights must be a table", 3)
	end

	for group, attrs in pairs(config.highlights) do
		if not utils.is_non_empty_string(group) then
			error("gitflow config error: highlights keys must be non-empty strings", 3)
		end
		if type(attrs) ~= "table" then
			error(("gitflow config error: highlights.%s must be a table"):format(group), 3)
		end
	end
end

---@param config GitflowConfig
local function validate_signs(config)
	if type(config.signs) ~= "table" then
		error("gitflow config error: signs must be a table", 3)
	end

	if type(config.signs.enable) ~= "boolean" then
		error("gitflow config error: signs.enable must be a boolean", 3)
	end

	local function validate_sign_text(name, value)
		if type(value) ~= "string" then
			error(("gitflow config error: signs.%s must be a string"):format(name), 3)
		end

		local width = vim.fn.strdisplaywidth(value)
		if width < 1 or width > 2 then
			error(("gitflow config error: signs.%s must be 1-2 cells wide"):format(name), 3)
		end
	end

	validate_sign_text("added", config.signs.added)
	validate_sign_text("modified", config.signs.modified)
	validate_sign_text("deleted", config.signs.deleted)
	validate_sign_text("conflict", config.signs.conflict)
end

---@param config GitflowConfig
local function validate_icons(config)
	if type(config.icons) ~= "table" then
		error("gitflow config error: icons must be a table", 3)
	end

	if type(config.icons.enable) ~= "boolean" then
		error("gitflow config error: icons.enable must be a boolean", 3)
	end
end

---@param config GitflowConfig
function M.validate(config)
	validate_keybindings(config)
	validate_ui(config)
	validate_behavior(config)
	validate_git(config)
	validate_sync(config)
	validate_quick_actions(config)
	validate_highlights(config)
	validate_signs(config)
	validate_icons(config)
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
