--- Shared engine behind list_picker.lua and label_picker.lua: a floating,
--- single/multi-select list with live incremental fuzzy filtering (press `/`
--- to type, results narrow as you go; j/k to move, <Space> to toggle, <CR>
--- to apply). The two picker modules were ~90% identical; this module holds
--- the one implementation, and each wraps it with its own item shape,
--- default title/placeholder text and name highlight.
---
--- A caller never requires this module directly -- go through
--- gitflow.ui.list_picker or gitflow.ui.label_picker, whose `M.open` keeps
--- its own namespace pair (so a `nvim_create_namespace` by name from a test
--- or another caller resolves to the right picker's extmarks) and item shape.

local ui_window = require("gitflow.ui.window")
local render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")
local matcher = require("gitflow.ui.matcher")
local icons = require("gitflow.icons")

local M = {}

---@class GitflowPickerItem
---@field name string
---@field description? string
---@field color? string  used only by a spec whose name_highlight reads it

---@class GitflowPickerSpec
---@field namespace_hl integer  extmark namespace for the full-render spans
---@field namespace_active integer  extmark namespace for the active-line accent
---@field search_augroup string  augroup name for the live-search autocmd
---@field filetype string  buffer filetype
---@field placeholder string  prompt text shown when the query is empty
---@field empty_text string  row shown when a query matches nothing
---@field default_title string  window title when the caller gives none
---@field name_highlight fun(item: GitflowPickerItem): string  highlight group for a row's name chunk

---@class GitflowPickerOpenOpts
---@field items GitflowPickerItem[]  already normalized by the wrapping module
---@field selected? string[]
---@field title? string
---@field multi_select? boolean  default true
---@field on_submit fun(selected: string[])
---@field on_cancel? fun()

---@param items GitflowPickerItem[]
---@param query string|nil
---@return GitflowPickerItem[]
local function searchable_text(item)
	return ("%s %s"):format(item.name or "", item.description or "")
end

---@param items GitflowPickerItem[]
---@param query string|nil
---@return GitflowPickerItem[]
function M.filter_items(items, query)
	local filtered = {}
	local trimmed_query = vim.trim(tostring(query or ""))

	for index, item in ipairs(items or {}) do
		local sc = matcher.fuzzy_score(searchable_text(item), trimmed_query)
		if sc ~= nil then
			filtered[#filtered + 1] = {
				index = index,
				item = item,
				score = sc,
			}
		end
	end

	table.sort(filtered, function(left, right)
		if left.score ~= right.score then
			return left.score > right.score
		end
		if left.item.name ~= right.item.name then
			return left.item.name < right.item.name
		end
		return left.index < right.index
	end)

	local results = {}
	for _, entry in ipairs(filtered) do
		results[#results + 1] = entry.item
	end
	return results
end

---@param state table
local function collect_selected(state)
	local selected = {}
	for _, item in ipairs(state.items) do
		local name = vim.trim(tostring(item.name or ""))
		if name ~= "" and state.selected[name] then
			selected[#selected + 1] = name
		end
	end
	return selected
end

---@param state table
local function selected_count(state)
	local n = 0
	for _, item in ipairs(state.items) do
		if state.selected[vim.trim(tostring(item.name or ""))] then
			n = n + 1
		end
	end
	return n
end

---@param state table
---@param from_hook boolean|nil  true when ui.window's close hook got here first
local function close_picker(state, from_hook)
	if state.closed then
		return
	end
	state.closed = true

	pcall(vim.api.nvim_del_augroup_by_name, state.spec.search_augroup)
	-- From the hook the window is already going away and deleting a buffer
	-- inside WinClosed is unsafe; `bufhidden=wipe` collects it.
	if not from_hook then
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			pcall(vim.api.nvim_win_close, state.winid, true)
		end
		if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
			pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
		end
	end

	state.winid = nil
	state.bufnr = nil
end

---Build the prompt line (line 1) chunks.
---@param state table
---@return table[]
local function prompt_chunks(state)
	local edge = render.spacing.edge
	local chunks = {
		{ edge .. icons.get("ui", "search") .. edge, "GitflowPickerPromptIcon" },
	}
	if state.query ~= "" then
		chunks[#chunks + 1] = { state.query, "GitflowPickerPrompt" }
	else
		chunks[#chunks + 1] = { state.spec.placeholder, "GitflowFormPlaceholder" }
	end
	return chunks
end

---Build the count/separator line (line 2) chunks.
---@param state table
---@return table[]
local function count_chunks(state)
	local shown = #state.filtered
	local total = #state.items
	local label = state.multi_select
		and ("%d/%d  ·  %d selected"):format(shown, total, selected_count(state))
		or ("%d/%d"):format(shown, total)
	local width = render.content_width({ winid = state.winid, bufnr = state.bufnr })
	local left = render.glyphs.rule .. render.glyphs.rule .. render.spacing.edge
	local used = vim.fn.strdisplaywidth(left) + vim.fn.strdisplaywidth(label) + 1
	local tail = string.rep(render.glyphs.rule, math.max(0, width - used))
	return {
		{ left, "GitflowSeparator" },
		{ label, "GitflowPickerCount" },
		{ render.spacing.edge, "GitflowSeparator" },
		{ tail, "GitflowSeparator" },
	}
end

---Build the result-row chunks for a single item, and apply its fuzzy-match
---highlight on the name.
---@param B GitflowRenderBuilder
---@param state table
---@param item GitflowPickerItem
---@return integer line_no
local function push_item(B, state, item)
	local name = vim.trim(tostring(item.name or ""))
	local desc = vim.trim(tostring(item.description or ""))
	local edge, gutter = render.spacing.edge, render.spacing.gutter
	local chunks = { { edge, nil } }
	if state.multi_select then
		if state.selected[name] then
			chunks[#chunks + 1] = { "[x]", "GitflowPickerCheck" }
		else
			chunks[#chunks + 1] = { "[ ]", "GitflowPickerCheckOff" }
		end
		chunks[#chunks + 1] = { edge, nil }
	else
		chunks[#chunks + 1] = { state.selected[name] and "> " or gutter, "GitflowPickerCheck" }
	end
	chunks[#chunks + 1] = { name, state.spec.name_highlight(item) }
	if desc ~= "" then
		chunks[#chunks + 1] = { gutter .. desc, "GitflowMeta" }
	end
	local line_no = B:push(chunks)

	if state.query ~= "" then
		local line_text = B.lines[line_no]
		local name_start = line_text:find(name, 1, true)
		if name_start then
			for _, pos in ipairs(matcher.match_positions(name, state.query)) do
				B:hl(line_no, name_start - 1 + pos, name_start + pos, "GitflowPickerMatch")
			end
		end
	end
	return line_no
end

---@param state table
local function build_hint(state)
	if state.multi_select then
		return render.hint_chunks({
			{ "j/k", "move" }, { "<Spc>", "toggle" }, { "/", "filter" },
			{ "<CR>", "apply" }, { "q", "close" },
		}, { leading = render.spacing.edge })
	end
	return render.hint_chunks({
		{ "j/k", "move" }, { "<CR>", "select" }, { "/", "filter" },
		{ "q", "close" },
	}, { leading = render.spacing.edge })
end

---Paint the active-line accent. It lives in its own namespace so moving the
---selection is two extmark calls, not a full re-render of the picker.
---@param state table
local function apply_active_line(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, state.spec.namespace_active, 0, -1)
	if state.active_line then
		render.highlight(
			bufnr, state.spec.namespace_active, "GitflowFormActiveField",
			state.active_line - 1, 0, -1
		)
	end
end

---Full render: prompt + count rule + results + hint.
---@param state table
local function render_all(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	state.filtered = M.filter_items(state.items, state.query)

	local B = render.builder()
	B:push(prompt_chunks(state))
	B:push(count_chunks(state))

	local line_entries = {}
	if #state.filtered == 0 then
		components.empty(B, state.spec.empty_text)
	else
		for _, item in ipairs(state.filtered) do
			local line_no = push_item(B, state, item)
			line_entries[line_no] = item
		end
	end

	B:blank()
	B:push(build_hint(state))

	state.line_entries = line_entries

	local fallback_line = #state.filtered > 0 and 3 or nil
	if state.active_line == nil or line_entries[state.active_line] == nil then
		state.active_line = fallback_line
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, B.lines)
	if not state.searching then
		vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	end

	B:apply(bufnr, state.spec.namespace_hl)
	apply_active_line(state)

	if state.winid and vim.api.nvim_win_is_valid(state.winid) and state.active_line then
		pcall(vim.api.nvim_win_set_cursor, state.winid, { state.active_line, 0 })
	end
end

---Re-render results + count only (lines 2..end), preserving the live prompt
---line being edited in search mode.
---@param state table
local function render_results_only(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	state.filtered = M.filter_items(state.items, state.query)

	local B = render.builder()
	-- index 1 placeholder for the (untouched) prompt line so highlight line
	-- numbers line up; we won't write line 1 back.
	B:raw("")
	B:push(count_chunks(state))
	local line_entries = {}
	if #state.filtered == 0 then
		components.empty(B, state.spec.empty_text)
	else
		for _, item in ipairs(state.filtered) do
			local line_no = push_item(B, state, item)
			line_entries[line_no] = item
		end
	end
	B:blank()
	B:push(build_hint(state))

	state.line_entries = line_entries
	state.active_line = (#state.filtered > 0) and 3 or nil

	-- Replace from line 2 (index 1) to end; leave the prompt line intact.
	vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, vim.list_slice(B.lines, 2))

	-- Re-apply highlights for the rewritten region.
	vim.api.nvim_buf_clear_namespace(bufnr, state.spec.namespace_hl, 1, -1)
	for line_no, list in pairs(B.spans) do
		if line_no >= 2 then
			for _, span in ipairs(list) do
				render.highlight(
					bufnr, state.spec.namespace_hl,
					span[3], line_no - 1, span[1], span[2]
				)
			end
		end
	end

	apply_active_line(state)
end

---@param state table
---@param delta integer
local function move_selection(state, delta)
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local lines = {}
	for line_no, _ in pairs(state.line_entries) do
		lines[#lines + 1] = line_no
	end
	table.sort(lines)
	if #lines == 0 then
		return
	end

	local current = state.active_line or lines[1]
	local index = 1
	for i, line_no in ipairs(lines) do
		if line_no == current then
			index = i
			break
		end
	end

	local next_index = ((index - 1 + delta) % #lines) + 1
	state.active_line = lines[next_index]

	pcall(vim.api.nvim_win_set_cursor, state.winid, { state.active_line, 0 })
	apply_active_line(state)
end

---@param state table
local function toggle_current(state)
	local line_no = state.active_line
	if not line_no then
		return
	end

	local item = state.line_entries[line_no]
	if not item then
		return
	end

	local name = vim.trim(tostring(item.name or ""))
	if name == "" then
		return
	end

	if state.multi_select then
		state.selected[name] = not state.selected[name] or nil
		render_all(state)
	else
		state.selected = { [name] = true }
		local selections = collect_selected(state)
		close_picker(state)
		state.on_submit(selections)
	end
end

---Enter live search: focus the prompt line and filter as the user types.
---@param state table
local function start_search(state)
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end
	state.searching = true
	vim.api.nvim_set_option_value("modifiable", true, { buf = state.bufnr })

	local prompt = " " .. icons.get("ui", "search") .. " " .. state.query
	vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, { prompt })

	local group = vim.api.nvim_create_augroup(state.spec.search_augroup, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		group = group,
		buffer = state.bufnr,
		callback = function()
			if not state.searching then
				return
			end
			local line = vim.api.nvim_buf_get_lines(state.bufnr, 0, 1, false)[1] or ""
			local prefix = " " .. icons.get("ui", "search") .. " "
			local q
			if vim.startswith(line, prefix) then
				q = line:sub(#prefix + 1)
			else
				q = line:gsub("^%s+", "")
			end
			state.query = vim.trim(q)
			render_results_only(state)
		end,
	})

	local function leave()
		state.searching = false
		pcall(vim.api.nvim_del_augroup_by_name, state.spec.search_augroup)
		vim.cmd("stopinsert")
		render_all(state)
	end

	vim.keymap.set("i", "<CR>", leave, { buffer = state.bufnr, silent = true })
	vim.keymap.set("i", "<Esc>", leave, { buffer = state.bufnr, silent = true })
	vim.keymap.set("i", "<C-c>", leave, { buffer = state.bufnr, silent = true })

	vim.api.nvim_set_current_win(state.winid)
	vim.api.nvim_win_set_cursor(state.winid, { 1, #prompt })
	vim.cmd("startinsert!")
end

---@param spec GitflowPickerSpec
---@param opts GitflowPickerOpenOpts
---@return table|nil  nil when the terminal is too small for the float
function M.open(spec, opts)
	local selected = {}
	for _, name in ipairs(opts.selected or {}) do
		local normalized = vim.trim(tostring(name or ""))
		if normalized ~= "" then
			selected[normalized] = true
		end
	end

	local multi_select = opts.multi_select
	if multi_select == nil then
		multi_select = true
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", spec.filetype, { buf = bufnr })

	local state = {
		spec = spec,
		bufnr = bufnr,
		winid = nil,
		items = opts.items,
		selected = selected,
		multi_select = multi_select,
		query = "",
		filtered = {},
		line_entries = {},
		active_line = nil,
		searching = false,
		on_submit = opts.on_submit,
		on_cancel = opts.on_cancel,
		closed = false,
	}

	local function confirm()
		local selections = collect_selected(state)
		close_picker(state)
		state.on_submit(selections)
	end

	-- Reached from the q/<Esc> binds and from ui.window's close hook (plain
	-- :q, :bd, a layout change). The latch is here, not just in close_picker,
	-- so a hook-then-keymap (or submit-then-hook) race cannot fire on_cancel
	-- twice.
	---@param from_hook boolean  true when the close hook got here first
	local function cancel(from_hook)
		if state.closed then
			return
		end
		close_picker(state, from_hook)
		if not state.on_cancel then
			return
		end
		if from_hook then
			vim.schedule(state.on_cancel)
		else
			state.on_cancel()
		end
	end

	state.winid = ui_window.open_float({
		bufnr = bufnr,
		width = 0.55,
		height = 0.6,
		title = "  " .. (opts.title or spec.default_title) .. "  ",
		title_pos = "center",
		border = "rounded",
		enter = true,
		on_close = function()
			cancel(true)
		end,
	})
	if not state.winid then
		-- open_float already said why; without a window there is no picker.
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		state.bufnr = nil
		state.closed = true
		return nil
	end
	vim.api.nvim_set_option_value("cursorline", false, { win = state.winid })

	render_all(state)

	local function cancel_from_keymap()
		cancel(false)
	end

	local map = function(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
	end

	map("j", function() move_selection(state, 1) end)
	map("k", function() move_selection(state, -1) end)
	map("<Down>", function() move_selection(state, 1) end)
	map("<Up>", function() move_selection(state, -1) end)
	map("/", function() start_search(state) end)
	map("i", function() start_search(state) end)
	map("c", function()
		state.query = ""
		render_all(state)
	end)
	map("q", cancel_from_keymap)
	map("<Esc>", cancel_from_keymap)

	if multi_select then
		map("<Space>", function() toggle_current(state) end)
		map("<Tab>", function() toggle_current(state) end)
		map("<CR>", confirm)
	else
		map("<CR>", function() toggle_current(state) end)
		map("<Space>", function() toggle_current(state) end)
	end

	return state
end

return M
