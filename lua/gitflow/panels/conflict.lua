local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_conflict = require("gitflow.git.conflict")
local conflict_view = require("gitflow.ui.conflict")

---@class GitflowConflictFileEntry
---@field path string
---@field hunk_count integer
---@field marker_error string|nil

---@class GitflowConflictPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field files GitflowConflictFileEntry[]
---@field line_entries table<integer, GitflowConflictFileEntry>
---@field active_operation GitflowConflictOperation|nil
---@field pending_open_path string|nil

local M = {}

---@type GitflowConflictPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	files = {},
	line_entries = {},
	active_operation = nil,
	pending_open_path = nil,
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

---@param operation GitflowConflictOperation|nil
---@return string
local function operation_label(operation)
	if operation == "merge" then
		return "merge"
	end
	if operation == "rebase" then
		return "rebase"
	end
	if operation == "cherry-pick" then
		return "cherry-pick"
	end
	return "none"
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("conflict", {
			filetype = "gitflowconflict",
			lines = { "Loading conflicts..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = ui.window.open_split({
		name = "conflict",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})

	vim.keymap.set("n", "<CR>", function()
		M.open_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "R", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "C", function()
		M.continue_operation()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "A", function()
		M.abort_operation()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param files GitflowConflictFileEntry[]
---@param operation GitflowConflictOperation|nil
local function render(files, operation)
	local lines = {
		"Gitflow Conflicts",
		"",
		("Active operation: %s"):format(operation_label(operation)),
		("Unresolved files: %d"):format(#files),
		"",
	}
	local line_entries = {}

	if #files == 0 then
		lines[#lines + 1] = "  (none)"
	else
		for _, item in ipairs(files) do
			local suffix = (" (%d hunks)"):format(item.hunk_count)
			lines[#lines + 1] = ("  %s%s"):format(item.path, suffix)
			line_entries[#lines] = item

			if item.marker_error then
				lines[#lines + 1] = ("    ! %s"):format(item.marker_error)
			end
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "<CR>: open 3-way view  r/R: refresh"
	lines[#lines + 1] = "C: continue operation  A: abort operation  q: quit"

	ui.buffer.update("conflict", lines)
	M.state.files = files
	M.state.line_entries = line_entries
	M.state.active_operation = operation
end

---@return GitflowConflictFileEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param path string
---@return GitflowConflictFileEntry|nil
local function file_entry(path)
	for _, item in ipairs(M.state.files) do
		if item.path == path then
			return item
		end
	end
	return nil
end

---@param path string
local function open_for_path(path)
	local item = file_entry(path)
	if not item then
		utils.notify(("'%s' is not currently listed as conflicted"):format(path), vim.log.levels.WARN)
		return
	end

	conflict_view.open(path, {
		cfg = M.state.cfg,
		on_resolved = function()
			M.refresh()
		end,
		on_closed = function()
			M.refresh()
		end,
	})
end

local function consume_pending_open()
	local path = M.state.pending_open_path
	if not path then
		return
	end
	M.state.pending_open_path = nil
	open_for_path(path)
end

---@param cfg GitflowConfig
---@param opts table|nil
function M.open(cfg, opts)
	M.state.cfg = cfg
	M.state.pending_open_path = opts and opts.path or nil
	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	git_conflict.active_operation({}, function(operation_err, operation)
		if operation_err then
			utils.notify(operation_err, vim.log.levels.WARN)
		end

		git_conflict.list({}, function(err, paths)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end

			local files = {}
			for _, path in ipairs(paths or {}) do
				local marker_err, hunks = git_conflict.read_markers(path)
				files[#files + 1] = {
					path = path,
					hunk_count = #hunks,
					marker_error = marker_err,
				}
			end
			render(files, operation)
			consume_pending_open()
		end)
	end)
end

function M.open_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No conflicted file selected", vim.log.levels.WARN)
		return
	end
	open_for_path(entry.path)
end

function M.open_path(path)
	if not M.state.cfg then
		return
	end
	M.state.pending_open_path = path
	M.refresh()
end

function M.continue_operation()
	if #M.state.files > 0 then
		utils.notify("Resolve and stage all conflicts before continuing", vim.log.levels.WARN)
		return
	end

	local confirmed = ui.input.confirm(
		("Run %s --continue?"):format(operation_label(M.state.active_operation)),
		{ choices = { "&Continue", "&Cancel" }, default_choice = 1 }
	)
	if not confirmed then
		return
	end

	git_conflict.continue_operation({}, function(err, operation, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			result_message(result, ("%s --continue completed"):format(operation or "operation")),
			vim.log.levels.INFO
		)
		M.refresh()
	end)
end

function M.abort_operation()
	local confirmed = ui.input.confirm(
		("Abort active %s operation?"):format(operation_label(M.state.active_operation)),
		{ choices = { "&Abort", "&Cancel" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	git_conflict.abort_operation({}, function(err, operation, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			result_message(result, ("%s --abort completed"):format(operation or "operation")),
			vim.log.levels.INFO
		)
		if conflict_view.is_open() then
			conflict_view.close()
		end
		M.refresh()
	end)
end

function M.close()
	if conflict_view.is_open() then
		conflict_view.close()
	end

	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("conflict")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("conflict")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.cfg = nil
	M.state.files = {}
	M.state.line_entries = {}
	M.state.active_operation = nil
	M.state.pending_open_path = nil
end

---@return boolean
function M.is_open()
	return M.state.winid ~= nil
		and vim.api.nvim_win_is_valid(M.state.winid)
		and M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
