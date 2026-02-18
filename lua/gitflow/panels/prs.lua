local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local ui_render = require("gitflow.ui.render")
local form = require("gitflow.ui.form")
local gh_prs = require("gitflow.gh.prs")
local gh_labels = require("gitflow.gh.labels")
local label_completion = require("gitflow.completion.labels")
local assignee_completion = require("gitflow.completion.assignees")
local label_picker = require("gitflow.ui.label_picker")
local list_picker = require("gitflow.ui.list_picker")
local review_panel = require("gitflow.panels.review")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local highlights = require("gitflow.highlights")
local config = require("gitflow.config")

---@class GitflowPrPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filters table
---@field line_entries table<integer, table>
---@field mode "list"|"view"
---@field active_pr_number integer|nil
---@field view_request_id integer

local M = {}
local PRS_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_prs_hl")
local PRS_FLOAT_TITLE = "Gitflow Pull Requests"
local PRS_FLOAT_FOOTER_HINTS = {
	{ action = "view", default = "<CR>", label = "view" },
	{ action = "create", default = "c", label = "create" },
	{ action = "comment", default = "C", label = "comment" },
	{ action = "labels", default = "L", label = "labels" },
	{ action = "assign", default = "A", label = "assign" },
	{ action = "merge", default = "m", label = "merge" },
	{ action = "checkout", default = "o", label = "checkout" },
	{ action = "review", default = "v", label = "review" },
	{ action = "refresh", default = "r", label = "refresh" },
	{ action = "back", default = "b", label = "back" },
	{ action = "close", default = "q", label = "close" },
}
local PRS_VIEW_HINTS = {
	{ action = "back", default = "b", label = "back" },
	{ action = "comment", default = "C", label = "comment" },
	{ action = "labels", default = "L", label = "labels" },
	{ action = "assign", default = "A", label = "assign" },
	{ action = "merge", default = "m", label = "merge" },
	{ action = "checkout", default = "o", label = "checkout" },
	{ action = "review", default = "v", label = "review" },
	{ action = "refresh", default = "r", label = "refresh" },
}

---@type GitflowPrPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	filters = {},
	line_entries = {},
	mode = "list",
	active_pr_number = nil,
	view_request_id = 0,
}

---@return integer
local function next_view_request_id()
	M.state.view_request_id = (M.state.view_request_id or 0) + 1
	return M.state.view_request_id
end

---@param request_id integer
---@return boolean
local function is_active_view_request(request_id)
	return M.state.view_request_id == request_id
end

---@param cfg GitflowConfig
---@return string
local function prs_float_footer(cfg)
	return ui_render.resolve_panel_key_hints(
		cfg, "prs", PRS_FLOAT_FOOTER_HINTS
	)
end

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
			footer = cfg.ui.float.footer and prs_float_footer(cfg) or nil,
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

	local pk = function(action, default)
		return config.resolve_panel_key(
			cfg, "prs", action, default
		)
	end

	vim.keymap.set("n", pk("view", "<CR>"), function()
		M.view_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", pk("create", "c"), function()
		M.create_interactive()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("comment", "C"), function()
		M.comment_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("labels", "L"), function()
		M.edit_labels_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("assign", "A"), function()
		M.edit_assignees_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("merge", "m"), function()
		M.merge_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("checkout", "o"), function()
		M.checkout_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("review", "v"), function()
		M.review_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("refresh", "r"), function()
		if M.state.mode == "view" and M.state.active_pr_number then
			M.open_view(M.state.active_pr_number)
			return
		end
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("back", "b"), function()
		if M.state.mode == "view" then
			M.state.mode = "list"
			M.refresh()
		end
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("close", "q"), function()
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

---@param review table
---@return string
local function review_author(review)
	local author = maybe_text(type(review.author) == "table" and review.author.login or review.author)
	if author ~= "-" then
		return author
	end
	author = maybe_text(type(review.user) == "table" and review.user.login or review.user)
	if author ~= "-" then
		return author
	end
	return "unknown"
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

---@param pr table
---@return string
local function join_label_names(pr)
	local labels = pr.labels or {}
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

local function render_loading(message)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Pull Requests", render_opts)
	lines[#lines + 1] = message
	ui.buffer.update("prs", lines)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(bufnr, PRS_HIGHLIGHT_NS, lines, {})
end

---@param prs table[]
local function render_list(prs)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Pull Requests", render_opts)
	lines[#lines + 1] = ("Filters: state=%s base=%s head=%s"):
		format(
			maybe_text(M.state.filters.state),
			maybe_text(M.state.filters.base),
			maybe_text(M.state.filters.head)
		)
	lines[#lines + 1] = ("PRs (%d)"):format(#prs)
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
			local labels = join_label_names(pr)
			local state_icon = icons.get("github", "pr_" .. state)
			lines[#lines + 1] = ("  #%s %s %s"):format(number, state_icon, title)
			lines[#lines + 1] = ("      refs: %s"):format(refs)
			lines[#lines + 1] = ("      labels: %s  assignees: %s"):format(labels, assignees)
			line_entries[#lines - 1] = pr
			line_entries[#lines] = pr
			line_entries[#lines - 2] = pr
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

	local entry_highlights = {}

	-- Mark section headers
	for line_no, line in ipairs(lines) do
		if vim.startswith(line, "Filters:")
			or vim.startswith(line, "PRs (")
		then
			entry_highlights[line_no] = "GitflowHeader"
		end
	end

	for line_no, pr in pairs(line_entries) do
		local group = pr_highlight_group(pr_state(pr))
		entry_highlights[line_no] = group
	end

	ui_render.apply_panel_highlights(bufnr, PRS_HIGHLIGHT_NS, lines, {
		entry_highlights = entry_highlights,
	})

	for line_no, pr in pairs(line_entries) do
		local line_text = lines[line_no] or ""
		if line_text:find("labels:", 1, true) then
			local pr_labels = pr.labels or {}
			for _, label in ipairs(pr_labels) do
				local label_name = type(label) == "table" and label.name
					or type(label) == "string" and label
				local label_color = type(label) == "table" and label.color
				if label_name and label_color then
					local group = highlights.label_color_group(label_color)
					local start_col = line_text:find(label_name, 1, true)
					if start_col then
						vim.api.nvim_buf_add_highlight(
							bufnr,
							PRS_HIGHLIGHT_NS,
							group,
							line_no - 1,
							start_col - 1,
							start_col - 1 + #label_name
						)
					end
				end
			end
		end
	end
end

---@param pr table
---@param review_comments table[]|nil
local function render_view(pr, review_comments)
	local view_state = pr_state(pr)
	local view_icon = icons.get("github", "pr_" .. view_state)
	local review_author_lines = {}
	local review_body_lines = {}
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		("PR #%s: %s"):format(maybe_text(pr.number), maybe_text(pr.title)),
		render_opts
	)
	local header_line_count = #lines
	lines[#lines + 1] = ("Title: %s"):format(maybe_text(pr.title))
	lines[#lines + 1] = ("State: %s %s"):format(view_icon, view_state)
	lines[#lines + 1] = ("Author: %s"):format(pr.author and maybe_text(pr.author.login) or "-")
	lines[#lines + 1] = ("Refs: %s -> %s"):
		format(maybe_text(pr.headRefName), maybe_text(pr.baseRefName))
	lines[#lines + 1] = ("Labels: %s"):format(join_label_names(pr))
	local labels_line_no = #lines
	lines[#lines + 1] = ("Assignees: %s"):format(join_assignee_names(pr))
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Body"
	lines[#lines + 1] = "----"

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
	lines[#lines + 1] = ("Changed files: %d"):format(type(pr.files) == "table" and #pr.files or 0)

	local reviews = pr.reviews or {}
	if type(reviews) == "table" and #reviews > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Reviews"
		lines[#lines + 1] = "-------"
		for _, review in ipairs(reviews) do
			local author = review_author(review)
			local state = maybe_text(review.state)
			local submitted_at = maybe_text(review.submittedAt)
			local header = ("@%s [%s]"):format(author, state)
			if submitted_at ~= "-" then
				header = ("%s (%s)"):format(header, submitted_at)
			end
			lines[#lines + 1] = ("%s:"):format(header)
			review_author_lines[#review_author_lines + 1] = #lines

			local review_message_lines = split_lines(tostring(review.body or ""))
			if #review_message_lines == 0 then
				lines[#lines + 1] = "  >> (empty)"
				review_body_lines[#review_body_lines + 1] = #lines
			else
				for _, review_body_line in ipairs(review_message_lines) do
					lines[#lines + 1] = ("  >> %s"):format(review_body_line)
					review_body_lines[#review_body_lines + 1] = #lines
				end
			end
			lines[#lines + 1] = ""
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "Comments"
	lines[#lines + 1] = "--------"

	local comments = pr.comments or {}
	if type(comments) ~= "table" or #comments == 0 then
		lines[#lines + 1] = "(none)"
	else
		for _, comment in ipairs(comments) do
			local author = comment.author
				and maybe_text(comment.author.login) or "unknown"
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

	local rc = review_comments or {}
	if type(rc) == "table" and #rc > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Review Comments"
		lines[#lines + 1] = "---------------"

		for _, c in ipairs(rc) do
			local author = review_author(c)
			local path = maybe_text(c.path)
			lines[#lines + 1] = ("@%s on %s:"):format(author, path)
			review_author_lines[#review_author_lines + 1] = #lines
			local body_lines = split_lines(tostring(c.body or ""))
			if #body_lines == 0 then
				lines[#lines + 1] = "  >> (empty)"
				review_body_lines[#review_body_lines + 1] = #lines
			else
				for _, bl in ipairs(body_lines) do
					lines[#lines + 1] = ("  >> %s"):format(bl)
					review_body_lines[#review_body_lines + 1] = #lines
				end
			end
			lines[#lines + 1] = ""
		end
	end

	lines[#lines + 1] = ui_render.resolve_panel_key_hints(
		M.state.cfg, "prs", PRS_VIEW_HINTS
	)

	ui.buffer.update("prs", lines)
	M.state.line_entries = {}
	M.state.mode = "view"
	M.state.active_pr_number = tonumber(pr.number)

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local entry_highlights = {}
	entry_highlights[header_line_count + 2] = pr_highlight_group(pr_state(pr))

	-- Mark section headers in detail view
	for line_no, line in ipairs(lines) do
		if line == "Body" or line == "Comments"
			or line == "Reviews" or line == "Review Comments" then
			entry_highlights[line_no] = "GitflowHeader"
		end
	end
	for _, line_no in ipairs(review_author_lines) do
		entry_highlights[line_no] = "GitflowReviewAuthor"
	end
	for _, line_no in ipairs(review_body_lines) do
		entry_highlights[line_no] = "GitflowReviewComment"
	end

	ui_render.apply_panel_highlights(bufnr, PRS_HIGHLIGHT_NS, lines, {
		entry_highlights = entry_highlights,
	})

	-- Colored labels in detail view
	local labels_line = lines[labels_line_no] or ""
	if labels_line:find("Labels:", 1, true) then
		local pr_labels = pr.labels or {}
		for _, label in ipairs(pr_labels) do
			local lname = type(label) == "table" and label.name
				or type(label) == "string" and label
			local lcolor = type(label) == "table" and label.color
			if lname and lcolor then
				local group = highlights.label_color_group(lcolor)
				local s = labels_line:find(lname, 1, true)
				if s then
					vim.api.nvim_buf_add_highlight(
						bufnr, PRS_HIGHLIGHT_NS, group,
						labels_line_no - 1, s - 1, s - 1 + #lname
					)
				end
			end
		end
	end
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

	next_view_request_id()
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

	local request_id = next_view_request_id()
	render_loading(("Loading PR #%s..."):format(tostring(number)))
	gh_prs.view(number, {}, function(err, pr)
		if not is_active_view_request(request_id) then
			return
		end
		if err then
			render_loading("Failed to load pull request")
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		local current_pr = pr or {}
		render_view(current_pr)
		gh_prs.review_comments(number, {}, function(rc_err, rc)
			if not is_active_view_request(request_id) then
				return
			end
			if rc_err then
				return
			end
			render_view(current_pr, rc or {})
		end)
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

---@param entries GitflowBranchEntry[]|nil
---@return { name: string }[]
local function build_base_branch_items(entries)
	local items = {}
	local seen = {}

	local function add(name)
		local normalized = vim.trim(name or "")
		if normalized == "" or seen[normalized] then
			return
		end
		seen[normalized] = true
		items[#items + 1] = { name = normalized }
	end

	for _, entry in ipairs(entries or {}) do
		if not entry.is_remote then
			add(entry.name)
		end
	end

	-- Fallback for unusual repos with no local branches available.
	if #items == 0 then
		for _, entry in ipairs(entries or {}) do
			if entry.is_remote and entry.remote and entry.short_name ~= "HEAD" then
				add(entry.short_name)
			end
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

	local function open_form(available_labels, branch_items, assignee_items)
		form.open({
			title = "Create Pull Request",
			fields = {
				{ name = "Title", key = "title", required = true },
				{ name = "Body", key = "body", multiline = true },
				{
					name = "Base branch",
					key = "base",
					picker = function(ctx)
						list_picker.open({
							title = "Select Base Branch",
							items = branch_items,
							selected = ctx.value ~= ""
								and { ctx.value } or {},
							multi_select = false,
							on_submit = function(selected)
								if #selected > 0 then
									ctx.set_value(selected[1])
								end
							end,
						})
					end,
				},
				{
					name = "Reviewers (comma-separated)",
					key = "reviewers",
					picker = function(ctx)
						list_picker.open({
							title = "Select Reviewers",
							items = assignee_items,
							selected = parse_csv_input(ctx.value),
							multi_select = true,
							on_submit = function(selected)
								ctx.set_value(
									table.concat(selected, ",")
								)
							end,
						})
					end,
				},
				{
					name = "Labels",
					key = "labels",
					picker = function(ctx)
						label_picker.open({
							title = "PR Labels",
							labels = available_labels,
							selected = parse_csv_input(ctx.value),
							on_submit = function(selected_labels)
								ctx.set_value(
									table.concat(selected_labels, ",")
								)
							end,
						})
					end,
				},
			},
			on_submit = function(values)
				gh_prs.create({
					title = values.title,
					body = values.body,
					base = vim.trim(values.base or ""),
					reviewers = parse_csv_input(values.reviewers),
					labels = parse_csv_input(values.labels),
				}, {}, function(err, response)
					if err then
						utils.notify(err, vim.log.levels.ERROR)
						return
					end
					local message = response and response.url
						and ("Created PR: %s"):format(response.url)
						or "Pull request created"
					utils.notify(message, vim.log.levels.INFO)
					M.refresh()
					if M.state.winid
						and vim.api.nvim_win_is_valid(M.state.winid)
					then
						vim.api.nvim_set_current_win(M.state.winid)
					end
				end)
			end,
		})
	end

	local loaded = { labels = nil, branches = nil, assignees = nil }
	local pending = 3

	local function try_open()
		pending = pending - 1
		if pending > 0 then
			return
		end
		vim.schedule(function()
			open_form(
				loaded.labels or {},
				loaded.branches or {},
				loaded.assignees or {}
			)
		end)
	end

	gh_labels.list({}, function(err, labels)
		if err then
			utils.notify(
				("Failed to load labels: %s"):format(err),
				vim.log.levels.WARN
			)
		end
		loaded.labels = type(labels) == "table" and labels or {}
		try_open()
	end)

	git_branch.list({}, function(err, entries)
		if err then
			utils.notify(
				("Failed to load branches: %s"):format(err),
				vim.log.levels.WARN
			)
		end
		loaded.branches = build_base_branch_items(entries)
		try_open()
	end)

	local assignee_comp = require("gitflow.completion.assignees")
	vim.schedule(function()
		local names = assignee_comp.list_repo_assignee_candidates()
		local items = {}
		for _, name in ipairs(names) do
			items[#items + 1] = { name = name }
		end
		loaded.assignees = items
		try_open()
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
	next_view_request_id()
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
