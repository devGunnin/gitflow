local config = require("gitflow.config")
local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")
local git_status = require("gitflow.git.status")
local git_stash = require("gitflow.git.stash")
local gh = require("gitflow.gh")
local gh_issues = require("gitflow.gh.issues")
local gh_prs = require("gitflow.gh.prs")
local gh_labels = require("gitflow.gh.labels")
local status_panel = require("gitflow.panels.status")
local diff_panel = require("gitflow.panels.diff")
local log_panel = require("gitflow.panels.log")
local stash_panel = require("gitflow.panels.stash")
local branch_panel = require("gitflow.panels.branch")
local issue_panel = require("gitflow.panels.issues")
local pr_panel = require("gitflow.panels.prs")
local label_panel = require("gitflow.panels.labels")
local review_panel = require("gitflow.panels.review")
local conflict_panel = require("gitflow.panels.conflict")
local palette_panel = require("gitflow.panels.palette")
local git_conflict = require("gitflow.git.conflict")

---@class GitflowSubcommand
---@field description string
---@field run fun(ctx: table): string|nil
---@field category string|nil

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

local function emit_post_operation()
	vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })
end

---@param output string
---@return boolean
local function output_mentions_no_local_changes(output)
	return output:lower():find("no local changes to save", 1, true) ~= nil
end

---@param message string|nil
local function run_stash_push(message)
	git_stash.push({ message = message }, function(err, result)
		if err then
			show_error(err)
			return
		end

		local output = result_message(result, "Created stash entry")
		if output_mentions_no_local_changes(output) then
			utils.notify(output, vim.log.levels.WARN)
		else
			show_info(output)
		end

			if stash_panel.is_open() then
				stash_panel.refresh()
			end
			refresh_status_panel_if_open()
			emit_post_operation()
		end)
end

local function prompt_and_run_stash_push()
	vim.ui.input({
		prompt = "Stash message (optional): ",
	}, function(input)
		if input == nil then
			return
		end

		local message = vim.trim(input)
		if message == "" then
			message = nil
		end
			run_stash_push(message)
		end)
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
				emit_post_operation()
			end)
		end)
	end)
end

---@param on_done fun(ok: boolean)|nil
local function push_with_upstream(on_done)
	git.git({ "rev-parse", "--abbrev-ref", "HEAD" }, {}, function(branch_result)
		if branch_result.code ~= 0 then
			show_error(result_message(branch_result, "Could not determine current branch"))
			if on_done then
				on_done(false)
			end
			return
		end

		local branch = vim.trim(branch_result.stdout)
		if branch == "" or branch == "HEAD" then
			show_error("Cannot set upstream from detached HEAD")
			if on_done then
				on_done(false)
			end
			return
		end

		local confirmed = ui.input.confirm(
			("No upstream for '%s'. Push with -u origin %s?"):format(branch, branch),
			{ choices = { "&Push", "&Cancel" }, default_choice = 1 }
		)
		if not confirmed then
			if on_done then
				on_done(false)
			end
			return
		end

		git.git({ "push", "-u", "origin", branch }, {}, function(push_result)
			if push_result.code ~= 0 then
				show_error(result_message(push_result, "git push -u failed"))
				if on_done then
					on_done(false)
				end
				return
			end
			show_info(result_message(push_result, "Pushed with upstream tracking"))
			emit_post_operation()
			if on_done then
				on_done(true)
			end
		end)
	end)
end

---@param on_done fun(ok: boolean)|nil
local function run_push(on_done)
	git.git({ "push" }, {}, function(result)
		if result.code == 0 then
			show_info(result_message(result, "Push completed"))
			emit_post_operation()
			if on_done then
				on_done(true)
			end
			return
		end

		local output = result_message(result, "git push failed")
		if output_mentions_upstream_problem(output) then
			push_with_upstream(on_done)
			return
		end

		show_error(output)
		if on_done then
			on_done(false)
		end
	end)
end

local function run_pull()
	git.git({ "pull" }, {}, function(result)
		if result.code ~= 0 then
			show_error(result_message(result, "git pull failed"))
			return
		end
		show_info(result_message(result, "Pull completed"))
		emit_post_operation()
	end)
end

---@param remote string|nil
local function run_fetch(remote)
	git_branch.fetch(remote, {}, function(err, result)
		if err then
			show_error(err)
			return
		end
		show_info(result_message(result, "Fetch completed"))
		emit_post_operation()
		if branch_panel.is_open() then
			branch_panel.refresh()
		end
	end)
end

---@param on_done fun(ok: boolean)|nil
local function run_quick_commit_flow(on_done)
	git_status.stage_all({}, function(stage_err)
		if stage_err then
			show_error(stage_err)
			if on_done then
				on_done(false)
			end
			return
		end

		git_status.fetch({}, function(fetch_err, _, grouped)
			if fetch_err then
				show_error(fetch_err)
				if on_done then
					on_done(false)
				end
				return
			end

			local staged_count = git_status.count_staged(grouped)
			if staged_count == 0 then
				utils.notify("No changes to commit", vim.log.levels.WARN)
				if on_done then
					on_done(false)
				end
				return
			end

			ui.input.prompt({
				prompt = "Quick commit message: ",
				on_cancel = function()
					utils.notify("Quick commit canceled", vim.log.levels.INFO)
					if on_done then
						on_done(false)
					end
				end,
			}, function(message)
				local trimmed = vim.trim(message)
				if trimmed == "" then
					utils.notify("Commit message cannot be empty", vim.log.levels.WARN)
					if on_done then
						on_done(false)
					end
					return
				end

				git.git({ "commit", "-m", trimmed }, {}, function(commit_result)
					if commit_result.code ~= 0 then
						show_error(result_message(commit_result, "git commit failed"))
						if on_done then
							on_done(false)
						end
						return
					end

					show_info(result_message(commit_result, "Commit created"))
					refresh_status_panel_if_open()
					emit_post_operation()
					if on_done then
						on_done(true)
					end
				end)
			end)
		end)
	end)
end

---@type table<GitflowQuickActionStep, fun(on_done: fun(ok: boolean)|nil)>
local quick_action_runners = {
	commit = run_quick_commit_flow,
	push = run_push,
}

---@param cfg GitflowConfig
---@param action_name "quick_commit"|"quick_push"
---@param on_done fun(ok: boolean)|nil
local function run_quick_action(cfg, action_name, on_done)
	local sequence = cfg.quick_actions[action_name]

	local function run_step(index)
		if index > #sequence then
			if on_done then
				on_done(true)
			end
			return
		end

		local step_name = sequence[index]
		local runner = quick_action_runners[step_name]
		if not runner then
			show_error(
				("Unknown quick action step '%s' in quick_actions.%s")
					:format(tostring(step_name), action_name)
			)
			if on_done then
				on_done(false)
			end
			return
		end

		runner(function(ok)
			if not ok then
				if on_done then
					on_done(false)
				end
				return
			end
			run_step(index + 1)
		end)
	end

	run_step(1)
end

---@param paths string[]
---@return string
local function format_conflicted_paths(paths)
	if #paths == 0 then
		return "(none)"
	end
	return table.concat(paths, "\n")
end

---@param cfg GitflowConfig
---@param output string
---@param heading string
---@param hint string|nil
local function handle_conflict_failure(cfg, output, heading, hint)
	local parsed = git_conflict.parse_conflicted_paths_from_output(output)

	---@param paths string[]
	local function notify_and_open(paths)
		local hint_text = ""
		if hint and hint ~= "" then
			hint_text = ("\n\n%s"):format(hint)
		end

		show_error(
			("%s\nConflicted files:\n%s%s\n\n%s"):format(
				heading,
				format_conflicted_paths(paths),
				hint_text,
				output
			)
		)
		refresh_status_panel_if_open()
		conflict_panel.open(cfg)
	end

	if #parsed > 0 then
		notify_and_open(parsed)
		return
	end

	git_conflict.list({}, function(err, conflicted)
		if err or #conflicted == 0 then
			show_error(output)
			return
		end
		notify_and_open(conflicted)
	end)
end

---@param branch string
---@param cfg GitflowConfig
local function run_merge(branch, cfg)
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
			emit_post_operation()
			return
		end

		local output = result_message(result, ("git merge %s failed"):format(branch))
		handle_conflict_failure(cfg, output, "Merge has conflicts.", nil)
	end)
end

---@param cfg GitflowConfig
local function run_merge_abort(cfg)
	git.git({ "merge", "--abort" }, {}, function(result)
		if result.code ~= 0 then
			show_error(result_message(result, "git merge --abort failed"))
			return
		end

		show_info(result_message(result, "git merge --abort completed"))
		if conflict_panel.is_open() then
			conflict_panel.close()
		end
		refresh_status_panel_if_open()
		emit_post_operation()
	end)
end

---@param args string[]
---@param cfg GitflowConfig
local function run_rebase(args, cfg)
	local git_args = { "rebase" }
	for _, arg in ipairs(args) do
		git_args[#git_args + 1] = arg
	end

	git.git(git_args, {}, function(result)
		local action = table.concat(git_args, " ")
		if result.code == 0 then
			local output = result_message(result, ("%s completed"):format(action))
			show_info(output)
			if action == "rebase --abort" or action == "rebase --continue" then
				conflict_panel.close()
			end
			refresh_status_panel_if_open()
			emit_post_operation()
			return
		end

		local output = result_message(result, ("%s failed"):format(action))
		handle_conflict_failure(
			cfg,
			output,
			"Rebase stopped with conflicts.",
			"Use :Gitflow rebase --continue or :Gitflow rebase --abort."
		)
	end)
end

---@param commit string
---@param cfg GitflowConfig
local function run_cherry_pick(commit, cfg)
	git.git({ "cherry-pick", commit }, {}, function(result)
		if result.code == 0 then
			local output = result_message(result, ("Cherry-picked %s"):format(commit))
			show_info(output)
			refresh_status_panel_if_open()
			emit_post_operation()
			return
		end

		local output = result_message(result, ("git cherry-pick %s failed"):format(commit))
		handle_conflict_failure(cfg, output, "Cherry-pick has conflicts.", nil)
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

---@param args string[]
---@param start_index integer
---@return string|nil
local function first_positional_from(args, start_index)
	for i = start_index, #args do
		local arg = args[i]
		if not vim.startswith(arg, "--") then
			return arg
		end
	end
	return nil
end

---@param value string|nil
---@return string|nil
local function trimmed_or_nil(value)
	if value == nil then
		return nil
	end
	local trimmed = vim.trim(value)
	if trimmed == "" then
		return nil
	end
	return trimmed
end

---@param text string|nil
---@return string[]
local function parse_csv(text)
	local items = {}
	for _, token in ipairs(vim.split(text or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if trimmed ~= "" then
			items[#items + 1] = trimmed
		end
	end
	return items
end

---@param args string[]
---@param start_index integer
---@return table
local function parse_issue_list_args(args, start_index)
	local options = {
		state = "open",
		label = nil,
		assignee = nil,
		limit = 100,
	}

	local i = start_index
	while i <= #args do
		local token = args[i]
		if token == "open" or token == "closed" or token == "all" then
			options.state = token
		elseif token == "--state" then
			options.state = args[i + 1] or options.state
			i = i + 1
		elseif token == "--label" then
			options.label = args[i + 1] or options.label
			i = i + 1
		elseif token == "--assignee" then
			options.assignee = args[i + 1] or options.assignee
			i = i + 1
		elseif token == "--limit" then
			options.limit = tonumber(args[i + 1]) or options.limit
			i = i + 1
		else
			local label = token:match("^label=(.+)$")
			if label then
				options.label = label
			end
			local assignee = token:match("^assignee=(.+)$")
			if assignee then
				options.assignee = assignee
			end
		end
		i = i + 1
	end

	return options
end

---@param args string[]
---@param start_index integer
---@return table
local function parse_pr_list_args(args, start_index)
	local options = {
		state = "open",
		base = nil,
		head = nil,
		limit = 100,
	}

	local i = start_index
	while i <= #args do
		local token = args[i]
		if token == "open" or token == "closed" or token == "merged" or token == "all" then
			options.state = token
		elseif token == "--state" then
			options.state = args[i + 1] or options.state
			i = i + 1
		elseif token == "--base" then
			options.base = args[i + 1] or options.base
			i = i + 1
		elseif token == "--head" then
			options.head = args[i + 1] or options.head
			i = i + 1
		elseif token == "--limit" then
			options.limit = tonumber(args[i + 1]) or options.limit
			i = i + 1
		else
			local base = token:match("^base=(.+)$")
			if base then
				options.base = base
			end
			local head = token:match("^head=(.+)$")
			if head then
				options.head = head
			end
		end
		i = i + 1
	end

	return options
end

---@param cfg GitflowConfig
local function run_sync(cfg)
	local strategy = (cfg.sync and cfg.sync.pull_strategy) or "rebase"
	local pull_args = { "pull" }
	if strategy == "rebase" then
		pull_args[#pull_args + 1] = "--rebase"
	else
		pull_args[#pull_args + 1] = "--no-rebase"
	end

	show_info("Sync step 1/3: git fetch --all --prune")
	git_branch.fetch(nil, {}, function(fetch_err, fetch_result)
		if fetch_err then
			show_error(("Sync failed during fetch: %s"):format(fetch_err))
			return
		end
		show_info(result_message(fetch_result, "Fetch completed"))
		if branch_panel.is_open() then
			branch_panel.refresh()
		end

		show_info(("Sync step 2/3: git pull (%s)"):format(strategy))
		git.git(pull_args, {}, function(pull_result)
			if pull_result.code ~= 0 then
				local output = result_message(pull_result, "git pull failed")
				handle_conflict_failure(
					cfg,
					output,
					"Sync stopped at pull step.",
					"Resolve conflicts, then run :Gitflow sync again."
				)
				return
			end

			show_info(result_message(pull_result, "Pull completed"))
			emit_post_operation()
			git_branch.is_ahead_of_upstream({}, function(ahead_err, ahead, count)
				if ahead_err then
					show_error(
						("Sync completed fetch/pull, but push check failed: %s"):format(ahead_err)
					)
					return
				end

				if not ahead then
					show_info("Sync complete: no outgoing commits, push skipped")
					refresh_status_panel_if_open()
					return
				end

				show_info(
					("Sync step 3/3: git push (%d outgoing commit(s))"):format(count or 0)
				)
				run_push(function(ok)
					if ok then
						show_info("Sync complete: fetch, pull, and push succeeded")
					end
					refresh_status_panel_if_open()
				end)
			end)
		end)
	end)
end

local github_subcommands = {
	issue = true,
	pr = true,
	label = true,
}

local ui_subcommands = {
	help = true,
	open = true,
	refresh = true,
	close = true,
	palette = true,
}

---@param name string
---@param subcommand GitflowSubcommand
---@return string
local function subcommand_category(name, subcommand)
	if subcommand.category and subcommand.category ~= "" then
		return subcommand.category
	end
	if github_subcommands[name] then
		return "GitHub"
	end
	if ui_subcommands[name] then
		return "UI"
	end
	return "Git"
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

		entries[#entries + 1] = {
			name = name,
			description = subcommand.description,
			category = subcommand_category(name, subcommand),
			keybinding = keybinding,
		}
	end
	return entries
end

---@param cfg GitflowConfig
local function open_palette(cfg)
	local entries = M.palette_entries(cfg)
	palette_panel.open(cfg, entries, function(entry)
		M.dispatch({ entry.name }, cfg)
	end)
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
			issue_panel.close()
			pr_panel.close()
			label_panel.close()
			review_panel.close()
			conflict_panel.close()
			palette_panel.close()
			return "Gitflow panels closed"
		end,
	}

	M.subcommands.palette = {
		description = "Open command palette",
		run = function()
			open_palette(cfg)
			return "Command palette opened"
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

	M.subcommands.sync = {
		description = "Fetch, pull, and push in sequence",
		run = function()
			run_sync(cfg)
			return "Running sync..."
		end,
	}

	M.subcommands["quick-commit"] = {
		description = "Stage all changes, then commit with a prompt",
		run = function()
			run_quick_action(cfg, "quick_commit")
			return "Running quick commit..."
		end,
	}

	M.subcommands["quick-push"] = {
		description = "Quick commit, then push",
		run = function()
			run_quick_action(cfg, "quick_push")
			return "Running quick push..."
		end,
	}

	M.subcommands.fetch = {
		description = "Run git fetch (supports optional remote)",
		run = function(ctx)
			local remote = first_positional(ctx.args)
			run_fetch(remote)
			if remote then
				return ("Running git fetch --prune %s..."):format(remote)
			end
			return "Running git fetch --all --prune..."
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
					local has_message_arg = ctx.args[3] ~= nil
					if has_message_arg then
						local message = table.concat(ctx.args, " ", 3)
						if vim.trim(message) == "" then
						message = nil
					end
					run_stash_push(message)
					else
						prompt_and_run_stash_push()
					end
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
					emit_post_operation()
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
					emit_post_operation()
				end)
				return "Running git stash drop..."
			end

			return ("Unknown stash action: %s"):format(action)
		end,
	}

	M.subcommands.issue = {
		description = "GitHub issues: list|view|create|comment|close|reopen|edit",
		run = function(ctx)
			local ready, prerequisite_error = gh.ensure_prerequisites()
			if not ready then
				return prerequisite_error or "GitHub CLI prerequisites are not satisfied"
			end

			local action = ctx.args[2] or "list"
			if action == "list" then
				issue_panel.open(cfg, parse_issue_list_args(ctx.args, 3))
				return "Loading issues..."
			end

			if action == "view" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow issue view <number>"
				end
				issue_panel.open_view(number, cfg)
				return ("Loading issue #%s..."):format(number)
			end

			if action == "create" then
				issue_panel.open(cfg, parse_issue_list_args(ctx.args, 3))
				vim.schedule(function()
					issue_panel.create_interactive()
				end)
				return "Opening issue creation prompt..."
			end

			if action == "comment" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow issue comment <number>"
				end

				local message = table.concat(ctx.args, " ", 4)
				if vim.trim(message) ~= "" then
					gh_issues.comment(number, message, {}, function(err)
						if err then
							show_error(err)
							return
						end
						show_info(("Comment posted to issue #%s"):format(number))
						if issue_panel.is_open() then
							issue_panel.refresh()
						end
					end)
					return ("Commenting on issue #%s..."):format(number)
				end

				issue_panel.open(cfg, parse_issue_list_args(ctx.args, 3))
				vim.schedule(function()
					issue_panel.open_view(number, cfg)
					vim.schedule(function()
						issue_panel.comment_under_cursor()
					end)
				end)
				return ("Opening comment prompt for issue #%s..."):format(number)
			end

			if action == "close" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow issue close <number>"
				end
				gh_issues.close(number, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Closed issue #%s"):format(number))
					if issue_panel.is_open() then
						issue_panel.refresh()
					end
				end)
				return ("Closing issue #%s..."):format(number)
			end

			if action == "reopen" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow issue reopen <number>"
				end
				gh_issues.reopen(number, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Reopened issue #%s"):format(number))
					if issue_panel.is_open() then
						issue_panel.refresh()
					end
				end)
				return ("Reopening issue #%s..."):format(number)
			end

			if action == "edit" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow issue edit <number> [title=...] [body=...] [add=...] [remove=...]"
				end

				local edit_opts = {}
				for i = 4, #ctx.args do
					local token = ctx.args[i]
					local title = token:match("^title=(.+)$")
					if title then
						edit_opts.title = title
					end
					local body = token:match("^body=(.+)$")
					if body then
						edit_opts.body = body
					end
					local add = token:match("^add=(.+)$")
					if add then
						edit_opts.add_labels = parse_csv(add)
					end
					local remove = token:match("^remove=(.+)$")
					if remove then
						edit_opts.remove_labels = parse_csv(remove)
					end
				end

				gh_issues.edit(number, edit_opts, {}, function(err, _result)
					if err then
						show_error(err)
						return
					end
					show_info(("Updated issue #%s"):format(number))
					if issue_panel.is_open() then
						issue_panel.refresh()
					end
				end)
				return ("Updating issue #%s..."):format(number)
			end

			return ("Unknown issue action: %s"):format(action)
		end,
	}

	M.subcommands.pr = {
		description = "GitHub PRs: list|view|review|submit-review|respond|create|comment|"
			.. "merge|checkout|close",
		run = function(ctx)
			local ready, prerequisite_error = gh.ensure_prerequisites()
			if not ready then
				return prerequisite_error or "GitHub CLI prerequisites are not satisfied"
			end

			local action = ctx.args[2] or "list"
			if action == "list" then
				pr_panel.open(cfg, parse_pr_list_args(ctx.args, 3))
				return "Loading pull requests..."
			end

			if action == "view" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr view <number>"
				end
				pr_panel.open_view(number, cfg)
				return ("Loading PR #%s..."):format(number)
			end

			if action == "review" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr review <number> [approve|request_changes|comment] [message]"
				end

				local mode = trimmed_or_nil(ctx.args[4])
				if mode == "request-changes" then
					mode = "request_changes"
				end

				if not mode then
					review_panel.open(cfg, number)
					return ("Loading review interface for PR #%s..."):format(number)
				end

				if mode ~= "approve" and mode ~= "request_changes" and mode ~= "comment" then
					return "Usage: :Gitflow pr review <number> [approve|request_changes|comment] [message]"
				end

				local message = table.concat(ctx.args, " ", 5)
				if vim.trim(message) == "" then
					review_panel.open(cfg, number)
					vim.schedule(function()
						if mode == "approve" then
							review_panel.review_approve()
						elseif mode == "request_changes" then
							review_panel.review_request_changes()
						else
							review_panel.review_comment()
						end
					end)
					return ("Opening %s review prompt for PR #%s..."):format(mode, number)
				end

				gh_prs.review(number, mode, message, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Submitted %s review for PR #%s"):format(mode, number))
					if review_panel.is_open() and tonumber(review_panel.state.pr_number) == tonumber(number) then
						review_panel.refresh()
					end
					if pr_panel.is_open() then
						pr_panel.refresh()
					end
				end)
				return ("Submitting %s review for PR #%s..."):format(mode, number)
			end

			if action == "submit-review" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr submit-review"
						.. " <number>"
						.. " <approve|request_changes|comment>"
						.. " [message]"
				end

				local mode = trimmed_or_nil(ctx.args[4])
				if mode == "request-changes" then
					mode = "request_changes"
				end
				if mode ~= "approve"
					and mode ~= "request_changes"
					and mode ~= "comment" then
					return "Usage: :Gitflow pr submit-review"
						.. " <number>"
						.. " <approve|request_changes|comment>"
						.. " [message]"
				end

				local message = table.concat(ctx.args, " ", 5)
				if vim.trim(message) == "" then
					message = ""
				end

				-- If review panel is open for this PR,
				-- use submit_review_direct to batch
				-- pending comments
				if review_panel.is_open()
					and tonumber(
						review_panel.state.pr_number
					) == tonumber(number) then
					review_panel.submit_review_direct(
						mode, message
					)
					return (
						"Submitting %s review for"
							.. " PR #%s..."
					):format(mode, number)
				end

				gh_prs.review(
					number, mode, message, {},
					function(err)
						if err then
							show_error(err)
							return
						end
						show_info(
							(
								"Submitted %s review"
									.. " for PR #%s"
							):format(mode, number)
						)
						if pr_panel.is_open() then
							pr_panel.refresh()
						end
					end
				)
				return (
					"Submitting %s review for PR #%s..."
				):format(mode, number)
			end

			if action == "respond" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr respond <number>"
				end
				review_panel.respond_to_review(number)
				return ("Loading reviews for PR #%s..."):format(number)
			end

			if action == "create" then
				pr_panel.open(cfg, parse_pr_list_args(ctx.args, 3))
				vim.schedule(function()
					pr_panel.create_interactive()
				end)
				return "Opening PR creation prompt..."
			end

			if action == "comment" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr comment <number>"
				end

				local message = table.concat(ctx.args, " ", 4)
				if vim.trim(message) ~= "" then
					gh_prs.comment(number, message, {}, function(err)
						if err then
							show_error(err)
							return
						end
						show_info(("Comment posted to PR #%s"):format(number))
						if pr_panel.is_open() then
							pr_panel.refresh()
						end
					end)
					return ("Commenting on PR #%s..."):format(number)
				end

				pr_panel.open(cfg, parse_pr_list_args(ctx.args, 3))
				vim.schedule(function()
					pr_panel.open_view(number, cfg)
					vim.schedule(function()
						pr_panel.comment_under_cursor()
					end)
				end)
				return ("Opening comment prompt for PR #%s..."):format(number)
			end

			if action == "merge" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr merge <number> [merge|squash|rebase]"
				end

				local strategy = ctx.args[4] or "merge"
				if strategy ~= "merge" and strategy ~= "squash" and strategy ~= "rebase" then
					return "Usage: :Gitflow pr merge <number> [merge|squash|rebase]"
				end

				gh_prs.merge(number, strategy, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Merged PR #%s (%s)"):format(number, strategy))
					if pr_panel.is_open() then
						pr_panel.refresh()
					end
				end)
				return ("Merging PR #%s (%s)..."):format(number, strategy)
			end

			if action == "checkout" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr checkout <number>"
				end

				gh_prs.checkout(number, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Checked out PR #%s"):format(number))
				end)
				return ("Checking out PR #%s..."):format(number)
			end

			if action == "close" then
				local number = first_positional_from(ctx.args, 3)
				if not number then
					return "Usage: :Gitflow pr close <number>"
				end

				gh_prs.close(number, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Closed PR #%s"):format(number))
					if pr_panel.is_open() then
						pr_panel.refresh()
					end
				end)
				return ("Closing PR #%s..."):format(number)
			end

			return ("Unknown pr action: %s"):format(action)
		end,
	}

	M.subcommands.label = {
		description = "GitHub labels: list|create|delete",
		run = function(ctx)
			local ready, prerequisite_error = gh.ensure_prerequisites()
			if not ready then
				return prerequisite_error or "GitHub CLI prerequisites are not satisfied"
			end

			local action = ctx.args[2] or "list"
			if action == "list" then
				label_panel.open(cfg)
				return "Loading labels..."
			end

			if action == "create" then
				local name = trimmed_or_nil(ctx.args[3])
				local color = trimmed_or_nil(ctx.args[4])
				if not name or not color then
					return "Usage: :Gitflow label create <name> <color> [description]"
				end
				local description = table.concat(ctx.args, " ", 5)
				if vim.trim(description) == "" then
					description = nil
				end

				gh_labels.create(name, color, description, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Created label '%s'"):format(name))
					if label_panel.is_open() then
						label_panel.refresh()
					end
				end)
				return ("Creating label '%s'..."):format(name)
			end

			if action == "delete" then
				local name = trimmed_or_nil(ctx.args[3])
				if not name then
					return "Usage: :Gitflow label delete <name>"
				end

				local confirmed = ui.input.confirm(
					("Delete label '%s'?"):format(name),
					{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
				)
				if not confirmed then
					return "Label deletion canceled"
				end

				gh_labels.delete(name, {}, function(err)
					if err then
						show_error(err)
						return
					end
					show_info(("Deleted label '%s'"):format(name))
					if label_panel.is_open() then
						label_panel.refresh()
					end
				end)
				return ("Deleting label '%s'..."):format(name)
			end

			return ("Unknown label action: %s"):format(action)
		end,
	}

	M.subcommands.conflicts = {
		description = "Open merge conflict resolution panel",
		run = function()
			conflict_panel.open(cfg)
			return "Conflict resolution panel opened"
		end,
	}

	M.subcommands.conflict = {
		description = "Alias for :Gitflow conflicts",
		run = function()
			conflict_panel.open(cfg)
			return "Conflict resolution panel opened"
		end,
	}

	M.subcommands.merge = {
		description = "Merge branch into current branch (supports --abort)",
		run = function(ctx)
			if has_flag(ctx.args, "--abort") then
				run_merge_abort(cfg)
				return "Running git merge --abort..."
			end

			local target = first_positional(ctx.args)
			if not target then
				return "Usage: :Gitflow merge <branch>|--abort"
			end
			run_merge(target, cfg)
			return ("Running git merge %s..."):format(target)
		end,
	}

	M.subcommands.rebase = {
		description = "Rebase current branch (supports --abort/--continue)",
		run = function(ctx)
			if has_flag(ctx.args, "--abort") then
				run_rebase({ "--abort" }, cfg)
				return "Running git rebase --abort..."
			end
			if has_flag(ctx.args, "--continue") then
				run_rebase({ "--continue" }, cfg)
				return "Running git rebase --continue..."
			end

			local target = first_positional(ctx.args)
			if not target then
				return "Usage: :Gitflow rebase <branch>|--abort|--continue"
			end
			run_rebase({ target }, cfg)
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
			run_cherry_pick(commit, cfg)
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
local function list_remote_candidates()
	local remotes = {}
	for _, line in ipairs(system_lines({ "remote" })) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			remotes[#remotes + 1] = trimmed
		end
	end
	table.sort(remotes)
	return remotes
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

local issue_actions = { "list", "view", "create", "comment", "close", "reopen", "edit" }
local pr_actions = {
	"list", "view", "review", "submit-review", "respond",
	"create", "comment", "merge", "checkout", "close",
}
local label_actions = { "list", "create", "delete" }

---@param cmdline string
---@param args string[]
---@return boolean
local function completing_action(cmdline, args)
	return #args == 2 or (#args == 3 and not cmdline:match("%s$"))
end

---@param subaction string|nil
---@param arglead string
---@return string[]
local function complete_issue(subaction, arglead)
	if subaction == "view"
		or subaction == "comment"
		or subaction == "close"
		or subaction == "reopen"
	then
		return {}
	end

	if subaction == "list" then
		local candidates = {
			"open",
			"closed",
			"all",
			"--state",
			"--label",
			"--assignee",
			"--limit",
			"label=",
			"assignee=",
		}
		return filter_candidates(arglead, candidates)
	end

	if subaction == "edit" then
		return filter_candidates(arglead, { "title=", "body=", "add=", "remove=" })
	end

	return {}
end

---@param subaction string|nil
---@param arglead string
---@return string[]
local function complete_pr(subaction, arglead)
	if subaction == "view"
		or subaction == "comment"
		or subaction == "checkout"
		or subaction == "close"
		or subaction == "respond" then
		return {}
	end

	if subaction == "list" then
		local candidates = {
			"open",
			"closed",
			"merged",
			"all",
			"--state",
			"--base",
			"--head",
			"--limit",
			"base=",
			"head=",
		}
		return filter_candidates(arglead, candidates)
	end

	if subaction == "merge" then
		return filter_candidates(
			arglead, { "merge", "squash", "rebase" }
		)
	end

	if subaction == "review" or subaction == "submit-review" then
		return filter_candidates(arglead, {
			"approve", "request_changes",
			"request-changes", "comment",
		})
	end

	return {}
end

---@param subaction string|nil
---@param arglead string
---@return string[]
local function complete_label(subaction, arglead)
	if subaction == "delete" then
		return {}
	end
	if subaction == "create" then
		return {}
	end
	return filter_candidates(arglead, { "list", "create", "delete" })
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
	if subcommand.category ~= nil and type(subcommand.category) ~= "string" then
		error("gitflow command error: subcommand category must be a string", 2)
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

	local args = split_args(cmdline)
	if #args == 0 then
		return {}
	end

	if #args == 1 then
		return filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	-- `:Gitflow <subcommand>` completion
	if #args == 2 and not cmdline:match("%s$") then
		return filter_candidates(arglead, utils.sorted_keys(M.subcommands))
	end

	local subcommand = args[2]
	if subcommand == "merge" then
		local candidates = { "--abort" }
		for _, value in ipairs(list_branch_candidates()) do
			candidates[#candidates + 1] = value
		end
		return filter_candidates(arglead, candidates)
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
	if subcommand == "fetch" then
		return filter_candidates(arglead, list_remote_candidates())
	end
	if subcommand == "issue" then
		if completing_action(cmdline, args) then
			return filter_candidates(arglead, issue_actions)
		end
		return complete_issue(args[3], arglead)
	end
	if subcommand == "pr" then
		if completing_action(cmdline, args) then
			return filter_candidates(arglead, pr_actions)
		end
		return complete_pr(args[3], arglead)
	end
	if subcommand == "label" then
		if completing_action(cmdline, args) then
			return filter_candidates(arglead, label_actions)
		end
		return complete_label(args[3], arglead)
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
	vim.keymap.set("n", "<Plug>(GitflowIssue)", "<Cmd>Gitflow issue list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPr)", "<Cmd>Gitflow pr list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowLabel)", "<Cmd>Gitflow label list<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowPalette)", "<Cmd>Gitflow palette<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowConflict)", "<Cmd>Gitflow conflicts<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowConflicts)", "<Cmd>Gitflow conflicts<CR>", { silent = true })

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
		issue = "<Plug>(GitflowIssue)",
		pr = "<Plug>(GitflowPr)",
		label = "<Plug>(GitflowLabel)",
		palette = "<Plug>(GitflowPalette)",
		conflict = "<Plug>(GitflowConflicts)",
	}
	for action, mapping in pairs(current.keybindings) do
		local plug = key_to_plug[action]
		if plug then
			vim.keymap.set("n", mapping, plug, { remap = true, silent = true })
		end
	end
end

return M
