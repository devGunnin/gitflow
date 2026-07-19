local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local ui_render = require("gitflow.ui.render")
local form = require("gitflow.ui.form")
local gh_issues = require("gitflow.gh.issues")
local gh_labels = require("gitflow.gh.labels")
local label_completion = require("gitflow.completion.labels")
local assignee_completion = require("gitflow.completion.assignees")
local label_picker = require("gitflow.ui.label_picker")
local list_picker = require("gitflow.ui.list_picker")
local derive = require("gitflow.issues.derive")
local views_store = require("gitflow.issues.views")
local icons = require("gitflow.icons")
local highlights = require("gitflow.highlights")

---@class GitflowIssuePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field fetch table  server-side query for the cached fetch
---@field cache table[]|nil  raw issues from the last fetch
---@field filters table  client-side predicate applied to the cache
---@field sort table  { key, direction }, kept across refreshes in a session
---@field group_by "none"|"milestone"|"assignee"|"label"
---@field collapsed table<string, boolean>  collapsed group ids
---@field line_groups table<integer, string>  header line -> group key
---@field line_entries table<integer, table>
---@field mode "list"|"view"
---@field active_issue_number integer|nil

local M = {}
local ISSUES_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_issues_hl")
local ISSUES_FLOAT_TITLE = "  Gitflow Issues  "
local ISSUES_FLOAT_FOOTER =
	" <CR> view · c create · C comment · x close · L labels"
	.. " · A assign · f filter · X clear · s sort · S sort dir"
	.. " · G group · <Tab> fold group · v/V/D views"
	.. " · r refresh · b back · q close "

--- Fetch broadly once so filter changes never need another `gh` round-trip.
local DEFAULT_FETCH_LIMIT = 300

---@type GitflowIssuePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	fetch = { state = "all", limit = DEFAULT_FETCH_LIMIT },
	cache = nil,
	filters = {},
	sort = { key = "updated", direction = "desc" },
	group_by = "none",
	collapsed = {},
	line_entries = {},
	line_groups = {},
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

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "issues",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = ISSUES_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and ISSUES_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "issues",
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

	vim.keymap.set("n", "x", function()
		M.close_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "L", function()
		M.edit_labels_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "A", function()
		M.edit_assignees_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "f", function()
		M.open_filter_menu()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "X", function()
		M.clear_filters()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "s", function()
		M.cycle_sort()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "S", function()
		M.toggle_sort_direction()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "G", function()
		M.cycle_group_by()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "<Tab>", function()
		M.toggle_group_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "v", function()
		M.switch_view()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "V", function()
		M.save_view()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "D", function()
		M.delete_view()
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
			M.rerender()
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

---@param state string
---@return string
local function issue_highlight_group(state)
	if state == "open" then
		return "GitflowIssueOpen"
	end
	return "GitflowIssueClosed"
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

---@param issue table
---@return string
local function join_assignee_names(issue)
	local assignees = issue.assignees or {}
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

---@param issue table
---@return string  the milestone title, or "-" when the issue has none
local function milestone_text(issue)
	local title = derive.milestone_title(issue)
	if title == "" then
		return "-"
	end
	return title
end

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

---Build colored chip chunks for an issue's labels.
---@param issue table
---@return table[]
local function label_chunks(issue)
	local labels = issue.labels or {}
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

---Push a section header line with a thin underline.
---@param B GitflowRenderBuilder
---@param icon string
---@param title string
---@return integer  the header line number
local function section_header(B, icon, title)
	local line_no = B:push({
		{ " ", nil },
		{ icon .. "  ", "GitflowSectionIcon" },
		{ title, "GitflowSectionTitle" },
	})
	B:raw(
		" " .. string.rep("-", math.max(8, vim.fn.strdisplaywidth(title) + 4)),
		"GitflowSeparator"
	)
	return line_no
end

---@param B GitflowRenderBuilder
---@param render_opts table
local function push_header(B, title, render_opts)
	for _, line in ipairs(ui_render.panel_header(title, render_opts)) do
		B:raw(line, ui_render.is_separator(line) and "GitflowSeparator" or "GitflowTitle")
	end
end

local function render_loading(message)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	push_header(B, "Gitflow Issues", render_opts)
	B:blank()
	B:push({
		{ "  ", nil },
		{ icons.get("ui", "clock") .. "  ", "GitflowSectionIcon" },
		{ message, "GitflowMeta" },
	})
	ui.buffer.update("issues", B.lines)
	M.state.line_entries = {}
	M.state.line_groups = {}
	B:apply(M.state.bufnr, ISSUES_HIGHLIGHT_NS)
end

---Summary bar: the rendered count plus every active filter.
---@param count integer
---@return table[]
local function summary_chunks(count)
	local chunks = {
		{ "  ", nil },
		{ icons.get("github", "issue_open") .. "  ", "GitflowSectionIcon" },
		{
			("%d issue%s"):format(count, count == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ "     state ", "GitflowMetaKey" },
		{ maybe_text(M.state.filters.state), "GitflowMeta" },
	}
	for _, key in ipairs({ "label", "assignee", "milestone" }) do
		local value = M.state.filters[key]
		if value and vim.trim(tostring(value)) ~= "" then
			chunks[#chunks + 1] = { ("   %s "):format(key), "GitflowMetaKey" }
			chunks[#chunks + 1] = { maybe_text(value), "GitflowMeta" }
		end
	end
	chunks[#chunks + 1] = { "   sort ", "GitflowMetaKey" }
	chunks[#chunks + 1] = {
		("%s %s"):format(M.state.sort.key, M.state.sort.direction),
		"GitflowMeta",
	}
	if M.state.group_by ~= "none" then
		chunks[#chunks + 1] = { "   group ", "GitflowMetaKey" }
		chunks[#chunks + 1] = { M.state.group_by, "GitflowMeta" }
	end
	return chunks
end

---Render one issue card and register its lines as selectable.
---@param B GitflowRenderBuilder
---@param issue table
---@param width integer
---@param line_entries table<integer, table>
local function push_issue_card(B, issue, width, line_entries)
	local number = tostring(issue.number or "?")
	local state = issue_state(issue)
	local state_icon = icons.get("github", "issue_" .. state)
	local title = maybe_text(issue.title)
	local time = ui_render.relative_time(issue.updatedAt)
	local left = (" %s  #%s  "):format(state_icon, number)
	local left_w = vim.fn.strdisplaywidth(left)
	local time_w = vim.fn.strdisplaywidth(time)
	local title_max = math.max(8, width - left_w - time_w - 2)
	title = ui_render.truncate(title, title_max)
	local gap = math.max(
		2, width - left_w - vim.fn.strdisplaywidth(title) - time_w
	)
	local title_group = state == "closed"
		and "GitflowCardTitleDim" or "GitflowCardTitle"
	local title_line = B:push({
		{ " ", nil },
		{ state_icon .. "  ", issue_highlight_group(state) },
		{ "#" .. number, "GitflowNumber" },
		{ "  ", nil },
		{ title, title_group },
		{ string.rep(" ", gap), nil },
		{ time, "GitflowRelTime" },
	})

	local meta = {
		{ "     ", nil },
		{ icons.get("ui", "author") .. " ", "GitflowMeta" },
		{
			issue.author and maybe_text(issue.author.login) or "\u{2014}",
			"GitflowAuthor",
		},
		{ "    labels: ", "GitflowMetaKey" },
	}
	for _, chunk in ipairs(label_chunks(issue)) do
		meta[#meta + 1] = chunk
	end
	local assignees = join_assignee_names(issue)
	if assignees ~= "-" then
		meta[#meta + 1] = { "    " .. icons.get("ui", "author") .. " ", "GitflowMeta" }
		meta[#meta + 1] = { assignees, "GitflowChip" }
	end
	meta[#meta + 1] = { "    milestone: ", "GitflowMetaKey" }
	meta[#meta + 1] = { milestone_text(issue), "GitflowChip" }
	local meta_line = B:push(meta)

	line_entries[title_line] = issue
	line_entries[meta_line] = issue
	B:blank()
end

---Stable identity for a group's collapsed state, scoped to the grouping mode
---so switching modes never inherits another mode's collapsed keys.
---@param key string
---@return string
local function collapse_id(key)
	return ("%s:%s"):format(M.state.group_by, key)
end

---@param key string
---@return string  the section heading for a group
local function group_heading(key)
	if key == "" then
		return derive.empty_group_label(M.state.group_by)
	end
	return key
end

---@param groups table[]
---@param total integer
local function render_list(groups, total)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	push_header(B, "Gitflow Issues", render_opts)

	B:push(summary_chunks(total))
	B:blank()

	local line_entries = {}
	local line_groups = {}
	local width = ui_render.content_width(render_opts)
	local grouped = M.state.group_by ~= "none"

	if total == 0 then
		B:push({
			{ "   ", nil },
			{ "No issues match these filters.", "GitflowMeta" },
		})
	end

	for _, group in ipairs(groups) do
		local collapsed = grouped and M.state.collapsed[collapse_id(group.key)] or false
		if grouped then
			local heading = ("%s (%d)"):format(group_heading(group.key), #group.issues)
			local icon = collapsed and icons.get("ui", "chevron")
				or icons.get("ui", "dot")
			line_groups[section_header(B, icon, heading)] = group.key
		end
		if not collapsed then
			for _, issue in ipairs(group.issues) do
				push_issue_card(B, issue, width, line_entries)
			end
		end
		if grouped then
			B:blank()
		end
	end

	ui.buffer.update("issues", B.lines)
	M.state.line_entries = line_entries
	M.state.line_groups = line_groups
	M.state.mode = "list"
	M.state.active_issue_number = nil

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, ISSUES_HIGHLIGHT_NS)

	-- Place the cursor on the first card.
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

---@param B GitflowRenderBuilder
---@param key string
---@param value_chunks table[]
local function meta_row(B, key, value_chunks)
	local chunks = {
		{ "  ", nil },
		{ ui_render.pad_right(key, 11), "GitflowMetaKey" },
	}
	for _, chunk in ipairs(value_chunks) do
		chunks[#chunks + 1] = chunk
	end
	return B:push(chunks)
end

---@param issue table
local function render_view(issue)
	local view_state = issue_state(issue)
	local view_icon = icons.get("github", "issue_" .. view_state)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	push_header(
		B,
		("Issue #%s: %s"):format(
			maybe_text(issue.number), maybe_text(issue.title)
		),
		render_opts
	)
	B:blank()

	meta_row(B, "Title:", { { maybe_text(issue.title), "GitflowCardTitle" } })
	meta_row(B, "State:", {
		{ view_icon .. " " .. view_state, issue_highlight_group(view_state) },
	})
	meta_row(B, "Author:", {
		{ issue.author and maybe_text(issue.author.login) or "\u{2014}", "GitflowAuthor" },
	})
	meta_row(B, "Labels:", label_chunks(issue))
	meta_row(B, "Assignees:", {
		{ join_assignee_names(issue), "GitflowChip" },
	})
	meta_row(B, "Milestone:", {
		{ milestone_text(issue), "GitflowChip" },
	})
	B:blank()

	section_header(B, icons.get("ui", "comment"), "Body")
	local body_lines = split_lines(tostring(issue.body or ""))
	if #body_lines == 0 then
		B:raw("   (no description)", "GitflowMeta")
	else
		for _, body_line in ipairs(body_lines) do
			B:raw("   " .. body_line)
		end
	end
	B:blank()

	local comments = issue.comments or {}
	local count = type(comments) == "table" and #comments or 0
	section_header(B, icons.get("ui", "comment"), ("Comments (%d)"):format(count))
	if count == 0 then
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

	ui.buffer.update("issues", B.lines)
	M.state.line_entries = {}
	M.state.line_groups = {}
	M.state.mode = "view"
	M.state.active_issue_number = tonumber(issue.number)

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
	B:apply(bufnr, ISSUES_HIGHLIGHT_NS)
end

---@return table|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---Run the full derivation — filter, sort, group — and render it.
local function render_derived()
	local issues = derive.apply(M.state.cache or {}, M.state.filters, M.state.sort)
	render_list(derive.group(issues, M.state.group_by), #issues)
end

---Split requested options into the server-side query and the client-side
---predicate: only what the client cannot evaluate is sent to `gh`.
---@param options table
local function set_query(options)
	M.state.fetch = {
		state = "all",
		limit = tonumber(options.limit) or DEFAULT_FETCH_LIMIT,
		search = options.search,
		assignee = derive.is_server_selector(options.assignee)
			and options.assignee or nil,
	}
	M.state.filters = {
		state = options.state or "open",
		label = options.label,
		assignee = options.assignee,
		milestone = options.milestone,
	}
end

---@param cfg GitflowConfig
---@param filters table|nil
function M.open(cfg, filters)
	M.state.cfg = cfg
	set_query(filters or {})
	M.state.cache = nil

	ensure_window(cfg)
	M.refresh()
end

---Re-render from the cache. Filter, sort, and grouping changes go through
---here so they cost no `gh` call.
function M.rerender()
	if not M.state.cache then
		M.refresh()
		return
	end
	render_derived()
end

---Refetch from GitHub and re-render.
function M.refresh()
	if not M.state.cfg then
		return
	end

	render_loading("Loading issues...")
	gh_issues.list(M.state.fetch, {}, function(err, issues)
		if err then
			render_loading("Failed to load issues")
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		M.state.cache = issues or {}
		render_derived()
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

---@param value string|nil
---@return string[]
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

-- ── Filters (#386) ────────────────────────────────────────────────────

local FILTER_STATES = { "open", "closed", "all" }
--- Offered by every single-value filter picker to clear that filter.
local ANY_VALUE = "(any)"

---Return the panel to the foreground after a picker closes.
local function focus_panel()
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_set_current_win(M.state.winid)
	end
end

---@param key "label"|"assignee"|"milestone"|"state"
---@param value string|nil  nil or "" clears the filter
local function set_filter(key, value)
	local trimmed = value and vim.trim(tostring(value)) or ""
	M.state.filters[key] = trimmed ~= "" and trimmed or nil
	M.rerender()
	focus_panel()
end

---Distinct label objects across the cache, keeping gh's colors for the picker.
---@return table[]
local function cached_labels()
	local seen, labels = {}, {}
	for _, issue in ipairs(M.state.cache or {}) do
		for _, label in ipairs(issue.labels or {}) do
			local name = type(label) == "table" and vim.trim(tostring(label.name or ""))
			if name and name ~= "" and not seen[name] then
				seen[name] = true
				labels[#labels + 1] = { name = name, color = label.color }
			end
		end
	end
	table.sort(labels, function(a, b)
		return a.name < b.name
	end)
	return labels
end

---@param field "assignee"|"milestone"
---@return table[]  list_picker items, "(any)" first so the filter can be cleared
local function value_items(field)
	local items = { { name = ANY_VALUE, description = "no filter" } }
	for _, value in ipairs(derive.distinct_values(M.state.cache or {}, field)) do
		items[#items + 1] = { name = value }
	end
	return items
end

---@param field "assignee"|"milestone"
local function pick_value(field)
	list_picker.open({
		title = ("Filter by %s"):format(field),
		items = value_items(field),
		selected = M.state.filters[field] and { M.state.filters[field] } or {},
		multi_select = false,
		on_submit = function(selected)
			local value = selected[1]
			set_filter(field, value ~= ANY_VALUE and value or nil)
		end,
		on_cancel = focus_panel,
	})
end

local function pick_labels()
	local labels = cached_labels()
	if #labels == 0 then
		utils.notify("No labels on the fetched issues", vim.log.levels.WARN)
		return
	end
	label_picker.open({
		title = "Filter by labels",
		labels = labels,
		selected = parse_csv_input(M.state.filters.label),
		on_submit = function(selected)
			set_filter("label", table.concat(selected, ","))
		end,
		on_cancel = focus_panel,
	})
end

---Advance the state filter through open -> closed -> all.
function M.cycle_state()
	set_filter("state", derive.cycle(FILTER_STATES, M.state.filters.state))
end

function M.clear_filters()
	M.state.filters = { state = "open" }
	M.rerender()
	utils.notify("Cleared issue filters", vim.log.levels.INFO)
end

-- ── Sorting (#387) ────────────────────────────────────────────────────

---Advance the sort key through updated -> number -> title -> milestone.
function M.cycle_sort()
	M.state.sort.key = derive.cycle(derive.SORT_KEYS, M.state.sort.key)
	M.rerender()
	utils.notify(
		("Sorting issues by %s (%s)"):format(M.state.sort.key, M.state.sort.direction),
		vim.log.levels.INFO
	)
end

function M.toggle_sort_direction()
	M.state.sort.direction =
		M.state.sort.direction == "asc" and "desc" or "asc"
	M.rerender()
end

-- ── Grouping (#390) ───────────────────────────────────────────────────

---Advance the grouping through none -> milestone -> assignee -> label.
function M.cycle_group_by()
	M.state.group_by = derive.cycle(derive.GROUP_KEYS, M.state.group_by)
	M.rerender()
	utils.notify(
		M.state.group_by == "none" and "Issue grouping off"
			or ("Grouping issues by %s"):format(M.state.group_by),
		vim.log.levels.INFO
	)
end

---Collapse or expand the group whose header the cursor is on.
function M.toggle_group_under_cursor()
	if M.state.group_by == "none" then
		utils.notify("Issues are not grouped", vim.log.levels.WARN)
		return
	end
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	local key = M.state.line_groups[line]
	if key == nil then
		utils.notify("Move the cursor onto a group header", vim.log.levels.WARN)
		return
	end

	local id = collapse_id(key)
	M.state.collapsed[id] = not M.state.collapsed[id] or nil
	M.rerender()
end

-- ── Saved views (#389) ────────────────────────────────────────────────

---@return GitflowIssueView[]|nil  nil when the saved-views file is unusable
local function load_views()
	local saved, err = views_store.load()
	if not saved then
		utils.notify(err, vim.log.levels.ERROR)
		return nil
	end
	return saved
end

---@param view GitflowIssueView
---@return string  one-line summary of what the view selects
local function describe_view(view)
	local parts = { view.filters.state or "open" }
	for _, key in ipairs({ "label", "assignee", "milestone" }) do
		if view.filters[key] then
			parts[#parts + 1] = ("%s %s"):format(key, view.filters[key])
		end
	end
	parts[#parts + 1] = ("sort %s %s"):format(view.sort.key, view.sort.direction)
	return table.concat(parts, " · ")
end

---@param saved GitflowIssueView[]
---@return table[]
local function view_items(saved)
	local items = {}
	for _, view in ipairs(saved) do
		items[#items + 1] = { name = view.name, description = describe_view(view) }
	end
	return items
end

---@param view GitflowIssueView
function M.apply_view(view)
	assert(type(view) == "table", "apply_view: view must be a table")
	M.state.filters = vim.deepcopy(view.filters)
	M.state.sort = vim.deepcopy(view.sort)
	M.rerender()
	focus_panel()
	utils.notify(("Issue view '%s'"):format(view.name), vim.log.levels.INFO)
end

---Persist the current filters and sort under a name the user picks.
function M.save_view()
	local saved = load_views()
	if not saved then
		return
	end

	input.prompt({ prompt = "Save issue view as: " }, function(value)
		local name = vim.trim(value or "")
		if name == "" then
			utils.notify("View name cannot be empty", vim.log.levels.WARN)
			return
		end

		local view = {
			name = name,
			filters = vim.deepcopy(M.state.filters),
			sort = vim.deepcopy(M.state.sort),
		}
		local ok, err = views_store.save(views_store.upsert(saved, view))
		if not ok then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Saved issue view '%s'"):format(name), vim.log.levels.INFO)
	end)
end

function M.switch_view()
	local saved = load_views()
	if not saved then
		return
	end
	if #saved == 0 then
		utils.notify("No saved issue views yet", vim.log.levels.WARN)
		return
	end

	list_picker.open({
		title = "Saved Issue Views",
		items = view_items(saved),
		multi_select = false,
		on_submit = function(selected)
			local view = views_store.find(saved, selected[1])
			if not view then
				focus_panel()
				return
			end
			M.apply_view(view)
		end,
		on_cancel = focus_panel,
	})
end

function M.delete_view()
	local saved = load_views()
	if not saved then
		return
	end
	if #saved == 0 then
		utils.notify("No saved issue views yet", vim.log.levels.WARN)
		return
	end

	list_picker.open({
		title = "Delete Saved View",
		items = view_items(saved),
		multi_select = false,
		on_submit = function(selected)
			local remaining, removed = views_store.remove(saved, selected[1])
			if not removed then
				focus_panel()
				return
			end
			local ok, err = views_store.save(remaining)
			focus_panel()
			if not ok then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Deleted issue view '%s'"):format(selected[1]),
				vim.log.levels.INFO
			)
		end,
		on_cancel = focus_panel,
	})
end

---@return table[]  filter-menu entries with their current value as description
local function filter_menu_items()
	local function current(key)
		local value = M.state.filters[key]
		if not value or vim.trim(tostring(value)) == "" then
			return "any"
		end
		return tostring(value)
	end
	return {
		{ name = "State", description = current("state") .. "  (cycles)" },
		{ name = "Labels", description = current("label") },
		{ name = "Assignee", description = current("assignee") },
		{ name = "Milestone", description = current("milestone") },
		{ name = "Clear all filters", description = "" },
	}
end

function M.open_filter_menu()
	if not M.state.cache then
		utils.notify("Issues are still loading", vim.log.levels.WARN)
		return
	end

	local actions = {
		State = M.cycle_state,
		Labels = pick_labels,
		Assignee = function() pick_value("assignee") end,
		Milestone = function() pick_value("milestone") end,
		["Clear all filters"] = M.clear_filters,
	}

	list_picker.open({
		title = "Issue Filters",
		items = filter_menu_items(),
		multi_select = false,
		on_submit = function(selected)
			local action = actions[selected[1]]
			if not action then
				focus_panel()
				return
			end
			-- Sub-pickers must open after this one has finished closing.
			vim.schedule(action)
		end,
		on_cancel = focus_panel,
	})
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

	local function open_form(available_labels, assignee_items)
		local label_names = {}
		for _, label in ipairs(available_labels) do
			if type(label) == "table" and label.name then
				label_names[#label_names + 1] = label.name
			end
		end
		local assignee_names = {}
		for _, item in ipairs(assignee_items) do
			if type(item) == "table" and item.name then
				assignee_names[#assignee_names + 1] = item.name
			end
		end

		form.open({
			title = "Create Issue",
			draft_key = "issue:create",
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
					placeholder = "Describe the issue… (Markdown supported)",
				},
				{
					name = "Labels",
					key = "labels",
					complete = names_completer(label_names),
					picker = function(ctx)
						label_picker.open({
							title = "Issue Labels",
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
				{
					name = "Assignees",
					key = "assignees",
					complete = names_completer(assignee_names),
					picker = function(ctx)
						list_picker.open({
							title = "Select Assignees",
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
			},
			on_submit = function(values)
				gh_issues.create({
					title = values.title,
					body = values.body,
					labels = parse_csv_input(values.labels),
					assignees = parse_csv_input(values.assignees),
				}, {}, function(err, response)
					if err then
						utils.notify(err, vim.log.levels.ERROR)
						return
					end
					local message = response and response.url
						and ("Created issue: %s"):format(response.url)
						or "Issue created"
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

	local loaded = { labels = nil, assignees = nil }
	local pending = 2

	local function try_open()
		pending = pending - 1
		if pending > 0 then
			return
		end
		vim.schedule(function()
			open_form(loaded.labels or {}, loaded.assignees or {})
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
local function comment_on_issue(number)
	input.prompt({
		multiline = true,
		title = ("Comment on issue #%s"):format(tostring(number)),
		draft_key = ("issue:%s:comment"):format(tostring(number)),
	}, function(body)
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
		choices = { "&Yes", "&No" },
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

		gh_issues.edit(number, {
			add_assignees = add_assignees,
			remove_assignees = remove_assignees,
		}, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Updated assignees for issue #%s"):format(tostring(number)),
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
	M.state.line_groups = {}
	M.state.mode = "list"
	M.state.active_issue_number = nil
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
