local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_status = require("gitflow.git.status")

---@class GitflowStatusPanelOpts
---@field on_commit fun()|nil
---@field on_open_diff fun(request: table, entry: GitflowStatusEntry)|nil

---@class GitflowStatusLineEntry
---@field entry GitflowStatusEntry
---@field diff_staged boolean

---@class GitflowStatusPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field opts GitflowStatusPanelOpts
---@field line_entries table<integer, GitflowStatusLineEntry>
---@field active boolean

local M = {}

---@type GitflowStatusPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	opts = {},
	line_entries = {},
	active = false,
}

---@param title string
---@param entries GitflowStatusEntry[]
---@param lines string[]
---@param line_entries table<integer, GitflowStatusLineEntry>
---@param diff_staged boolean
local function append_section(title, entries, lines, line_entries, diff_staged)
	lines[#lines + 1] = title
	if #entries == 0 then
		lines[#lines + 1] = "  (none)"
		lines[#lines + 1] = ""
		return
	end

	for _, entry in ipairs(entries) do
		local status = entry.index_status .. entry.worktree_status
		local line = ("  %s  %s"):format(status, entry.path)
		lines[#lines + 1] = line
		line_entries[#lines] = {
			entry = entry,
			diff_staged = diff_staged,
		}
	end
	lines[#lines + 1] = ""
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("status", {
			filetype = "gitflowstatus",
			lines = { "Loading git status..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = ui.window.open_split({
		name = "status",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
			M.state.active = false
		end,
	})

	vim.keymap.set("n", "s", function()
		M.stage_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "u", function()
		M.unstage_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "a", function()
		M.stage_all()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "A", function()
		M.unstage_all()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "cc", function()
		if M.state.opts.on_commit then
			M.state.opts.on_commit()
		else
			utils.notify("Commit handler is not configured", vim.log.levels.WARN)
		end
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "dd", function()
		M.open_diff_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "X", function()
		M.revert_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@return GitflowStatusLineEntry|nil
local function entry_under_cursor()
	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	if vim.api.nvim_get_current_buf() ~= bufnr then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	return M.state.line_entries[cursor[1]]
end

---@param grouped GitflowStatusGroups
local function render(grouped)
	local lines = {
		"Gitflow Status",
		"",
	}
	local line_entries = {}

	append_section("Staged", grouped.staged, lines, line_entries, true)
	append_section("Unstaged", grouped.unstaged, lines, line_entries, false)
	append_section("Untracked", grouped.untracked, lines, line_entries, false)

	ui.buffer.update("status", lines)
	M.state.line_entries = line_entries
end

---@param err string|nil
local function notify_if_error(err)
	if err then
		utils.notify(err, vim.log.levels.ERROR)
		return true
	end
	return false
end

---@param operation fun(cb: fun(err: string|nil))
local function run_status_operation(operation)
	operation(function(err)
		if notify_if_error(err) then
			return
		end
		M.refresh()
	end)
end

---@param cfg GitflowConfig
---@param opts GitflowStatusPanelOpts|nil
function M.open(cfg, opts)
	M.state.opts = opts or {}
	M.state.active = true

	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	git_status.fetch({}, function(err, _, grouped)
		if notify_if_error(err) then
			return
		end
		render(grouped)
	end)
end

function M.stage_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	run_status_operation(function(done)
		local entry = line_entry.entry
		git_status.stage_file(entry.path, {}, function(err)
			done(err)
		end)
	end)
end

function M.unstage_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	run_status_operation(function(done)
		local entry = line_entry.entry
		git_status.unstage_file(entry.path, {}, function(err)
			done(err)
		end)
	end)
end

function M.stage_all()
	run_status_operation(function(done)
		git_status.stage_all({}, function(err)
			done(err)
		end)
	end)
end

function M.unstage_all()
	run_status_operation(function(done)
		git_status.unstage_all({}, function(err)
			done(err)
		end)
	end)
end

function M.open_diff_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	if M.state.opts.on_open_diff then
		local entry = line_entry.entry
		M.state.opts.on_open_diff({
			path = entry.path,
			staged = line_entry.diff_staged,
		}, entry)
		return
	end

	utils.notify("Diff handler is not configured", vim.log.levels.WARN)
end

function M.revert_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	local entry = line_entry.entry
	local confirmed = ui.input.confirm(
		("Revert all uncommitted changes for '%s'?"):format(entry.path),
		{ choices = { "&Revert", "&Cancel" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	git_status.revert_file(entry.path, { untracked = entry.untracked }, function(err)
		if notify_if_error(err) then
			return
		end
		utils.notify(("Reverted changes in '%s'"):format(entry.path), vim.log.levels.INFO)
		M.refresh()
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("status")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("status")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.active = false
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
