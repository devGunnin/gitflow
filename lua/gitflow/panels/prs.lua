local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local gh_prs = require("gitflow.gh.prs")
local label_completion = require("gitflow.completion.labels")
local assignee_completion = require("gitflow.completion.assignees")
local review_panel = require("gitflow.panels.review")
local icons = require("gitflow.icons")

---@class GitflowPrPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filters table
---@field line_entries table<integer, table>
---@field mode "list"|"view"
---@field active_pr_number integer|nil

local M = {}
local PRS_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_prs_hl")
local PRS_FLOAT_TITLE = "Gitflow Pull Requests"
local PRS_FLOAT_FOOTER =
	"<CR> view  c create  C comment  L labels  A assign  m merge"
	.. "  o checkout  v review  r refresh  b back  q close"

---@type GitflowPrPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	filters = {},
	line_entries = {},
	mode = "list",
	active_pr_number = nil,
}

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("prs", {
			filetype = "markdown",
			lines = { "Loading pull requests..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "prs",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = PRS_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and PRS_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "prs",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.view_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "c", function()
		M.create_interactive()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "C", function()
		M.comment_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "L", function()
		M.edit_labels_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "A", function()
		M.edit_assignees_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "m", function()
		M.merge_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "o", function()
		M.checkout_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "v", function()
		M.review_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		if M.state.mode == "view" and M.state.active_pr_number then
			M.open_view(M.state.active_pr_number)
			return
		end
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "b", function()
		if M.state.mode == "view" then
			M.state.mode = "list"
			M.refresh()
		end
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param value string|nil
---@return string
local function maybe_text(value)
	local text = vim.trim(tostring(value or ""))
	if text == "" then
		return "-"
	end
	return text
end

---@param pr table
---@return string
local function pr_state(pr)
	if pr.mergedAt ~= nil and pr.mergedAt ~= vim.NIL and tostring(pr.mergedAt) ~= "" then
		return "merged"
	end
	if pr.isDraft then
		return "draft"
	end
	local state = maybe_text(pr.state):lower()
	if state == "open" then
		return "open"
	end
	if state == "closed" then
		return "closed"
	end
	return state
end

---@param state string
---@return string
local function pr_highlight_group(state)
	if state == "open" then
		return "GitflowPROpen"
	end
	if state == "merged" then
		return "GitflowPRMerged"
	end
	if state == "draft" then
		return "GitflowPRDraft"
	end
	return "GitflowPRClosed"
end

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

---@param pr table
---@return string
local function join_assignee_names(pr)
	local assignees = pr.assignees or {}
	if type(assignees) ~= "table" or #assignees == 0 then
		return "-"
	end

	local names = {}
	for _, assignee in ipairs(assignees) do
		if type(assignee) == "table" and assignee.login then
			names[#names + 1] = assignee.login
		elseif type(assignee) == "string" then
			names[#names + 1] = assignee
		end
	end
	if #names == 0 then
		return "-"
	end
	return table.concat(names, ", ")
end

local function render_loading(message)
	ui.buffer.update("prs", {
		"Gitflow Pull Requests",
		"",
		message,
	})
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, PRS_HIGHLIGHT_NS, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, PRS_HIGHLIGHT_NS, "GitflowTitle", 0, 0, -1)
end

---@param prs table[]
local function render_list(prs)
	local lines = {
		"Gitflow Pull Requests",
		"",
		("Filters: state=%s base=%s head=%s"):
			format(
				maybe_text(M.state.filters.state),
				maybe_text(M.state.filters.base),
				maybe_text(M.state.filters.head)
			),
		("PRs (%d)"):format(#prs),
	}
	local line_entries = {}

	if #prs == 0 then
		lines[#lines + 1] = "  (none)"
	else
		for _, pr in ipairs(prs) do
			local number = tostring(pr.number or "?")
			local state = pr_state(pr)
			local title = maybe_text(pr.title)
			local refs = ("%s -> %s"):format(
				maybe_text(pr.headRefName), maybe_text(pr.baseRefName)
			)
			local assignees = join_assignee_names(pr)
			local state_icon = icons.get("github", "pr_" .. state)
			lines[#lines + 1] = ("  #%s %s %s"):format(number, state_icon, title)
			lines[#lines + 1] = ("      refs: %s  assignees: %s"):format(
				refs, assignees
			)
			line_entries[#lines - 1] = pr
			line_entries[#lines] = pr
		end
	end

	ui.buffer.update("prs", lines)
	M.state.line_entries = line_entries
	M.state.mode = "list"
	M.state.active_pr_number = nil

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, PRS_HIGHLIGHT_NS, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, PRS_HIGHLIGHT_NS, "GitflowTitle", 0, 0, -1)

	for line_no, pr in pairs(line_entries) do
		local group = pr_highlight_group(pr_state(pr))
		vim.api.nvim_buf_add_highlight(bufnr, PRS_HIGHLIGHT_NS, group, line_no - 1, 0, -1)
	end
end

---@param pr table
local function render_view(pr)
	local view_state = pr_state(pr)
	local view_icon = icons.get("github", "pr_" .. view_state)
	local lines = {
		("PR #%s: %s"):format(maybe_text(pr.number), maybe_text(pr.title)),
		("State: %s %s"):format(view_icon, view_state),
		("Author: %s"):format(pr.author and maybe_text(pr.author.login) or "-"),
		("Refs: %s -> %s"):format(maybe_text(pr.headRefName), maybe_text(pr.baseRefName)),
		("Assignees: %s"):format(join_assignee_names(pr)),
		"",
		"Body",
		"----",
	}

	local body_lines = split_lines(tostring(pr.body or ""))
	if #body_lines == 0 then
		lines[#lines + 1] = "(empty)"
	else
		for _, body_line in ipairs(body_lines) do
			lines[#lines + 1] = body_line
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = ("Review requests: %d"):
		format(type(pr.reviewRequests) == "table" and #pr.reviewRequests or 0)
	lines[#lines + 1] = ("Reviews: %d"):format(type(pr.reviews) == "table" and #pr.reviews or 0)
	lines[#lines + 1] = ("Comments: %d"):format(type(pr.comments) == "table" and #pr.comments or 0)
	lines[#lines + 1] = ("Changed files: %d"):format(type(pr.files) == "table" and #pr.files or 0)
	ui.buffer.update("prs", lines)
	M.state.line_entries = {}
	M.state.mode = "view"
	M.state.active_pr_number = tonumber(pr.number)

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, PRS_HIGHLIGHT_NS, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, PRS_HIGHLIGHT_NS, "GitflowTitle", 0, 0, -1)
	vim.api.nvim_buf_add_highlight(
		bufnr,
		PRS_HIGHLIGHT_NS,
		pr_highlight_group(pr_state(pr)),
		1,
		0,
		-1
	)
end

---@return table|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param cfg GitflowConfig
---@param filters table|nil
function M.open(cfg, filters)
	M.state.cfg = cfg
	M.state.filters = vim.tbl_extend("force", {
		state = "open",
		base = nil,
		head = nil,
		limit = 100,
	}, filters or {})

	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	if not M.state.cfg then
		return
	end

	render_loading("Loading pull requests...")
	gh_prs.list(M.state.filters, {}, function(err, prs)
		if err then
			render_loading("Failed to load pull requests")
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_list(prs or {})
	end)
end

---@param number integer|string
---@param cfg GitflowConfig|nil
function M.open_view(number, cfg)
	if cfg then
		M.state.cfg = cfg
	end
	if not M.state.cfg then
		return
	end
	ensure_window(M.state.cfg)

	render_loading(("Loading PR #%s..."):format(tostring(number)))
	gh_prs.view(number, {}, function(err, pr)
		if err then
			render_loading("Failed to load pull request")
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_view(pr or {})
	end)
end

function M.view_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	M.open_view(entry.number)
end

local function parse_csv_input(value)
	local items = {}
	for _, part in ipairs(vim.split(value or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(part)
		if trimmed ~= "" then
			items[#items + 1] = trimmed
		end
	end
	return items
end

---@param value string
---@return string[], string[]
local function parse_label_patch(value)
	local add = {}
	local remove = {}
	for _, token in ipairs(vim.split(value or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if trimmed == "" then
			goto continue
		end
		if vim.startswith(trimmed, "+") then
			add[#add + 1] = vim.trim(trimmed:sub(2))
		elseif vim.startswith(trimmed, "-") then
			remove[#remove + 1] = vim.trim(trimmed:sub(2))
		else
			add[#add + 1] = trimmed
		end
		::continue::
	end
	return add, remove
end

function M.create_interactive()
	if not M.state.cfg then
		return
	end

	input.prompt({ prompt = "PR title: " }, function(title)
		local normalized_title = vim.trim(title or "")
		if normalized_title == "" then
			utils.notify("PR title cannot be empty", vim.log.levels.WARN)
			return
		end

		input.prompt({ prompt = "PR body: " }, function(body)
			input.prompt({ prompt = "Base branch (optional): " }, function(base)
				input.prompt({ prompt = "Reviewers (comma-separated): " }, function(reviewers_raw)
					input.prompt({ prompt = "Labels (comma-separated): " }, function(labels_raw)
						gh_prs.create({
							title = normalized_title,
							body = body,
							base = vim.trim(base or ""),
							reviewers = parse_csv_input(reviewers_raw),
							labels = parse_csv_input(labels_raw),
						}, {}, function(err, response)
							if err then
								utils.notify(err, vim.log.levels.ERROR)
								return
							end
							local message = response and response.url and ("Created PR: %s"):format(response.url)
								or "Pull request created"
							utils.notify(message, vim.log.levels.INFO)
							M.refresh()
						end)
					end)
				end)
			end)
		end)
	end)
end

---@param number integer|string
local function comment_on_pr(number)
	input.prompt({ prompt = ("PR #%s comment: "):format(tostring(number)) }, function(body)
		local normalized = vim.trim(body or "")
		if normalized == "" then
			utils.notify("Comment cannot be empty", vim.log.levels.WARN)
			return
		end

		gh_prs.comment(number, normalized, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(("Comment posted to PR #%s"):format(tostring(number)), vim.log.levels.INFO)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

function M.comment_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	comment_on_pr(number)
end

function M.edit_labels_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	input.prompt({
		prompt = "Labels (+bug,-wip,docs): ",
		completion = function(arglead, _, _)
			return label_completion.complete_issue_patch(arglead)
		end,
	}, function(value)
		local add_labels, remove_labels = parse_label_patch(value)
		if #add_labels == 0 and #remove_labels == 0 then
			utils.notify("No label edits provided", vim.log.levels.WARN)
			return
		end

		gh_prs.edit(number, {
			add_labels = add_labels,
			remove_labels = remove_labels,
		}, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(("Updated labels for PR #%s"):format(tostring(number)), vim.log.levels.INFO)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

---@param value string
---@return string[], string[]
local function parse_assignee_patch(value)
	local add = {}
	local remove = {}
	for _, token in ipairs(vim.split(value or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if trimmed == "" then
			goto continue
		end
		if vim.startswith(trimmed, "+") then
			add[#add + 1] = vim.trim(trimmed:sub(2))
		elseif vim.startswith(trimmed, "-") then
			remove[#remove + 1] = vim.trim(trimmed:sub(2))
		else
			add[#add + 1] = trimmed
		end
		::continue::
	end
	return add, remove
end

function M.edit_assignees_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	input.prompt({
		prompt = "Assignees (+user,-user,user): ",
		completion = function(arglead, _, _)
			return assignee_completion.complete_assignee_patch(arglead)
		end,
	}, function(value)
		local add_assignees, remove_assignees = parse_assignee_patch(value)
		if #add_assignees == 0 and #remove_assignees == 0 then
			utils.notify("No assignee edits provided", vim.log.levels.WARN)
			return
		end

		gh_prs.edit(number, {
			add_assignees = add_assignees,
			remove_assignees = remove_assignees,
		}, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Updated assignees for PR #%s"):format(tostring(number)),
				vim.log.levels.INFO
			)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

function M.merge_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	local choice = vim.fn.confirm(
		("Merge PR #%s with strategy:"):format(tostring(number)),
		"&Merge\n&Squash\n&Rebase\n&Cancel",
		1
	)
	if choice == 4 or choice == 0 then
		return
	end

	local strategy = "merge"
	if choice == 2 then
		strategy = "squash"
	elseif choice == 3 then
		strategy = "rebase"
	end

	gh_prs.merge(number, strategy, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Merged PR #%s (%s)"):format(tostring(number), strategy), vim.log.levels.INFO)
		if M.state.mode == "view" then
			M.open_view(number)
		else
			M.refresh()
		end
	end)
end

function M.checkout_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	gh_prs.checkout(number, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Checked out PR #%s"):format(tostring(number)), vim.log.levels.INFO)
	end)
end

function M.review_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	if not M.state.cfg then
		utils.notify("Gitflow config unavailable for review panel", vim.log.levels.ERROR)
		return
	end

	review_panel.open(M.state.cfg, number)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("prs")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("prs")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.mode = "list"
	M.state.active_pr_number = nil
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
