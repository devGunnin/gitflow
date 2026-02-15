--- Generic single/multi-select picker for branches, assignees, etc.
--- Reuses the fuzzy-filter pattern from label_picker but without color logic.

local ui_window = require("gitflow.ui.window")

local M = {}

local PICKER_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_list_picker_hl")

---@class GitflowListPickerItem
---@field name string
---@field description? string

---@class GitflowListPickerOpts
---@field items GitflowListPickerItem[]
---@field selected? string[]
---@field title? string
---@field multi_select? boolean  default true
---@field on_submit fun(selected: string[])
---@field on_cancel? fun()

---@class GitflowListPickerState
---@field bufnr integer|nil
---@field winid integer|nil
---@field items GitflowListPickerItem[]
---@field selected table<string, boolean>
---@field multi_select boolean
---@field query string
---@field filtered GitflowListPickerItem[]
---@field line_entries table<integer, GitflowListPickerItem>
---@field active_line integer|nil
---@field on_submit fun(selected: string[])
---@field on_cancel fun()|nil
---@field closed boolean

---@param text string|nil
---@return string
local function normalize(text)
	return vim.trim(tostring(text or "")):lower()
end

---@param haystack string
---@param needle string
---@return integer|nil
local function fuzzy_score(haystack, needle)
	if needle == "" then
		return 0
	end

	local search = normalize(haystack)
	local query = normalize(needle)
	local offset = 1
	local score = 0
	local streak = 0

	for index = 1, #query do
		local char = query:sub(index, index)
		local found = search:find(char, offset, true)
		if not found then
			return nil
		end

		if found == offset then
			streak = streak + 1
			score = score + 10 + streak
		else
			streak = 0
			score = score + math.max(1, 6 - (found - offset))
		end
		offset = found + 1
	end

	return score
end

---@param item GitflowListPickerItem
---@return string
local function searchable_text(item)
	return ("%s %s"):format(item.name or "", item.description or "")
end

---@param items GitflowListPickerItem[]
---@param query string|nil
---@return GitflowListPickerItem[]
function M.filter_items(items, query)
	local filtered = {}
	local trimmed_query = vim.trim(tostring(query or ""))

	for index, item in ipairs(items or {}) do
		local sc = fuzzy_score(searchable_text(item), trimmed_query)
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

---@param state GitflowListPickerState
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

---@param state GitflowListPickerState
local function close_picker(state)
	if state.closed then
		return
	end
	state.closed = true

	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		pcall(vim.api.nvim_win_close, state.winid, true)
	end
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
	end

	state.winid = nil
	state.bufnr = nil
end

---@param state GitflowListPickerState
local function apply_highlights(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, PICKER_HIGHLIGHT_NS, 0, -1)

	vim.api.nvim_buf_add_highlight(
		bufnr, PICKER_HIGHLIGHT_NS, "GitflowHeader", 0, 0, -1
	)
	vim.api.nvim_buf_add_highlight(
		bufnr, PICKER_HIGHLIGHT_NS, "GitflowSeparator", 1, 0, -1
	)

	for line_no, _ in pairs(state.line_entries) do
		if state.active_line == line_no then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				PICKER_HIGHLIGHT_NS,
				"GitflowFormActiveField",
				line_no - 1,
				0,
				-1
			)
		end
	end
end

---@param state GitflowListPickerState
local function render(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	state.filtered = M.filter_items(state.items, state.query)

	local lines = {
		("Search: %s"):format(
			state.query ~= "" and state.query or "(press / to filter)"
		),
		string.rep("\u{2500}", 40),
	}
	local line_entries = {}

	if #state.filtered == 0 then
		lines[#lines + 1] = "  (no matching items)"
	else
		for _, item in ipairs(state.filtered) do
			local name = vim.trim(tostring(item.name or ""))
			local desc = vim.trim(tostring(item.description or ""))
			local line
			if state.multi_select then
				local marker = state.selected[name] and "[x]" or "[ ]"
				line = (" %s %s"):format(marker, name)
			else
				local marker = state.selected[name] and ">" or " "
				line = (" %s %s"):format(marker, name)
			end
			if desc ~= "" then
				line = ("%s - %s"):format(line, desc)
			end
			lines[#lines + 1] = line
			line_entries[#lines] = item
		end
	end

	lines[#lines + 1] = ""
	if state.multi_select then
		lines[#lines + 1] =
			"j/k move  <Space> toggle  / filter  c clear"
			.. "  <CR> apply  q cancel"
	else
		lines[#lines + 1] =
			"j/k move  <CR> select  / filter  c clear  q cancel"
	end

	state.line_entries = line_entries

	local fallback_line = #state.filtered > 0 and 3 or nil
	if state.active_line == nil
		or line_entries[state.active_line] == nil
	then
		state.active_line = fallback_line
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	apply_highlights(state)

	if state.winid
		and vim.api.nvim_win_is_valid(state.winid)
		and state.active_line
	then
		vim.api.nvim_win_set_cursor(state.winid, { state.active_line, 0 })
	end
end

---@param state GitflowListPickerState
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

	vim.api.nvim_win_set_cursor(state.winid, { state.active_line, 0 })
	apply_highlights(state)
end

---@param state GitflowListPickerState
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
		state.selected[name] = not state.selected[name]
		render(state)
	else
		-- Single select: clear others, set this one
		state.selected = { [name] = true }
		-- Confirm immediately
		local selections = collect_selected(state)
		close_picker(state)
		state.on_submit(selections)
	end
end

---@param state GitflowListPickerState
local function set_query(state)
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(state.winid)
	vim.fn.inputsave()
	local query = vim.fn.input("Search: ", state.query)
	vim.fn.inputrestore()
	if vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end

	state.query = vim.trim(tostring(query or ""))
	render(state)
end

---@param opts GitflowListPickerOpts
---@return GitflowListPickerState
function M.open(opts)
	local items = {}
	for _, item in ipairs(opts.items or {}) do
		if type(item) == "table" then
			local name = vim.trim(tostring(item.name or ""))
			if name ~= "" then
				items[#items + 1] = {
					name = name,
					description = item.description,
				}
			end
		elseif type(item) == "string" then
			local name = vim.trim(item)
			if name ~= "" then
				items[#items + 1] = { name = name }
			end
		end
	end

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
	vim.api.nvim_set_option_value(
		"filetype", "gitflow-list-picker", { buf = bufnr }
	)

	local state = {
		bufnr = bufnr,
		winid = nil,
		items = items,
		selected = selected,
		multi_select = multi_select,
		query = "",
		filtered = {},
		line_entries = {},
		active_line = nil,
		on_submit = opts.on_submit,
		on_cancel = opts.on_cancel,
		closed = false,
	}

	state.winid = ui_window.open_float({
		bufnr = bufnr,
		width = 0.55,
		height = 0.6,
		title = "  " .. (opts.title or "Select") .. "  ",
		title_pos = "center",
		border = "rounded",
		enter = true,
	})

	render(state)

	local function confirm()
		local selections = collect_selected(state)
		close_picker(state)
		state.on_submit(selections)
	end

	local function cancel()
		close_picker(state)
		if state.on_cancel then
			state.on_cancel()
		end
	end

	vim.keymap.set("n", "j", function()
		move_selection(state, 1)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "k", function()
		move_selection(state, -1)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "<Down>", function()
		move_selection(state, 1)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "<Up>", function()
		move_selection(state, -1)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "/", function()
		set_query(state)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "c", function()
		state.query = ""
		render(state)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "q", cancel, { buffer = bufnr, silent = true })
	vim.keymap.set(
		"n", "<Esc>", cancel, { buffer = bufnr, silent = true }
	)

	if multi_select then
		vim.keymap.set("n", "<Space>", function()
			toggle_current(state)
		end, { buffer = bufnr, silent = true })
		vim.keymap.set(
			"n", "<CR>", confirm, { buffer = bufnr, silent = true }
		)
	else
		vim.keymap.set("n", "<CR>", function()
			toggle_current(state)
		end, { buffer = bufnr, silent = true })
		vim.keymap.set("n", "<Space>", function()
			toggle_current(state)
		end, { buffer = bufnr, silent = true })
	end

	return state
end

return M
