--- Generic single/multi-select picker for branches, assignees, reviewers, etc.
--- Live, incremental fuzzy filtering: press `/` to type and watch results
--- narrow as you go; navigate with j/k, toggle with <Space>, apply with <CR>.

local ui_window = require("gitflow.ui.window")
local render = require("gitflow.ui.render")
local icons = require("gitflow.icons")

local M = {}

local PICKER_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_list_picker_hl")
local SEARCH_AUGROUP = "GitflowListPickerSearch"

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

---Greedy subsequence match positions (0-based byte indices into `text`).
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

---Build the prompt line (line 1) chunks.
---@param state table
---@return table[]
local function prompt_chunks(state)
	local chunks = {
		{ " " .. icons.get("ui", "search") .. " ", "GitflowPickerPromptIcon" },
	}
	if state.query ~= "" then
		chunks[#chunks + 1] = { state.query, "GitflowPickerPrompt" }
	else
		chunks[#chunks + 1] = { "type to filter…", "GitflowFormPlaceholder" }
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

---Build the result-row chunks for a single item.
---@param state table
---@param item GitflowListPickerItem
---@return table[]
local function item_chunks(state, item)
	local name = vim.trim(tostring(item.name or ""))
	local desc = vim.trim(tostring(item.description or ""))
	local chunks = { { " ", nil } }
	if state.multi_select then
		if state.selected[name] then
			chunks[#chunks + 1] = { "[x]", "GitflowPickerCheck" }
		else
			chunks[#chunks + 1] = { "[ ]", "GitflowPickerCheckOff" }
		end
		chunks[#chunks + 1] = { " ", nil }
	else
		chunks[#chunks + 1] = { state.selected[name] and "> " or "  ", "GitflowPickerCheck" }
	end
	chunks[#chunks + 1] = { name, "GitflowChip" }
	if desc ~= "" then
		chunks[#chunks + 1] = { "  " .. desc, "GitflowMeta" }
	end
	return chunks
end

---@param state table
local function build_hint(state)
	if state.multi_select then
		return render.hint_chunks({
			{ "j/k", "move" }, { "<Spc>", "toggle" }, { "/", "filter" },
			{ "<CR>", "apply" }, { "q", "close" },
		}, { leading = " " })
	end
	return render.hint_chunks({
		{ "j/k", "move" }, { "<CR>", "select" }, { "/", "filter" },
		{ "q", "close" },
	}, { leading = " " })
end

---Full render: prompt + count rule + results + hint.
---@param state table
local function render(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	state.filtered = M.filter_items(state.items, state.query)

	local B = require("gitflow.ui.render").builder()
	B:push(prompt_chunks(state))
	B:push(count_chunks(state))

	local line_entries = {}
	if #state.filtered == 0 then
		B:raw("   (no matching items)", "GitflowMeta")
	else
		for _, item in ipairs(state.filtered) do
			local line_no = B:push(item_chunks(state, item))
			line_entries[line_no] = item
			-- fuzzy match highlight on the name
			if state.query ~= "" then
				local line_text = B.lines[line_no]
				local name = vim.trim(tostring(item.name or ""))
				local name_start = line_text:find(name, 1, true)
				if name_start then
					for _, pos in ipairs(match_positions(name, state.query)) do
						B:hl(line_no, name_start - 1 + pos, name_start + pos, "GitflowPickerMatch")
					end
				end
			end
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

	B:apply(bufnr, PICKER_HIGHLIGHT_NS)
	-- active-line accent (separate so it layers over chips)
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

---Re-render results + count only (lines 2..end), preserving the live prompt
---line being edited in search mode.
---@param state table
local function render_results_only(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	state.filtered = M.filter_items(state.items, state.query)

	local B = require("gitflow.ui.render").builder()
	-- index 1 placeholder for the (untouched) prompt line so highlight line
	-- numbers line up; we won't write line 1 back.
	B:raw("")
	B:push(count_chunks(state))
	local line_entries = {}
	if #state.filtered == 0 then
		B:raw("   (no matching items)", "GitflowMeta")
	else
		for _, item in ipairs(state.filtered) do
			local line_no = B:push(item_chunks(state, item))
			line_entries[line_no] = item
			local line_text = B.lines[line_no]
			local name = vim.trim(tostring(item.name or ""))
			local name_start = line_text:find(name, 1, true)
			if name_start and state.query ~= "" then
				for _, pos in ipairs(match_positions(name, state.query)) do
					B:hl(line_no, name_start - 1 + pos, name_start + pos, "GitflowPickerMatch")
				end
			end
		end
	end
	B:blank()
	B:push(build_hint(state))

	state.line_entries = line_entries
	state.active_line = (#state.filtered > 0) and 3 or nil

	-- Replace from line 2 (index 1) to end; leave the prompt line intact.
	vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, vim.list_slice(B.lines, 2))

	-- Re-apply highlights for the rewritten region.
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
	-- refresh active-line accent
	vim.api.nvim_buf_clear_namespace(state.bufnr, PICKER_HIGHLIGHT_NS, 0, -1)
	render(state)
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
		render(state)
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

	local function leave(confirm)
		state.searching = false
		pcall(vim.api.nvim_del_augroup_by_name, SEARCH_AUGROUP)
		vim.cmd("stopinsert")
		render(state)
		if confirm then
			-- stay in normal-mode navigation on results
		end
	end

	vim.keymap.set("i", "<CR>", function()
		leave(true)
	end, { buffer = state.bufnr, silent = true })
	vim.keymap.set("i", "<Esc>", function()
		leave(false)
	end, { buffer = state.bufnr, silent = true })
	vim.keymap.set("i", "<C-c>", function()
		leave(false)
	end, { buffer = state.bufnr, silent = true })

	vim.api.nvim_set_current_win(state.winid)
	vim.api.nvim_win_set_cursor(state.winid, { 1, #prompt })
	vim.cmd("startinsert!")
end

---@param opts GitflowListPickerOpts
---@return table
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
		searching = false,
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
	map("/", function() start_search(state) end)
	map("i", function() start_search(state) end)
	map("c", function()
		state.query = ""
		render(state)
	end)
	map("q", cancel)
	map("<Esc>", cancel)

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
