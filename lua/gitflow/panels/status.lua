local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_log = require("gitflow.git.log")
local git_status = require("gitflow.git.status")
local git_branch = require("gitflow.git.branch")
local conflict_panel = require("gitflow.panels.conflict")

---@class GitflowStatusPanelOpts
---@field on_commit fun()|nil
---@field on_open_diff fun(request: table, entry: table|nil)|nil

---@class GitflowStatusFileLineEntry
---@field kind "file"
---@field entry GitflowStatusEntry
---@field diff_staged boolean

---@class GitflowStatusCommitLineEntry
---@field kind "commit"
---@field entry GitflowLogEntry
---@field pushable boolean

---@alias GitflowStatusLineEntry GitflowStatusFileLineEntry|GitflowStatusCommitLineEntry

---@class GitflowStatusUpstream
---@field full_name string
---@field remote string
---@field branch string

---@class GitflowStatusPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field opts GitflowStatusPanelOpts
---@field line_entries table<integer, GitflowStatusLineEntry>
---@field active boolean

local M = {}
local STATUS_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_status_hl")
local STATUS_FLOAT_TITLE = "Gitflow Status"
local STATUS_FLOAT_FOOTER =
	"s stage  u unstage  a stage all  A unstage all  cc commit  dd diff"
	.. "  cx conflicts  p push  X revert  r refresh  q close"

---@type GitflowStatusPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	opts = {},
	line_entries = {},
	active = false,
}

---@param title string
---@param entries GitflowStatusEntry[]
---@param lines string[]
---@param line_entries table<integer, GitflowStatusLineEntry>
---@param diff_staged boolean
local function append_file_section(title, entries, lines, line_entries, diff_staged)
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
			kind = "file",
			entry = entry,
			diff_staged = diff_staged,
		}
	end
	lines[#lines + 1] = ""
end

---@param title string
---@param entries GitflowLogEntry[]
---@param lines string[]
---@param line_entries table<integer, GitflowStatusLineEntry>
---@param pushable boolean|table<string, boolean>
local function append_commit_section(title, entries, lines, line_entries, pushable)
	lines[#lines + 1] = title
	if #entries == 0 then
		lines[#lines + 1] = "  (none)"
		lines[#lines + 1] = ""
		return
	end

	for _, entry in ipairs(entries) do
		local entry_pushable = false
		if type(pushable) == "boolean" then
			entry_pushable = pushable
		elseif type(pushable) == "table" then
			entry_pushable = pushable[entry.sha] == true
		end

		lines[#lines + 1] = ("  %s"):format(entry.summary)
		line_entries[#lines] = {
			kind = "commit",
			entry = entry,
			pushable = entry_pushable,
		}
	end
	lines[#lines + 1] = ""
end

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = git.output(result)
	if output == "" then
		return ("git %s failed"):format(action)
	end
	return ("git %s failed: %s"):format(action, output)
end

---@param output string
---@return boolean
local function output_mentions_no_upstream(output)
	local normalized = output:lower()
	if normalized:find("no upstream configured", 1, true) then
		return true
	end
	if normalized:find("no upstream", 1, true) then
		return true
	end
	if normalized:find("does not point to a branch", 1, true) then
		return true
	end
	return false
end

---@param cb fun(err: string|nil, upstream: GitflowStatusUpstream|nil)
local function resolve_upstream(cb)
	git.git({
		"rev-parse",
		"--abbrev-ref",
		"--symbolic-full-name",
		"@{upstream}",
	}, {}, function(result)
		if result.code ~= 0 then
			local output = git.output(result)
			if output_mentions_no_upstream(output) then
				cb(nil, nil)
				return
			end
			cb(error_from_result(result, "rev-parse @{upstream}"), nil)
			return
		end

		local full_name = vim.trim(result.stdout or "")
		if full_name == "" then
			cb(nil, nil)
			return
		end

		local remote, branch = full_name:match("^([^/]+)/(.+)$")
		if not remote or not branch then
			cb(("Could not parse upstream branch from '%s'"):format(full_name), nil)
			return
		end

		cb(nil, {
			full_name = full_name,
			remote = remote,
			branch = branch,
		})
	end)
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

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "status",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = STATUS_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and STATUS_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
				M.state.active = false
			end,
		})
	else
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
	end

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

	vim.keymap.set("n", "cx", function()
		M.open_conflict_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "p", function()
		M.push_under_cursor()
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

---@return GitflowStatusFileLineEntry|nil
local function file_entry_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry or line_entry.kind ~= "file" then
		return nil
	end
	return line_entry
end

---@return GitflowStatusCommitLineEntry|nil
local function commit_entry_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry or line_entry.kind ~= "commit" then
		return nil
	end
	return line_entry
end

---@param grouped GitflowStatusGroups
---@param outgoing_entries GitflowLogEntry[]
---@param incoming_entries GitflowLogEntry[]
---@param upstream_name string|nil
---@param current_branch string
local function render(grouped, outgoing_entries, incoming_entries, upstream_name, current_branch)
	local lines = {
		"Gitflow Status",
		"",
	}
	local line_entries = {}

	append_file_section(
		("Staged (%d)"):format(#grouped.staged),
		grouped.staged,
		lines,
		line_entries,
		true
	)
	append_file_section(
		("Unstaged (%d)"):format(#grouped.unstaged),
		grouped.unstaged,
		lines,
		line_entries,
		false
	)
	append_file_section(
		("Untracked (%d)"):format(#grouped.untracked),
		grouped.untracked,
		lines,
		line_entries,
		false
	)

	if upstream_name then
		if #outgoing_entries > 0 then
			append_commit_section(
				"Commit History (oldest -> newest)",
				outgoing_entries,
				lines,
				line_entries,
				true
			)
		end
		local outgoing_title = ("Outgoing (oldest -> newest, not on %s)"):format(upstream_name)
		append_commit_section(outgoing_title, outgoing_entries, lines, line_entries, true)
		local incoming_title = ("Incoming (oldest -> newest, only on %s)"):format(upstream_name)
		append_commit_section(incoming_title, incoming_entries, lines, line_entries, false)
	else
		lines[#lines + 1] = "Outgoing / Incoming"
		lines[#lines + 1] = "  (upstream branch is not configured)"
		lines[#lines + 1] = ""
	end

	lines[#lines + 1] = ("Current branch: %s"):format(current_branch)

	ui.buffer.update("status", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, STATUS_HIGHLIGHT_NS, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, STATUS_HIGHLIGHT_NS, "GitflowTitle", 0, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, STATUS_HIGHLIGHT_NS, "GitflowFooter", #lines - 1, 0, -1)

	for line_no, line in ipairs(lines) do
		if vim.startswith(line, "Staged")
			or vim.startswith(line, "Unstaged")
			or vim.startswith(line, "Untracked")
			or vim.startswith(line, "Outgoing")
			or vim.startswith(line, "Incoming")
			or vim.startswith(line, "Commit History")
		then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				STATUS_HIGHLIGHT_NS,
				"GitflowHeader",
				line_no - 1,
				0,
				-1
			)
		end
	end

	for line_no, entry in pairs(line_entries) do
		if entry.kind ~= "file" then
			goto continue
		end

		local group = "GitflowUnstaged"
		if entry.entry.untracked then
			group = "GitflowUntracked"
		elseif entry.diff_staged then
			group = "GitflowStaged"
		end

		vim.api.nvim_buf_add_highlight(bufnr, STATUS_HIGHLIGHT_NS, group, line_no - 1, 0, -1)

		::continue::
	end
end

---@param err string|nil
local function notify_if_error(err)
	if err then
		utils.notify(err, vim.log.levels.ERROR)
		return true
	end
	return false
end

local function emit_post_operation()
	vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })
end

---@param operation fun(cb: fun(err: string|nil))
local function run_status_operation(operation)
	operation(function(err)
		if notify_if_error(err) then
			return
		end
		emit_post_operation()
		M.refresh()
	end)
end

---@param cfg GitflowConfig
---@param opts GitflowStatusPanelOpts|nil
function M.open(cfg, opts)
	M.state.cfg = cfg
	M.state.opts = opts or {}
	M.state.active = true

	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	git_branch.current({}, function(_, branch)
		git_status.fetch({}, function(err, _, grouped)
			if notify_if_error(err) then
				return
			end

			local current_branch = branch or "(unknown)"

			resolve_upstream(function(upstream_err, upstream)
				if notify_if_error(upstream_err) then
					return
				end

				if not upstream then
					render(grouped, {}, {}, nil, current_branch)
					return
				end

				git_log.list({
					count = cfg.git.log.count,
					format = cfg.git.log.format,
					reverse = true,
					range = ("%s..HEAD"):format(upstream.full_name),
				}, function(outgoing_err, outgoing_entries)
					if notify_if_error(outgoing_err) then
						return
					end

					git_log.list({
						count = cfg.git.log.count,
						format = cfg.git.log.format,
						reverse = true,
						range = ("HEAD..%s"):format(upstream.full_name),
					}, function(incoming_err, incoming_entries)
						if notify_if_error(incoming_err) then
							return
						end

						render(
							grouped,
							outgoing_entries or {},
							incoming_entries or {},
							upstream.full_name,
							current_branch
						)
					end)
				end)
			end)
		end)
	end)
end

function M.stage_under_cursor()
	local line_entry = file_entry_under_cursor()
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
	local line_entry = file_entry_under_cursor()
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
		utils.notify("No item selected", vim.log.levels.WARN)
		return
	end

	if M.state.opts.on_open_diff then
		if line_entry.kind == "file" then
			local entry = line_entry.entry
			M.state.opts.on_open_diff({
				path = entry.path,
				staged = line_entry.diff_staged,
			}, entry)
			return
		end

		local commit = line_entry.entry
		M.state.opts.on_open_diff({
			commit = commit.sha,
		}, commit)
		return
	end

	utils.notify("Diff handler is not configured", vim.log.levels.WARN)
end

function M.push_under_cursor()
	local line_entry = commit_entry_under_cursor()
	if not line_entry or not line_entry.pushable then
		utils.notify("No outgoing commit selected", vim.log.levels.WARN)
		return
	end

	resolve_upstream(function(err, upstream)
		if notify_if_error(err) then
			return
		end
		if not upstream then
			utils.notify("No upstream branch configured for current branch", vim.log.levels.WARN)
			return
		end

		local commit = line_entry.entry
		local confirmed = ui.input.confirm(
			("Push commits through %s to %s?"):format(commit.short_sha, upstream.full_name),
			{ choices = { "&Push", "&Cancel" }, default_choice = 2 }
		)
		if not confirmed then
			return
		end

		local refspec = ("%s:refs/heads/%s"):format(commit.sha, upstream.branch)
		git.git({ "push", upstream.remote, refspec }, {}, function(push_result)
			if push_result.code ~= 0 then
				utils.notify(error_from_result(push_result, "push"), vim.log.levels.ERROR)
				return
			end

			local output = git.output(push_result)
			if output == "" then
				output = ("Pushed through %s"):format(commit.short_sha)
			end
			utils.notify(output, vim.log.levels.INFO)
			emit_post_operation()
			M.refresh()
		end)
	end)
end

function M.revert_under_cursor()
	local line_entry = file_entry_under_cursor()
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
		emit_post_operation()
		M.refresh()
	end)
end

---@param entry GitflowStatusEntry
---@return boolean
local function is_conflicted(entry)
	return entry.index_status == "U" or entry.worktree_status == "U"
end

function M.open_conflict_under_cursor()
	local line_entry = file_entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	local entry = line_entry.entry
	if not is_conflicted(entry) then
		utils.notify(("'%s' is not in a conflict state"):format(entry.path), vim.log.levels.WARN)
		return
	end

	if not M.state.cfg then
		utils.notify("Status panel is not configured", vim.log.levels.WARN)
		return
	end

	conflict_panel.open(M.state.cfg, { path = entry.path })
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
	M.state.cfg = nil
	M.state.line_entries = {}
	M.state.active = false
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
