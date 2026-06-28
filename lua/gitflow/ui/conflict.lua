--- Single-pane inline merge-conflict resolver (issue #370).
---
--- Replaces the old four-board layout with ONE focused editor showing the
--- conflicted file. Each conflict is colour-coded — OURS (current) vs THEIRS
--- (incoming) — with inline labels and a winbar listing every bind:
---   o take ours · t take theirs · b keep both · 2 base · e edit · a all
---   ]x/[x jump between conflicts · r refresh · q save & close

local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_conflict = require("gitflow.git.conflict")

---@class GitflowConflictViewState
---@field active boolean
---@field path string|nil
---@field cfg GitflowConfig|nil
---@field prev_winid integer|nil
---@field prev_tabid integer|nil
---@field tabid integer|nil
---@field merged_bufnr integer|nil
---@field merged_winid integer|nil
---@field hunks GitflowConflictHunk[]
---@field prompt_shown boolean
---@field on_resolved fun(path: string)|nil
---@field on_closed fun(path: string)|nil

local M = {}

local ns = vim.api.nvim_create_namespace("gitflow_conflict_view")
local label_ns = vim.api.nvim_create_namespace("gitflow_conflict_labels")

---@type GitflowConflictViewState
M.state = {
	active = false,
	path = nil,
	cfg = nil,
	prev_winid = nil,
	prev_tabid = nil,
	tabid = nil,
	-- Kept for backwards compatibility; always nil in the single-pane view.
	local_bufnr = nil,
	base_bufnr = nil,
	remote_bufnr = nil,
	local_winid = nil,
	base_winid = nil,
	remote_winid = nil,
	merged_bufnr = nil,
	merged_winid = nil,
	hunks = {},
	prompt_shown = false,
	on_resolved = nil,
	on_closed = nil,
}

---@param result GitflowGitResult|nil
---@param fallback string
---@return string
local function result_message(result, fallback)
	if not result then
		return fallback
	end
	local output = git.output(result)
	if output == "" then
		return fallback
	end
	return output
end

---@param path string
---@return string|nil, string[]|nil
local function read_path(path)
	local ok, lines = pcall(vim.fn.readfile, path, "b")
	if not ok or type(lines) ~= "table" then
		return ("Could not read '%s'"):format(path), nil
	end
	for _, line in ipairs(lines) do
		if line:find("\0", 1, true) then
			return ("File '%s' appears to be binary and cannot be resolved in UI"):format(path), nil
		end
	end
	return nil, lines
end

---@param path string
---@param lines string[]
---@return string|nil
local function write_path(path, lines)
	local ok, err = pcall(vim.fn.writefile, lines, path, "b")
	if not ok then
		return ("Could not write '%s': %s"):format(path, tostring(err))
	end
	return nil
end

---@param hunk GitflowConflictHunk
---@param line integer
---@return boolean
local function hunk_contains_line(hunk, line)
	return line >= hunk.start_line and line <= hunk.end_line
end

---@param line integer
---@return integer|nil
local function hunk_index_for_line(line)
	for index, hunk in ipairs(M.state.hunks) do
		if hunk_contains_line(hunk, line) then
			return index
		end
	end
	return nil
end

-- ── styling ────────────────────────────────────────────────────────────
---@param winid integer|nil
local function set_winbar(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end
	local short = vim.fn.fnamemodify(M.state.path or "", ":t")
	local left = #M.state.hunks
	local status = left == 0 and "all resolved \u{f42e}"
		or ("%d conflict%s left"):format(left, left == 1 and "" or "s")
	local bar = table.concat({
		"%#GitflowConflictMarker#  \u{f071} ",
		"%#GitflowTitle#" .. short,
		"%#GitflowConflictMarker#  ·  ",
		"%#GitflowHintText#" .. status,
		"%#GitflowConflictMarker#  ·  ",
		"%#GitflowHintKey#o%#GitflowHintText# ours  ",
		"%#GitflowHintKey#t%#GitflowHintText# theirs  ",
		"%#GitflowHintKey#b%#GitflowHintText# both  ",
		"%#GitflowHintKey#e%#GitflowHintText# edit  ",
		"%#GitflowHintKey#]x/[x%#GitflowHintText# jump  ",
		"%#GitflowHintKey#q%#GitflowHintText# save&close ",
	})
	pcall(vim.api.nvim_set_option_value, "winbar", bar, { win = winid })
end

local function apply_highlights()
	local bufnr = M.state.merged_bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(bufnr, label_ns, 0, -1)

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local function hl(line, group)
		if line >= 1 and line <= line_count then
			pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, group, line - 1, 0, -1)
		end
	end
	local function label(line, text, group)
		if line >= 1 and line <= line_count then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, label_ns, line - 1, 0, {
				virt_text = { { text, group } },
				virt_text_pos = "right_align",
			})
		end
	end

	for index, hunk in ipairs(M.state.hunks) do
		local ours_end = hunk.start_line + #(hunk.local_lines or {})
		-- marker + region lines
		hl(hunk.start_line, "GitflowConflictMarker")
		for line = hunk.start_line + 1, ours_end do
			hl(line, "GitflowConflictOurs")
		end
		-- base section (between ours and the ======= marker) stays dim
		for line = ours_end + 1, hunk.middle_line - 1 do
			hl(line, "GitflowConflictBase")
		end
		hl(hunk.middle_line, "GitflowConflictMarker")
		for line = hunk.middle_line + 1, hunk.end_line - 1 do
			hl(line, "GitflowConflictTheirs")
		end
		hl(hunk.end_line, "GitflowConflictMarker")

		label(hunk.start_line,
			("\u{25c0} OURS · conflict %d/%d "):format(index, #M.state.hunks),
			"GitflowConflictOursLabel")
		label(hunk.middle_line, " THEIRS \u{25b6} ", "GitflowConflictTheirsLabel")
	end

	set_winbar(M.state.merged_winid)
end

-- ── disk sync ──────────────────────────────────────────────────────────
---@return string|nil
local function flush_merged_to_disk()
	local bufnr = M.state.merged_bufnr
	local path = M.state.path
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not path then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return write_path(path, lines)
end

---@return string|nil
local function reload_merged_from_disk()
	local bufnr = M.state.merged_bufnr
	local path = M.state.path
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not path then
		return nil
	end
	local err, lines = read_path(path)
	if err then
		return err
	end
	ui.buffer.update(bufnr, lines or {})
	M.state.hunks = git_conflict.parse_markers(lines or {})
	apply_highlights()
	return nil
end

---@return integer|nil
local function current_hunk_index()
	local winid = M.state.merged_winid
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(winid)[1]
	local direct = hunk_index_for_line(line)
	if direct then
		return direct
	end
	for index, hunk in ipairs(M.state.hunks) do
		if line < hunk.start_line then
			return index
		end
	end
	if #M.state.hunks > 0 then
		return #M.state.hunks
	end
	return nil
end

---@param direction 1|-1
local function jump_hunk(direction)
	local winid = M.state.merged_winid
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end
	if #M.state.hunks == 0 then
		utils.notify("No unresolved conflict hunks", vim.log.levels.INFO)
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
	if direction > 0 then
		for _, hunk in ipairs(M.state.hunks) do
			if hunk.start_line > cursor_line then
				vim.api.nvim_win_set_cursor(winid, { hunk.start_line, 0 })
				return
			end
		end
		vim.api.nvim_win_set_cursor(winid, { M.state.hunks[1].start_line, 0 })
		return
	end
	for index = #M.state.hunks, 1, -1 do
		local hunk = M.state.hunks[index]
		if hunk.start_line < cursor_line then
			vim.api.nvim_win_set_cursor(winid, { hunk.start_line, 0 })
			return
		end
	end
	vim.api.nvim_win_set_cursor(winid, { M.state.hunks[#M.state.hunks].start_line, 0 })
end

local function maybe_mark_resolved()
	local path = M.state.path
	if not path then
		return
	end
	if #M.state.hunks ~= 0 or M.state.prompt_shown then
		return
	end
	M.state.prompt_shown = true
	local confirmed = ui.input.confirm(
		("All conflicts in '%s' are resolved. Mark file as resolved?"):format(path),
		{ choices = { "&Yes", "&No" }, default_choice = 1 }
	)
	if not confirmed then
		return
	end
	local on_resolved = M.state.on_resolved
	git_conflict.mark_resolved(path, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			result_message(result, ("Marked '%s' as resolved"):format(path)),
			vim.log.levels.INFO
		)
		if on_resolved then
			on_resolved(path)
		end
	end)
end

---@param choice "local"|"base"|"remote"|"both"
local function apply_resolution(choice)
	local path = M.state.path
	if not path then
		return
	end
	local flush_err = flush_merged_to_disk()
	if flush_err then
		utils.notify(flush_err, vim.log.levels.ERROR)
		return
	end
	local index = current_hunk_index()
	if not index then
		utils.notify("No conflict hunk selected", vim.log.levels.WARN)
		return
	end
	local cursor_line = M.state.hunks[index] and M.state.hunks[index].start_line
	git_conflict.resolve_hunk(path, index, choice, nil, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		local reload_err = reload_merged_from_disk()
		if reload_err then
			utils.notify(reload_err, vim.log.levels.ERROR)
			return
		end
		-- Keep the cursor near where the resolved conflict was.
		local winid = M.state.merged_winid
		if winid and vim.api.nvim_win_is_valid(winid) and cursor_line then
			local total = vim.api.nvim_buf_line_count(M.state.merged_bufnr)
			pcall(vim.api.nvim_win_set_cursor, winid, { math.min(cursor_line, total), 0 })
		end
		maybe_mark_resolved()
	end)
end

local function accept_all_from_side()
	local path = M.state.path
	if not path then
		return
	end
	if #M.state.hunks == 0 then
		utils.notify("No unresolved conflict hunks", vim.log.levels.INFO)
		return
	end
	local selection = vim.fn.confirm(
		"Accept all unresolved conflicts using which side?",
		"&Ours\n&Theirs\n&Both\n&Cancel",
		1
	)
	local choice
	if selection == 1 then
		choice = "local"
	elseif selection == 2 then
		choice = "remote"
	elseif selection == 3 then
		choice = "both"
	else
		return
	end
	local flush_err = flush_merged_to_disk()
	if flush_err then
		utils.notify(flush_err, vim.log.levels.ERROR)
		return
	end
	for index = #M.state.hunks, 1, -1 do
		local resolve_err = nil
		git_conflict.resolve_hunk(path, index, choice, nil, {}, function(err)
			resolve_err = err
		end)
		if resolve_err then
			utils.notify(resolve_err, vim.log.levels.ERROR)
			return
		end
	end
	local reload_err = reload_merged_from_disk()
	if reload_err then
		utils.notify(reload_err, vim.log.levels.ERROR)
		return
	end
	maybe_mark_resolved()
end

local function enter_manual_edit()
	local winid = M.state.merged_winid
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end
	local index = current_hunk_index()
	if not index then
		utils.notify("No conflict hunk selected", vim.log.levels.WARN)
		return
	end
	local hunk = M.state.hunks[index]
	vim.api.nvim_set_current_win(winid)
	vim.api.nvim_win_set_cursor(winid, { hunk.start_line, 0 })
	vim.cmd("startinsert")
end

local function refresh_hunks_from_buffer()
	local bufnr = M.state.merged_bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		M.state.hunks = {}
		return
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	M.state.hunks = git_conflict.parse_markers(lines)
	apply_highlights()
end

local function reset_state()
	M.state.active = false
	M.state.path = nil
	M.state.cfg = nil
	M.state.prev_winid = nil
	M.state.prev_tabid = nil
	M.state.tabid = nil
	M.state.merged_bufnr = nil
	M.state.merged_winid = nil
	M.state.hunks = {}
	M.state.prompt_shown = false
	M.state.on_resolved = nil
	M.state.on_closed = nil
end

function M.close()
	if not M.state.active then
		return
	end
	local path = M.state.path
	local flush_err = flush_merged_to_disk()
	if flush_err then
		utils.notify(flush_err, vim.log.levels.ERROR)
	end
	refresh_hunks_from_buffer()
	maybe_mark_resolved()

	local merged_bufnr = M.state.merged_bufnr
	if M.state.tabid and vim.api.nvim_tabpage_is_valid(M.state.tabid) then
		pcall(vim.api.nvim_set_current_tabpage, M.state.tabid)
		pcall(vim.cmd, "tabclose")
	end
	if merged_bufnr then
		ui.buffer.teardown(merged_bufnr)
	end

	local on_closed = M.state.on_closed
	reset_state()
	if path and on_closed then
		on_closed(path)
	end
end

---@param direction 1|-1
function M.jump(direction)
	jump_hunk(direction)
end

function M.refresh()
	refresh_hunks_from_buffer()
	local err = flush_merged_to_disk()
	if err then
		utils.notify(err, vim.log.levels.ERROR)
		return
	end
	local reload_err = reload_merged_from_disk()
	if reload_err then
		utils.notify(reload_err, vim.log.levels.ERROR)
		return
	end
	maybe_mark_resolved()
end

---@param side "local"|"base"|"remote"|"both"|"ours"|"theirs"
function M.resolve_current(side)
	if side == "ours" then
		side = "local"
	elseif side == "theirs" then
		side = "remote"
	end
	apply_resolution(side)
end

function M.resolve_both()
	apply_resolution("both")
end

function M.resolve_all_from_prompt()
	accept_all_from_side()
end

function M.edit_current_hunk()
	enter_manual_edit()
end

---@param bufnr integer
local function set_keymaps(bufnr)
	local function map(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
	end
	map("o", function() M.resolve_current("local") end)
	map("1", function() M.resolve_current("local") end)
	map("t", function() M.resolve_current("remote") end)
	map("3", function() M.resolve_current("remote") end)
	map("2", function() M.resolve_current("base") end)
	map("b", function() M.resolve_both() end)
	map("a", function() M.resolve_all_from_prompt() end)
	map("e", function() M.edit_current_hunk() end)
	map("]x", function() M.jump(1) end)
	map("[x", function() M.jump(-1) end)
	map("r", function() M.refresh() end)
	map("q", function() M.close() end)
end

---@param path string
---@param lines string[]
---@param callbacks table
local function open_single_pane(path, lines, callbacks)
	local merged_bufnr = ui.buffer.create(
		("conflict-merged-%s"):format(path:gsub("[^%w_]", "_")),
		{ filetype = "gitflowconflictmerge", lines = lines }
	)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = merged_bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = merged_bufnr })
	vim.api.nvim_set_option_value("modifiable", true, { buf = merged_bufnr })
	vim.api.nvim_set_option_value("readonly", false, { buf = merged_bufnr })

	local prev_winid = vim.api.nvim_get_current_win()
	local prev_tabid = vim.api.nvim_get_current_tabpage()

	-- A single full-screen tab so the user can focus on the file.
	vim.cmd("tabnew")
	local tabid = vim.api.nvim_get_current_tabpage()
	local merged_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(merged_winid, merged_bufnr)
	pcall(vim.api.nvim_set_option_value, "wrap", false, { win = merged_winid })
	pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = merged_winid })

	set_keymaps(merged_bufnr)

	M.state.active = true
	M.state.path = path
	M.state.cfg = callbacks.cfg
	M.state.prev_winid = prev_winid
	M.state.prev_tabid = prev_tabid
	M.state.tabid = tabid
	M.state.merged_bufnr = merged_bufnr
	M.state.merged_winid = merged_winid
	M.state.hunks = git_conflict.parse_markers(lines)
	M.state.prompt_shown = false
	M.state.on_resolved = callbacks.on_resolved
	M.state.on_closed = callbacks.on_closed

	apply_highlights()
	vim.api.nvim_set_current_win(merged_winid)
	if #M.state.hunks > 0 then
		pcall(vim.api.nvim_win_set_cursor, merged_winid, { M.state.hunks[1].start_line, 0 })
	end
end

---@param path string
---@param opts table|nil  { cfg, on_resolved, on_closed }
function M.open(path, opts)
	local callbacks = opts or {}
	local normalized = vim.trim(path or "")
	if normalized == "" then
		utils.notify("Conflict file path is required", vim.log.levels.ERROR)
		return
	end
	if M.state.active then
		M.close()
	end

	local err, lines = read_path(normalized)
	if err then
		utils.notify(err, vim.log.levels.ERROR)
		return
	end
	open_single_pane(normalized, lines or {}, callbacks)
end

---@return boolean
function M.is_open()
	return M.state.active
		and M.state.merged_bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.merged_bufnr)
end

return M
