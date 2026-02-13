local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local icons = require("gitflow.icons")

---@class GitflowPaletteEntry
---@field name string
---@field description string
---@field category string
---@field keybinding string|nil

---@class GitflowPalettePanelState
---@field cfg GitflowConfig|nil
---@field prompt_bufnr integer|nil
---@field list_bufnr integer|nil
---@field prompt_winid integer|nil
---@field list_winid integer|nil
---@field line_entries table<integer, GitflowPaletteEntry>
---@field selected_line integer|nil
---@field entries GitflowPaletteEntry[]
---@field query string
---@field on_select fun(entry: GitflowPaletteEntry)|nil
---@field augroup integer|nil
---@field highlight_ns integer|nil
---@field render_ns integer|nil
---@field numbered_entries table<integer, GitflowPaletteEntry>

local M = {}
local SELECTION_HIGHLIGHT = "GitflowPaletteSelection"
local PALETTE_PROMPT_FOOTER =
	"[1-9] quick select  <CR> confirm  / search  q close"
local PALETTE_LIST_FOOTER =
	"[1-9] quick select  <CR> select  j/k move  q close"

---@type GitflowPalettePanelState
M.state = {
	cfg = nil,
	prompt_bufnr = nil,
	list_bufnr = nil,
	prompt_winid = nil,
	list_winid = nil,
	line_entries = {},
	selected_line = nil,
	entries = {},
	query = "",
	on_select = nil,
	augroup = nil,
	highlight_ns = nil,
	render_ns = nil,
	numbered_entries = {},
}

local CATEGORY_ORDER = {
	Git = 1,
	GitHub = 2,
	UI = 3,
}

local CATEGORY_ICON_KEYS = {
	Git = "git",
	GitHub = "github",
	UI = "ui",
}

---@param text string
---@return string
local function normalize(text)
	return (text or ""):lower()
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

---@param entry GitflowPaletteEntry
---@return string
local function searchable_text(entry)
	return ("%s %s %s"):format(entry.name, entry.description, entry.category)
end

---@param entries GitflowPaletteEntry[]
---@param query string
---@return GitflowPaletteEntry[]
function M.filter_entries(entries, query)
	local filtered = {}
	local trimmed_query = vim.trim(query or "")

	for _, entry in ipairs(entries or {}) do
		local score = fuzzy_score(searchable_text(entry), trimmed_query)
		if score ~= nil then
			filtered[#filtered + 1] = {
				name = entry.name,
				description = entry.description,
				category = entry.category,
				keybinding = entry.keybinding,
				_score = score,
			}
		end
	end

	table.sort(filtered, function(a, b)
		local left_rank = CATEGORY_ORDER[a.category] or 99
		local right_rank = CATEGORY_ORDER[b.category] or 99
		if left_rank ~= right_rank then
			return left_rank < right_rank
		end
		if a._score ~= b._score then
			return a._score > b._score
		end
		return a.name < b.name
	end)

	for _, item in ipairs(filtered) do
		item._score = nil
	end

	return filtered
end

---@return integer[]
local function selectable_lines()
	local lines = {}
	for line, _ in pairs(M.state.line_entries) do
		lines[#lines + 1] = line
	end
	table.sort(lines)
	return lines
end

---@return integer|nil
local function selected_line()
	if M.state.selected_line
		and M.state.line_entries[M.state.selected_line]
	then
		return M.state.selected_line
	end

	local winid = M.state.list_winid
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(winid)[1]
	if M.state.line_entries[line] then
		return line
	end

	return nil
end

local function clear_selection_highlight()
	local bufnr = M.state.list_bufnr
	local ns = M.state.highlight_ns
	if not bufnr or not ns or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

---@param line integer|nil
local function apply_selection_highlight(line)
	local bufnr = M.state.list_bufnr
	local ns = M.state.highlight_ns
	if not bufnr or not ns or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	clear_selection_highlight()
	if not line or not M.state.line_entries[line] then
		return
	end

	vim.api.nvim_buf_add_highlight(
		bufnr, ns, SELECTION_HIGHLIGHT, line - 1, 0, -1
	)
end

---@param line integer
local function set_selected_line(line)
	local winid = M.state.list_winid
	local bufnr = M.state.list_bufnr
	if not winid or not bufnr or not vim.api.nvim_win_is_valid(winid) then
		return
	end

	local count = vim.api.nvim_buf_line_count(bufnr)
	local clamped = math.max(1, math.min(line, count))
	M.state.selected_line = clamped
	vim.api.nvim_win_set_cursor(winid, { clamped, 0 })
	apply_selection_highlight(clamped)
end

---@param delta integer
local function move_selection(delta)
	local lines = selectable_lines()
	if #lines == 0 then
		return
	end

	local current = selected_line() or lines[1]
	local index = 1
	for i, line in ipairs(lines) do
		if line >= current then
			index = i
			break
		end
	end

	local next_index = index + delta
	if next_index < 1 then
		next_index = 1
	elseif next_index > #lines then
		next_index = #lines
	end
	set_selected_line(lines[next_index])
end

local function focus_prompt()
	local winid = M.state.prompt_winid
	if winid and vim.api.nvim_win_is_valid(winid) then
		vim.api.nvim_set_current_win(winid)
		vim.cmd("startinsert")
	end
end

local function stop_insert_mode_if_active()
	local mode = vim.api.nvim_get_mode().mode
	if mode:match("^[iRrSs]") then
		vim.cmd("stopinsert")
	end
end

local function execute_selected()
	local line = selected_line()
	if not line then
		utils.notify("No command selected", vim.log.levels.WARN)
		return
	end

	local entry = M.state.line_entries[line]
	if not entry then
		utils.notify("No command selected", vim.log.levels.WARN)
		return
	end

	stop_insert_mode_if_active()

	local on_select = M.state.on_select
	M.close()
	if on_select then
		on_select(entry)
	end
end

---@param entry GitflowPaletteEntry
---@param number integer
local function execute_numbered(entry, number)
	if not entry then
		return
	end

	stop_insert_mode_if_active()

	local on_select = M.state.on_select
	M.close()
	if on_select then
		on_select(entry)
	end
end

---@param width integer
---@return string
local function separator_line(width)
	local sep = string.rep("\u{2500}", width)
	return sep
end

---@param bufnr integer
---@param ns integer
---@param row integer  0-indexed
---@param col_start integer  byte offset
---@param col_end integer  byte offset (-1 for end of line)
---@param hl_group string
local function add_hl(bufnr, ns, row, col_start, col_end, hl_group)
	vim.api.nvim_buf_add_highlight(bufnr, ns, hl_group, row, col_start, col_end)
end

local function render()
	local list_bufnr = M.state.list_bufnr
	if not list_bufnr or not vim.api.nvim_buf_is_valid(list_bufnr) then
		return
	end

	local render_ns = M.state.render_ns
	if render_ns then
		vim.api.nvim_buf_clear_namespace(list_bufnr, render_ns, 0, -1)
	end

	local cfg = M.state.cfg
	local width = 60
	if cfg then
		local columns = vim.o.columns
		width = math.max(50, math.floor(columns * cfg.ui.float.width))
	end

	local query = M.state.query or ""
	local filtered = M.filter_entries(M.state.entries, query)
	local lines = {}
	local line_entries = {}
	local highlights = {}
	local numbered_entries = {}
	local active_category = nil
	local entry_number = 0

	if #filtered == 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "  No commands match the current query."
	else
		for _, entry in ipairs(filtered) do
			if entry.category ~= active_category then
				if active_category ~= nil then
					lines[#lines + 1] = ""
				end

				local icon_key = CATEGORY_ICON_KEYS[entry.category]
				local icon = ""
				if icon_key then
					icon = icons.get("palette", icon_key)
				end
				local header_text
				if icon ~= "" then
					header_text = ("  %s %s"):format(icon, entry.category)
				else
					header_text = ("  %s"):format(entry.category)
				end
				lines[#lines + 1] = header_text
				highlights[#highlights + 1] = {
					row = #lines - 1,
					col_start = 0,
					col_end = -1,
					group = "GitflowPaletteHeader",
				}

				local sep = ("  %s"):format(
					separator_line(math.max(1, width - 4))
				)
				lines[#lines + 1] = sep
				highlights[#highlights + 1] = {
					row = #lines - 1,
					col_start = 0,
					col_end = -1,
					group = "GitflowPaletteHeader",
				}
				active_category = entry.category
			end

			entry_number = entry_number + 1
			local num_prefix = ""
			if entry_number <= 9 then
				num_prefix = ("[%d] "):format(entry_number)
				numbered_entries[entry_number] = entry
			end

			local keybind_hint = ""
			if entry.keybinding and entry.keybinding ~= "" then
				keybind_hint = ("[%s]"):format(entry.keybinding)
			end

			local left_part = ("    %s%s"):format(
				num_prefix, entry.name
			)
			local desc_part = (" \u{2014} %s"):format(entry.description)
			local content_len = vim.fn.strdisplaywidth(left_part)
				+ vim.fn.strdisplaywidth(desc_part)

			local line_text
			if keybind_hint ~= "" then
				local hint_len = vim.fn.strdisplaywidth(keybind_hint)
				local pad = math.max(
					1, width - content_len - hint_len - 2
				)
				line_text = left_part
					.. desc_part
					.. string.rep(" ", pad)
					.. keybind_hint
			else
				line_text = left_part .. desc_part
			end
			lines[#lines + 1] = line_text
			line_entries[#lines] = entry

			local row = #lines - 1
			local byte_offset = 4
			if entry_number <= 9 then
				local badge_len = #num_prefix
				highlights[#highlights + 1] = {
					row = row,
					col_start = byte_offset,
					col_end = byte_offset + badge_len,
					group = "GitflowPaletteIndex",
				}
				byte_offset = byte_offset + badge_len
			end

			local name_len = #entry.name
			highlights[#highlights + 1] = {
				row = row,
				col_start = byte_offset,
				col_end = byte_offset + name_len,
				group = "GitflowPaletteCommand",
			}

			local dash_str = " \u{2014} "
			local dash_byte_start = byte_offset + name_len
			local dash_byte_len = #dash_str
			local desc_byte_start = dash_byte_start + dash_byte_len
			local desc_byte_len = #entry.description
			highlights[#highlights + 1] = {
				row = row,
				col_start = desc_byte_start,
				col_end = desc_byte_start + desc_byte_len,
				group = "GitflowPaletteDescription",
			}

			if keybind_hint ~= "" then
				local hint_byte_start = #line_text - #keybind_hint
				highlights[#highlights + 1] = {
					row = row,
					col_start = hint_byte_start,
					col_end = #line_text,
					group = "GitflowPaletteKeybind",
				}
			end
		end
	end

	ui.buffer.update(list_bufnr, lines)
	M.state.line_entries = line_entries
	M.state.numbered_entries = numbered_entries

	if render_ns then
		for _, hl in ipairs(highlights) do
			add_hl(
				list_bufnr, render_ns,
				hl.row, hl.col_start, hl.col_end, hl.group
			)
		end
	end

	local selection = selectable_lines()
	if #selection == 0 then
		M.state.selected_line = nil
		apply_selection_highlight(nil)
		return
	end

	local current = selected_line()
	if not current or not M.state.line_entries[current] then
		current = selection[1]
	end
	set_selected_line(current)
end

local function refresh_query()
	local prompt_bufnr = M.state.prompt_bufnr
	if not prompt_bufnr or not vim.api.nvim_buf_is_valid(prompt_bufnr) then
		return
	end

	local line = vim.api.nvim_buf_get_lines(
		prompt_bufnr, 0, 1, false
	)[1] or ""
	M.state.query = line
	render()
end

---@param cfg GitflowConfig
---@return integer, integer, integer, integer, integer
local function compute_layout(cfg)
	local columns = vim.o.columns
	local editor_lines = vim.o.lines - vim.o.cmdheight

	local width = math.max(50, math.floor(columns * cfg.ui.float.width))
	local prompt_height = 3
	local list_height = math.max(
		10, math.floor(editor_lines * cfg.ui.float.height)
	)
	local combined_height = prompt_height + 1 + list_height

	if combined_height > editor_lines - 2 then
		list_height = math.max(8, editor_lines - prompt_height - 3)
		combined_height = prompt_height + 1 + list_height
	end

	local row = math.max(
		0, math.floor((editor_lines - combined_height) / 2)
	)
	local col = math.max(0, math.floor((columns - width) / 2))
	return width, prompt_height, list_height, row, col
end

local function setup_prompt_autocmd()
	local group = vim.api.nvim_create_augroup(
		"GitflowPalettePrompt", { clear = true }
	)
	M.state.augroup = group

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		group = group,
		buffer = M.state.prompt_bufnr,
		callback = function()
			refresh_query()
		end,
	})
end

local function apply_keymaps()
	local prompt_bufnr = M.state.prompt_bufnr
	local list_bufnr = M.state.list_bufnr
	if not prompt_bufnr or not list_bufnr then
		return
	end

	local prompt_normal_opts = {
		buffer = prompt_bufnr, silent = true, nowait = true,
	}
	local prompt_insert_opts = {
		buffer = prompt_bufnr,
		silent = true,
		nowait = true,
		expr = true,
	}
	local list_opts = {
		buffer = list_bufnr, silent = true, nowait = true,
	}
	local prompt_navigation_keys = {
		{ key = "<Down>", delta = 1 },
		{ key = "<Up>", delta = -1 },
		{ key = "<C-n>", delta = 1 },
		{ key = "<C-p>", delta = -1 },
		{ key = "<Tab>", delta = 1 },
		{ key = "<S-Tab>", delta = -1 },
		{ key = "<C-j>", delta = 1 },
		{ key = "<C-k>", delta = -1 },
	}

	vim.keymap.set({ "n", "i" }, "<Esc>", function()
		M.close()
	end, prompt_normal_opts)
	vim.keymap.set({ "n", "i" }, "<CR>", function()
		execute_selected()
	end, prompt_normal_opts)
	for _, mapping in ipairs(prompt_navigation_keys) do
		vim.keymap.set("n", mapping.key, function()
			move_selection(mapping.delta)
		end, prompt_normal_opts)
		vim.keymap.set("i", mapping.key, function()
			move_selection(mapping.delta)
			return ""
		end, prompt_insert_opts)
	end

	for i = 1, 9 do
		local num_key = tostring(i)
		vim.keymap.set("n", num_key, function()
			local entry = M.state.numbered_entries[i]
			if entry then
				execute_numbered(entry, i)
			end
		end, prompt_normal_opts)
		vim.keymap.set("n", num_key, function()
			local entry = M.state.numbered_entries[i]
			if entry then
				execute_numbered(entry, i)
			end
		end, list_opts)
	end

	vim.keymap.set("n", "<CR>", function()
		execute_selected()
	end, list_opts)
	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, list_opts)
	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, list_opts)
	vim.keymap.set("n", "<C-n>", function()
		move_selection(1)
	end, list_opts)
	vim.keymap.set("n", "<C-p>", function()
		move_selection(-1)
	end, list_opts)
	vim.keymap.set("n", "q", function()
		M.close()
	end, list_opts)
	vim.keymap.set("n", "<Esc>", function()
		M.close()
	end, list_opts)
end

function M.close()
	clear_selection_highlight()

	if M.state.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M.state.augroup)
	end

	if M.state.prompt_winid then
		ui.window.close(M.state.prompt_winid)
	end
	if M.state.list_winid then
		ui.window.close(M.state.list_winid)
	end

	if M.state.prompt_bufnr then
		ui.buffer.teardown(M.state.prompt_bufnr)
	end
	if M.state.list_bufnr then
		ui.buffer.teardown(M.state.list_bufnr)
	end

	M.state.cfg = nil
	M.state.prompt_bufnr = nil
	M.state.list_bufnr = nil
	M.state.prompt_winid = nil
	M.state.list_winid = nil
	M.state.line_entries = {}
	M.state.selected_line = nil
	M.state.entries = {}
	M.state.query = ""
	M.state.on_select = nil
	M.state.augroup = nil
	M.state.highlight_ns = nil
	M.state.render_ns = nil
	M.state.numbered_entries = {}
end

---@param cfg GitflowConfig
---@param entries GitflowPaletteEntry[]
---@param on_select fun(entry: GitflowPaletteEntry)|nil
function M.open(cfg, entries, on_select)
	M.close()

	M.state.cfg = cfg
	M.state.entries = vim.deepcopy(entries or {})
	M.state.on_select = on_select
	M.state.query = ""
	M.state.line_entries = {}
	M.state.selected_line = nil
	M.state.numbered_entries = {}
	M.state.highlight_ns = vim.api.nvim_create_namespace(
		"GitflowPaletteSelection"
	)
	M.state.render_ns = vim.api.nvim_create_namespace(
		"GitflowPaletteRender"
	)

	local width, prompt_height, list_height, row, col =
		compute_layout(cfg)
	local prompt_bufnr = ui.buffer.create("palette_prompt", {
		filetype = "gitflowpaletteprompt",
		lines = { "" },
	})
	local list_bufnr = ui.buffer.create("palette_list", {
		filetype = "gitflowpalette",
		lines = { "Loading palette..." },
	})

	M.state.prompt_bufnr = prompt_bufnr
	M.state.list_bufnr = list_bufnr

	vim.api.nvim_set_option_value(
		"modifiable", true, { buf = prompt_bufnr }
	)
	vim.api.nvim_set_option_value(
		"modifiable", false, { buf = list_bufnr }
	)

	M.state.prompt_winid = ui.window.open_float({
		name = "palette_prompt",
		bufnr = prompt_bufnr,
		width = width,
		height = prompt_height,
		row = row,
		col = col,
		border = cfg.ui.float.border,
		title = " Gitflow ",
		title_pos = cfg.ui.float.title_pos,
		footer = cfg.ui.float.footer
			and PALETTE_PROMPT_FOOTER or nil,
		footer_pos = cfg.ui.float.footer_pos,
	})

	M.state.list_winid = ui.window.open_float({
		name = "palette_list",
		bufnr = list_bufnr,
		width = width,
		height = list_height,
		row = row + prompt_height + 1,
		col = col,
		border = cfg.ui.float.border,
		title = " Commands ",
		title_pos = cfg.ui.float.title_pos,
		footer = cfg.ui.float.footer
			and PALETTE_LIST_FOOTER or nil,
		footer_pos = cfg.ui.float.footer_pos,
	})

	vim.api.nvim_set_option_value(
		"wrap", false, { win = M.state.prompt_winid }
	)
	vim.api.nvim_set_option_value(
		"wrap", false, { win = M.state.list_winid }
	)
	vim.api.nvim_set_option_value(
		"cursorline", true, { win = M.state.list_winid }
	)

	setup_prompt_autocmd()
	apply_keymaps()
	render()
	focus_prompt()
end

---@return boolean
function M.is_open()
	return M.state.list_bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.list_bufnr)
end

return M
