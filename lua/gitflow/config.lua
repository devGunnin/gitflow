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
---@field separator_width integer|nil  fixed rule width; 0 adapts to the window
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
---@field debounce integer

---@class GitflowIconsConfig
---@field enable boolean

---@class GitflowInlineBlameConfig
---@field enable boolean
---@field auto boolean
---@field delay integer
---@field date_format string

---@class GitflowActionsConfig
---@field watch_interval integer  poll interval (ms, min 1000) for the actions panel's live-watch

---@class GitflowConfig
---@field keybindings table<string, string|false>|false
---@field panel_keybindings table<string, table<string, string|false>>
---@field ui GitflowUiConfig
---@field behavior GitflowBehaviorConfig
---@field git GitflowGitConfig
---@field sync GitflowSyncConfig
---@field quick_actions GitflowQuickActionsConfig
---@field highlights GitflowHighlightConfig
---@field signs GitflowSignsConfig
---@field icons GitflowIconsConfig
---@field inline_blame GitflowInlineBlameConfig
---@field notifications table
---@field actions GitflowActionsConfig

local M = {}

---@return GitflowConfig
function M.defaults()
	return {
		keybindings = {
			-- Documented defaults — must match README.md, KEYBINDINGS.md, and
			-- doc/gitflow.txt. Every entry here is also exercised by
			-- scripts/test_keybinding_docs.lua.
			help = "<leader>gh",
			open = "<leader>go",
			-- `<leader>`-prefixed because bare `gr` is Neovim 0.11's LSP
			-- prefix and bare `gs`/`gc`/`gD` are built-in commands. Panels
			-- refresh with plain `r` from inside, so this map is a fallback.
			refresh = "<leader>gz",
			close = "<leader>gq",
			status = "<leader>gs",
			commit = "<leader>gc",
			push = "<leader>gP",
			pull = "<leader>gp",
			fetch = "<leader>gf",
			diff = "<leader>gd",
			log = "gl",
			stash = "gS",
			stash_push = "gZ",
			stash_pop = "gX",
			branch = "<leader>gb",
			issue = "<leader>gi",
			pr = "<leader>gr",
			label = "<leader>gL",
			conflict = "<leader>gm",
			palette = "<leader>gx",
			reset = "<leader>gR",
			pr_review = "<leader>gG",
			-- Additional actions for panels that pre-date their own doc entries.
			revert = "<leader>gv",
			tag = "<leader>gt",
			blame = "gB",
			blame_inline = "<leader>gB",
			worktree = "gW",
			reflog = "<leader>gF",
			cherry_pick = "gC",
			rebase_interactive = "<leader>gI",
			actions = "gA",
			notifications = "<leader>gn",
		},
		-- Per-panel key overrides, keyed by the panel's registry name and then
		-- by the DEFAULT key the panel advertises: a string moves the binding,
		-- `false` removes it. `:Gitflow help` and every panel's `?` list both.
		panel_keybindings = {},
		ui = {
			default_layout = "float",
			-- Fixed width for panel rules; 0 adapts to the window.
			separator_width = 0,
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
			pull_strategy = "rebase",
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
			-- Debounce (ms) before refreshing signs after a write, so a burst
			-- of rapid writes costs one git chain instead of one per write.
			debounce = 300,
		},
		icons = {
			enable = true,
		},
		inline_blame = {
			-- Master switch for the inline-blame feature. When false,
			-- :Gitflow blame-inline does nothing and no autocmds are installed.
			enable = true,
			-- Automatically show inline blame in every file buffer.
			auto = false,
			-- Debounce (ms) before blaming the cursor line.
			delay = 200,
			-- os.date() format for the author date.
			date_format = "%Y-%m-%d",
		},
		notifications = {
			max_entries = 200,
		},
		actions = {
			-- How often the actions panel polls while watching a run (ms).
			watch_interval = 10000,
		},
	}
end

---@type GitflowConfig
M.current = M.defaults()

--- Config paths whose keys are free-form, so unknown-key checking must stop
--- there: highlight group names are arbitrary and user-defined.
local OPEN_CONFIG_PATHS = {
	highlights = true,
	panel_keybindings = true,
}

---Two actions bound to the same keys means one silently shadows the other,
---so report every collision instead of letting the loser vanish.
---@param keybindings table<string, string>
local function validate_keybinding_collisions(keybindings)
	local actions_by_mapping = {}
	for _, action in ipairs(utils.sorted_keys(keybindings)) do
		local mapping = keybindings[action]
		if mapping ~= false then
			actions_by_mapping[mapping] = actions_by_mapping[mapping] or {}
			table.insert(actions_by_mapping[mapping], action)
		end
	end

	local collisions = {}
	for _, mapping in ipairs(utils.sorted_keys(actions_by_mapping)) do
		local actions = actions_by_mapping[mapping]
		if #actions > 1 then
			collisions[#collisions + 1] =
				("'%s' is bound to %s"):format(mapping, table.concat(actions, ", "))
		end
	end

	if #collisions > 0 then
		error(
			("gitflow config error: duplicate keybindings — %s"):format(
				table.concat(collisions, "; ")
			),
			3
		)
	end
end

---The global map set is opt-out at two grains: `keybindings = false` installs
---none of them, and a single action set to `false` installs just that one
---nowhere. Both matter — gitflow's maps are ordinary normal-mode mappings in
---every buffer, so a user whose config already owns a key needs a way to say
---so without restating all 32 defaults.
---@param config GitflowConfig
local function validate_keybindings(config)
	if config.keybindings == false then
		return
	end
	if type(config.keybindings) ~= "table" then
		error(
			"gitflow config error: keybindings must be a table, or false to "
				.. "install no global mappings",
			3
		)
	end

	for action, mapping in pairs(config.keybindings) do
		if not utils.is_non_empty_string(action) then
			error("gitflow config error: keybindings keys must be non-empty strings", 3)
		end
		if mapping ~= false and not utils.is_non_empty_string(mapping) then
			error(
				("gitflow config error: keybinding '%s' must be a non-empty "
					.. "string, or false to disable it"):format(action),
				3
			)
		end
	end

	validate_keybinding_collisions(config.keybindings)
end

---Per-panel key overrides. Keyed by the panel's registry name, then by the
---default key label the panel advertises; the value is the replacement key,
---or `false` to unbind it. A key label that matches no entry is reported
---where it is applied (`ui/panel.lua`), not here: panels register their
---registries on demand, well after `setup()` has run.
---@param config GitflowConfig
local function validate_panel_keybindings(config)
	if type(config.panel_keybindings) ~= "table" then
		error("gitflow config error: panel_keybindings must be a table", 3)
	end

	for panel_name, overrides in pairs(config.panel_keybindings) do
		if not utils.is_non_empty_string(panel_name) then
			error(
				"gitflow config error: panel_keybindings keys must be panel names",
				3
			)
		end
		if type(overrides) ~= "table" then
			error(
				("gitflow config error: panel_keybindings.%s must be a table"):format(
					panel_name
				),
				3
			)
		end

		local claimed = {}
		for default_key, replacement in pairs(overrides) do
			if not utils.is_non_empty_string(default_key) then
				error(
					("gitflow config error: panel_keybindings.%s keys must be "
						.. "the panel's default key labels"):format(panel_name),
					3
				)
			end
			if replacement ~= false and not utils.is_non_empty_string(replacement) then
				error(
					("gitflow config error: panel_keybindings.%s['%s'] must be a "
						.. "non-empty string, or false to unbind it"):format(
						panel_name, default_key
					),
					3
				)
			end
			-- Two verbs on one key means the second silently shadows the first.
			if replacement ~= false then
				if claimed[replacement] then
					error(
						("gitflow config error: panel_keybindings.%s maps both "
							.. "'%s' and '%s' onto '%s'"):format(
							panel_name, claimed[replacement], default_key, replacement
						),
						3
					)
				end
				claimed[replacement] = default_key
			end
		end
	end
end

---Reject options that no longer reach anything — a typo like
---`inline_blame = { enalbe = false }` otherwise silently keeps the default.
---@param opts table|nil  raw user options, before merging with defaults
local function validate_known_keys(opts)
	local unknown = utils.unknown_keys(M.defaults(), opts, OPEN_CONFIG_PATHS)
	if #unknown == 0 then
		return
	end

	local messages = {}
	for _, entry in ipairs(unknown) do
		if entry.suggestion then
			messages[#messages + 1] =
				("'%s' (did you mean '%s'?)"):format(entry.path, entry.suggestion)
		else
			messages[#messages + 1] = ("'%s'"):format(entry.path)
		end
	end

	error(
		("gitflow config error: unknown option %s"):format(table.concat(messages, ", ")),
		3
	)
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

	if config.ui.separator_width ~= nil then
		local width = config.ui.separator_width
		if type(width) ~= "number" or width < 0 or width ~= math.floor(width) then
			error(
				"gitflow config error: ui.separator_width must be 0 (adaptive) "
					.. "or a positive integer",
				3
			)
		end
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

	if type(config.signs.debounce) ~= "number" or config.signs.debounce < 0 then
		error("gitflow config error: signs.debounce must be a non-negative number", 3)
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
local function validate_inline_blame(config)
	if type(config.inline_blame) ~= "table" then
		error("gitflow config error: inline_blame must be a table", 3)
	end
	if type(config.inline_blame.enable) ~= "boolean" then
		error("gitflow config error: inline_blame.enable must be a boolean", 3)
	end
	if type(config.inline_blame.auto) ~= "boolean" then
		error("gitflow config error: inline_blame.auto must be a boolean", 3)
	end
	if type(config.inline_blame.delay) ~= "number" or config.inline_blame.delay < 0 then
		error("gitflow config error: inline_blame.delay must be a non-negative number", 3)
	end
	if not utils.is_non_empty_string(config.inline_blame.date_format) then
		error("gitflow config error: inline_blame.date_format must be a non-empty string", 3)
	end
end

---@param config GitflowConfig
local function validate_notifications(config)
	if type(config.notifications) ~= "table" then
		error("gitflow config error: notifications must be a table", 3)
	end
	if type(config.notifications.max_entries) ~= "number" or config.notifications.max_entries < 1 then
		error("gitflow config error: notifications.max_entries" .. " must be a positive number", 3)
	end
end

local MIN_WATCH_INTERVAL_MS = 1000

---@param config GitflowConfig
local function validate_actions(config)
	if type(config.actions) ~= "table" then
		error("gitflow config error: actions must be a table", 3)
	end
	-- Floor, not just "positive": the value is milliseconds, so the natural
	-- typo `watch_interval = 10` (meaning seconds) would poll GitHub 100x/s.
	if type(config.actions.watch_interval) ~= "number"
		or config.actions.watch_interval < MIN_WATCH_INTERVAL_MS then
		error(
			("gitflow config error: actions.watch_interval must be at least %d (milliseconds)")
				:format(MIN_WATCH_INTERVAL_MS),
			3
		)
	end
end

---@param config GitflowConfig
function M.validate(config)
	validate_keybindings(config)
	validate_panel_keybindings(config)
	validate_ui(config)
	validate_behavior(config)
	validate_git(config)
	validate_sync(config)
	validate_quick_actions(config)
	validate_highlights(config)
	validate_signs(config)
	validate_icons(config)
	validate_inline_blame(config)
	validate_notifications(config)
	validate_actions(config)
end

---@param opts table|nil
---@return GitflowConfig
function M.setup(opts)
	-- Checked against raw opts: the merged table always has every default key.
	validate_known_keys(opts)
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
