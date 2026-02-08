local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local gh_issues = require("gitflow.gh.issues")

---@class GitflowIssuePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filters table
---@field line_entries table<integer, table>
---@field mode "list"|"view"
---@field active_issue_number integer|nil

local M = {}

---@type GitflowIssuePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	filters = {},
	line_entries = {},
	mode = "list",
	active_issue_number = nil,
}

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("issues", {
			filetype = "markdown",
			lines = { "Loading issues..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = ui.window.open_split({
		name = "issues",
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

	vim.keymap.set("n", "x", function()
		M.close_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "l", function()
		M.edit_labels_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		if M.state.mode == "view" and M.state.active_issue_number then
			M.open_view(M.state.active_issue_number)
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

---@param issue table
---@return string
local function issue_state(issue)
	local state = maybe_text(issue.state):lower()
	if state == "open" then
		return "open"
	end
	if state == "closed" then
		return "closed"
	end
	return state
end

---@param issue table
---@return string
local function join_label_names(issue)
	local labels = issue.labels or {}
	if type(labels) ~= "table" or #labels == 0 then
		return "-"
	end

	local names = {}
	for _, label in ipairs(labels) do
		if type(label) == "table" and label.name then
			names[#names + 1] = label.name
		elseif type(label) == "string" then
			names[#names + 1] = label
		end
	end
	if #names == 0 then
		return "-"
	end
	return table.concat(names, ", ")
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
	ui.buffer.update("issues", {
		"Gitflow Issues",
		"",
		message,
	})
	M.state.line_entries = {}
end

---@param issues table[]
local function render_list(issues)
	local lines = {
		"Gitflow Issues",
		"",
		("Filters: state=%s label=%s assignee=%s"):
			format(maybe_text(M.state.filters.state), maybe_text(M.state.filters.label), maybe_text(M.state.filters.assignee)),
		("Issues (%d)"):format(#issues),
	}
	local line_entries = {}

	if #issues == 0 then
		lines[#lines + 1] = "  (none)"
	else
		for _, issue in ipairs(issues) do
			local number = tostring(issue.number or "?")
			local state = issue_state(issue)
			local title = maybe_text(issue.title)
			local labels = join_label_names(issue)
			lines[#lines + 1] = ("  #%s [%s] %s"):format(number, state, title)
			lines[#lines + 1] = ("      labels: %s"):format(labels)
			line_entries[#lines - 1] = issue
			line_entries[#lines] = issue
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "<CR>: view  c: create  C: comment  x: close  l: labels  r: refresh  q: quit"

	ui.buffer.update("issues", lines)
	M.state.line_entries = line_entries
	M.state.mode = "list"
	M.state.active_issue_number = nil
end

---@param issue table
local function render_view(issue)
	local lines = {
		("Issue #%s: %s"):format(maybe_text(issue.number), maybe_text(issue.title)),
		("State: %s"):format(issue_state(issue)),
		("Author: %s"):format(issue.author and maybe_text(issue.author.login) or "-"),
		("Labels: %s"):format(join_label_names(issue)),
		"",
		"Body",
		"----",
	}

	local body_lines = split_lines(tostring(issue.body or ""))
	if #body_lines == 0 then
		lines[#lines + 1] = "(empty)"
	else
		for _, body_line in ipairs(body_lines) do
			lines[#lines + 1] = body_line
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "Comments"
	lines[#lines + 1] = "--------"

	local comments = issue.comments or {}
	if type(comments) ~= "table" or #comments == 0 then
		lines[#lines + 1] = "(none)"
	else
		for _, comment in ipairs(comments) do
			local author = comment.author and maybe_text(comment.author.login) or "unknown"
			lines[#lines + 1] = ("%s:"):format(author)
			local comment_lines = split_lines(tostring(comment.body or ""))
			if #comment_lines == 0 then
				lines[#lines + 1] = "  (empty)"
			else
				for _, comment_line in ipairs(comment_lines) do
					lines[#lines + 1] = ("  %s"):format(comment_line)
				end
			end
			lines[#lines + 1] = ""
		end
	end

	lines[#lines + 1] = "b: back to list  C: comment  x: close  l: labels  r: refresh"

	ui.buffer.update("issues", lines)
	M.state.line_entries = {}
	M.state.mode = "view"
	M.state.active_issue_number = tonumber(issue.number)
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
		label = nil,
		assignee = nil,
		limit = 100,
	}, filters or {})

	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	if not M.state.cfg then
		return
	end

	render_loading("Loading issues...")
	gh_issues.list(M.state.filters, {}, function(err, issues)
		if err then
			render_loading("Failed to load issues")
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_list(issues or {})
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

	render_loading(("Loading issue #%s..."):format(tostring(number)))
	gh_issues.view(number, {}, function(err, issue)
		if err then
			render_loading("Failed to load issue")
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_view(issue or {})
	end)
end

function M.view_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No issue selected", vim.log.levels.WARN)
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

	input.prompt({ prompt = "Issue title: " }, function(title)
		local normalized_title = vim.trim(title or "")
		if normalized_title == "" then
			utils.notify("Issue title cannot be empty", vim.log.levels.WARN)
			return
		end

		input.prompt({ prompt = "Issue body: " }, function(body)
			input.prompt({ prompt = "Labels (comma-separated): " }, function(labels_raw)
				input.prompt({ prompt = "Assignees (comma-separated): " }, function(assignees_raw)
					gh_issues.create({
						title = normalized_title,
						body = body,
						labels = parse_csv_input(labels_raw),
						assignees = parse_csv_input(assignees_raw),
					}, {}, function(err, response)
						if err then
							utils.notify(err, vim.log.levels.ERROR)
							return
						end
						local message = response and response.url and ("Created issue: %s"):format(response.url)
							or "Issue created"
						utils.notify(message, vim.log.levels.INFO)
						M.refresh()
					end)
				end)
			end)
		end)
	end)
end

---@param number integer|string
local function comment_on_issue(number)
	input.prompt({ prompt = ("Issue #%s comment: "):format(tostring(number)) }, function(body)
		local normalized = vim.trim(body or "")
		if normalized == "" then
			utils.notify("Comment cannot be empty", vim.log.levels.WARN)
			return
		end

		gh_issues.comment(number, normalized, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(("Comment posted to issue #%s"):format(tostring(number)), vim.log.levels.INFO)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

function M.comment_under_cursor()
	local number = M.state.active_issue_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No issue selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No issue selected", vim.log.levels.WARN)
		return
	end
	comment_on_issue(number)
end

---@param number integer|string
local function close_issue(number)
	gh_issues.close(number, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Closed issue #%s"):format(tostring(number)), vim.log.levels.INFO)
		if M.state.mode == "view" then
			M.open_view(number)
		else
			M.refresh()
		end
	end)
end

function M.close_under_cursor()
	local number = M.state.active_issue_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No issue selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No issue selected", vim.log.levels.WARN)
		return
	end

	local confirmed = input.confirm(("Close issue #%s?"):format(tostring(number)), {
		choices = { "&Close", "&Cancel" },
		default_choice = 2,
	})
	if not confirmed then
		return
	end

	close_issue(number)
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

function M.edit_labels_under_cursor()
	local number = M.state.active_issue_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No issue selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No issue selected", vim.log.levels.WARN)
		return
	end

	input.prompt({ prompt = "Labels (+bug,-wip,docs): " }, function(value)
		local add_labels, remove_labels = parse_label_patch(value)
		if #add_labels == 0 and #remove_labels == 0 then
			utils.notify("No label edits provided", vim.log.levels.WARN)
			return
		end

		gh_issues.edit(number, {
			add_labels = add_labels,
			remove_labels = remove_labels,
		}, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(("Updated labels for issue #%s"):format(tostring(number)), vim.log.levels.INFO)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("issues")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("issues")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.mode = "list"
	M.state.active_issue_number = nil
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
