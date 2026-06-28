--- Multi-select label picker with live fuzzy filtering and color previews.
--- Press `/` to type and watch labels narrow as you go; <Space> toggles,
--- <CR> applies.

local ui_window = require("gitflow.ui.window")
local highlights = require("gitflow.highlights")
local render = require("gitflow.ui.render")
local icons = require("gitflow.icons")

local M = {}

local PICKER_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_label_picker_hl")
local SEARCH_AUGROUP = "GitflowLabelPickerSearch"

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

---@param text string
---@param query string
---@return integer[]
local function match_positions(text, query)
	local positions = {}
	local q = normalize(query)
	if q == "" then
		return positions
	end
	local lower = text:lower()
	local offset = 1
	for i = 1, #q do
		local found = lower:find(q:sub(i, i), offset, true)
		if not found then
			return {}
		end
		positions[#positions + 1] = found - 1
		offset = found + 1
	end
	return positions
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

---@param state table
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

---@param state table
local function selected_count(state)
	local n = 0
	for _, label in ipairs(state.labels) do
		if state.selected[vim.trim(tostring(label.name or ""))] then
			n = n + 1
		end
	end
	return n
end

---@param state table
local function close_picker(state)
	if state.closed then
		return
	end
	state.closed = true

	pcall(vim.api.nvim_del_augroup_by_name, SEARCH_AUGROUP)
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		pcall(vim.api.nvim_win_close, state.winid, true)
	end
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
	end

	state.winid = nil
	state.bufnr = nil
end

---@param state table
---@return table[]
local function prompt_chunks(state)
	local chunks = {
		{ " " .. icons.get("ui", "search") .. " ", "GitflowPickerPromptIcon" },
	}
	if state.query ~= "" then
		chunks[#chunks + 1] = { state.query, "GitflowPickerPrompt" }
	else
		chunks[#chunks + 1] = { "filter labels…", "GitflowFormPlaceholder" }
	end
	return chunks
end

---@param state table
---@return table[]
local function count_chunks(state)
	local label = ("%d/%d  ·  %d selected"):format(
		#state.filtered, #state.labels, selected_count(state)
	)
	local width = render.content_width({ winid = state.winid, bufnr = state.bufnr })
	local left = "── "
	local used = vim.fn.strdisplaywidth(left) + vim.fn.strdisplaywidth(label) + 1
	local tail = string.rep("\u{2500}", math.max(0, width - used))
	return {
		{ left, "GitflowSeparator" },
		{ label, "GitflowPickerCount" },
		{ " ", "GitflowSeparator" },
		{ tail, "GitflowSeparator" },
	}
end

---@param B GitflowRenderBuilder
---@param state table
---@param label GitflowLabelPickerLabel
---@return integer line_no
local function push_label(B, state, label)
	local name = vim.trim(tostring(label.name or ""))
	local desc = vim.trim(tostring(label.description or ""))
	local chunks = { { " ", nil } }
	if state.selected[name] then
		chunks[#chunks + 1] = { "[x]", "GitflowPickerCheck" }
	else
		chunks[#chunks + 1] = { "[ ]", "GitflowPickerCheckOff" }
	end
	chunks[#chunks + 1] = { " ", nil }
	local color_group = highlights.label_color_group(label.color or "")
	chunks[#chunks + 1] = { name, color_group }
	if desc ~= "" then
		chunks[#chunks + 1] = { "  " .. desc, "GitflowMeta" }
	end
	local line_no = B:push(chunks)
	-- fuzzy match highlight on the name (layer over the chip color)
	if state.query ~= "" then
		local line_text = B.lines[line_no]
		local name_start = line_text:find(name, 1, true)
		if name_start then
			for _, pos in ipairs(match_positions(name, state.query)) do
				B:hl(line_no, name_start - 1 + pos, name_start + pos, "GitflowPickerMatch")
			end
		end
	end
	return line_no
end

---@param state table
local function build_hint()
	return render.hint_chunks({
		{ "j/k", "move" }, { "<Spc>", "toggle" }, { "/", "filter" },
		{ "<CR>", "apply" }, { "q", "close" },
	}, { leading = " " })
end

---@param state table
local function render(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	state.filtered = M.filter_labels(state.labels, state.query)

	local B = require("gitflow.ui.render").builder()
	B:push(prompt_chunks(state))
	B:push(count_chunks(state))

	local line_entries = {}
	if #state.filtered == 0 then
		B:raw("   (no matching labels)", "GitflowMeta")
	else
		for _, label in ipairs(state.filtered) do
			local line_no = push_label(B, state, label)
			line_entries[line_no] = label
		end
	end

	B:blank()
	B:push(build_hint())

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

	B:apply(bufnr, PICKER_HIGHLIGHT_NS)
	if state.active_line then
		pcall(
			vim.api.nvim_buf_add_highlight, bufnr, PICKER_HIGHLIGHT_NS,
			"GitflowFormActiveField", state.active_line - 1, 0, -1
		)
	end

	if state.winid and vim.api.nvim_win_is_valid(state.winid) and state.active_line then
		pcall(vim.api.nvim_win_set_cursor, state.winid, { state.active_line, 0 })
	end
end

---@param state table
local function render_results_only(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	state.filtered = M.filter_labels(state.labels, state.query)

	local B = require("gitflow.ui.render").builder()
	B:raw("") -- placeholder for the untouched prompt line
	B:push(count_chunks(state))
	local line_entries = {}
	if #state.filtered == 0 then
		B:raw("   (no matching labels)", "GitflowMeta")
	else
		for _, label in ipairs(state.filtered) do
			local line_no = push_label(B, state, label)
			line_entries[line_no] = label
		end
	end
	B:blank()
	B:push(build_hint())

	state.line_entries = line_entries
	state.active_line = (#state.filtered > 0) and 3 or nil

	vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, vim.list_slice(B.lines, 2))
	vim.api.nvim_buf_clear_namespace(bufnr, PICKER_HIGHLIGHT_NS, 1, -1)
	for line_no, list in pairs(B.spans) do
		if line_no >= 2 then
			for _, span in ipairs(list) do
				pcall(
					vim.api.nvim_buf_add_highlight, bufnr, PICKER_HIGHLIGHT_NS,
					span[3], line_no - 1, span[1], span[2]
				)
			end
		end
	end
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
	render(state)
end

---@param state table
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

	state.selected[name] = not state.selected[name] or nil
	render(state)
end

---@param state table
local function start_search(state)
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end
	state.searching = true
	vim.api.nvim_set_option_value("modifiable", true, { buf = state.bufnr })

	local prompt = " " .. icons.get("ui", "search") .. " " .. state.query
	vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, { prompt })

	local group = vim.api.nvim_create_augroup(SEARCH_AUGROUP, { clear = true })
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
		pcall(vim.api.nvim_del_augroup_by_name, SEARCH_AUGROUP)
		vim.cmd("stopinsert")
		render(state)
	end

	vim.keymap.set("i", "<CR>", leave, { buffer = state.bufnr, silent = true })
	vim.keymap.set("i", "<Esc>", leave, { buffer = state.bufnr, silent = true })
	vim.keymap.set("i", "<C-c>", leave, { buffer = state.bufnr, silent = true })

	vim.api.nvim_set_current_win(state.winid)
	vim.api.nvim_win_set_cursor(state.winid, { 1, #prompt })
	vim.cmd("startinsert!")
end

---@param opts GitflowLabelPickerOpts
---@return table
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
		searching = false,
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
	vim.api.nvim_set_option_value("cursorline", false, { win = state.winid })

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

	local map = function(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
	end

	map("j", function() move_selection(state, 1) end)
	map("k", function() move_selection(state, -1) end)
	map("<Down>", function() move_selection(state, 1) end)
	map("<Up>", function() move_selection(state, -1) end)
	map("<Space>", function() toggle_current(state) end)
	map("<Tab>", function() toggle_current(state) end)
	map("/", function() start_search(state) end)
	map("i", function() start_search(state) end)
	map("c", function()
		state.query = ""
		render(state)
	end)
	map("<CR>", confirm)
	map("q", cancel)
	map("<Esc>", cancel)

	return state
end

return M
