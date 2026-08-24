local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_conflict = require("gitflow.git.conflict")
local conflict_view = require("gitflow.ui.conflict")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local icons = require("gitflow.icons")

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
---@field request_id integer

local M = {}

---@type GitflowConflictPanelState
M.state = {
	cfg = nil,
	files = {},
	line_entries = {},
	active_operation = nil,
	pending_open_path = nil,
	auto_continue_prompted = false,
	auto_continue_operation = nil,
	prompt_when_resolved = false,
}

local P = panel.new({
	name = "conflict",
	title = "Gitflow Conflicts",
	filetype = "gitflowconflict",
	loading = "Loading conflicts…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "open resolver", essential = true, run = function()
			M.open_under_cursor()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "C", desc = "continue", essential = true, run = function()
			M.continue_operation()
		end },
		{ key = "X", desc = "abort", destructive = true, run = function()
			M.abort_operation()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

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

local function render_loading()
	P:render_loading("Scanning for conflicts…")
end

---@param message string
local function render_error(message)
	P:render_error("Could not list conflicts", {
		detail = message,
		hint = "Press r to retry \u{b7} q to close",
	})
end

---@param files GitflowConflictFileEntry[]
---@param operation GitflowConflictOperation|nil
local function render(files, operation)
	local B = P:begin_render()

	-- Summary bar: active operation + unresolved count. When everything is
	-- resolved the count flips to an "all resolved" affordance in the ok accent.
	local op = operation_label(operation)
	local resolved = #files == 0
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("ui", "merge") .. "  ", "GitflowSectionIcon" },
		{ op ~= "none" and (op .. " in progress") or "No active operation",
			"GitflowSectionTitle" },
		{ components.separators.field, nil },
		{
			resolved and (icons.get("git_state", "staged") .. " all resolved")
				or ("%s %d unresolved"):format(
					icons.get("git_state", "conflict"), #files
				),
			resolved and "GitflowReviewApproved" or "GitflowConflictRemote",
		},
	})
	B:blank()

	components.section(
		B,
		icons.get("git_state", "conflict"),
		("Conflicted files (%d)"):format(#files)
	)

	local line_entries = {}
	if #files == 0 then
		if op ~= "none" then
			components.empty(B, "All conflicts resolved", {
				icon = icons.get("git_state", "staged"),
				hint = ("Press C to continue the %s, or A to abort."):format(op),
			})
		else
			components.empty(B, "No conflicts", {
				icon = icons.get("git_state", "staged"),
				hint = "Your working tree has no unmerged paths.",
			})
		end
	else
		for _, item in ipairs(files) do
			local line_no = B:push({
				{ components.spacing.edge, nil },
				{ icons.get("git_state", "conflict") .. "  ", "GitflowConflictRemote" },
				{ item.path, "GitflowCardTitle" },
				{ ("   (%d hunk%s)"):format(
					item.hunk_count, item.hunk_count == 1 and "" or "s"
				), "GitflowMeta" },
			})
			line_entries[line_no] = item

			if item.marker_error then
				B:push({
					{ components.spacing.indent .. components.spacing.edge, nil },
					{ icons.get("ui", "error") .. " ", "GitflowStateErrorIcon" },
					{ item.marker_error, "GitflowStateError" },
				})
			end
		end
	end

	P:push_hints(B)

	M.state.files = files
	M.state.active_operation = operation
	if P:paint(B) then
		M.state.line_entries = line_entries
	end
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
	if not P:ensure_window(cfg) then
		return
	end
	render_loading()
	M.refresh()
end

function M.refresh()
	local request_id = P:next_request()
	git_conflict.active_operation({}, function(operation_err, operation)
		if not P:is_active(request_id) then
			return
		end
		if operation_err then
			utils.notify(operation_err, vim.log.levels.WARN)
		end

		git_conflict.list({}, function(err, paths)
			if not P:is_active(request_id) then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				render_error(err)
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

	P:close()
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
	return P:has_window() and P:is_open()
end

return M
