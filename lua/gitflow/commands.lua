local config = require("gitflow.config")
local utils = require("gitflow.utils")
local shared = require("gitflow.commands.shared")

---@class GitflowSubcommand
---@field description string
---@field run fun(cmd: table): string|nil
---@field category string|nil
---@field complete fun(arglead: string, cmdline: string, args: string[]): string[]|nil

---@class GitflowCommandArea
---@field register fun(ctx: GitflowAreaContext)
---@field panels table[]|nil  panel modules this area owns; `:Gitflow close` closes them in order

---@class GitflowAreaContext
---@field config GitflowConfig
---@field register fun(name: string, subcommand: GitflowSubcommand)
---@field commands table  this module, for areas that drive the dispatcher itself

---@class GitflowCommandState
---@field panel_buffer integer|nil
---@field panel_window integer|nil

local M = {}

---Areas owning the built-in subcommands. A new panel adds its module here and
---registers from that module; nothing else in this file needs to change.
---Order matters: `:Gitflow close` closes area panels in this order.
local AREA_MODULES = {
	"gitflow.commands.remote",
	"gitflow.commands.workspace",
	"gitflow.commands.github",
	"gitflow.commands.history",
	"gitflow.commands.actions",
	"gitflow.commands.inspect",
	"gitflow.commands.worktree",
	"gitflow.commands.shell",
}

---@type table<string, GitflowSubcommand>
M.subcommands = {}

---@type GitflowCommandState
M.state = {
	panel_buffer = nil,
	panel_window = nil,
}

---@type GitflowCommandArea[]
local registered_areas = {}

---@return string
function M.usage()
	local lines = { "Gitflow usage: :Gitflow <subcommand>", "", "Subcommands:" }
	for _, name in ipairs(utils.sorted_keys(M.subcommands)) do
		lines[#lines + 1] = ("  %-10s %s"):format(name, M.subcommands[name].description)
	end
	return table.concat(lines, "\n")
end

---@param cfg GitflowConfig
---@return GitflowPaletteEntry[]
function M.palette_entries(cfg)
	local entries = {}
	for _, name in ipairs(utils.sorted_keys(M.subcommands)) do
		local subcommand = M.subcommands[name]
		local keybinding = cfg.keybindings[name]
		if not keybinding and name == "conflicts" then
			keybinding = cfg.keybindings.conflict
		end

		local category = subcommand.category
		if category == nil or category == "" then
			category = "Git"
		end

		entries[#entries + 1] = {
			name = name,
			description = subcommand.description,
			category = category,
			keybinding = keybinding,
		}
	end
	return entries
end

---@param name string
---@param subcommand GitflowSubcommand
function M.register_subcommand(name, subcommand)
	if not utils.is_non_empty_string(name) then
		error("gitflow command error: subcommand name must be a non-empty string", 2)
	end
	if type(subcommand) ~= "table" or type(subcommand.run) ~= "function" then
		error("gitflow command error: subcommand must define a run(ctx) function", 2)
	end
	if not utils.is_non_empty_string(subcommand.description) then
		error("gitflow command error: subcommand must define a description", 2)
	end
	if subcommand.category ~= nil and type(subcommand.category) ~= "string" then
		error("gitflow command error: subcommand category must be a string", 2)
	end
	if subcommand.complete ~= nil and type(subcommand.complete) ~= "function" then
		error("gitflow command error: subcommand complete must be a function", 2)
	end
	M.subcommands[name] = subcommand
end

---Load one area module and let it register its subcommands.
---An area that does not honour the contract fails loudly here rather than
---silently contributing nothing to `:Gitflow`.
---@param modname string
---@param cfg GitflowConfig
---@return GitflowCommandArea
local function register_area(modname, cfg)
	local area = require(modname)
	if type(area) ~= "table" or type(area.register) ~= "function" then
		error(("gitflow command error: area '%s' must export register(ctx)"):format(modname))
	end
	for index, panel in ipairs(area.panels or {}) do
		if type(panel) ~= "table" or type(panel.close) ~= "function" then
			error(("gitflow command error: area '%s' panel #%d has no close()"):format(modname, index))
		end
	end

	area.register({ config = cfg, register = M.register_subcommand, commands = M })
	return area
end

---@param cfg GitflowConfig
local function register_builtin_subcommands(cfg)
	registered_areas = {}
	for _, modname in ipairs(AREA_MODULES) do
		registered_areas[#registered_areas + 1] = register_area(modname, cfg)
	end
end

---Close every panel owned by a registered area, in area declaration order.
function M.close_area_panels()
	for _, area in ipairs(registered_areas) do
		for _, panel in ipairs(area.panels or {}) do
			panel.close()
		end
	end
end

---@param commandline string
---@return string[]
local function split_args(commandline)
	if commandline == "" then
		return {}
	end
	return vim.split(commandline, "%s+", { trimempty = true })
end

---xpcall handler: keep the original cause plus a traceback so a crash stays
---reportable after dispatch turns it into a plain message.
---@param err any
---@return string
local function handler_traceback(err)
	if type(err) ~= "string" then
		err = vim.inspect(err)
	end
	return debug.traceback(err, 2)
end

---@param args string[]
---@param cfg GitflowConfig
---@return string
function M.dispatch(args, cfg)
	if #args == 0 then
		local usage = M.usage()
		shared.show_info(usage)
		return usage
	end

	local subcommand_name = args[1]
	local subcommand = M.subcommands[subcommand_name]
	if not subcommand then
		local message = ("Unknown Gitflow subcommand: %s"):format(subcommand_name)
		utils.notify(message, vim.log.levels.ERROR)
		return message
	end

	local ok, result = xpcall(subcommand.run, handler_traceback, {
		args = args,
		config = cfg,
	})
	if not ok then
		local message = ("Gitflow subcommand '%s' failed: %s"):format(
			subcommand_name,
			result
		)
		utils.notify(message, vim.log.levels.ERROR)
		return message
	end

	if result and result ~= "" and subcommand_name ~= "help" then
		shared.show_info(result)
	end

	return result or ""
end

---@param arglead string
---@param cmdline string|nil
---@param _cursorpos integer|nil
---@return string[]
function M.complete(arglead, cmdline, _cursorpos)
	if cmdline == nil then
		return shared.filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	local args = split_args(cmdline)
	if #args == 0 then
		return {}
	end

	if #args == 1 then
		return shared.filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	-- `:Gitflow <subcommand>` completion
	if #args == 2 and not cmdline:match("%s$") then
		return shared.filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	local subcommand = M.subcommands[args[2]]
	if subcommand and subcommand.complete then
		return subcommand.complete(arglead, cmdline, args) or {}
	end

	return {}
end

---@param cfg GitflowConfig|nil
function M.setup(cfg)
	local current = cfg or config.get()
	register_builtin_subcommands(current)

	pcall(vim.api.nvim_del_user_command, "Gitflow")
	vim.api.nvim_create_user_command("Gitflow", function(params)
		local args = split_args(params.args or "")
		M.dispatch(args, current)
	end, {
		nargs = "*",
		complete = function(arglead, cmdline, cursorpos)
			return M.complete(arglead, cmdline, cursorpos)
		end,
		desc = "Gitflow command dispatcher",
	})

	vim.keymap.set("n", "<Plug>(GitflowHelp)", "<Cmd>Gitflow help<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowOpen)", "<Cmd>Gitflow open<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowRefresh)", "<Cmd>Gitflow refresh<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowClose)", "<Cmd>Gitflow close<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowStatus)", "<Cmd>Gitflow status<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowBranch)", "<Cmd>Gitflow branch<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowCommit)", "<Cmd>Gitflow commit<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPush)", "<Cmd>Gitflow push<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPull)", "<Cmd>Gitflow pull<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowFetch)", "<Cmd>Gitflow fetch<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowDiff)", "<Cmd>Gitflow diff<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowLog)", "<Cmd>Gitflow log<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowStash)", "<Cmd>Gitflow stash list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowStashPush)", "<Cmd>Gitflow stash push<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowStashPop)", "<Cmd>Gitflow stash pop<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowIssue)", "<Cmd>Gitflow issue list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPr)", "<Cmd>Gitflow pr list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowLabel)", "<Cmd>Gitflow label list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPalette)", "<Cmd>Gitflow palette<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowReset)", "<Cmd>Gitflow reset<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowRevert)", "<Cmd>Gitflow revert<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowTag)", "<Cmd>Gitflow tag list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowCherryPick)", "<Cmd>Gitflow cherry-pick-panel<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowRebaseInteractive)", "<Cmd>Gitflow rebase-interactive<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowActions)", "<Cmd>Gitflow actions<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowBlame)", "<Cmd>Gitflow blame<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowReflog)", "<Cmd>Gitflow reflog<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowConflict)", "<Cmd>Gitflow conflicts<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowConflicts)", "<Cmd>Gitflow conflicts<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowBlameInline)", "<Cmd>Gitflow blame-inline<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowWorktree)", "<Cmd>Gitflow worktree list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowNotifications)", "<Cmd>Gitflow notifications<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPrReview)", "<Cmd>Gitflow pr-review<CR>", { silent = true })

	local key_to_plug = {
		help = "<Plug>(GitflowHelp)",
		open = "<Plug>(GitflowOpen)",
		refresh = "<Plug>(GitflowRefresh)",
		close = "<Plug>(GitflowClose)",
		status = "<Plug>(GitflowStatus)",
		branch = "<Plug>(GitflowBranch)",
		commit = "<Plug>(GitflowCommit)",
		push = "<Plug>(GitflowPush)",
		pull = "<Plug>(GitflowPull)",
		fetch = "<Plug>(GitflowFetch)",
		diff = "<Plug>(GitflowDiff)",
		log = "<Plug>(GitflowLog)",
		stash = "<Plug>(GitflowStash)",
		stash_push = "<Plug>(GitflowStashPush)",
		stash_pop = "<Plug>(GitflowStashPop)",
		issue = "<Plug>(GitflowIssue)",
		pr = "<Plug>(GitflowPr)",
		label = "<Plug>(GitflowLabel)",
		reset = "<Plug>(GitflowReset)",
		revert = "<Plug>(GitflowRevert)",
		tag = "<Plug>(GitflowTag)",
		blame = "<Plug>(GitflowBlame)",
		reflog = "<Plug>(GitflowReflog)",
		cherry_pick = "<Plug>(GitflowCherryPick)",
		rebase_interactive = "<Plug>(GitflowRebaseInteractive)",
		actions = "<Plug>(GitflowActions)",
		palette = "<Plug>(GitflowPalette)",
		conflict = "<Plug>(GitflowConflicts)",
		blame_inline = "<Plug>(GitflowBlameInline)",
		worktree = "<Plug>(GitflowWorktree)",
		notifications = "<Plug>(GitflowNotifications)",
		pr_review = "<Plug>(GitflowPrReview)",
	}
	for action, mapping in pairs(current.keybindings) do
		local plug = key_to_plug[action]
		if plug then
			vim.keymap.set("n", mapping, plug, { remap = true, silent = true })
		end
	end
end

return M
