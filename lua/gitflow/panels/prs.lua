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
local PRS_FLOAT_TITLE = "  Gitflow Pull Requests  "
local PRS_FLOAT_FOOTER =
	" <CR> view · c create · m merge · o checkout · v review"
	.. " · L labels · x close PR · r refresh · q close "

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

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_set_option_value(
			"cursorline", true, { win = M.state.winid }
		)
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

	vim.keymap.set("n", "x", function()
		M.close_pr_under_cursor()
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

---@param pr table
---@return table[]
local function label_chunks(pr)
	local labels = pr.labels or {}
	if type(labels) ~= "table" or #labels == 0 then
		return { { "\u{2014}", "GitflowMeta" } }
	end
	local chunks = {}
	for _, label in ipairs(labels) do
		local name = type(label) == "table" and label.name
			or (type(label) == "string" and label or nil)
		if name then
			if #chunks > 0 then
				chunks[#chunks + 1] = { " ", "GitflowMeta" }
			end
			local color = type(label) == "table" and label.color
			local group = color and highlights.label_color_group(color)
				or "GitflowChip"
			chunks[#chunks + 1] = { name, group }
		end
	end
	if #chunks == 0 then
		return { { "\u{2014}", "GitflowMeta" } }
	end
	return chunks
end

---@param B GitflowRenderBuilder
---@param icon string
---@param title string
local function section_header(B, icon, title)
	B:push({
		{ " ", nil },
		{ icon .. "  ", "GitflowSectionIcon" },
		{ title, "GitflowSectionTitle" },
	})
	B:raw(
		" " .. string.rep("-", math.max(8, vim.fn.strdisplaywidth(title) + 4)),
		"GitflowSeparator"
	)
end

---@param B GitflowRenderBuilder
---@param title string
---@param render_opts table
local function push_header(B, title, render_opts)
	for _, line in ipairs(ui_render.panel_header(title, render_opts)) do
		B:raw(line, ui_render.is_separator(line) and "GitflowSeparator" or "GitflowTitle")
	end
end

---@param B GitflowRenderBuilder
---@param key string
---@param value_chunks table[]
local function meta_row(B, key, value_chunks)
	local chunks = {
		{ "  ", nil },
		{ ui_render.pad_right(key, 12), "GitflowMetaKey" },
	}
	for _, chunk in ipairs(value_chunks) do
		chunks[#chunks + 1] = chunk
	end
	return B:push(chunks)
end

---@param pr table
---@return string
local function pr_state_icon(state)
	return icons.get("github", "pr_" .. state)
end

local function render_loading(message)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	push_header(B, "Gitflow Pull Requests", render_opts)
	B:blank()
	B:push({
		{ "  ", nil },
		{ icons.get("ui", "clock") .. "  ", "GitflowSectionIcon" },
		{ message, "GitflowMeta" },
	})
	ui.buffer.update("prs", B.lines)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, PRS_HIGHLIGHT_NS)
end

---@param prs table[]
local function render_list(prs)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	push_header(B, "Gitflow Pull Requests", render_opts)

	local summary = {
		{ "  ", nil },
		{ icons.get("github", "pr_open") .. "  ", "GitflowSectionIcon" },
		{ ("PRs (%d)"):format(#prs), "GitflowSectionTitle" },
		{ "     state ", "GitflowMetaKey" },
		{ maybe_text(M.state.filters.state), "GitflowMeta" },
	}
	if M.state.filters.base then
		summary[#summary + 1] = { "   base ", "GitflowMetaKey" }
		summary[#summary + 1] = { maybe_text(M.state.filters.base), "GitflowMeta" }
	end
	B:push(summary)
	B:blank()

	local line_entries = {}
	if #prs == 0 then
		B:push({
			{ "   ", nil },
			{ "No pull requests match these filters.", "GitflowMeta" },
		})
	else
		local width = ui_render.content_width(render_opts)
		for _, pr in ipairs(prs) do
			local number = tostring(pr.number or "?")
			local state = pr_state(pr)
			local state_icon = pr_state_icon(state)
			local title = maybe_text(pr.title)
			local time = ui_render.relative_time(pr.updatedAt)
			local left = (" %s  #%s  "):format(state_icon, number)
			local left_w = vim.fn.strdisplaywidth(left)
			local time_w = vim.fn.strdisplaywidth(time)
			local title_max = math.max(8, width - left_w - time_w - 2)
			title = ui_render.truncate(title, title_max)
			local gap = math.max(
				2, width - left_w - vim.fn.strdisplaywidth(title) - time_w
			)
			local title_group = (state == "merged" or state == "closed")
				and "GitflowCardTitleDim" or "GitflowCardTitle"
			local title_line = B:push({
				{ " ", nil },
				{ state_icon .. "  ", pr_highlight_group(state) },
				{ "#" .. number, "GitflowNumber" },
				{ "  ", nil },
				{ title, title_group },
				{ string.rep(" ", gap), nil },
				{ time, "GitflowRelTime" },
			})

			local meta = {
				{ "     ", nil },
				{ icons.get("ui", "ref") .. " ", "GitflowMeta" },
				{ maybe_text(pr.headRefName), "GitflowChip" },
				{ " \u{2192} ", "GitflowMeta" },
				{ maybe_text(pr.baseRefName), "GitflowChip" },
				{ "    " .. icons.get("ui", "author") .. " ", "GitflowMeta" },
				{ pr.author and maybe_text(pr.author.login) or "\u{2014}", "GitflowAuthor" },
				{ "    labels: ", "GitflowMetaKey" },
			}
			for _, chunk in ipairs(label_chunks(pr)) do
				meta[#meta + 1] = chunk
			end
			local meta_line = B:push(meta)

			line_entries[title_line] = pr
			line_entries[meta_line] = pr
			B:blank()
		end
	end

	ui.buffer.update("prs", B.lines)
	M.state.line_entries = line_entries
	M.state.mode = "list"
	M.state.active_pr_number = nil

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, PRS_HIGHLIGHT_NS)

	local first_line = nil
	for line_no in pairs(line_entries) do
		if not first_line or line_no < first_line then
			first_line = line_no
		end
	end
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_set_option_value(
			"cursorline", true, { win = M.state.winid }
		)
		if first_line then
			pcall(vim.api.nvim_win_set_cursor, M.state.winid, { first_line, 0 })
		end
	end
end

---@param pr table
---@param review_comments table[]|nil
local function render_view(pr, review_comments)
	local view_state = pr_state(pr)
	local view_icon = pr_state_icon(view_state)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	push_header(
		B,
		("PR #%s: %s"):format(maybe_text(pr.number), maybe_text(pr.title)),
		render_opts
	)
	B:blank()

	meta_row(B, "Title:", { { maybe_text(pr.title), "GitflowCardTitle" } })
	meta_row(B, "State:", {
		{ view_icon .. " " .. view_state, pr_highlight_group(view_state) },
	})
	meta_row(B, "Author:", {
		{ pr.author and maybe_text(pr.author.login) or "\u{2014}", "GitflowAuthor" },
	})
	meta_row(B, "Refs:", {
		{ maybe_text(pr.headRefName), "GitflowChip" },
		{ " \u{2192} ", "GitflowMeta" },
		{ maybe_text(pr.baseRefName), "GitflowChip" },
	})
	meta_row(B, "Labels:", label_chunks(pr))
	meta_row(B, "Assignees:", { { join_assignee_names(pr), "GitflowChip" } })
	B:blank()

	local n_reviews = type(pr.reviews) == "table" and #pr.reviews or 0
	local n_files = type(pr.files) == "table" and #pr.files or 0
	local n_reqs = type(pr.reviewRequests) == "table" and #pr.reviewRequests or 0
	B:push({
		{ "  ", nil },
		{ icons.get("ui", "check") .. " ", "GitflowCount" },
		{ ("%d file%s changed"):format(n_files, n_files == 1 and "" or "s"), "GitflowMeta" },
		{ "   \u{b7}   ", "GitflowHintSep" },
		{ ("%d review%s"):format(n_reviews, n_reviews == 1 and "" or "s"), "GitflowMeta" },
		{ "   \u{b7}   ", "GitflowHintSep" },
		{ ("%d requested"):format(n_reqs), "GitflowMeta" },
	})
	B:blank()

	section_header(B, icons.get("ui", "comment"), "Body")
	local body_lines = split_lines(tostring(pr.body or ""))
	if #body_lines == 0 then
		B:raw("   (no description)", "GitflowMeta")
	else
		for _, body_line in ipairs(body_lines) do
			B:raw("   " .. body_line)
		end
	end
	B:blank()

	local reviews = pr.reviews or {}
	if type(reviews) == "table" and #reviews > 0 then
		section_header(B, icons.get("github", "review_approved"), "Reviews")
		for _, review in ipairs(reviews) do
			local author = review_author(review)
			local state = maybe_text(review.state)
			local submitted_at = maybe_text(review.submittedAt)
			local header = ("@%s [%s]"):format(author, state)
			if submitted_at ~= "-" then
				header = ("%s (%s)"):format(header, submitted_at)
			end
			B:raw(("%s:"):format(header), "GitflowReviewAuthor")
			local review_message_lines = split_lines(tostring(review.body or ""))
			if #review_message_lines == 0 then
				B:raw("  >> (empty)", "GitflowReviewComment")
			else
				for _, review_body_line in ipairs(review_message_lines) do
					B:raw(("  >> %s"):format(review_body_line), "GitflowReviewComment")
				end
			end
			B:blank()
		end
	end

	local comments = pr.comments or {}
	local comment_count = type(comments) == "table" and #comments or 0
	section_header(B, icons.get("ui", "comment"), ("Comments (%d)"):format(comment_count))
	if comment_count == 0 then
		B:raw("   (none)", "GitflowMeta")
	else
		for _, comment in ipairs(comments) do
			local author = comment.author
				and maybe_text(comment.author.login) or "unknown"
			B:push({
				{ "   ", nil },
				{ icons.get("ui", "author") .. " ", "GitflowMeta" },
				{ author .. ":", "GitflowAuthor" },
			})
			local comment_lines = split_lines(tostring(comment.body or ""))
			if #comment_lines == 0 then
				B:raw("     (empty)", "GitflowMeta")
			else
				for _, comment_line in ipairs(comment_lines) do
					B:raw("     " .. comment_line)
				end
			end
			B:blank()
		end
	end

	local rc = review_comments or {}
	if type(rc) == "table" and #rc > 0 then
		section_header(B, icons.get("ui", "comment"), "Review Comments")
		for _, c in ipairs(rc) do
			local author = review_author(c)
			local path = maybe_text(c.path)
			B:raw(("@%s on %s:"):format(author, path), "GitflowReviewAuthor")
			local cbody = split_lines(tostring(c.body or ""))
			if #cbody == 0 then
				B:raw("  >> (empty)", "GitflowReviewComment")
			else
				for _, bl in ipairs(cbody) do
					B:raw(("  >> %s"):format(bl), "GitflowReviewComment")
				end
			end
			B:blank()
		end
	end

	ui.buffer.update("prs", B.lines)
	M.state.line_entries = {}
	M.state.mode = "view"
	M.state.active_pr_number = tonumber(pr.number)

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_set_option_value(
			"cursorline", false, { win = M.state.winid }
		)
		pcall(vim.api.nvim_win_set_cursor, M.state.winid, { 1, 0 })
	end

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, PRS_HIGHLIGHT_NS)
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
		gh_prs.review_comments(number, {}, function(rc_err, rc)
			if not is_active_view_request(request_id) then
				return
			end
			render_view(pr or {}, not rc_err and rc or nil)
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

	local function names_completer(names)
		return function(lead)
			local query = vim.trim(tostring(lead or "")):lower()
			local out = {}
			for _, name in ipairs(names) do
				if query == "" or tostring(name):lower():find(query, 1, true) then
					out[#out + 1] = name
				end
			end
			return out
		end
	end

	local function open_form(available_labels, branch_items, assignee_items)
		local label_names = {}
		for _, label in ipairs(available_labels) do
			if type(label) == "table" and label.name then
				label_names[#label_names + 1] = label.name
			end
		end
		local branch_names = {}
		for _, item in ipairs(branch_items) do
			if type(item) == "table" and item.name then
				branch_names[#branch_names + 1] = item.name
			end
		end
		local reviewer_names = {}
		for _, item in ipairs(assignee_items) do
			if type(item) == "table" and item.name then
				reviewer_names[#reviewer_names + 1] = item.name
			end
		end

		form.open({
			title = "Create Pull Request",
			draft_key = "pr:create",
			fields = {
				{
					name = "Title",
					key = "title",
					required = true,
					placeholder = "Short, descriptive summary",
				},
				{
					name = "Body",
					key = "body",
					multiline = true,
					placeholder = "Describe the change… (Markdown supported)",
				},
				{
					name = "Base branch",
					key = "base",
					complete = names_completer(branch_names),
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
					complete = names_completer(reviewer_names),
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
					complete = names_completer(label_names),
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

---@param number integer|string
local function close_pr(number)
	gh_prs.close(number, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			("Closed PR #%s"):format(tostring(number)),
			vim.log.levels.INFO
		)
		if M.state.mode == "view" then
			M.open_view(number)
		else
			M.refresh()
		end
	end)
end

function M.close_pr_under_cursor()
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

	local confirmed = input.confirm(
		("Close PR #%s?"):format(tostring(number)),
		{ choices = { "&Yes", "&No" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	close_pr(number)
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
