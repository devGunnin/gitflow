--- Reusable PR-review-style diff viewer (no comments).
---
--- A two-pane tabpage: a file tree/list on the left and a rich per-file diff on
--- the right. Drives off any unified diff — a single commit, a commit range, or
--- the working tree — so `git log`, `:Gitflow diff` and status all share one
--- polished "review mode" surface (issue #369).
---
--- The file list is a `ui/panel.lua` panel: the base owns its keys, its hint
--- chrome, its request generation and its line→entry map. The one thing it
--- does not own is placement — the pane is a fixed-width vsplit inside this
--- module's own tabpage — so the window is built here and handed over.

local git = require("gitflow.git")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local ui_render = require("gitflow.ui.render")
local inline = require("gitflow.review.inline")
local icons = require("gitflow.icons")
local utils = require("gitflow.utils")

local M = {}

local FILE_LIST_WIDTH = 42
local DIFF_NS = vim.api.nvim_create_namespace("gitflow_diffview_diff_hl")
local LINENR_NS = vim.api.nvim_create_namespace("gitflow_diffview_linenr")

---@type table
M.state = {
	tabpage = nil,
	diff_winid = nil,
	files = {},
	file_diffs = {},
	file_line_map = {},
	active_idx = nil,
	hunk_anchors = {},
	title = "",
	cfg = nil,
}

---Keys bound on the file-list pane and, minus the ones that only make sense
---there, on every diff buffer the right pane shows. One declaration, so the
---two can no longer disagree with each other or with the hint bar.
---@type GitflowPanelKeymap[]
local KEYMAPS = {
	{ key = "<CR>/o", keys = { "<CR>", "o", "<2-LeftMouse>" }, desc = "open",
		essential = true, list_only = true, run = function()
			M.open_under_cursor()
		end },
	{ key = "]f/[f", keys = { "]f", "[f" }, desc = "file", run = function(key)
		if key == "]f" then
			M.next_file()
		else
			M.prev_file()
		end
	end },
	{ key = "]c/[c", keys = { "]c", "[c" }, desc = "hunk", run = function(key)
		if key == "]c" then
			M.next_hunk()
		else
			M.prev_hunk()
		end
	end },
	{ key = "r", desc = "refresh", list_only = true, run = function()
		M.refresh()
	end },
	{ key = "q", desc = "close", essential = true, run = function()
		M.close()
	end },
}

local P = panel.new({
	name = "diffview",
	title = "Gitflow Diffview",
	filetype = "gitflow-diffview",
	loading = "Loading diff…",
	state = M.state,
	-- `render` empties this before every paint, error and empty states
	-- included; registered so a state drawn through the base stays covered.
	entry_maps = { "file_line_map" },
	keymaps = KEYMAPS,
})

-- ── status glyphs ──────────────────────────────────────────────────────

---@param status string|nil
---@return string, string
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
	if not P:bufnr() then
		return
	end
	M.state.file_line_map = {}

	local total_add, total_del = 0, 0
	for _, f in ipairs(M.state.files) do
		total_add = total_add + (f.additions or 0)
		total_del = total_del + (f.deletions or 0)
	end

	local B = P:begin_render(ui_render.spacing.edge .. M.state.title)
	B:push({
		{ ui_render.spacing.edge, nil },
		{ ("Files (%d)"):format(#M.state.files), "GitflowSectionTitle" },
		{ ("  +%d"):format(total_add), "GitflowReviewCountAdd" },
		{ (" -%d"):format(total_del), "GitflowReviewCountDel" },
	})
	B:blank()

	if #M.state.files == 0 then
		components.empty(B, "(no changes)")
	end

	for idx, f in ipairs(M.state.files) do
		local icon, icon_hl = status_icon(f.status)
		local dir, name = f.path:match("^(.*/)([^/]+)$")
		dir = dir or ""
		name = name or f.path
		M.state.file_line_map[B:push({
			{ ui_render.spacing.gutter, nil },
			{ icon .. "  ", icon_hl },
			{ dir, "GitflowMeta" },
			{ name, M.state.active_idx == idx
				and "GitflowTitle" or "GitflowCardTitle" },
			{ ("   +%d"):format(f.additions or 0), "GitflowReviewCountAdd" },
			{ (" -%d"):format(f.deletions or 0), "GitflowReviewCountDel" },
		})] = idx
	end

	P:push_hints(B)
	P:paint(B)
end

-- ── diff pane (right) ──────────────────────────────────────────────────

---@param bufnr integer
local function bind_diff_keys(bufnr)
	local opts = { buffer = bufnr, silent = true, nowait = true }
	for _, entry in ipairs(KEYMAPS) do
		if not entry.list_only then
			for _, binding in ipairs(panel.bindings(entry)) do
				vim.keymap.set("n", binding.key, function()
					entry.run(binding.run_key)
				end, opts)
			end
		end
	end
end

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

	local B = ui_render.builder()
	local linenr = {} -- line_no(1-based) -> { old, new }
	local hunk_anchors = {}

	local icon = status_icon(file.status)
	B:raw(("%s  %s"):format(icon, file.path), "GitflowDiffFileHeader")
	B:blank()

	if not file_diff or #(file_diff.hunks or {}) == 0 then
		components.empty(B, "(no textual changes)")
	else
		for _, hunk in ipairs(file_diff.hunks) do
			hunk_anchors[#hunk_anchors + 1] =
				B:raw(hunk.header, "GitflowDiffHunkHeader")
			for _, l in ipairs(hunk.lines or {}) do
				local sign = l.kind == "add" and "+"
					or (l.kind == "del" and "-" or " ")
				local hl = l.kind == "add" and "GitflowAdded"
					or (l.kind == "del" and "GitflowRemoved" or "GitflowDiffContext")
				linenr[B:raw(sign .. " " .. (l.text or ""), hl)] =
					{ old = l.old_line, new = l.new_line }
			end
		end
	end

	B:flush(bufnr, bufnr, DIFF_NS)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "diff", { buf = bufnr })

	vim.api.nvim_win_set_buf(diff_winid, bufnr)
	M.state.diff_bufnr = bufnr
	M.state.hunk_anchors = hunk_anchors

	-- old/new line numbers as dim virtual text on the left. Its own namespace:
	-- the builder diffs DIFF_NS against a snapshot, so nothing else may write
	-- there.
	for line_no, nums in pairs(linenr) do
		local label = ("%4s %4s"):format(
			nums.old and tostring(nums.old) or "",
			nums.new and tostring(nums.new) or ""
		)
		pcall(vim.api.nvim_buf_set_extmark, bufnr, LINENR_NS, line_no - 1, 0, {
			virt_text = { { label .. " ", "GitflowDiffLineNr" } },
			virt_text_pos = "inline",
		})
	end

	bind_diff_keys(bufnr)

	local winbar = ("%%#GitflowTitle#  %s   %s "):format(M.state.title, file.path)
	pcall(vim.api.nvim_set_option_value, "winbar", winbar, { win = diff_winid })

	if #hunk_anchors > 0 then
		pcall(vim.api.nvim_win_set_cursor, diff_winid, { hunk_anchors[1], 0 })
	end
end

---Move the file-list cursor onto the row for file index `idx`.
---@param idx integer
local function select_file_line(idx)
	if not P:has_window() then
		return
	end
	for line, file_idx in pairs(M.state.file_line_map) do
		if file_idx == idx then
			pcall(vim.api.nvim_win_set_cursor, M.state.winid, { line, 0 })
			return
		end
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
	if not P:has_window() then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(M.state.winid)[1]
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

---@param forward boolean
local function jump_hunk(forward)
	local winid = M.state.diff_winid
	local anchors = M.state.hunk_anchors
	if not winid or not vim.api.nvim_win_is_valid(winid) or #anchors == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(winid)[1]
	if forward then
		for _, l in ipairs(anchors) do
			if l > cur then
				pcall(vim.api.nvim_win_set_cursor, winid, { l, 0 })
				return
			end
		end
		pcall(vim.api.nvim_win_set_cursor, winid, { anchors[1], 0 })
		return
	end
	for i = #anchors, 1, -1 do
		if anchors[i] < cur then
			pcall(vim.api.nvim_win_set_cursor, winid, { anchors[i], 0 })
			return
		end
	end
	pcall(vim.api.nvim_win_set_cursor, winid, { anchors[#anchors], 0 })
end

function M.next_hunk()
	jump_hunk(true)
end

function M.prev_hunk()
	jump_hunk(false)
end

-- ── layout ─────────────────────────────────────────────────────────────

---Drop the file-list buffer. It is `bufhidden = "hide"`, so closing its window
---is not enough — without this it leaks one buffer per open. Idempotent.
local function delete_file_list_buffer()
	local bufnr = M.state.bufnr
	M.state.bufnr = nil
	M.state.winid = nil
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

local function build_tabpage()
	vim.cmd("tabnew")
	M.state.tabpage = vim.api.nvim_get_current_tabpage()

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "gitflow-diffview", { buf = bufnr })
	M.state.bufnr = bufnr
	P:bind_keymaps(bufnr)

	vim.cmd("topleft vsplit")
	M.state.winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(M.state.winid, bufnr)
	vim.api.nvim_win_set_width(M.state.winid, FILE_LIST_WIDTH)
	local options = {
		number = false, relativenumber = false, signcolumn = "no",
		wrap = false, winfixwidth = true, cursorline = true,
	}
	for opt, val in pairs(options) do
		pcall(vim.api.nvim_set_option_value, opt, val, { win = M.state.winid })
	end

	vim.cmd("wincmd l")
	M.state.diff_winid = vim.api.nvim_get_current_win()

	local placeholder = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = placeholder })
	local B = ui_render.builder()
	B:blank()
	components.empty(B, "Select a file on the left with <CR> to view its diff.")
	B:blank()
	components.hint_bar(B, {
		{ "]f/[f", "file" }, { "]c/[c", "hunk" }, { "q", "close" },
	})
	B:flush(placeholder, placeholder, DIFF_NS)
	vim.api.nvim_set_option_value("modifiable", false, { buf = placeholder })
	vim.api.nvim_win_set_buf(M.state.diff_winid, placeholder)

	vim.api.nvim_set_current_win(M.state.winid)
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
---@param focus_path string|nil  file to select in the list (defaults to first)
local function open_from_git(args, title, cfg, focus_path)
	-- Unconditional: close also drops a file-list buffer left behind by a tab
	-- the user closed with a bare `:tabclose`.
	M.close()
	M.state.cfg = cfg
	M.state.title = title
	M.state._last = { args = args, title = title, focus_path = focus_path }

	-- Two rapid opens race: without this the loser still builds a tabpage, and
	-- it renders the winner's title over its own diff.
	local request_id = P:next_request()
	git.git(args, {}, function(result)
		-- The generation alone, not `P:is_active`: the tabpage is built from
		-- inside this callback, so the panel has no window yet to check.
		if M.state.request_id ~= request_id then
			return
		end
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
		if #M.state.files == 0 then
			return
		end
		local target = 1
		if focus_path then
			for idx, f in ipairs(M.state.files) do
				if f.path == focus_path then
					target = idx
					break
				end
			end
		end
		M.open_index(target)
		select_file_line(target)
		if P:has_window() then
			vim.api.nvim_set_current_win(M.state.winid)
		end
	end)
end

---Review a single commit's diff.
---@param cfg table|nil
---@param sha string
function M.open_commit(cfg, sha)
	open_from_git({ "show", "--patch", "--no-color", sha },
		("Commit %s"):format(tostring(sha):sub(1, 8)), cfg)
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
	-- Always review the full set of changes; `opts.path` only decides which
	-- file is focused in the list, not which files are shown (issue: status
	-- `dd` should open every changed file, not just one).
	local focus_path = opts.path ~= "" and opts.path or nil
	open_from_git(args, opts.staged and "Staged changes" or "Working tree", cfg, focus_path)
end

function M.refresh()
	if M.state._last then
		local last = M.state._last
		open_from_git(last.args, last.title, M.state.cfg, last.focus_path)
	end
end

function M.is_open()
	return M.state.tabpage ~= nil and vim.api.nvim_tabpage_is_valid(M.state.tabpage)
end

function M.close()
	-- Discard any in-flight open; its callback must not resurrect a tabpage.
	P:next_request()

	local tabpage = M.state.tabpage
	M.state.tabpage = nil
	M.state.diff_winid = nil
	M.state.files = {}
	M.state.file_diffs = {}
	M.state.file_line_map = {}
	M.state.active_idx = nil
	M.state.hunk_anchors = {}
	if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
		-- Close this diffview's own tabpage explicitly. Using a bare
		-- `tabclose` would close whatever tab is currently focused, which is
		-- the wrong tab when close runs while the user is on another tab
		-- (e.g. opening a second diff, which calls close() first).
		for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
			pcall(vim.api.nvim_win_close, winid, true)
		end
	end

	delete_file_list_buffer()
end

return M
