--- Reusable PR-review-style diff viewer (no comments).
---
--- A two-pane tabpage: a file tree/list on the left and a rich per-file diff on
--- the right. Drives off any unified diff — a single commit, a commit range, or
--- the working tree — so `git log`, `:Gitflow diff` and status all share one
--- polished "review mode" surface (issue #369).

local git = require("gitflow.git")
local inline = require("gitflow.review.inline")
local icons = require("gitflow.icons")
local utils = require("gitflow.utils")

local M = {}

local FILE_LIST_WIDTH = 42
local LIST_NS = vim.api.nvim_create_namespace("gitflow_diffview_list_hl")
local DIFF_NS = vim.api.nvim_create_namespace("gitflow_diffview_diff_hl")
local LINENR_NS = vim.api.nvim_create_namespace("gitflow_diffview_linenr")

---@type table
M.state = {
	tabpage = nil,
	file_list_winid = nil,
	file_list_bufnr = nil,
	diff_winid = nil,
	files = {},
	file_diffs = {},
	file_line_map = {},
	active_idx = nil,
	hunk_anchors = {},
	title = "",
	cfg = nil,
}

-- ── status glyphs ──────────────────────────────────────────────────────
local function status_icon(status)
	if status == "A" then
		return icons.get("file_status", "A"), "GitflowAdded"
	elseif status == "D" then
		return icons.get("file_status", "D"), "GitflowRemoved"
	elseif status == "R" then
		return icons.get("file_status", "R"), "GitflowModified"
	end
	return icons.get("file_status", "M"), "GitflowModified"
end

---@param hunks table[]
---@return integer, integer
local function count_changes(hunks)
	local add, del = 0, 0
	for _, hunk in ipairs(hunks or {}) do
		for _, line in ipairs(hunk.lines or {}) do
			if line.kind == "add" then
				add = add + 1
			elseif line.kind == "del" then
				del = del + 1
			end
		end
	end
	return add, del
end

-- ── file list (left pane) ──────────────────────────────────────────────
local function render_file_list()
	local bufnr = M.state.file_list_bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local lines = {}
	local spans = {}
	local file_line_map = {}

	local total_add, total_del = 0, 0
	for _, f in ipairs(M.state.files) do
		total_add = total_add + (f.additions or 0)
		total_del = total_del + (f.deletions or 0)
	end

	local function push(text, hls)
		lines[#lines + 1] = text
		if hls then
			for _, h in ipairs(hls) do
				h.line = #lines - 1
				spans[#spans + 1] = h
			end
		end
	end

	push(" " .. M.state.title, { { col_start = 0, col_end = -1, hl = "GitflowTitle" } })
	push(string.rep("\u{2500}", FILE_LIST_WIDTH - 2), { { col_start = 0, col_end = -1, hl = "GitflowSeparator" } })
	local files_header = (" Files (%d)"):format(#M.state.files)
	push(files_header .. ("  +%d -%d"):format(total_add, total_del), {
		{ col_start = 0, col_end = #files_header, hl = "GitflowSectionTitle" },
		{ col_start = #files_header, col_end = #files_header + #("  +" .. total_add), hl = "GitflowReviewCountAdd" },
		{ col_start = #files_header + #("  +" .. total_add), col_end = -1, hl = "GitflowReviewCountDel" },
	})
	push("")

	if #M.state.files == 0 then
		push("   (no changes)", { { col_start = 0, col_end = -1, hl = "GitflowMeta" } })
	end

	for idx, f in ipairs(M.state.files) do
		local icon, icon_hl = status_icon(f.status)
		local dir, name = f.path:match("^(.*/)([^/]+)$")
		dir = dir or ""
		name = name or f.path
		local active = M.state.active_idx == idx
		local prefix = " " .. icon .. "  "
		local counts = ("   +%d -%d"):format(f.additions or 0, f.deletions or 0)
		local text = prefix .. dir .. name .. counts
		local dir_start = #prefix
		local name_start = dir_start + #dir
		local counts_start = name_start + #name
		local add_str = ("   +%d"):format(f.additions or 0)
		push(text, {
			{ col_start = 1, col_end = 1 + #icon, hl = icon_hl },
			{ col_start = dir_start, col_end = name_start, hl = "GitflowMeta" },
			{ col_start = name_start, col_end = counts_start, hl = active and "GitflowTitle" or "GitflowCardTitle" },
			{ col_start = counts_start, col_end = counts_start + #add_str, hl = "GitflowReviewCountAdd" },
			{ col_start = counts_start + #add_str, col_end = -1, hl = "GitflowReviewCountDel" },
		})
		file_line_map[#lines] = idx
	end

	push("")
	local hint = " <CR>/o open · ]f/[f file · ]c/[c hunk · r refresh · q close"
	push(hint, { { col_start = 0, col_end = -1, hl = "GitflowReviewHint" } })

	M.state.file_line_map = file_line_map

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	vim.api.nvim_buf_clear_namespace(bufnr, LIST_NS, 0, -1)
	for _, sp in ipairs(spans) do
		pcall(vim.api.nvim_buf_add_highlight, bufnr, LIST_NS, sp.hl, sp.line, sp.col_start, sp.col_end)
	end
end

-- ── diff pane (right) ──────────────────────────────────────────────────
---@param file table  { path, status }
local function render_diff(file)
	local file_diff = M.state.file_diffs[file.path]
	local diff_winid = M.state.diff_winid
	if not diff_winid or not vim.api.nvim_win_is_valid(diff_winid) then
		return
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_buf_set_name(bufnr, ("gitflow://diff/%s"):format(file.path))

	local lines = {}
	local spans = {}
	local linenr = {} -- line_idx(0-based) -> {old, new}
	local hunk_anchors = {}

	local function push(text, hl)
		lines[#lines + 1] = text
		if hl then
			spans[#spans + 1] = { line = #lines - 1, hl = hl }
		end
	end

	local icon = status_icon(file.status)
	push(("%s  %s"):format(icon, file.path), "GitflowDiffFileHeader")
	push("")

	if not file_diff or #(file_diff.hunks or {}) == 0 then
		push("  (no textual changes)", "GitflowMeta")
	else
		for _, hunk in ipairs(file_diff.hunks) do
			push(hunk.header, "GitflowDiffHunkHeader")
			hunk_anchors[#hunk_anchors + 1] = #lines
			for _, l in ipairs(hunk.lines or {}) do
				local sign = l.kind == "add" and "+" or (l.kind == "del" and "-" or " ")
				local hl = l.kind == "add" and "GitflowAdded"
					or (l.kind == "del" and "GitflowRemoved" or "GitflowDiffContext")
				push(sign .. " " .. (l.text or ""), hl)
				linenr[#lines - 1] = { old = l.old_line, new = l.new_line }
			end
		end
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "diff", { buf = bufnr })

	vim.api.nvim_win_set_buf(diff_winid, bufnr)
	M.state.diff_bufnr = bufnr
	M.state.hunk_anchors = hunk_anchors

	vim.api.nvim_buf_clear_namespace(bufnr, DIFF_NS, 0, -1)
	for _, sp in ipairs(spans) do
		pcall(vim.api.nvim_buf_add_highlight, bufnr, DIFF_NS, sp.hl, sp.line, 0, -1)
	end
	-- old/new line numbers as dim virtual text on the left.
	for line_idx, nums in pairs(linenr) do
		local label = ("%4s %4s"):format(
			nums.old and tostring(nums.old) or "",
			nums.new and tostring(nums.new) or ""
		)
		pcall(vim.api.nvim_buf_set_extmark, bufnr, LINENR_NS, line_idx, 0, {
			virt_text = { { label .. " ", "GitflowDiffLineNr" } },
			virt_text_pos = "inline",
		})
	end

	-- diff-pane keymaps
	local kopts = { buffer = bufnr, silent = true, nowait = true }
	vim.keymap.set("n", "]f", M.next_file, kopts)
	vim.keymap.set("n", "[f", M.prev_file, kopts)
	vim.keymap.set("n", "]c", M.next_hunk, kopts)
	vim.keymap.set("n", "[c", M.prev_hunk, kopts)
	vim.keymap.set("n", "q", M.close, kopts)

	local winbar = ("%%#GitflowTitle#  %s   %s "):format(M.state.title, file.path)
	pcall(vim.api.nvim_set_option_value, "winbar", winbar, { win = diff_winid })

	if #hunk_anchors > 0 then
		pcall(vim.api.nvim_win_set_cursor, diff_winid, { hunk_anchors[1], 0 })
	end
end

---@param idx integer
function M.open_index(idx)
	local file = M.state.files[idx]
	if not file then
		return
	end
	M.state.active_idx = idx
	render_diff(file)
	render_file_list()
end

function M.open_under_cursor()
	if not M.state.file_list_winid or not vim.api.nvim_win_is_valid(M.state.file_list_winid) then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(M.state.file_list_winid)[1]
	local idx = M.state.file_line_map[cursor]
	if idx then
		M.open_index(idx)
	end
end

function M.next_file()
	if #M.state.files == 0 then
		return
	end
	local idx = (M.state.active_idx or 0) + 1
	if idx > #M.state.files then
		idx = 1
	end
	M.open_index(idx)
end

function M.prev_file()
	if #M.state.files == 0 then
		return
	end
	local idx = (M.state.active_idx or 2) - 1
	if idx < 1 then
		idx = #M.state.files
	end
	M.open_index(idx)
end

local function jump_hunk(forward)
	local winid = M.state.diff_winid
	if not winid or not vim.api.nvim_win_is_valid(winid) or #M.state.hunk_anchors == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(winid)[1]
	if forward then
		for _, l in ipairs(M.state.hunk_anchors) do
			if l > cur then
				pcall(vim.api.nvim_win_set_cursor, winid, { l, 0 })
				return
			end
		end
		pcall(vim.api.nvim_win_set_cursor, winid, { M.state.hunk_anchors[1], 0 })
	else
		for i = #M.state.hunk_anchors, 1, -1 do
			if M.state.hunk_anchors[i] < cur then
				pcall(vim.api.nvim_win_set_cursor, winid, { M.state.hunk_anchors[i], 0 })
				return
			end
		end
		pcall(vim.api.nvim_win_set_cursor, winid, { M.state.hunk_anchors[#M.state.hunk_anchors], 0 })
	end
end

function M.next_hunk()
	jump_hunk(true)
end

function M.prev_hunk()
	jump_hunk(false)
end

-- ── layout ─────────────────────────────────────────────────────────────
local function ensure_file_list_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "gitflow-diffview", { buf = bufnr })
	M.state.file_list_bufnr = bufnr

	local kopts = { buffer = bufnr, silent = true, nowait = true }
	vim.keymap.set("n", "<CR>", M.open_under_cursor, kopts)
	vim.keymap.set("n", "o", M.open_under_cursor, kopts)
	vim.keymap.set("n", "<2-LeftMouse>", M.open_under_cursor, kopts)
	vim.keymap.set("n", "]f", M.next_file, kopts)
	vim.keymap.set("n", "[f", M.prev_file, kopts)
	vim.keymap.set("n", "]c", M.next_hunk, kopts)
	vim.keymap.set("n", "[c", M.prev_hunk, kopts)
	vim.keymap.set("n", "r", M.refresh, kopts)
	vim.keymap.set("n", "q", M.close, kopts)
	return bufnr
end

local function build_tabpage()
	vim.cmd("tabnew")
	M.state.tabpage = vim.api.nvim_get_current_tabpage()

	ensure_file_list_buffer()

	vim.cmd("topleft vsplit")
	M.state.file_list_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(M.state.file_list_winid, M.state.file_list_bufnr)
	vim.api.nvim_win_set_width(M.state.file_list_winid, FILE_LIST_WIDTH)
	for opt, val in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false, winfixwidth = true, cursorline = true }) do
		pcall(vim.api.nvim_set_option_value, opt, val, { win = M.state.file_list_winid })
	end

	vim.cmd("wincmd l")
	M.state.diff_winid = vim.api.nvim_get_current_win()

	local placeholder = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = placeholder })
	vim.api.nvim_buf_set_lines(placeholder, 0, -1, false, {
		"", "  Select a file on the left with <CR> to view its diff.",
		"", "  ]f/[f next/prev file · ]c/[c next/prev hunk · q close",
	})
	vim.api.nvim_set_option_value("modifiable", false, { buf = placeholder })
	vim.api.nvim_win_set_buf(M.state.diff_winid, placeholder)

	vim.api.nvim_set_current_win(M.state.file_list_winid)
end

-- ── entry points ───────────────────────────────────────────────────────
---@param diff_text string
local function ingest(diff_text)
	M.state.file_diffs = inline.parse_diff(diff_text or "")
	local files = {}
	for path, fd in pairs(M.state.file_diffs) do
		local add, del = count_changes(fd.hunks)
		files[#files + 1] = {
			path = path,
			status = fd.status or "M",
			additions = add,
			deletions = del,
		}
	end
	table.sort(files, function(a, b)
		return a.path < b.path
	end)
	M.state.files = files
	M.state.active_idx = nil
end

---@param args string[]  git argv that produces a unified diff
---@param title string
---@param cfg table|nil
local function open_from_git(args, title, cfg)
	if M.is_open() then
		M.close()
	end
	M.state.cfg = cfg
	M.state.title = title
	M.state._last = { args = args, title = title }

	git.git(args, {}, function(result)
		if (result.code or 1) ~= 0 then
			utils.notify(
				("git diff failed: %s"):format(git.output(result)),
				vim.log.levels.ERROR
			)
			return
		end
		local diff_text = result.stdout or ""
		if vim.trim(diff_text) == "" then
			utils.notify("No changes to review.", vim.log.levels.INFO)
			return
		end
		ingest(diff_text)
		build_tabpage()
		render_file_list()
		if #M.state.files > 0 then
			M.open_index(1)
			vim.api.nvim_set_current_win(M.state.file_list_winid)
		end
	end)
end

---Review a single commit's diff.
---@param cfg table|nil
---@param sha string
function M.open_commit(cfg, sha)
	local short = tostring(sha):sub(1, 8)
	open_from_git({ "show", "--patch", "--no-color", sha }, ("Commit %s"):format(short), cfg)
end

---Review the combined diff of a commit range (exclusive of `from`).
---@param cfg table|nil
---@param from string
---@param to string
function M.open_range(cfg, from, to)
	local title = ("%s … %s"):format(tostring(from):sub(1, 8), tostring(to):sub(1, 8))
	open_from_git({ "--no-pager", "diff", "--no-color", from .. ".." .. to }, title, cfg)
end

---Review the working tree (optionally staged).
---@param cfg table|nil
---@param opts table|nil  { staged = boolean, path = string }
function M.open_working(cfg, opts)
	opts = opts or {}
	local args = { "--no-pager", "diff", "--no-color" }
	if opts.staged then
		args[#args + 1] = "--staged"
	end
	if opts.path and opts.path ~= "" then
		args[#args + 1] = "--"
		args[#args + 1] = opts.path
	end
	open_from_git(args, opts.staged and "Staged changes" or "Working tree", cfg)
end

function M.refresh()
	if M.state._last then
		local last = M.state._last
		open_from_git(last.args, last.title, M.state.cfg)
	end
end

function M.is_open()
	return M.state.tabpage ~= nil and vim.api.nvim_tabpage_is_valid(M.state.tabpage)
end

function M.close()
	local tabpage = M.state.tabpage
	M.state.tabpage = nil
	M.state.file_list_winid = nil
	M.state.diff_winid = nil
	M.state.files = {}
	M.state.file_diffs = {}
	M.state.file_line_map = {}
	M.state.active_idx = nil
	M.state.hunk_anchors = {}
	if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
		pcall(vim.cmd, "tabclose")
	end
end

return M
