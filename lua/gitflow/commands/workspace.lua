-- Area: the working copy — status, branches, commits, diffs, log and stash.
local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_status = require("gitflow.git.status")
local git_stash = require("gitflow.git.stash")
local shared = require("gitflow.commands.shared")
local status_panel = require("gitflow.panels.status")
local branch_panel = require("gitflow.panels.branch")
local diff_panel = require("gitflow.panels.diff")
local diffview_panel = require("gitflow.panels.diffview")
local log_panel = require("gitflow.panels.log")
local stash_panel = require("gitflow.panels.stash")

local M = {}

M.panels = { status_panel, branch_panel, diff_panel, log_panel, stash_panel }

---@param message string|nil
local function run_stash_push(message)
	git_stash.push({ message = message }, function(err, result)
		if err then
			shared.show_error(err)
			return
		end

		local output = shared.result_message(result, "Created stash entry")
		if git_stash.output_mentions_no_local_changes(output) then
			utils.notify(output, vim.log.levels.WARN)
		else
			shared.show_info(output)
		end

		if stash_panel.is_open() then
			stash_panel.refresh()
		end
		shared.refresh_status_panel_if_open()
		shared.emit_post_operation()
	end)
end

local function prompt_and_run_stash_push()
	ui.input.prompt({
		multiline = true,
		title = "Stash message (optional)",
		draft_key = "stash:push:message",
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
			shared.show_error(err)
			return
		end

		local staged_count = git_status.count_staged(grouped)
		if staged_count == 0 then
			utils.notify("No staged changes to commit", vim.log.levels.WARN)
			return
		end

		local prompt_text = amend and "Amend commit message: " or "Commit message: "
		ui.input.prompt({
			multiline = true,
			title = prompt_text:gsub(":%s*$", ""),
			draft_key = amend and "commit:amend:message" or "commit:create:message",
		}, function(message)
			local trimmed = vim.trim(message)
			if trimmed == "" then
				utils.notify("Commit message cannot be empty", vim.log.levels.WARN)
				return
			end

			local confirmed = ui.input.confirm(
				("Commit %d staged file(s)?"):format(staged_count),
				{ choices = { "&Yes", "&No" }, default_choice = 1 }
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
					shared.show_error(shared.result_message(commit_result, "git commit failed"))
					return
				end

				shared.show_info(shared.result_message(commit_result, "Commit created"))
				shared.refresh_status_panel_if_open()
				shared.emit_post_operation()
			end)
		end)
	end)
end

---Parse an optional stash index argument.
---@param value string|nil
---@return integer|nil index  nil when no index was given (means the latest entry)
---@return string|nil err
local function parse_stash_index(value)
	local raw = shared.trimmed_or_nil(value)
	if raw == nil then
		return nil, nil
	end
	local index = tonumber(raw)
	if index == nil or index < 0 or index % 1 ~= 0 then
		return nil,
			("Invalid stash index: %s (expected a non-negative whole number)"):format(raw)
	end
	return index, nil
end

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config

	ctx.register("status", {
		description = "Open git status panel",
		run = function()
			status_panel.open(cfg, {
				on_commit = function()
					open_commit_prompt(false)
				end,
				on_open_diff = function(request)
					-- Route status diffs through the PR-review-style viewer.
					if request and request.commit then
						diffview_panel.open_commit(cfg, request.commit)
					else
						diffview_panel.open_working(cfg, {
							staged = request and request.staged,
							path = request and request.path,
						})
					end
				end,
			})
			return "Git status panel opened"
		end,
	})

	ctx.register("branch", {
		description = "Open branch list panel",
		run = function()
			branch_panel.open(cfg)
			return "Branch panel opened"
		end,
	})

	ctx.register("commit", {
		description = "Create commit from staged changes (supports --amend)",
		run = function(cmd)
			local amend = shared.has_flag(cmd.args, "--amend")
			open_commit_prompt(amend)
			if amend then
				return "Commit prompt opened (amend)"
			end
			return "Commit prompt opened"
		end,
	})

	ctx.register("diff", {
		description = "Open diff buffer (supports --staged [path])",
		run = function(cmd)
			diff_panel.open(cfg, {
				staged = shared.has_flag(cmd.args, "--staged"),
				path = shared.first_positional(cmd.args),
			})
			return "Diff view opened"
		end,
	})

	ctx.register("log", {
		description = "Open commit log panel",
		run = function()
			-- <CR> reviews a commit (and V marks a range) in the review viewer.
			log_panel.open(cfg, {
				on_open_commit = function(sha)
					diffview_panel.open_commit(cfg, sha)
				end,
			})
			return "Log view opened"
		end,
	})

	ctx.register("stash", {
		description = "Stash operations: list|push|pop|drop",
		run = function(cmd)
			local action = cmd.args[2] or "list"
			if action == "list" then
				stash_panel.open(cfg)
				return "Stash view opened"
			end

			if action == "push" then
				local has_message_arg = cmd.args[3] ~= nil
				if has_message_arg then
					local message = table.concat(cmd.args, " ", 3)
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
				local index, index_error = parse_stash_index(cmd.args[3])
				if index_error then
					return index_error
				end
				git_stash.pop({ index = index }, function(err, result)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(shared.result_message(result, "Applied stash entry"))
					if stash_panel.is_open() then
						stash_panel.refresh()
					end
					shared.refresh_status_panel_if_open()
					shared.emit_post_operation()
				end)
				return "Running git stash pop..."
			end
			if action == "apply" then
				local index, index_error = parse_stash_index(cmd.args[3])
				if index_error then
					return index_error
				end
				git_stash.apply({ index = index }, function(err, result)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(shared.result_message(result, "Applied stash entry (kept)"))
					shared.refresh_status_panel_if_open()
					shared.emit_post_operation()
				end)
				return "Running git stash apply..."
			end

			if action == "drop" then
				local index = tonumber(cmd.args[3])
				if not index then
					return "Usage: :Gitflow stash drop <index>"
				end
				git_stash.drop(index, {}, function(err, result)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(shared.result_message(result, "Dropped stash entry"))
					if stash_panel.is_open() then
						stash_panel.refresh()
					end
					shared.emit_post_operation()
				end)
				return "Running git stash drop..."
			end

			return ("Unknown stash action: %s"):format(action)
		end,
	})
end

return M
