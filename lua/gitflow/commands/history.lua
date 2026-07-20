-- Area: rewriting and combining history — merge, rebase, cherry-pick, reset,
-- revert, tags and the conflict resolver.
local git = require("gitflow.git")
local git_tag = require("gitflow.git.tag")
local shared = require("gitflow.commands.shared")
local conflict_panel = require("gitflow.panels.conflict")
local reset_panel = require("gitflow.panels.reset")
local cherry_pick_panel = require("gitflow.panels.cherry_pick")
local rebase_panel = require("gitflow.panels.rebase")
local revert_panel = require("gitflow.panels.revert")
local tag_panel = require("gitflow.panels.tag")

local M = {}

M.panels = { conflict_panel, reset_panel, cherry_pick_panel, rebase_panel, revert_panel, tag_panel }

local LOCK_MAX_ATTEMPTS = 10
local LOCK_RETRY_DELAY_MS = 150

local TAG_ACTIONS = { "list", "create", "delete", "push" }

---@param output string
---@return boolean
local function mentions_index_lock(output)
	local normalized = (output or ""):lower()
	if not normalized:find("index.lock", 1, true) then
		return false
	end
	return normalized:find("file exists", 1, true) ~= nil
		or normalized:find("unable to create", 1, true) ~= nil
		or normalized:find("another git process", 1, true) ~= nil
end

---@param args string[]
---@param opts GitflowGitRunOpts|nil
---@param cb fun(result: GitflowGitResult)
---@param attempt integer|nil
local function git_with_lock_retry(args, opts, cb, attempt)
	local current = attempt or 1
	git.git(args, opts or {}, function(result)
		if result.code == 0 then
			cb(result)
			return
		end
		local output = git.output(result)
		if mentions_index_lock(output) and current < LOCK_MAX_ATTEMPTS then
			vim.defer_fn(function()
				git_with_lock_retry(args, opts, cb, current + 1)
			end, LOCK_RETRY_DELAY_MS)
			return
		end
		cb(result)
	end)
end

---@param branch string
---@param cfg GitflowConfig
local function run_merge(branch, cfg)
	-- A merge that creates a merge commit would launch $GIT_EDITOR for the
	-- message; keep it non-interactive so it uses the default message and
	-- never blocks on `vi`.
	git_with_lock_retry(
		{ "merge", branch }, git.with_noninteractive_editor(nil),
		function(result)
		if result.code == 0 then
			local output = shared.result_message(result, ("Merged '%s'"):format(branch))
			local merge_type = "Merge commit created"
			local normalized = output:lower()
			if normalized:find("fast%-forward", 1) then
				merge_type = "Fast-forward merge completed"
			elseif normalized:find("already up to date", 1, true) then
				merge_type = "Already up to date"
			end

			shared.show_info(("%s\n%s"):format(merge_type, output))
			shared.refresh_status_panel_if_open()
			shared.emit_post_operation()
			return
		end

		local output = shared.result_message(result, ("git merge %s failed"):format(branch))
		shared.handle_conflict_failure(cfg, output, "Merge has conflicts.", nil)
	end)
end

---@param cfg GitflowConfig
local function run_merge_abort(cfg)
	git_with_lock_retry({ "merge", "--abort" }, {}, function(result)
		if result.code ~= 0 then
			shared.show_error(shared.result_message(result, "git merge --abort failed"))
			return
		end

		shared.show_info(shared.result_message(result, "git merge --abort completed"))
		if conflict_panel.is_open() then
			conflict_panel.close()
		end
		shared.refresh_status_panel_if_open()
		shared.emit_post_operation()
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
			local output = shared.result_message(result, ("%s completed"):format(action))
			shared.show_info(output)
			if action == "rebase --abort" or action == "rebase --continue" then
				conflict_panel.close()
			end
			shared.refresh_status_panel_if_open()
			shared.emit_post_operation()
			return
		end

		local output = shared.result_message(result, ("%s failed"):format(action))
		shared.handle_conflict_failure(
			cfg,
			output,
			"Rebase stopped with conflicts.",
			"Use :Gitflow rebase --continue" .. " or :Gitflow rebase --abort."
		)
	end)
end

---@param commit string
---@param cfg GitflowConfig
local function run_cherry_pick(commit, cfg)
	git.git(
		{ "cherry-pick", commit }, git.with_noninteractive_editor(nil),
		function(result)
		if result.code == 0 then
			local output = shared.result_message(result, ("Cherry-picked %s"):format(commit))
			shared.show_info(output)
			shared.refresh_status_panel_if_open()
			shared.emit_post_operation()
			return
		end

		local output = shared.result_message(result, ("git cherry-pick %s failed"):format(commit))
		shared.handle_conflict_failure(cfg, output, "Cherry-pick has conflicts.", nil)
	end)
end

---@return string[]
local function list_commit_candidates()
	local hashes = {}
	for _, line in ipairs(shared.system_lines({ "log", "--all", "--pretty=format:%H", "-n", "400" })) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			hashes[#hashes + 1] = trimmed
		end
	end
	return hashes
end

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config

	ctx.register("reset", {
		description = "Open git reset panel",
		run = function()
			reset_panel.open(cfg)
			return "Reset panel opened"
		end,
	})

	ctx.register("revert", {
		description = "Open git revert panel",
		run = function()
			revert_panel.open(cfg)
			return "Revert panel opened"
		end,
	})

	ctx.register("tag", {
		description = "Tag operations: list|create|delete|push",
		run = function(cmd)
			local action = cmd.args[2] or "list"
			if action == "list" then
				tag_panel.open(cfg)
				return "Tag panel opened"
			end

			if action == "create" then
				local name = shared.trimmed_or_nil(cmd.args[3])
				if not name then
					return "Usage: :Gitflow tag create <name> [message]"
				end
				local message = nil
				if cmd.args[4] then
					message = table.concat(cmd.args, " ", 4)
					if vim.trim(message) == "" then
						message = nil
					end
				end
				git_tag.create(name, { message = message }, function(err)
					if err then
						shared.show_error(err)
						return
					end
					local label = message and "annotated" or "lightweight"
					shared.show_info(("Created %s tag '%s'"):format(label, name))
					if tag_panel.is_open() then
						tag_panel.refresh()
					end
					shared.emit_post_operation()
				end)
				return ("Creating tag '%s'..."):format(name)
			end

			if action == "delete" then
				local name = shared.trimmed_or_nil(cmd.args[3])
				if not name then
					return "Usage: :Gitflow tag delete <name>"
				end
				git_tag.delete(name, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Deleted tag '%s'"):format(name))
					if tag_panel.is_open() then
						tag_panel.refresh()
					end
					shared.emit_post_operation()
				end)
				return ("Deleting tag '%s'..."):format(name)
			end

			if action == "push" then
				local name = shared.trimmed_or_nil(cmd.args[3])
				if not name then
					return "Usage: :Gitflow tag push <name> [remote]"
				end
				local remote = shared.trimmed_or_nil(cmd.args[4])
				git_tag.push(name, remote, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Pushed tag '%s'"):format(name))
				end)
				return ("Pushing tag '%s'..."):format(name)
			end

			return ("Unknown tag action: %s"):format(action)
		end,
		complete = function(arglead, cmdline, args)
			if shared.completing_action(cmdline, args) then
				return shared.filter_candidates(arglead, TAG_ACTIONS)
			end
			return {}
		end,
	})

	ctx.register("conflicts", {
		description = "Open merge conflict resolution panel",
		run = function()
			conflict_panel.open(cfg)
			return "Conflict resolution panel opened"
		end,
	})

	ctx.register("conflict", {
		description = "Alias for :Gitflow conflicts",
		run = function()
			conflict_panel.open(cfg)
			return "Conflict resolution panel opened"
		end,
	})

	ctx.register("merge", {
		description = "Merge branch into current branch (supports --abort)",
		run = function(cmd)
			if shared.has_flag(cmd.args, "--abort") then
				run_merge_abort(cfg)
				return "Running git merge --abort..."
			end

			local target = shared.first_positional(cmd.args)
			if not target then
				return "Usage: :Gitflow merge <branch>|--abort"
			end
			run_merge(target, cfg)
			return ("Running git merge %s..."):format(target)
		end,
		complete = function(arglead)
			local candidates = { "--abort" }
			for _, value in ipairs(shared.list_branch_candidates()) do
				candidates[#candidates + 1] = value
			end
			return shared.filter_candidates(arglead, candidates)
		end,
	})

	ctx.register("rebase", {
		description = "Rebase current branch (supports --abort/--continue)",
		run = function(cmd)
			if shared.has_flag(cmd.args, "--abort") then
				run_rebase({ "--abort" }, cfg)
				return "Running git rebase --abort..."
			end
			if shared.has_flag(cmd.args, "--continue") then
				run_rebase({ "--continue" }, cfg)
				return "Running git rebase --continue..."
			end

			local target = shared.first_positional(cmd.args)
			if not target then
				return "Usage: :Gitflow rebase <branch>|--abort|--continue"
			end
			run_rebase({ target }, cfg)
			return ("Running git rebase %s..."):format(target)
		end,
		complete = function(arglead)
			local options = { "--abort", "--continue" }
			local candidates = {}
			for _, value in ipairs(options) do
				candidates[#candidates + 1] = value
			end
			for _, value in ipairs(shared.list_branch_candidates()) do
				candidates[#candidates + 1] = value
			end
			return shared.filter_candidates(arglead, candidates)
		end,
	})

	ctx.register("cherry-pick", {
		description = "Cherry-pick a commit onto current branch",
		run = function(cmd)
			local commit = shared.first_positional(cmd.args)
			if not commit then
				return "Usage: :Gitflow cherry-pick <commit>"
			end
			run_cherry_pick(commit, cfg)
			return ("Running git cherry-pick %s..."):format(commit)
		end,
		complete = function(arglead)
			return shared.filter_candidates(arglead, list_commit_candidates())
		end,
	})

	ctx.register("cherry-pick-panel", {
		description = "Open cherry-pick panel (branch-aware commit picker)",
		run = function()
			cherry_pick_panel.open(cfg)
			return "Cherry-pick panel opened"
		end,
	})

	ctx.register("rebase-interactive", {
		description = "Open rebase panel (normal rebase, press i for interactive)",
		run = function()
			rebase_panel.open(cfg)
			return "Rebase panel opened"
		end,
	})
end

return M
