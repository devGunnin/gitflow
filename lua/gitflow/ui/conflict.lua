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
---@field local_bufnr integer|nil
---@field base_bufnr integer|nil
---@field remote_bufnr integer|nil
---@field merged_bufnr integer|nil
---@field local_winid integer|nil
---@field base_winid integer|nil
---@field remote_winid integer|nil
---@field merged_winid integer|nil
---@field hunks GitflowConflictHunk[]
---@field prompt_shown boolean
---@field on_resolved fun(path: string)|nil
---@field on_closed fun(path: string)|nil

local M = {}

local ns = vim.api.nvim_create_namespace("gitflow_conflict_view")

---@type GitflowConflictViewState
M.state = {
	active = false,
	path = nil,
	cfg = nil,
	prev_winid = nil,
	prev_tabid = nil,
	tabid = nil,
	local_bufnr = nil,
	base_bufnr = nil,
	remote_bufnr = nil,
	merged_bufnr = nil,
	local_winid = nil,
	base_winid = nil,
	remote_winid = nil,
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

---@param value string
---@return string
local function sanitize(value)
	return value:gsub("[^%w_]", "_")
end

---@param lines string[]
---@param fallback string
---@return string[]
local function with_fallback(lines, fallback)
	if #lines > 0 then
		return lines
	end
	return { fallback }
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

---@param bufnr integer|nil
---@param group string
local function highlight_hunks(bufnr, group)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for _, hunk in ipairs(M.state.hunks) do
		local start_line = math.max(1, math.min(hunk.start_line, line_count))
		local end_line = math.max(start_line, math.min(hunk.end_line, line_count))
		for line = start_line, end_line do
			vim.api.nvim_buf_add_highlight(bufnr, ns, group, line - 1, 0, -1)
		end
	end
end

local function apply_highlights()
	highlight_hunks(M.state.local_bufnr, "GitflowConflictLocal")
	highlight_hunks(M.state.base_bufnr, "GitflowConflictBase")
	highlight_hunks(M.state.remote_bufnr, "GitflowConflictRemote")
	highlight_hunks(M.state.merged_bufnr, "GitflowConflictResolved")
end

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
		local message = result_message(result, ("Marked '%s' as resolved"):format(path))
		utils.notify(message, vim.log.levels.INFO)
		if on_resolved then
			on_resolved(path)
		end
	end)
end

---@param choice "local"|"base"|"remote"
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
		"Accept all unresolved hunks from which side?",
		"&Local\n&Base\n&Remote\n&Cancel",
		1
	)
	local choice = nil
	if selection == 1 then
		choice = "local"
	elseif selection == 2 then
		choice = "base"
	elseif selection == 3 then
		choice = "remote"
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

local function teardown_buffers()
	if M.state.local_bufnr then
		ui.buffer.teardown(M.state.local_bufnr)
	end
	if M.state.base_bufnr then
		ui.buffer.teardown(M.state.base_bufnr)
	end
	if M.state.remote_bufnr then
		ui.buffer.teardown(M.state.remote_bufnr)
	end
	if M.state.merged_bufnr then
		ui.buffer.teardown(M.state.merged_bufnr)
	end
end

local function reset_state()
	M.state.active = false
	M.state.path = nil
	M.state.cfg = nil
	M.state.prev_winid = nil
	M.state.prev_tabid = nil
	M.state.tabid = nil
	M.state.local_bufnr = nil
	M.state.base_bufnr = nil
	M.state.remote_bufnr = nil
	M.state.merged_bufnr = nil
	M.state.local_winid = nil
	M.state.base_winid = nil
	M.state.remote_winid = nil
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

	if M.state.tabid and vim.api.nvim_tabpage_is_valid(M.state.tabid) then
		pcall(vim.api.nvim_set_current_tabpage, M.state.tabid)
		pcall(vim.cmd, "tabclose")
	end

	teardown_buffers()

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

---@param side "local"|"base"|"remote"
function M.resolve_current(side)
	apply_resolution(side)
end

function M.resolve_all_from_prompt()
	accept_all_from_side()
end

function M.edit_current_hunk()
	enter_manual_edit()
end

---@param path string
---@param cb fun(err: string|nil, context: table|nil)
local function load_context(path, cb)
	git_conflict.get_version(path, "local", {}, function(local_err, local_lines)
		if local_err then
			cb(local_err, nil)
			return
		end

		git_conflict.get_version(path, "base", {}, function(base_err, base_lines)
			if base_err then
				cb(base_err, nil)
				return
			end

			git_conflict.get_version(path, "remote", {}, function(remote_err, remote_lines)
				if remote_err then
					cb(remote_err, nil)
					return
				end

				local read_err, merged_lines = read_path(path)
				if read_err then
					cb(read_err, nil)
					return
				end

				cb(nil, {
					local_lines = local_lines or {},
					base_lines = base_lines or {},
					remote_lines = remote_lines or {},
					merged_lines = merged_lines or {},
				})
			end)
		end)
	end)
end

---@param opts table
local function configure_windows(opts)
	local top_wins = { opts.local_winid, opts.base_winid, opts.remote_winid }
	for _, winid in ipairs(top_wins) do
		if winid and vim.api.nvim_win_is_valid(winid) then
			vim.api.nvim_set_option_value("scrollbind", true, { win = winid })
			vim.api.nvim_set_option_value("cursorbind", true, { win = winid })
			vim.api.nvim_set_option_value("wrap", false, { win = winid })
		end
	end

	if opts.merged_winid and vim.api.nvim_win_is_valid(opts.merged_winid) then
		vim.api.nvim_set_option_value("scrollbind", false, { win = opts.merged_winid })
		vim.api.nvim_set_option_value("cursorbind", false, { win = opts.merged_winid })
		vim.api.nvim_set_option_value("wrap", false, { win = opts.merged_winid })

		local height = math.max(8, math.floor((vim.o.lines - vim.o.cmdheight) * 0.33))
		vim.api.nvim_win_set_height(opts.merged_winid, height)
	end
end

---@param bufnr integer
local function set_buffer_defaults(bufnr)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
end

---@param bufnr integer
---@param handler fun()
local function map_close(bufnr, handler)
	vim.keymap.set("n", "q", handler, { buffer = bufnr, silent = true, nowait = true })
end

---@param bufnr integer
local function set_top_buffer_options(bufnr)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
end

---@param path string
---@param ctx table
---@param callbacks table
local function open_layout(path, ctx, callbacks)
	local name_key = sanitize(path)
	local local_bufnr = ui.buffer.create(("conflict-local-%s"):format(name_key), {
		filetype = "diff",
		lines = with_fallback(ctx.local_lines, "(local version unavailable)"),
	})
	local base_bufnr = ui.buffer.create(("conflict-base-%s"):format(name_key), {
		filetype = "diff",
		lines = with_fallback(ctx.base_lines, "(base version unavailable)"),
	})
	local remote_bufnr = ui.buffer.create(("conflict-remote-%s"):format(name_key), {
		filetype = "diff",
		lines = with_fallback(ctx.remote_lines, "(remote version unavailable)"),
	})
	local merged_bufnr = ui.buffer.create(("conflict-merged-%s"):format(name_key), {
		filetype = "gitflowconflictmerge",
		lines = ctx.merged_lines,
	})

	set_buffer_defaults(local_bufnr)
	set_buffer_defaults(base_bufnr)
	set_buffer_defaults(remote_bufnr)
	set_buffer_defaults(merged_bufnr)

	set_top_buffer_options(local_bufnr)
	set_top_buffer_options(base_bufnr)
	set_top_buffer_options(remote_bufnr)

	vim.api.nvim_set_option_value("modifiable", true, { buf = merged_bufnr })
	vim.api.nvim_set_option_value("readonly", false, { buf = merged_bufnr })

	local prev_winid = vim.api.nvim_get_current_win()
	local prev_tabid = vim.api.nvim_get_current_tabpage()

	vim.cmd("tabnew")

	local tabid = vim.api.nvim_get_current_tabpage()
	local local_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(local_winid, local_bufnr)

	vim.cmd("vsplit")
	local base_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(base_winid, base_bufnr)

	vim.cmd("vsplit")
	local remote_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(remote_winid, remote_bufnr)

	vim.cmd("split")
	local merged_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(merged_winid, merged_bufnr)
	vim.cmd("wincmd J")
	merged_winid = vim.api.nvim_get_current_win()

	vim.cmd("wincmd =")
	configure_windows({
		local_winid = local_winid,
		base_winid = base_winid,
		remote_winid = remote_winid,
		merged_winid = merged_winid,
	})

	map_close(local_bufnr, M.close)
	map_close(base_bufnr, M.close)
	map_close(remote_bufnr, M.close)
	map_close(merged_bufnr, M.close)

	vim.keymap.set("n", "1", function()
		M.resolve_current("local")
	end, { buffer = merged_bufnr, silent = true, nowait = true })
	vim.keymap.set("n", "2", function()
		M.resolve_current("base")
	end, { buffer = merged_bufnr, silent = true, nowait = true })
	vim.keymap.set("n", "3", function()
		M.resolve_current("remote")
	end, { buffer = merged_bufnr, silent = true, nowait = true })
	vim.keymap.set("n", "a", function()
		M.resolve_all_from_prompt()
	end, { buffer = merged_bufnr, silent = true, nowait = true })
	vim.keymap.set("n", "e", function()
		M.edit_current_hunk()
	end, { buffer = merged_bufnr, silent = true, nowait = true })
	vim.keymap.set("n", "]x", function()
		M.jump(1)
	end, { buffer = merged_bufnr, silent = true, nowait = true })
	vim.keymap.set("n", "[x", function()
		M.jump(-1)
	end, { buffer = merged_bufnr, silent = true, nowait = true })
	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = merged_bufnr, silent = true, nowait = true })

	M.state.active = true
	M.state.path = path
	M.state.cfg = callbacks.cfg
	M.state.prev_winid = prev_winid
	M.state.prev_tabid = prev_tabid
	M.state.tabid = tabid
	M.state.local_bufnr = local_bufnr
	M.state.base_bufnr = base_bufnr
	M.state.remote_bufnr = remote_bufnr
	M.state.merged_bufnr = merged_bufnr
	M.state.local_winid = local_winid
	M.state.base_winid = base_winid
	M.state.remote_winid = remote_winid
	M.state.merged_winid = merged_winid
	M.state.hunks = git_conflict.parse_markers(ctx.merged_lines)
	M.state.prompt_shown = false
	M.state.on_resolved = callbacks.on_resolved
	M.state.on_closed = callbacks.on_closed

	apply_highlights()
	vim.api.nvim_set_current_win(merged_winid)
end

---@param path string
---@param opts table|nil
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

	load_context(normalized, function(err, ctx)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		open_layout(normalized, ctx or {}, callbacks)
	end)
end

---@return boolean
function M.is_open()
	return M.state.active
		and M.state.tabid ~= nil
		and vim.api.nvim_tabpage_is_valid(M.state.tabid)
		and M.state.merged_bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.merged_bufnr)
end

return M
