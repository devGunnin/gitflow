local ui_window = require("gitflow.ui.window")
local highlights = require("gitflow.highlights")

local M = {}

local PICKER_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_label_picker_hl")

---@class GitflowLabelPickerLabel
---@field name string
---@field color? string
---@field description? string

---@class GitflowLabelPickerOpts
---@field labels GitflowLabelPickerLabel[]
---@field selected? string[]
---@field title? string
---@field on_submit fun(selected: string[])
---@field on_cancel? fun()

---@class GitflowLabelPickerState
---@field bufnr integer|nil
---@field winid integer|nil
---@field labels GitflowLabelPickerLabel[]
---@field selected table<string, boolean>
---@field query string
---@field filtered GitflowLabelPickerLabel[]
---@field line_entries table<integer, GitflowLabelPickerLabel>
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

---@param label GitflowLabelPickerLabel
---@return string
local function searchable_text(label)
	return ("%s %s"):format(label.name or "", label.description or "")
end

---@param labels GitflowLabelPickerLabel[]
---@param query string|nil
---@return GitflowLabelPickerLabel[]
function M.filter_labels(labels, query)
	local filtered = {}
	local trimmed_query = vim.trim(tostring(query or ""))

	for index, label in ipairs(labels or {}) do
		local score = fuzzy_score(searchable_text(label), trimmed_query)
		if score ~= nil then
			filtered[#filtered + 1] = {
				index = index,
				label = label,
				score = score,
			}
		end
	end

	table.sort(filtered, function(left, right)
		if left.score ~= right.score then
			return left.score > right.score
		end
		if left.label.name ~= right.label.name then
			return left.label.name < right.label.name
		end
		return left.index < right.index
	end)

	local results = {}
	for _, item in ipairs(filtered) do
		results[#results + 1] = item.label
	end
	return results
end

---@param state GitflowLabelPickerState
local function collect_selected(state)
	local selected = {}
	for _, label in ipairs(state.labels) do
		local name = vim.trim(tostring(label.name or ""))
		if name ~= "" and state.selected[name] then
			selected[#selected + 1] = name
		end
	end
	return selected
end

---@param state GitflowLabelPickerState
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

---@param state GitflowLabelPickerState
local function apply_highlights(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, PICKER_HIGHLIGHT_NS, 0, -1)

	vim.api.nvim_buf_add_highlight(bufnr, PICKER_HIGHLIGHT_NS, "GitflowHeader", 0, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, PICKER_HIGHLIGHT_NS, "GitflowSeparator", 1, 0, -1)

	for line_no, label in pairs(state.line_entries) do
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

		local line = vim.api.nvim_buf_get_lines(bufnr, line_no - 1, line_no, false)[1] or ""
		local label_name = vim.trim(tostring(label.name or ""))
		if label_name ~= "" then
			local start_col = line:find(label_name, 1, true)
			if start_col then
				local group = highlights.label_color_group(label.color or "")
				vim.api.nvim_buf_add_highlight(
					bufnr,
					PICKER_HIGHLIGHT_NS,
					group,
					line_no - 1,
					start_col - 1,
					start_col - 1 + #label_name
				)
			end
		end
	end
end

---@param state GitflowLabelPickerState
local function render(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	state.filtered = M.filter_labels(state.labels, state.query)

	local lines = {
		("Search: %s"):format(state.query ~= "" and state.query or "(press / to filter)"),
		string.rep("─", 40),
	}
	local line_entries = {}

	if #state.filtered == 0 then
		lines[#lines + 1] = "  (no matching labels)"
	else
		for _, label in ipairs(state.filtered) do
			local name = vim.trim(tostring(label.name or ""))
			local desc = vim.trim(tostring(label.description or ""))
			local marker = state.selected[name] and "[x]" or "[ ]"
			local line = (" %s %s"):format(marker, name)
			if desc ~= "" then
				line = ("%s - %s"):format(line, desc)
			end
			lines[#lines + 1] = line
			line_entries[#lines] = label
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "j/k move  <Space> toggle  / filter  c clear  <CR> apply  q cancel"

	state.line_entries = line_entries

	local fallback_line = #state.filtered > 0 and 3 or nil
	if state.active_line == nil or line_entries[state.active_line] == nil then
		state.active_line = fallback_line
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	apply_highlights(state)

	if state.winid and vim.api.nvim_win_is_valid(state.winid) and state.active_line then
		vim.api.nvim_win_set_cursor(state.winid, { state.active_line, 0 })
	end
end

---@param state GitflowLabelPickerState
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

---@param state GitflowLabelPickerState
local function toggle_current(state)
	local line_no = state.active_line
	if not line_no then
		return
	end

	local label = state.line_entries[line_no]
	if not label then
		return
	end

	local name = vim.trim(tostring(label.name or ""))
	if name == "" then
		return
	end

	state.selected[name] = not state.selected[name]
	render(state)
end

---@param state GitflowLabelPickerState
local function set_query(state)
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(state.winid)
	vim.fn.inputsave()
	local query = vim.fn.input("Label search: ", state.query)
	vim.fn.inputrestore()
	if vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end

	state.query = vim.trim(tostring(query or ""))
	render(state)
end

---@param opts GitflowLabelPickerOpts
---@return GitflowLabelPickerState
function M.open(opts)
	local labels = {}
	for _, label in ipairs(opts.labels or {}) do
		if type(label) == "table" then
			local name = vim.trim(tostring(label.name or ""))
			if name ~= "" then
				labels[#labels + 1] = {
					name = name,
					color = label.color,
					description = label.description,
				}
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

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "gitflow-label-picker", { buf = bufnr })

	local state = {
		bufnr = bufnr,
		winid = nil,
		labels = labels,
		selected = selected,
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
		title = "  " .. (opts.title or "Select Labels") .. "  ",
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
	vim.keymap.set("n", "<Space>", function()
		toggle_current(state)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "/", function()
		set_query(state)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "c", function()
		state.query = ""
		render(state)
	end, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "<CR>", confirm, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "q", cancel, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = bufnr, silent = true })

	return state
end

return M
