local config = require("gitflow.config")
local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_status = require("gitflow.git.status")
local git_stash = require("gitflow.git.stash")
local status_panel = require("gitflow.panels.status")
local diff_panel = require("gitflow.panels.diff")
local log_panel = require("gitflow.panels.log")
local stash_panel = require("gitflow.panels.stash")

---@class GitflowSubcommand
---@field description string
---@field run fun(ctx: table): string|nil

---@class GitflowCommandState
---@field panel_buffer integer|nil
---@field panel_window integer|nil

local M = {}

---@type table<string, GitflowSubcommand>
M.subcommands = {}

---@type GitflowCommandState
M.state = {
	panel_buffer = nil,
	panel_window = nil,
}

---@return string
function M.usage()
	local lines = { "Gitflow usage: :Gitflow <subcommand>", "", "Subcommands:" }
	for _, name in ipairs(utils.sorted_keys(M.subcommands)) do
		lines[#lines + 1] = ("  %-10s %s"):format(name, M.subcommands[name].description)
	end
	return table.concat(lines, "\n")
end

---@param message string
local function show_info(message)
	utils.notify(message, vim.log.levels.INFO)
end

---@param message string
local function show_error(message)
	utils.notify(message, vim.log.levels.ERROR)
end

---@param result GitflowGitResult
---@param fallback string
---@return string
local function result_message(result, fallback)
	local output = git.output(result)
	if output == "" then
		return fallback
	end
	return output
end

---@param cfg GitflowConfig
local function open_panel(cfg)
	local bufnr = ui.buffer.create("main", {
		filetype = "gitflow",
		lines = {
			"Gitflow",
			"",
			"Plugin skeleton initialized.",
			"Run :Gitflow status to open Stage 2 status panel.",
		},
	})
	M.state.panel_buffer = bufnr

	if cfg.ui.default_layout == "float" then
		M.state.panel_window = ui.window.open_float({
			name = "main",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = cfg.ui.float.title,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.panel_window = nil
			end,
		})
		return
	end

	M.state.panel_window = ui.window.open_split({
		name = "main",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.panel_window = nil
		end,
	})
end

---@param output string
---@return boolean
local function output_mentions_upstream_problem(output)
	local normalized = output:lower()
	if normalized:find("has no upstream branch", 1, true) then
		return true
	end
	if normalized:find("set%-upstream", 1) then
		return true
	end
	if normalized:find("no upstream", 1, true) then
		return true
	end
	return false
end

local function refresh_status_panel_if_open()
	if status_panel.is_open() then
		status_panel.refresh()
	end
end

---@param amend boolean
local function open_commit_prompt(amend)
	git_status.fetch({}, function(err, _, grouped)
		if err then
			show_error(err)
			return
		end

		local staged_count = git_status.count_staged(grouped)
		if staged_count == 0 then
			utils.notify("No staged changes to commit", vim.log.levels.WARN)
			return
		end

		local prompt_text = amend and "Amend commit message: " or "Commit message: "
		ui.input.prompt({
			prompt = prompt_text,
		}, function(message)
			local trimmed = vim.trim(message)
			if trimmed == "" then
				utils.notify("Commit message cannot be empty", vim.log.levels.WARN)
				return
			end

			local confirmed = ui.input.confirm(
				("Commit %d staged file(s)?"):format(staged_count),
				{ choices = { "&Commit", "&Cancel" }, default_choice = 1 }
			)
			if not confirmed then
				return
			end

			local args = { "commit", "-m", trimmed }
			if amend then
				table.insert(args, 2, "--amend")
			end

			git.git(args, {}, function(commit_result)
				if commit_result.code ~= 0 then
					show_error(result_message(commit_result, "git commit failed"))
					return
				end

				show_info(result_message(commit_result, "Commit created"))
				refresh_status_panel_if_open()
			end)
		end)
	end)
end

local function push_with_upstream()
	git.git({ "rev-parse", "--abbrev-ref", "HEAD" }, {}, function(branch_result)
		if branch_result.code ~= 0 then
			show_error(result_message(branch_result, "Could not determine current branch"))
			return
		end

		local branch = vim.trim(branch_result.stdout)
		if branch == "" or branch == "HEAD" then
			show_error("Cannot set upstream from detached HEAD")
			return
		end

		local confirmed = ui.input.confirm(
			("No upstream for '%s'. Push with -u origin %s?"):format(branch, branch),
			{ choices = { "&Push", "&Cancel" }, default_choice = 1 }
		)
		if not confirmed then
			return
		end

		git.git({ "push", "-u", "origin", branch }, {}, function(push_result)
			if push_result.code ~= 0 then
				show_error(result_message(push_result, "git push -u failed"))
				return
			end
			show_info(result_message(push_result, "Pushed with upstream tracking"))
		end)
	end)
end

local function run_push()
	git.git({ "push" }, {}, function(result)
		if result.code == 0 then
			show_info(result_message(result, "Push completed"))
			return
		end

		local output = result_message(result, "git push failed")
		if output_mentions_upstream_problem(output) then
			push_with_upstream()
			return
		end

		show_error(output)
	end)
end

local function run_pull()
	git.git({ "pull" }, {}, function(result)
		if result.code ~= 0 then
			show_error(result_message(result, "git pull failed"))
			return
		end
		show_info(result_message(result, "Pull completed"))
	end)
end

---@param args string[]
---@return boolean
local function has_flag(args, flag)
	for i = 2, #args do
		if args[i] == flag then
			return true
		end
	end
	return false
end

---@param args string[]
---@return string|nil
local function first_positional(args)
	for i = 2, #args do
		local arg = args[i]
		if not vim.startswith(arg, "--") then
			return arg
		end
	end
	return nil
end

---@param cfg GitflowConfig
local function register_builtin_subcommands(cfg)
	M.subcommands.help = {
		description = "Show Gitflow usage",
		run = function()
			local usage = M.usage()
			show_info(usage)
			return usage
		end,
	}

	M.subcommands.open = {
		description = "Open the Gitflow main panel",
		run = function()
			open_panel(cfg)
			return "Gitflow panel opened"
		end,
	}

	M.subcommands.refresh = {
		description = "Refresh main/status panel content",
		run = function()
			local bufnr = M.state.panel_buffer or ui.buffer.get("main")
			if bufnr then
				ui.buffer.update(bufnr, {
					"Gitflow",
					"",
					("Last refresh: %s"):format(os.date("%Y-%m-%d %H:%M:%S")),
				})
			end

			if status_panel.is_open() then
				status_panel.refresh()
			end
			return "Gitflow panel refreshed"
		end,
	}

	M.subcommands.close = {
		description = "Close open Gitflow panels",
		run = function()
			if M.state.panel_window then
				ui.window.close(M.state.panel_window)
			else
				ui.window.close("main")
			end
			if M.state.panel_buffer then
				ui.buffer.teardown(M.state.panel_buffer)
			else
				ui.buffer.teardown("main")
			end
			M.state.panel_window = nil
			M.state.panel_buffer = nil

			status_panel.close()
			diff_panel.close()
			log_panel.close()
			stash_panel.close()
			return "Gitflow panels closed"
		end,
	}

	M.subcommands.status = {
		description = "Open git status panel",
		run = function()
			status_panel.open(cfg, {
				on_commit = function()
					open_commit_prompt(false)
				end,
				on_open_diff = function(request)
					diff_panel.open(cfg, request)
				end,
			})
			return "Git status panel opened"
		end,
	}

	M.subcommands.commit = {
		description = "Create commit from staged changes (supports --amend)",
		run = function(ctx)
			local amend = has_flag(ctx.args, "--amend")
			open_commit_prompt(amend)
			if amend then
				return "Commit prompt opened (amend)"
			end
			return "Commit prompt opened"
		end,
	}

	M.subcommands.push = {
		description = "Run git push",
		run = function()
			run_push()
			return "Running git push..."
		end,
	}

	M.subcommands.pull = {
		description = "Run git pull",
		run = function()
			run_pull()
			return "Running git pull..."
		end,
	}

	M.subcommands.diff = {
		description = "Open diff buffer (supports --staged [path])",
		run = function(ctx)
			diff_panel.open(cfg, {
				staged = has_flag(ctx.args, "--staged"),
				path = first_positional(ctx.args),
			})
			return "Diff view opened"
		end,
	}

	M.subcommands.log = {
		description = "Open commit log panel",
		run = function()
			log_panel.open(cfg, {
				on_open_commit = function(sha)
					diff_panel.open(cfg, { commit = sha })
				end,
			})
			return "Log view opened"
		end,
	}

	M.subcommands.stash = {
		description = "Stash operations: list|push|pop|drop",
		run = function(ctx)
			local action = ctx.args[2] or "list"
			if action == "list" then
				stash_panel.open(cfg)
				return "Stash view opened"
			end

			if action == "push" then
				local message = table.concat(ctx.args, " ", 3)
				if message == "" then
					message = nil
				end
				git_stash.push({ message = message }, function(err, result)
					if err then
						show_error(err)
						return
					end
					show_info(result_message(result, "Created stash entry"))
					if stash_panel.state.bufnr then
						stash_panel.refresh()
					end
					refresh_status_panel_if_open()
				end)
				return "Running git stash push..."
			end

			if action == "pop" then
				local index = tonumber(ctx.args[3])
				git_stash.pop({ index = index }, function(err, result)
					if err then
						show_error(err)
						return
					end
					show_info(result_message(result, "Applied stash entry"))
					if stash_panel.state.bufnr then
						stash_panel.refresh()
					end
					refresh_status_panel_if_open()
				end)
				return "Running git stash pop..."
			end

			if action == "drop" then
				local index = tonumber(ctx.args[3])
				if not index then
					return "Usage: :Gitflow stash drop <index>"
				end
				git_stash.drop(index, {}, function(err, result)
					if err then
						show_error(err)
						return
					end
					show_info(result_message(result, "Dropped stash entry"))
					if stash_panel.state.bufnr then
						stash_panel.refresh()
					end
				end)
				return "Running git stash drop..."
			end

			return ("Unknown stash action: %s"):format(action)
		end,
	}
end

---@param commandline string
---@return string[]
local function split_args(commandline)
	if commandline == "" then
		return {}
	end
	return vim.split(commandline, "%s+", { trimempty = true })
end

---@param args string[]
---@param cfg GitflowConfig
---@return string
function M.dispatch(args, cfg)
	if #args == 0 then
		local usage = M.usage()
		show_info(usage)
		return usage
	end

	local subcommand_name = args[1]
	local subcommand = M.subcommands[subcommand_name]
	if not subcommand then
		local message = ("Unknown Gitflow subcommand: %s"):format(subcommand_name)
		utils.notify(message, vim.log.levels.ERROR)
		return message
	end

	local result = subcommand.run({
		args = args,
		config = cfg,
	})

	if result and result ~= "" and subcommand_name ~= "help" then
		show_info(result)
	end

	return result or ""
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
	M.subcommands[name] = subcommand
end

---@param arglead string
---@return string[]
function M.complete(arglead)
	local matches = {}
	for _, name in ipairs(utils.sorted_keys(M.subcommands)) do
		if arglead == "" or vim.startswith(name, arglead) then
			matches[#matches + 1] = name
		end
	end
	return matches
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
		complete = function(arglead)
			return M.complete(arglead)
		end,
		desc = "Gitflow command dispatcher",
	})

	vim.keymap.set("n", "<Plug>(GitflowHelp)", "<Cmd>Gitflow help<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowOpen)", "<Cmd>Gitflow open<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowRefresh)", "<Cmd>Gitflow refresh<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowClose)", "<Cmd>Gitflow close<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowStatus)", "<Cmd>Gitflow status<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowCommit)", "<Cmd>Gitflow commit<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPush)", "<Cmd>Gitflow push<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPull)", "<Cmd>Gitflow pull<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowDiff)", "<Cmd>Gitflow diff<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowLog)", "<Cmd>Gitflow log<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowStash)", "<Cmd>Gitflow stash list<CR>", { silent = true })

	local key_to_plug = {
		help = "<Plug>(GitflowHelp)",
		open = "<Plug>(GitflowOpen)",
		refresh = "<Plug>(GitflowRefresh)",
		close = "<Plug>(GitflowClose)",
		status = "<Plug>(GitflowStatus)",
		commit = "<Plug>(GitflowCommit)",
		push = "<Plug>(GitflowPush)",
		pull = "<Plug>(GitflowPull)",
		diff = "<Plug>(GitflowDiff)",
		log = "<Plug>(GitflowLog)",
		stash = "<Plug>(GitflowStash)",
	}
	for action, mapping in pairs(current.keybindings) do
		local plug = key_to_plug[action]
		if plug then
			vim.keymap.set("n", mapping, plug, { remap = true, silent = true })
		end
	end
end

return M
