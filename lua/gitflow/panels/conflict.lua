local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_conflict = require("gitflow.git.conflict")
local conflict_view = require("gitflow.ui.conflict")
local ui_render = require("gitflow.ui.render")
local config = require("gitflow.config")

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
---@field auto_continue_prompted boolean
---@field auto_continue_operation GitflowConflictOperation|nil
---@field prompt_when_resolved boolean

local M = {}
local CONFLICT_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_conflict_hl")
local CONFLICT_FLOAT_TITLE = "Gitflow Conflicts"
local CONFLICT_FLOAT_FOOTER_HINTS = {
	{ action = "open", default = "<CR>", label = "open 3-way" },
	{ action = "refresh", default = "r", label = "refresh" },
	{ action = "continue", default = "C", label = "continue" },
	{ action = "abort", default = "A", label = "abort" },
	{ action = "close", default = "q", label = "close" },
}

---@type GitflowConflictPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	files = {},
	line_entries = {},
	active_operation = nil,
	pending_open_path = nil,
	auto_continue_prompted = false,
	auto_continue_operation = nil,
	prompt_when_resolved = false,
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

---@param operation GitflowConflictOperation|nil
---@return boolean
local function supports_auto_continue(operation)
	return operation == "merge" or operation == "rebase"
end

local function reset_auto_continue_prompt()
	M.state.auto_continue_prompted = false
	M.state.auto_continue_operation = nil
end

---@param cfg GitflowConfig
---@return string
local function conflict_float_footer(cfg)
	return ui_render.resolve_panel_key_hints(
		cfg, "conflict", CONFLICT_FLOAT_FOOTER_HINTS
	)
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

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "conflict",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = CONFLICT_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and conflict_float_footer(cfg) or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "conflict",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	local pk = function(action, default)
		return config.resolve_panel_key(
			cfg, "conflict", action, default
		)
	end

	vim.keymap.set("n", pk("open", "<CR>"), function()
		M.open_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", pk("refresh", "r"), function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("refresh_alias", "R"), function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("continue", "C"), function()
		M.continue_operation()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("abort", "A"), function()
		M.abort_operation()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("close", "q"), function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param files GitflowConflictFileEntry[]
---@param operation GitflowConflictOperation|nil
local function render(files, operation)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Conflicts", render_opts)
	local header_line_count = #lines
	lines[#lines + 1] = ("Active operation: %s"):format(operation_label(operation))
	lines[#lines + 1] = ("Unresolved files: %d"):format(#files)
	lines[#lines + 1] = ""
	local line_entries = {}

	if #files == 0 then
		lines[#lines + 1] = ui_render.empty()
	else
		for _, item in ipairs(files) do
			local suffix = (" (%d hunks)"):format(item.hunk_count)
			lines[#lines + 1] = ui_render.entry(("%s%s"):format(item.path, suffix))
			line_entries[#lines] = item

			if item.marker_error then
				lines[#lines + 1] = ("    ! %s"):format(item.marker_error)
			end
		end
	end

	ui.buffer.update("conflict", lines)
	M.state.files = files
	M.state.line_entries = line_entries
	M.state.active_operation = operation

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local entry_highlights = {}
	entry_highlights[header_line_count + 1] = "GitflowHeader"
	entry_highlights[header_line_count + 2] = "GitflowHeader"

	-- File entry lines
	for line_no, _ in pairs(line_entries) do
		entry_highlights[line_no] = "GitflowConflictBase"
	end

	-- Error marker lines
	for line_no, line in ipairs(lines) do
		if vim.startswith(line, "    ! ") then
			entry_highlights[line_no] = "GitflowConflictRemote"
		end
	end

	ui_render.apply_panel_highlights(bufnr, CONFLICT_HIGHLIGHT_NS, lines, {
		entry_highlights = entry_highlights,
	})
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
			M.state.prompt_when_resolved = true
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

local function maybe_prompt_auto_continue()
	local operation = M.state.active_operation
	if not M.state.prompt_when_resolved then
		return
	end

	if #M.state.files ~= 0 then
		return
	end

	if not supports_auto_continue(operation) then
		M.state.prompt_when_resolved = false
		reset_auto_continue_prompt()
		return
	end

	if M.state.auto_continue_prompted and M.state.auto_continue_operation == operation then
		return
	end

	M.state.prompt_when_resolved = false
	M.state.auto_continue_prompted = true
	M.state.auto_continue_operation = operation

	local confirmed = ui.input.confirm(
		("All conflicts are resolved. Continue %s now?"):format(operation_label(operation)),
		{ choices = { "&Continue", "&Later" }, default_choice = 1 }
	)
	if not confirmed then
		return
	end

	M.continue_operation({
		skip_confirm = true,
		reset_prompt_on_error = true,
		ignore_missing_operation = true,
		expected_operation = operation,
	})
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
			maybe_prompt_auto_continue()
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

---@param opts table|nil
function M.continue_operation(opts)
	local options = opts or {}

	if #M.state.files > 0 then
		utils.notify("Resolve and stage all conflicts before continuing", vim.log.levels.WARN)
		return
	end

	if not options.skip_confirm then
		local confirmed = ui.input.confirm(
			("Run %s --continue?"):format(operation_label(M.state.active_operation)),
			{ choices = { "&Yes", "&No" }, default_choice = 1 }
		)
		if not confirmed then
			return
		end
	end

	local function on_continue(err, operation, result)
		if err then
			if options.ignore_missing_operation and err == "No active operation to continue" then
				M.refresh()
				return
			end
			if options.reset_prompt_on_error then
				reset_auto_continue_prompt()
			end
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			result_message(result, ("%s --continue completed"):format(operation or "operation")),
			vim.log.levels.INFO
		)
		M.state.prompt_when_resolved = false
		M.refresh()
	end

	local function run_continue()
		if options.expected_operation then
			git_conflict.continue_operation_for(options.expected_operation, {}, on_continue)
			return
		end
		git_conflict.continue_operation({}, on_continue)
	end

	if options.expected_operation then
		git_conflict.active_operation({}, function(active_err, active_operation)
			if active_err then
				utils.notify(active_err, vim.log.levels.ERROR)
				return
			end
			if active_operation ~= options.expected_operation then
				M.refresh()
				return
			end
			run_continue()
		end)
		return
	end

	run_continue()
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
	M.state.auto_continue_prompted = false
	M.state.auto_continue_operation = nil
	M.state.prompt_when_resolved = false
end

---@return boolean
function M.is_open()
	return M.state.winid ~= nil
		and vim.api.nvim_win_is_valid(M.state.winid)
		and M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
