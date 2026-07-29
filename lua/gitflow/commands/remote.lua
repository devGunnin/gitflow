-- Area: talking to remotes — push, pull, fetch, sync and the quick actions.
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")
local git_status = require("gitflow.git.status")
local ui = require("gitflow.ui")
local shared = require("gitflow.commands.shared")
local branch_panel = require("gitflow.panels.branch")

local M = {}

M.panels = {}

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
	-- A branch created from another branch can inherit a differently-named
	-- upstream; git refuses the push with this wording instead of "no upstream".
	if normalized:find("upstream branch of your current branch does not match", 1, true) then
		return true
	end
	return false
end

---Read one git config value. An unset key (exit 1) is a normal outcome and
---yields nil; any other failure is surfaced.
---@param key string
---@param cb fun(value: string|nil, err: string|nil)
local function read_git_config(key, cb)
	git.git({ "config", "--get", key }, {}, function(result)
		if result.code ~= 0 and result.code ~= 1 then
			cb(nil, shared.result_message(result, ("git config --get %s failed"):format(key)))
			return
		end

		local value = vim.trim(result.stdout or "")
		if value == "" then
			cb(nil, nil)
			return
		end
		cb(value, nil)
	end)
end

---Push-remote config keys in git's own precedence order: `pushRemote` and
---`pushDefault` override the branch's tracking remote for pushes.
---@param branch string
---@return string[]
local function push_remote_config_keys(branch)
	return {
		("branch.%s.pushRemote"):format(branch),
		"remote.pushDefault",
		("branch.%s.remote"):format(branch),
	}
end

---@param keys string[]
---@param index integer
---@param cb fun(value: string|nil, err: string|nil)
local function first_configured_value(keys, index, cb)
	if index > #keys then
		cb(nil, nil)
		return
	end

	read_git_config(keys[index], function(value, err)
		if err then
			cb(nil, err)
			return
		end
		if value then
			cb(value, nil)
			return
		end
		first_configured_value(keys, index + 1, cb)
	end)
end

---Pick the push destination. Never guesses between several equally plausible
---remotes: pushing to the wrong one is not recoverable from the user's side.
---@param branch string
---@param remotes string[]
---@param configured string|nil  first push-remote config value that was set
---@return string|nil remote, string|nil err
local function select_push_remote(branch, remotes, configured)
	-- "." is the local repository (branch.autoSetupMerge=always), not a remote.
	if configured and configured ~= "." then
		if not vim.tbl_contains(remotes, configured) then
			return nil, ("Configured push remote '%s' is not a known remote (have: %s)")
				:format(configured, table.concat(remotes, ", "))
		end
		return configured, nil
	end

	if #remotes == 1 then
		return remotes[1], nil
	end
	if vim.tbl_contains(remotes, "origin") then
		return "origin", nil
	end

	return nil, ("Ambiguous push remote for '%s': %s. Set one with 'git config branch.%s.pushRemote <remote>'")
		:format(branch, table.concat(remotes, ", "), branch)
end

---@param branch string
---@param cb fun(remote: string|nil, err: string|nil)
local function resolve_push_remote(branch, cb)
	git.git({ "remote" }, {}, function(result)
		if result.code ~= 0 then
			cb(nil, shared.result_message(result, "git remote failed"))
			return
		end

		local output = vim.trim(result.stdout or "")
		if output == "" then
			cb(nil, "No remotes configured")
			return
		end

		local remotes = vim.split(output, "\n", { plain = true, trimempty = true })
		first_configured_value(push_remote_config_keys(branch), 1, function(configured, config_err)
			if config_err then
				cb(nil, config_err)
				return
			end
			cb(select_push_remote(branch, remotes, configured))
		end)
	end)
end

---@param on_done fun(ok: boolean)|nil
local function push_with_upstream(on_done)
	git.git({ "rev-parse", "--abbrev-ref", "HEAD" }, {}, function(branch_result)
		if branch_result.code ~= 0 then
			shared.show_error(shared.result_message(branch_result, "Could not determine current branch"))
			if on_done then
				on_done(false)
			end
			return
		end

		local branch = vim.trim(branch_result.stdout)
		if branch == "" or branch == "HEAD" then
			shared.show_error("Cannot set upstream from detached HEAD")
			if on_done then
				on_done(false)
			end
			return
		end

		resolve_push_remote(branch, function(remote, remote_err)
			if remote_err or not remote then
				shared.show_error(remote_err or "Could not determine remote")
				if on_done then
					on_done(false)
				end
				return
			end

			-- Push the branch to a same-named branch on the remote and track it.
			git.git({ "push", "-u", remote, branch }, {}, function(push_result)
				if push_result.code ~= 0 then
					shared.show_error(shared.result_message(push_result, "git push -u failed"))
					if on_done then
						on_done(false)
					end
					return
				end
				shared.show_info(shared.result_message(
					push_result,
					("Pushed '%s' to %s and set upstream"):format(branch, remote)
				))
				shared.emit_post_operation()
				if on_done then
					on_done(true)
				end
			end)
		end)
	end)
end

---@param on_done fun(ok: boolean)|nil
local function run_push(on_done)
	git.git({ "push" }, {}, function(result)
		if result.code == 0 then
			shared.show_info(shared.result_message(result, "Push completed"))
			shared.emit_post_operation()
			if on_done then
				on_done(true)
			end
			return
		end

		local output = shared.result_message(result, "git push failed")
		if output_mentions_upstream_problem(output) then
			push_with_upstream(on_done)
			return
		end

		shared.show_error(output)
		if on_done then
			on_done(false)
		end
	end)
end

local function run_pull()
	git.git({ "pull" }, {}, function(result)
		if result.code ~= 0 then
			shared.show_error(shared.result_message(result, "git pull failed"))
			return
		end
		shared.show_info(shared.result_message(result, "Pull completed"))
		shared.emit_post_operation()
	end)
end

---@param remote string|nil
local function run_fetch(remote)
	git_branch.fetch(remote, {}, function(err, result)
		if err then
			shared.show_error(err)
			return
		end
		shared.show_info(shared.result_message(result, "Fetch completed"))
		shared.emit_post_operation()
		if branch_panel.is_open() then
			branch_panel.refresh()
		end
	end)
end

---@param on_done fun(ok: boolean)|nil
local function run_quick_commit_flow(on_done)
	git_status.stage_all({}, function(stage_err)
		if stage_err then
			shared.show_error(stage_err)
			if on_done then
				on_done(false)
			end
			return
		end

		git_status.fetch({}, function(fetch_err, _, grouped)
			if fetch_err then
				shared.show_error(fetch_err)
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
				multiline = true,
				title = "Quick commit message",
				draft_key = "commit:quick:message",
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
						shared.show_error(shared.result_message(commit_result, "git commit failed"))
						if on_done then
							on_done(false)
						end
						return
					end

					shared.show_info(shared.result_message(commit_result, "Commit created"))
					shared.refresh_status_panel_if_open()
					shared.emit_post_operation()
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
			shared.show_error(("Unknown quick action step '%s' in quick_actions.%s"):format(tostring(step_name), action_name))
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

---@param cfg GitflowConfig
local function run_sync(cfg)
	local strategy = (cfg.sync and cfg.sync.pull_strategy) or "rebase"
	local pull_args = { "pull" }
	if strategy == "rebase" then
		pull_args[#pull_args + 1] = "--rebase"
	else
		pull_args[#pull_args + 1] = "--no-rebase"
	end

	shared.show_info("Sync step 1/3: git fetch --all --prune")
	git_branch.fetch(nil, {}, function(fetch_err, fetch_result)
		if fetch_err then
			shared.show_error(("Sync failed during fetch: %s"):format(fetch_err))
			return
		end
		shared.show_info(shared.result_message(fetch_result, "Fetch completed"))
		if branch_panel.is_open() then
			branch_panel.refresh()
		end

		shared.show_info(("Sync step 2/3: git pull (%s)"):format(strategy))
		git.git(pull_args, {}, function(pull_result)
			if pull_result.code ~= 0 then
				local output = shared.result_message(pull_result, "git pull failed")
				shared.handle_conflict_failure(
					cfg,
					output,
					"Sync stopped at pull step.",
					"Resolve conflicts, then run :Gitflow sync again."
				)
				return
			end

			shared.show_info(shared.result_message(pull_result, "Pull completed"))
			shared.emit_post_operation()
			git_branch.is_ahead_of_upstream({}, function(ahead_err, ahead, count)
				if ahead_err then
					shared.show_error(("Sync completed fetch/pull, but push check failed: %s"):format(ahead_err))
					return
				end

				if not ahead then
					shared.show_info("Sync complete: no outgoing commits, push skipped")
					shared.refresh_status_panel_if_open()
					return
				end

				shared.show_info(("Sync step 3/3: git push (%d outgoing commit(s))"):format(count or 0))
				run_push(function(ok)
					if ok then
						shared.show_info("Sync complete: fetch, pull, and push succeeded")
					end
					shared.refresh_status_panel_if_open()
				end)
			end)
		end)
	end)
end

---@return string[]
local function list_remote_candidates()
	local remotes = {}
	for _, line in ipairs(shared.system_lines({ "remote" })) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			remotes[#remotes + 1] = trimmed
		end
	end
	table.sort(remotes)
	return remotes
end

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config

	ctx.register("push", {
		description = "Run git push",
		run = function()
			run_push()
			return "Running git push..."
		end,
	})

	ctx.register("pull", {
		description = "Run git pull",
		run = function()
			run_pull()
			return "Running git pull..."
		end,
	})

	ctx.register("sync", {
		description = "Fetch, pull, and push in sequence",
		run = function()
			run_sync(cfg)
			return "Running sync..."
		end,
	})

	ctx.register("quick-commit", {
		description = "Stage all changes, then commit with a prompt",
		run = function()
			run_quick_action(cfg, "quick_commit")
			return "Running quick commit..."
		end,
	})

	ctx.register("quick-push", {
		description = "Quick commit, then push",
		run = function()
			run_quick_action(cfg, "quick_push")
			return "Running quick push..."
		end,
	})

	ctx.register("fetch", {
		description = "Run git fetch (supports optional remote)",
		run = function(cmd)
			local remote = shared.first_positional(cmd.args)
			run_fetch(remote)
			if remote then
				return ("Running git fetch --prune %s..."):format(remote)
			end
			return "Running git fetch --all --prune..."
		end,
		complete = function(arglead)
			return shared.filter_candidates(arglead, list_remote_candidates())
		end,
	})
end

return M
