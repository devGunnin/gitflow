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
local icons = require("gitflow.icons")
local highlights = require("gitflow.highlights")

---@class GitflowIssuePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filters table
---@field line_entries table<integer, table>
---@field mode "list"|"view"
---@field active_issue_number integer|nil

local M = {}
local ISSUES_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_issues_hl")
local ISSUES_FLOAT_TITLE = "  Gitflow Issues  "
local ISSUES_FLOAT_FOOTER =
	" <CR> view · c create · C comment · x close · L labels"
	.. " · A assign · r refresh · b back · q close "

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
	B:apply(M.state.bufnr, ISSUES_HIGHLIGHT_NS)
end

---@param issues table[]
local function render_list(issues)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	push_header(B, "Gitflow Issues", render_opts)

	-- Summary / filter bar
	local summary = {
		{ "  ", nil },
		{ icons.get("github", "issue_open") .. "  ", "GitflowSectionIcon" },
		{
			("%d issue%s"):format(#issues, #issues == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ "     state ", "GitflowMetaKey" },
		{ maybe_text(M.state.filters.state), "GitflowMeta" },
	}
	if M.state.filters.label then
		summary[#summary + 1] = { "   label ", "GitflowMetaKey" }
		summary[#summary + 1] = { maybe_text(M.state.filters.label), "GitflowMeta" }
	end
	if M.state.filters.assignee then
		summary[#summary + 1] = { "   assignee ", "GitflowMetaKey" }
		summary[#summary + 1] = { maybe_text(M.state.filters.assignee), "GitflowMeta" }
	end
	B:push(summary)
	B:blank()

	local line_entries = {}
	if #issues == 0 then
		B:push({
			{ "   ", nil },
			{ "No issues match these filters.", "GitflowMeta" },
		})
	else
		local width = ui_render.content_width(render_opts)
		for _, issue in ipairs(issues) do
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
			local meta_line = B:push(meta)

			line_entries[title_line] = issue
			line_entries[meta_line] = issue
			B:blank()
		end
	end

	ui.buffer.update("issues", B.lines)
	M.state.line_entries = line_entries
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
	M.state.mode = "list"
	M.state.active_issue_number = nil
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
