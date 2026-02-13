local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local icons = require("gitflow.icons")

---@class GitflowPaletteEntry
---@field name string
---@field description string
---@field command string
---@field keybind string

---@class GitflowPaletteCategory
---@field label string
---@field icon_name string
---@field entries GitflowPaletteEntry[]

---@class GitflowPaletteState
---@field bufnr integer|nil
---@field prompt_bufnr integer|nil
---@field winid integer|nil
---@field prompt_winid integer|nil
---@field selection integer
---@field line_entries table<integer, GitflowPaletteEntry>
---@field selectable_lines integer[]
---@field query string
---@field on_select fun(entry: GitflowPaletteEntry)|nil
---@field hl_ns integer
---@field categories GitflowPaletteCategory[]

local M = {}

---@type GitflowPaletteState
M.state = {
	bufnr = nil,
	prompt_bufnr = nil,
	winid = nil,
	prompt_winid = nil,
	selection = 1,
	line_entries = {},
	selectable_lines = {},
	query = "",
	on_select = nil,
	hl_ns = vim.api.nvim_create_namespace("gitflow_palette"),
	categories = {},
}

---@return GitflowPaletteCategory[]
local function build_categories()
	return {
		{
			label = "Git",
			icon_name = "git",
			entries = {
				{
					name = "Status",
					description = "View working tree status",
					command = "status",
					keybind = "gs",
				},
				{
					name = "Commit",
					description = "Commit staged changes",
					command = "commit",
					keybind = "gc",
				},
				{
					name = "Push",
					description = "Push to remote",
					command = "push",
					keybind = "gp",
				},
				{
					name = "Pull",
					description = "Pull from remote",
					command = "pull",
					keybind = "gP",
				},
				{
					name = "Diff",
					description = "View diff output",
					command = "diff",
					keybind = "gd",
				},
				{
					name = "Log",
					description = "Browse commit log",
					command = "log",
					keybind = "gl",
				},
				{
					name = "Stash",
					description = "Manage stash entries",
					command = "stash",
					keybind = "gS",
				},
			},
		},
		{
			label = "GitHub",
			icon_name = "github",
			entries = {},
		},
		{
			label = "UI",
			icon_name = "ui",
			entries = {
				{
					name = "Help",
					description = "Show Gitflow usage",
					command = "help",
					keybind = "<leader>gh",
				},
				{
					name = "Refresh",
					description = "Refresh panel content",
					command = "refresh",
					keybind = "<leader>gr",
				},
				{
					name = "Close",
					description = "Close all panels",
					command = "close",
					keybind = "<leader>gq",
				},
			},
		},
	}
end

---@param text string
---@param width integer
---@return string
local function pad_right(text, width)
	local text_len = vim.fn.strdisplaywidth(text)
	if text_len >= width then
		return text
	end
	return text .. string.rep(" ", width - text_len)
end

---@param width integer
---@return string
local function separator_line(width)
	local ch = icons.get("palette", "separator")
	if ch == "" then
		ch = "-"
	end
	return string.rep(ch, width)
end

---@param categories GitflowPaletteCategory[]
---@param query string
---@return GitflowPaletteCategory[]
local function filter_categories(categories, query)
	if query == "" then
		return categories
	end
	local lower_query = query:lower()
	local result = {}
	for _, cat in ipairs(categories) do
		local filtered_entries = {}
		for _, entry in ipairs(cat.entries) do
			local match_name = entry.name:lower():find(lower_query, 1, true)
			local match_desc = entry.description:lower():find(lower_query, 1, true)
			local match_cmd = entry.command:lower():find(lower_query, 1, true)
			if match_name or match_desc or match_cmd then
				filtered_entries[#filtered_entries + 1] = entry
			end
		end
		if #filtered_entries > 0 then
			result[#result + 1] = {
				label = cat.label,
				icon_name = cat.icon_name,
				entries = filtered_entries,
			}
		end
	end
	return result
end

---@param categories GitflowPaletteCategory[]
---@param content_width integer
---@return string[], table<integer, GitflowPaletteEntry>, integer[]
local function build_lines(categories, content_width)
	local lines = {}
	local line_entries = {}
	local selectable_lines = {}
	local entry_number = 0

	for cat_idx, cat in ipairs(categories) do
		if cat_idx > 1 then
			lines[#lines + 1] = ""
		end

		local icon = icons.get("palette", cat.icon_name)
		local header = (" %s %s"):format(icon, cat.label)
		lines[#lines + 1] = header

		lines[#lines + 1] = " " .. separator_line(content_width - 2)

		for _, entry in ipairs(cat.entries) do
			entry_number = entry_number + 1
			local num_prefix = (" %d"):format(entry_number)
			local name_part = ("  %s"):format(entry.name)
			local desc_part = entry.description
			local keybind_hint = ("[%s]"):format(entry.keybind)

			local left = num_prefix .. name_part
			local left_and_desc = left .. "  " .. desc_part
			local right_len = vim.fn.strdisplaywidth(keybind_hint) + 1
			local available = content_width - right_len
			local padded_left = pad_right(left_and_desc, available)
			local line = padded_left .. " " .. keybind_hint

			lines[#lines + 1] = line
			line_entries[#lines] = entry
			selectable_lines[#selectable_lines + 1] = #lines
		end
	end

	return lines, line_entries, selectable_lines
end

---@param bufnr integer
---@param lines string[]
---@param line_entries table<integer, GitflowPaletteEntry>
local function apply_highlights(bufnr, lines, line_entries)
	local ns = M.state.hl_ns
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	for i, line in ipairs(lines) do
		local row = i - 1
		if line_entries[i] then
			local kb_start = line:find("%[")
			if kb_start then
				vim.api.nvim_buf_add_highlight(
					bufnr, ns, "GitflowPaletteKeybind", row, kb_start - 1, #line
				)
			end
			local num_match = line:match("^ (%d+)")
			if num_match then
				vim.api.nvim_buf_add_highlight(
					bufnr, ns, "GitflowPaletteNumber", row, 0,
					1 + #num_match
				)
			end
			local desc_start = nil
			local name_end = nil
			for _, cat in ipairs(M.state.categories) do
				for _, entry in ipairs(cat.entries) do
					if line_entries[i] == entry then
						local _, ne = line:find(entry.name, 1, true)
						if ne then
							name_end = ne
							local ds = line:find(entry.description, ne + 1, true)
							if ds then
								desc_start = ds
							end
						end
						break
					end
				end
				if desc_start then
					break
				end
			end
			if desc_start and kb_start then
				vim.api.nvim_buf_add_highlight(
					bufnr, ns, "GitflowPaletteDescription", row,
					desc_start - 1, kb_start - 2
				)
			end
		elseif line:match("^%s*$") then
			-- blank line, no highlight
		elseif line:find(separator_line(4), 1, true) then
			vim.api.nvim_buf_add_highlight(
				bufnr, ns, "GitflowPaletteSeparator", row, 0, #line
			)
		else
			vim.api.nvim_buf_add_highlight(
				bufnr, ns, "GitflowPaletteHeader", row, 0, #line
			)
		end
	end
end

---@param selection integer  -- 1-based index into selectable_lines
local function update_selection_highlight(selection)
	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local ns = M.state.hl_ns
	for _, line_nr in ipairs(M.state.selectable_lines) do
		vim.api.nvim_buf_clear_namespace(bufnr, ns + 1, line_nr - 1, line_nr)
	end

	local sel_ns = vim.api.nvim_create_namespace("gitflow_palette_selection")
	vim.api.nvim_buf_clear_namespace(bufnr, sel_ns, 0, -1)

	if selection >= 1 and selection <= #M.state.selectable_lines then
		local target_line = M.state.selectable_lines[selection]
		local lines = vim.api.nvim_buf_get_lines(bufnr, target_line - 1, target_line, false)
		if #lines > 0 then
			vim.api.nvim_buf_add_highlight(
				bufnr, sel_ns, "GitflowPaletteSelection",
				target_line - 1, 0, #lines[1]
			)
		end
	end
end

local function render_entries()
	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local content_width = 60
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		content_width = vim.api.nvim_win_get_width(M.state.winid)
	end

	local filtered = filter_categories(M.state.categories, M.state.query)
	local lines, line_entries, selectable_lines =
		build_lines(filtered, content_width)

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	M.state.line_entries = line_entries
	M.state.selectable_lines = selectable_lines

	apply_highlights(bufnr, lines, line_entries)

	if M.state.selection > #selectable_lines then
		M.state.selection = math.max(1, #selectable_lines)
	end
	if M.state.selection < 1 and #selectable_lines > 0 then
		M.state.selection = 1
	end

	update_selection_highlight(M.state.selection)
end

---@param delta integer
local function move_selection(delta)
	local count = #M.state.selectable_lines
	if count == 0 then
		return
	end
	local new_sel = M.state.selection + delta
	if new_sel < 1 then
		new_sel = count
	elseif new_sel > count then
		new_sel = 1
	end
	M.state.selection = new_sel
	update_selection_highlight(new_sel)

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		local target_line = M.state.selectable_lines[new_sel]
		vim.api.nvim_win_set_cursor(M.state.winid, { target_line, 0 })
	end
end

local function select_current()
	local sel = M.state.selection
	if sel < 1 or sel > #M.state.selectable_lines then
		return
	end
	local line_nr = M.state.selectable_lines[sel]
	local entry = M.state.line_entries[line_nr]
	if not entry then
		return
	end
	vim.cmd("stopinsert")
	M.close()
	if M.state.on_select then
		M.state.on_select(entry)
	end
end

---@param number integer
local function quick_select(number)
	local idx = 0
	for _, cat in ipairs(M.state.categories) do
		local filtered = filter_categories({ cat }, M.state.query)
		if #filtered > 0 then
			for _, entry in ipairs(filtered[1].entries) do
				idx = idx + 1
				if idx == number then
					vim.cmd("stopinsert")
					M.close()
					if M.state.on_select then
						M.state.on_select(entry)
					end
					return
				end
			end
		end
	end
end

---@param bufnr integer
local function apply_prompt_keymaps(bufnr)
	local opts = { buffer = bufnr, silent = true, nowait = true }

	vim.keymap.set("i", "<CR>", function()
		select_current()
	end, opts)

	vim.keymap.set("i", "<Esc>", function()
		vim.cmd("stopinsert")
		M.close()
	end, opts)

	vim.keymap.set("i", "<Down>", function()
		move_selection(1)
	end, opts)

	vim.keymap.set("i", "<Up>", function()
		move_selection(-1)
	end, opts)

	vim.keymap.set("i", "<C-n>", function()
		move_selection(1)
	end, opts)

	vim.keymap.set("i", "<C-p>", function()
		move_selection(-1)
	end, opts)

	vim.keymap.set("i", "<Tab>", function()
		move_selection(1)
	end, opts)

	vim.keymap.set("i", "<S-Tab>", function()
		move_selection(-1)
	end, opts)

	vim.keymap.set("i", "<C-j>", function()
		move_selection(1)
	end, opts)

	vim.keymap.set("i", "<C-k>", function()
		move_selection(-1)
	end, opts)
end

---@param bufnr integer
local function apply_list_keymaps(bufnr)
	local opts = { buffer = bufnr, silent = true, nowait = true }

	vim.keymap.set("n", "<CR>", function()
		select_current()
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		M.close()
	end, opts)

	vim.keymap.set("n", "q", function()
		M.close()
	end, opts)

	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, opts)

	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, opts)

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			quick_select(i)
		end, opts)
	end
end

---@param cfg GitflowConfig
---@param opts table|nil
function M.open(cfg, opts)
	opts = opts or {}
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		M.close()
	end

	M.state.categories = build_categories()
	M.state.query = ""
	M.state.selection = 1
	M.state.on_select = opts.on_select

	local list_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = list_bufnr })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = list_bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = list_bufnr })
	vim.api.nvim_set_option_value("buflisted", false, { buf = list_bufnr })
	vim.api.nvim_set_option_value(
		"filetype", "gitflowpalette", { buf = list_bufnr }
	)
	M.state.bufnr = list_bufnr

	local prompt_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = prompt_bufnr })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = prompt_bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = prompt_bufnr })
	vim.api.nvim_set_option_value("buflisted", false, { buf = prompt_bufnr })
	M.state.prompt_bufnr = prompt_bufnr

	local columns = vim.o.columns
	local lines_total = vim.o.lines - vim.o.cmdheight
	local width = math.max(40, math.min(70, math.floor(columns * 0.5)))
	local list_height = math.max(10, math.min(25, math.floor(lines_total * 0.5)))
	local prompt_height = 1
	local total_height = list_height + prompt_height + 2
	local start_row = math.floor((lines_total - total_height) / 2)
	local start_col = math.floor((columns - width) / 2)

	local border_chars = { "\u{256d}", "\u{2500}", "\u{256e}",
		"\u{2502}", "\u{256f}", "\u{2500}", "\u{2570}", "\u{2502}" }

	local footer_opts = {}
	if vim.fn.has("nvim-0.10") == 1 then
		footer_opts.footer = " <CR>=Select  <Esc>=Close  1-9=Quick "
		footer_opts.footer_pos = "center"
	end

	local list_win_config = {
		relative = "editor",
		style = "minimal",
		width = width,
		height = list_height,
		row = start_row,
		col = start_col,
		border = border_chars,
		title = " Gitflow ",
		title_pos = "center",
	}
	for k, v in pairs(footer_opts) do
		list_win_config[k] = v
	end

	M.state.winid = vim.api.nvim_open_win(list_bufnr, false, list_win_config)
	vim.api.nvim_set_option_value("cursorline", false, { win = M.state.winid })
	vim.api.nvim_set_option_value(
		"winhighlight",
		"FloatBorder:GitflowBorder,FloatTitle:GitflowTitle",
		{ win = M.state.winid }
	)

	local prompt_row = start_row + list_height + 2
	M.state.prompt_winid = vim.api.nvim_open_win(prompt_bufnr, true, {
		relative = "editor",
		style = "minimal",
		width = width,
		height = prompt_height,
		row = prompt_row,
		col = start_col,
		border = border_chars,
		title = " Search ",
		title_pos = "center",
	})
	vim.api.nvim_set_option_value(
		"winhighlight",
		"FloatBorder:GitflowBorder,FloatTitle:GitflowTitle",
		{ win = M.state.prompt_winid }
	)

	render_entries()
	apply_list_keymaps(list_bufnr)
	apply_prompt_keymaps(prompt_bufnr)

	vim.cmd("startinsert")

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = prompt_bufnr,
		callback = function()
			local prompt_lines = vim.api.nvim_buf_get_lines(
				prompt_bufnr, 0, 1, false
			)
			M.state.query = (prompt_lines[1] or "")
			M.state.selection = 1
			render_entries()
		end,
	})
end

function M.close()
	vim.cmd("stopinsert")

	if M.state.prompt_winid and vim.api.nvim_win_is_valid(M.state.prompt_winid) then
		vim.api.nvim_win_close(M.state.prompt_winid, true)
	end
	M.state.prompt_winid = nil

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_close(M.state.winid, true)
	end
	M.state.winid = nil

	if M.state.prompt_bufnr and vim.api.nvim_buf_is_valid(M.state.prompt_bufnr) then
		pcall(vim.api.nvim_buf_delete, M.state.prompt_bufnr, { force = true })
	end
	M.state.prompt_bufnr = nil

	if M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) then
		pcall(vim.api.nvim_buf_delete, M.state.bufnr, { force = true })
	end
	M.state.bufnr = nil

	M.state.line_entries = {}
	M.state.selectable_lines = {}
end

---@return boolean
function M.is_open()
	return M.state.winid ~= nil
		and vim.api.nvim_win_is_valid(M.state.winid)
end

return M
