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
local branch_panel = require("gitflow.panels.branch")

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

---@param paths string[]
---@return string
local function format_conflicted_paths(paths)
	if #paths == 0 then
		return "(none)"
	end
	return table.concat(paths, "\n")
end

---@param output string
---@return string[]
local function parse_conflicted_paths_from_output(output)
	local conflicts = {}
	local seen = {}
	for _, line in ipairs(vim.split(output or "", "\n", { trimempty = true })) do
		local path = line:match("^CONFLICT%s+%b()%:%s+.+%s+in%s+(.+)$")
		if path then
			local trimmed = vim.trim(path)
			if trimmed ~= "" and not seen[trimmed] then
				seen[trimmed] = true
				conflicts[#conflicts + 1] = trimmed
			end
		end
	end
	return conflicts
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(conflicted_paths: string[])
local function collect_conflicted_paths(opts, cb)
	git.git({ "diff", "--name-only", "--diff-filter=U" }, opts, function(result)
		if result.code ~= 0 then
			cb({})
			return
		end

		local conflicted = {}
		for _, line in ipairs(vim.split(result.stdout or "", "\n", { trimempty = true })) do
			conflicted[#conflicted + 1] = line
		end
		cb(conflicted)
	end)
end

---@param branch string
local function run_merge(branch)
	git.git({ "merge", branch }, {}, function(result)
		if result.code == 0 then
			local output = result_message(result, ("Merged '%s'"):format(branch))
			local merge_type = "Merge commit created"
			local normalized = output:lower()
			if normalized:find("fast%-forward", 1) then
				merge_type = "Fast-forward merge completed"
			elseif normalized:find("already up to date", 1, true) then
				merge_type = "Already up to date"
			end

			show_info(("%s\n%s"):format(merge_type, output))
			refresh_status_panel_if_open()
			return
		end

		local output = result_message(result, ("git merge %s failed"):format(branch))
		local parsed_conflicts = parse_conflicted_paths_from_output(output)
		if #parsed_conflicts > 0 then
			show_error(
				("Merge has conflicts.\nConflicted files:\n%s\n\n%s"):format(
					format_conflicted_paths(parsed_conflicts),
					output
				)
			)
			refresh_status_panel_if_open()
			return
		end

		collect_conflicted_paths({}, function(conflicted)
			if #conflicted == 0 then
				show_error(output)
				return
			end

			show_error(
				("Merge has conflicts.\nConflicted files:\n%s\n\n%s"):format(
					format_conflicted_paths(conflicted),
					output
				)
			)
			refresh_status_panel_if_open()
		end)
	end)
end

---@param args string[]
local function run_rebase(args)
	local git_args = { "rebase" }
	for _, arg in ipairs(args) do
		git_args[#git_args + 1] = arg
	end

	git.git(git_args, {}, function(result)
		local action = table.concat(git_args, " ")
		if result.code == 0 then
			local output = result_message(result, ("%s completed"):format(action))
			show_info(output)
			refresh_status_panel_if_open()
			return
		end

		local output = result_message(result, ("%s failed"):format(action))
		local parsed_conflicts = parse_conflicted_paths_from_output(output)
		if #parsed_conflicts > 0 then
			show_error(
				("Rebase stopped with conflicts.\nConflicted files:\n%s\n\nUse :Gitflow rebase "
					.. "--continue or :Gitflow rebase --abort.\n\n%s"):format(
					format_conflicted_paths(parsed_conflicts),
					output
				)
			)
			refresh_status_panel_if_open()
			return
		end

		collect_conflicted_paths({}, function(conflicted)
			if #conflicted == 0 then
				show_error(output)
				return
			end

			show_error(
				("Rebase stopped with conflicts.\nConflicted files:\n%s\n\nUse :Gitflow rebase "
					.. "--continue or :Gitflow rebase --abort.\n\n%s"):format(
					format_conflicted_paths(conflicted),
					output
				)
			)
			refresh_status_panel_if_open()
		end)
	end)
end

---@param commit string
local function run_cherry_pick(commit)
	git.git({ "cherry-pick", commit }, {}, function(result)
		if result.code == 0 then
			local output = result_message(result, ("Cherry-picked %s"):format(commit))
			show_info(output)
			refresh_status_panel_if_open()
			return
		end

		local output = result_message(result, ("git cherry-pick %s failed"):format(commit))
		local parsed_conflicts = parse_conflicted_paths_from_output(output)
		if #parsed_conflicts > 0 then
			show_error(
				("Cherry-pick has conflicts.\nConflicted files:\n%s\n\n%s"):format(
					format_conflicted_paths(parsed_conflicts),
					output
				)
			)
			refresh_status_panel_if_open()
			return
		end

		collect_conflicted_paths({}, function(conflicted)
			if #conflicted == 0 then
				show_error(output)
				return
			end

			show_error(
				("Cherry-pick has conflicts.\nConflicted files:\n%s\n\n%s"):format(
					format_conflicted_paths(conflicted),
					output
				)
			)
			refresh_status_panel_if_open()
		end)
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
			if branch_panel.is_open() then
				branch_panel.refresh()
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
			branch_panel.close()
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

	M.subcommands.branch = {
		description = "Open branch list panel",
		run = function()
			branch_panel.open(cfg)
			return "Branch panel opened"
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
					if stash_panel.is_open() then
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
					if stash_panel.is_open() then
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
					if stash_panel.is_open() then
						stash_panel.refresh()
					end
				end)
				return "Running git stash drop..."
			end

			return ("Unknown stash action: %s"):format(action)
		end,
	}

	M.subcommands.merge = {
		description = "Merge branch into current branch",
		run = function(ctx)
			local target = first_positional(ctx.args)
			if not target then
				return "Usage: :Gitflow merge <branch>"
			end
			run_merge(target)
			return ("Running git merge %s..."):format(target)
		end,
	}

	M.subcommands.rebase = {
		description = "Rebase current branch (supports --abort/--continue)",
		run = function(ctx)
			if has_flag(ctx.args, "--abort") then
				run_rebase({ "--abort" })
				return "Running git rebase --abort..."
			end
			if has_flag(ctx.args, "--continue") then
				run_rebase({ "--continue" })
				return "Running git rebase --continue..."
			end

			local target = first_positional(ctx.args)
			if not target then
				return "Usage: :Gitflow rebase <branch>|--abort|--continue"
			end
			run_rebase({ target })
			return ("Running git rebase %s..."):format(target)
		end,
	}

	M.subcommands["cherry-pick"] = {
		description = "Cherry-pick a commit onto current branch",
		run = function(ctx)
			local commit = first_positional(ctx.args)
			if not commit then
				return "Usage: :Gitflow cherry-pick <commit>"
			end
			run_cherry_pick(commit)
			return ("Running git cherry-pick %s..."):format(commit)
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

---@param arglead string
---@param candidates string[]
---@return string[]
local function filter_candidates(arglead, candidates)
	local filtered = {}
	for _, value in ipairs(candidates) do
		if arglead == "" or vim.startswith(value, arglead) then
			filtered[#filtered + 1] = value
		end
	end
	return filtered
end

---@param args string[]
---@return string[]
local function system_lines(args)
	local cmd = { "git" }
	for _, arg in ipairs(args) do
		cmd[#cmd + 1] = arg
	end

	local lines = {}
	if vim.system then
		local result = vim.system(cmd, { text = true }):wait()
		if (result.code or 1) ~= 0 then
			return lines
		end
		lines = vim.split(result.stdout or "", "\n", { trimempty = true })
	else
		lines = vim.fn.systemlist(cmd)
		if vim.v.shell_error ~= 0 then
			return {}
		end
	end

	return lines
end

---@return string[]
local function list_branch_candidates()
	local names = {}
	for _, line in ipairs(system_lines({
		"for-each-ref",
		"--format=%(refname:short)",
		"refs/heads",
		"refs/remotes",
	})) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and not trimmed:match("/HEAD$") then
			names[#names + 1] = trimmed
		end
	end
	table.sort(names)
	return names
end

---@return string[]
local function list_commit_candidates()
	local hashes = {}
	for _, line in ipairs(system_lines({ "log", "--all", "--pretty=format:%H", "-n", "400" })) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			hashes[#hashes + 1] = trimmed
		end
	end
	return hashes
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
---@param cmdline string|nil
---@param _cursorpos integer|nil
---@return string[]
function M.complete(arglead, cmdline, _cursorpos)
	if cmdline == nil then
		return filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	local commandline = cmdline
	local args = split_args(commandline)
	if #args == 0 then
		return {}
	end

	if #args == 1 then
		return filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	-- `:Gitflow <subcommand>` completion
	if #args == 2 and not commandline:match("%s$") then
		return filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	local subcommand = args[2]
	if subcommand == "merge" then
		return filter_candidates(arglead, list_branch_candidates())
	end
	if subcommand == "rebase" then
		local options = { "--abort", "--continue" }
		local candidates = {}
		for _, value in ipairs(options) do
			candidates[#candidates + 1] = value
		end
		for _, value in ipairs(list_branch_candidates()) do
			candidates[#candidates + 1] = value
		end
		return filter_candidates(arglead, candidates)
	end
	if subcommand == "cherry-pick" then
		return filter_candidates(arglead, list_commit_candidates())
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
	vim.keymap.set("n", "<Plug>(GitflowDiff)", "<Cmd>Gitflow diff<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowLog)", "<Cmd>Gitflow log<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowStash)", "<Cmd>Gitflow stash list<CR>", { silent = true })

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
