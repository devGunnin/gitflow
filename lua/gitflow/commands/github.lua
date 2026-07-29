-- Area: GitHub — issues, pull requests, labels and PR review mode.
local ui = require("gitflow.ui")
local gh = require("gitflow.gh")
local gh_issues = require("gitflow.gh.issues")
local gh_prs = require("gitflow.gh.prs")
local gh_labels = require("gitflow.gh.labels")
local shared = require("gitflow.commands.shared")
local issue_panel = require("gitflow.panels.issues")
local pr_panel = require("gitflow.panels.prs")
local label_panel = require("gitflow.panels.labels")
local review_panel = require("gitflow.panels.review")
local label_completion = require("gitflow.completion.labels")
local assignee_completion = require("gitflow.completion.assignees")

local M = {}

M.panels = { issue_panel, pr_panel, label_panel, review_panel }

local ISSUE_ACTIONS = { "list", "view", "create", "comment", "close", "reopen", "edit" }
local PR_ACTIONS = {
	"list",
	"view",
	"review",
	"review-commits",
	"submit-review",
	"respond",
	"create",
	"comment",
	"merge",
	"checkout",
	"close",
	"edit",
}
local LABEL_ACTIONS = { "list", "create", "delete" }

-- Accepted `key=value` edit tokens per subcommand: { key, field, csv }.
local EDIT_TOKEN_SPECS = {
	issue = {
		{ "title", "title" },
		{ "body", "body" },
		{ "add", "add_labels", true },
		{ "remove", "remove_labels", true },
		{ "add_assignees", "add_assignees", true },
		{ "remove_assignees", "remove_assignees", true },
	},
	pr = {
		{ "add", "add_labels", true },
		{ "remove", "remove_labels", true },
		{ "add_assignees", "add_assignees", true },
		{ "remove_assignees", "remove_assignees", true },
		{ "reviewers", "reviewers", true },
	},
}

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

---Parse `key=value` edit tokens for `issue edit` / `pr edit`.
---A token whose key is unknown or whose value is empty is rejected outright, so
---a typo can never be silently dropped into a no-op edit reported as success.
---@param kind "issue"|"pr"
---@param args string[]
---@param start_index integer
---@param usage string
---@return table|nil options  nil when the request would edit nothing
---@return string|nil err
local function parse_edit_options(kind, args, start_index, usage)
	local spec = EDIT_TOKEN_SPECS[kind]
	if not spec then
		error(("gitflow command error: no edit spec for %s"):format(tostring(kind)), 2)
	end

	local options = {}
	local rejected = {}
	for i = start_index, #args do
		local token = args[i]
		local field, value
		for _, entry in ipairs(spec) do
			local raw = token:match("^" .. entry[1] .. "=(.+)$")
			if raw then
				field = entry[2]
				value = entry[3] and parse_csv(raw) or raw
				break
			end
		end
		-- an empty csv list carries no edit, so treat it like an unknown key
		if field and (type(value) ~= "table" or #value > 0) then
			options[field] = value
		else
			rejected[#rejected + 1] = token
		end
	end

	if #rejected > 0 then
		return nil,
			("Unrecognized or empty edit option(s): %s\n%s"):format(
				table.concat(rejected, " "),
				usage
			)
	end
	if next(options) == nil then
		return nil, "No edits requested — supply at least one option.\n" .. usage
	end
	return options, nil
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

-- ── completion ──────────────────────────────────────────────────────────

---@param subaction string|nil
---@param arglead string
---@return string[]
local function complete_issue(subaction, arglead)
	if subaction == "view" or subaction == "comment" or subaction == "close" or subaction == "reopen" then
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
		return shared.filter_candidates(arglead, candidates)
	end

	if subaction == "edit" then
		return shared.filter_candidates(arglead, {
			"title=",
			"body=",
			"add=",
			"remove=",
			"add_assignees=",
			"remove_assignees=",
		})
	end

	return {}
end

---@param subaction string|nil
---@param arglead string
---@return string[]
local function complete_pr(subaction, arglead)
	if
		subaction == "view"
		or subaction == "comment"
		or subaction == "checkout"
		or subaction == "close"
		or subaction == "respond"
	then
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
		return shared.filter_candidates(arglead, candidates)
	end

	if subaction == "merge" then
		return shared.filter_candidates(arglead, { "merge", "squash", "rebase" })
	end

	if subaction == "edit" then
		return shared.filter_candidates(arglead, {
			"add=",
			"remove=",
			"add_assignees=",
			"remove_assignees=",
			"reviewers=",
		})
	end

	if subaction == "review" or subaction == "submit-review" then
		return shared.filter_candidates(arglead, {
			"approve",
			"request_changes",
			"request-changes",
			"comment",
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
	return shared.filter_candidates(arglead, { "list", "create", "delete" })
end

---`<sub> edit` accepts `key=` tokens whose values complete from live GitHub data.
---@param args string[]
---@param arglead string
---@return string[]|nil  nil when arglead is not a live-completing edit token
local function complete_edit_token(args, arglead)
	if args[3] ~= "edit" then
		return nil
	end
	if vim.startswith(arglead, "add=") then
		return label_completion.complete_token(arglead, "add")
	end
	if vim.startswith(arglead, "remove=") then
		return label_completion.complete_token(arglead, "remove")
	end
	if vim.startswith(arglead, "add_assignees=") then
		return assignee_completion.complete_token(arglead, "add_assignees")
	end
	if vim.startswith(arglead, "remove_assignees=") then
		return assignee_completion.complete_token(arglead, "remove_assignees")
	end
	return nil
end

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config

	ctx.register("pr-review", {
		description = "Toggle PR review mode (tabpage with file list + inline diff)",
		category = "GitHub",
		run = function(cmd)
			local positional = shared.first_positional(cmd.args)
			if positional then
				review_panel.open(cfg, positional)
				return ("Opening PR review mode for #%s..."):format(positional)
			end
			review_panel.toggle(cfg)
			if review_panel.is_open() then
				return "Closing PR review mode"
			end
			return "Opening PR picker for review mode"
		end,
	})

	ctx.register("issue", {
		description = "GitHub issues: list|view|create|comment|close|reopen|edit",
		category = "GitHub",
		run = function(cmd)
			local ready, prerequisite_error = gh.ensure_prerequisites()
			if not ready then
				return prerequisite_error or "GitHub CLI prerequisites are not satisfied"
			end

			local action = cmd.args[2] or "list"
			if action == "list" then
				issue_panel.open(cfg, parse_issue_list_args(cmd.args, 3))
				return "Loading issues..."
			end

			if action == "view" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow issue view <number>"
				end
				issue_panel.open_view(number, cfg)
				return ("Loading issue #%s..."):format(number)
			end

			if action == "create" then
				issue_panel.open(cfg, parse_issue_list_args(cmd.args, 3))
				vim.schedule(function()
					issue_panel.create_interactive()
				end)
				return "Opening issue creation prompt..."
			end

			if action == "comment" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow issue comment <number>"
				end

				local message = table.concat(cmd.args, " ", 4)
				if vim.trim(message) ~= "" then
					gh_issues.comment(number, message, {}, function(err)
						if err then
							shared.show_error(err)
							return
						end
						shared.show_info(("Comment posted to issue #%s"):format(number))
						if issue_panel.is_open() then
							issue_panel.refresh()
						end
					end)
					return ("Commenting on issue #%s..."):format(number)
				end

				issue_panel.open(cfg, parse_issue_list_args(cmd.args, 3))
				vim.schedule(function()
					issue_panel.open_view(number, cfg)
					vim.schedule(function()
						issue_panel.comment_under_cursor()
					end)
				end)
				return ("Opening comment prompt for issue #%s..."):format(number)
			end

			if action == "close" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow issue close <number>"
				end
				gh_issues.close(number, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Closed issue #%s"):format(number))
					if issue_panel.is_open() then
						issue_panel.refresh()
					end
				end)
				return ("Closing issue #%s..."):format(number)
			end

			if action == "reopen" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow issue reopen <number>"
				end
				gh_issues.reopen(number, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Reopened issue #%s"):format(number))
					if issue_panel.is_open() then
						issue_panel.refresh()
					end
				end)
				return ("Reopening issue #%s..."):format(number)
			end

			if action == "edit" then
				local usage = "Usage: :Gitflow issue edit <number>"
					.. " [title=...] [body=...]"
					.. " [add=...] [remove=...]"
					.. " [add_assignees=...] [remove_assignees=...]"
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return usage
				end

				local edit_opts, edit_error =
					parse_edit_options("issue", cmd.args, 4, usage)
				if edit_error then
					return edit_error
				end

				gh_issues.edit(number, edit_opts, {}, function(err, _result)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Updated issue #%s"):format(number))
					if issue_panel.is_open() then
						issue_panel.refresh()
					end
				end)
				return ("Updating issue #%s..."):format(number)
			end

			return ("Unknown issue action: %s"):format(action)
		end,
		complete = function(arglead, cmdline, args)
			if shared.completing_action(cmdline, args) then
				return shared.filter_candidates(arglead, ISSUE_ACTIONS)
			end
			local live = complete_edit_token(args, arglead)
			if live then
				return live
			end
			return complete_issue(args[3], arglead)
		end,
	})

	ctx.register("pr", {
		description = "GitHub PRs: list|view|review|submit-review|respond|create|comment|"
			.. "merge|checkout|close|edit",
		category = "GitHub",
		run = function(cmd)
			local ready, prerequisite_error = gh.ensure_prerequisites()
			if not ready then
				return prerequisite_error or "GitHub CLI prerequisites are not satisfied"
			end

			local action = cmd.args[2] or "list"
			if action == "list" then
				pr_panel.open(cfg, parse_pr_list_args(cmd.args, 3))
				return "Loading pull requests..."
			end

			if action == "view" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr view <number>"
				end
				pr_panel.open_view(number, cfg)
				return ("Loading PR #%s..."):format(number)
			end

			if action == "review-commits" then
				-- Scope review mode to a single commit or range (#363).
				local number = shared.first_positional_from(cmd.args, 3)
				if review_panel.is_open() then
					review_panel.scope_to_commits()
					return "Choose commit(s) to scope the review..."
				end
				if not number then
					return "Usage: :Gitflow pr review-commits <number>"
				end
				review_panel.open(cfg, number)
				return ("Opening review for PR #%s — press C to scope to commits"):format(
					number)
			end

			if action == "review" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr review <number> [approve|request_changes|comment] [message]"
				end

				local mode = shared.trimmed_or_nil(cmd.args[4])
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

				local message = table.concat(cmd.args, " ", 5)
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
						shared.show_error(err)
						return
					end
					shared.show_info(("Submitted %s review for PR #%s"):format(mode, number))
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
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr submit-review"
						.. " <number>"
						.. " <approve|request_changes|comment>"
						.. " [message]"
				end

				local mode = shared.trimmed_or_nil(cmd.args[4])
				if mode == "request-changes" then
					mode = "request_changes"
				end
				if mode ~= "approve" and mode ~= "request_changes" and mode ~= "comment" then
					return "Usage: :Gitflow pr submit-review"
						.. " <number>"
						.. " <approve|request_changes|comment>"
						.. " [message]"
				end

				local message = table.concat(cmd.args, " ", 5)
				if vim.trim(message) == "" then
					message = ""
				end

				-- If review panel is open for this PR,
				-- use submit_review_direct to batch
				-- pending comments
				if review_panel.is_open() and tonumber(review_panel.state.pr_number) == tonumber(number) then
					review_panel.submit_review_direct(mode, message)
					return ("Submitting %s review for" .. " PR #%s..."):format(mode, number)
				end

				gh_prs.review(number, mode, message, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Submitted %s review" .. " for PR #%s"):format(mode, number))
					if pr_panel.is_open() then
						pr_panel.refresh()
					end
				end)
				return ("Submitting %s review for PR #%s..."):format(mode, number)
			end

			if action == "respond" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr respond <number>"
				end
				review_panel.respond_to_review(number)
				return ("Loading reviews for PR #%s..."):format(number)
			end

			if action == "create" then
				pr_panel.open(cfg, parse_pr_list_args(cmd.args, 3))
				vim.schedule(function()
					pr_panel.create_interactive()
				end)
				return "Opening PR creation prompt..."
			end

			if action == "comment" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr comment <number>"
				end

				local message = table.concat(cmd.args, " ", 4)
				if vim.trim(message) ~= "" then
					gh_prs.comment(number, message, {}, function(err)
						if err then
							shared.show_error(err)
							return
						end
						shared.show_info(("Comment posted to PR #%s"):format(number))
						if pr_panel.is_open() then
							pr_panel.refresh()
						end
					end)
					return ("Commenting on PR #%s..."):format(number)
				end

				pr_panel.open(cfg, parse_pr_list_args(cmd.args, 3))
				vim.schedule(function()
					pr_panel.open_view(number, cfg)
					vim.schedule(function()
						pr_panel.comment_under_cursor()
					end)
				end)
				return ("Opening comment prompt for PR #%s..."):format(number)
			end

			if action == "merge" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr merge <number> [merge|squash|rebase]"
				end

				local strategy = cmd.args[4] or "merge"
				if strategy ~= "merge" and strategy ~= "squash" and strategy ~= "rebase" then
					return "Usage: :Gitflow pr merge <number> [merge|squash|rebase]"
				end

				gh_prs.merge(number, strategy, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Merged PR #%s (%s)"):format(number, strategy))
					if pr_panel.is_open() then
						pr_panel.refresh()
					end
				end)
				return ("Merging PR #%s (%s)..."):format(number, strategy)
			end

			if action == "checkout" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr checkout <number>"
				end

				gh_prs.checkout(number, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Checked out PR #%s"):format(number))
				end)
				return ("Checking out PR #%s..."):format(number)
			end

			if action == "close" then
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return "Usage: :Gitflow pr close <number>"
				end

				gh_prs.close(number, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Closed PR #%s"):format(number))
					if pr_panel.is_open() then
						pr_panel.refresh()
					end
				end)
				return ("Closing PR #%s..."):format(number)
			end

			if action == "edit" then
				local usage = "Usage: :Gitflow pr edit <number>"
					.. " [add=...] [remove=...]"
					.. " [add_assignees=...] [remove_assignees=...]"
					.. " [reviewers=...]"
				local number = shared.first_positional_from(cmd.args, 3)
				if not number then
					return usage
				end

				local edit_opts, edit_error =
					parse_edit_options("pr", cmd.args, 4, usage)
				if edit_error then
					return edit_error
				end

				gh_prs.edit(number, edit_opts, {}, function(err, _result)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Updated PR #%s"):format(number))
					if pr_panel.is_open() then
						pr_panel.refresh()
					end
				end)
				return ("Updating PR #%s..."):format(number)
			end

			return ("Unknown pr action: %s"):format(action)
		end,
		complete = function(arglead, cmdline, args)
			if shared.completing_action(cmdline, args) then
				return shared.filter_candidates(arglead, PR_ACTIONS)
			end
			local live = complete_edit_token(args, arglead)
			if live then
				return live
			end
			return complete_pr(args[3], arglead)
		end,
	})

	ctx.register("label", {
		description = "GitHub labels: list|create|delete",
		category = "GitHub",
		run = function(cmd)
			local ready, prerequisite_error = gh.ensure_prerequisites()
			if not ready then
				return prerequisite_error or "GitHub CLI prerequisites are not satisfied"
			end

			local action = cmd.args[2] or "list"
			if action == "list" then
				label_panel.open(cfg)
				return "Loading labels..."
			end

			if action == "create" then
				local name = shared.trimmed_or_nil(cmd.args[3])
				local color = shared.trimmed_or_nil(cmd.args[4])
				if not name or not color then
					return "Usage: :Gitflow label create <name> <color> [description]"
				end
				local description = table.concat(cmd.args, " ", 5)
				if vim.trim(description) == "" then
					description = nil
				end

				gh_labels.create(name, color, description, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Created label '%s'"):format(name))
					if label_panel.is_open() then
						label_panel.refresh()
					end
				end)
				return ("Creating label '%s'..."):format(name)
			end

			if action == "delete" then
				local name = shared.trimmed_or_nil(cmd.args[3])
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
						shared.show_error(err)
						return
					end
					shared.show_info(("Deleted label '%s'"):format(name))
					if label_panel.is_open() then
						label_panel.refresh()
					end
				end)
				return ("Deleting label '%s'..."):format(name)
			end

			return ("Unknown label action: %s"):format(action)
		end,
		complete = function(arglead, cmdline, args)
			if shared.completing_action(cmdline, args) then
				return shared.filter_candidates(arglead, LABEL_ACTIONS)
			end
			return complete_label(args[3], arglead)
		end,
	})
end

return M
