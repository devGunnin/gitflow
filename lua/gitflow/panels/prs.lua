local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local gh_prs = require("gitflow.gh.prs")

---@class GitflowPrPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filters table
---@field line_entries table<integer, table>
---@field mode "list"|"view"
---@field active_pr_number integer|nil

local M = {}

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

	M.state.winid = ui.window.open_split({
		name = "prs",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})

	vim.keymap.set("n", "<CR>", function()
		M.view_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "c", function()
		M.create_interactive()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "C", function()
		M.comment_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "m", function()
		M.merge_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "o", function()
		M.checkout_under_cursor()
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

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

local function render_loading(message)
	ui.buffer.update("prs", {
		"Gitflow Pull Requests",
		"",
		message,
	})
	M.state.line_entries = {}
end

---@param prs table[]
local function render_list(prs)
	local lines = {
		"Gitflow Pull Requests",
		"",
		("Filters: state=%s base=%s head=%s"):
			format(maybe_text(M.state.filters.state), maybe_text(M.state.filters.base), maybe_text(M.state.filters.head)),
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
			local refs = ("%s -> %s"):format(maybe_text(pr.headRefName), maybe_text(pr.baseRefName))
			lines[#lines + 1] = ("  #%s [%s] %s"):format(number, state, title)
			lines[#lines + 1] = ("      refs: %s"):format(refs)
			line_entries[#lines - 1] = pr
			line_entries[#lines] = pr
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "<CR>: view  c: create  C: comment  m: merge  o: checkout  r: refresh  q: quit"

	ui.buffer.update("prs", lines)
	M.state.line_entries = line_entries
	M.state.mode = "list"
	M.state.active_pr_number = nil
end

---@param pr table
local function render_view(pr)
	local lines = {
		("PR #%s: %s"):format(maybe_text(pr.number), maybe_text(pr.title)),
		("State: %s"):format(pr_state(pr)),
		("Author: %s"):format(pr.author and maybe_text(pr.author.login) or "-"),
		("Refs: %s -> %s"):format(maybe_text(pr.headRefName), maybe_text(pr.baseRefName)),
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
	lines[#lines + 1] = ("Review requests: %d"):format(type(pr.reviewRequests) == "table" and #pr.reviewRequests or 0)
	lines[#lines + 1] = ("Reviews: %d"):format(type(pr.reviews) == "table" and #pr.reviews or 0)
	lines[#lines + 1] = ("Comments: %d"):format(type(pr.comments) == "table" and #pr.comments or 0)
	lines[#lines + 1] = ("Changed files: %d"):format(type(pr.files) == "table" and #pr.files or 0)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "b: back to list  C: comment  m: merge  o: checkout  r: refresh"

	ui.buffer.update("prs", lines)
	M.state.line_entries = {}
	M.state.mode = "view"
	M.state.active_pr_number = tonumber(pr.number)
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
