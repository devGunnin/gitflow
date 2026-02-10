local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")

---@class GitflowBranchPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field line_entries table<integer, GitflowBranchEntry>

local M = {}
local BRANCH_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_branch_hl")

---@type GitflowBranchPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	line_entries = {},
}

---@param result GitflowGitResult
---@param fallback string
---@return string
local function result_message(result, fallback)
	local output = git.output(result)
	if output == "" then
		return fallback
	end
	return output
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("branch", {
			filetype = "gitflowbranch",
			lines = { "Loading branches..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = ui.window.open_split({
		name = "branch",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})

	vim.keymap.set("n", "<CR>", function()
		M.switch_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "c", function()
		M.create_branch()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "d", function()
		M.delete_under_cursor(false)
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "D", function()
		M.delete_under_cursor(true)
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.rename_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "R", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "f", function()
		M.fetch_remotes()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param title string
---@param entries GitflowBranchEntry[]
---@param lines string[]
---@param line_entries table<integer, GitflowBranchEntry>
local function append_section(title, entries, lines, line_entries)
	lines[#lines + 1] = title
	if #entries == 0 then
		lines[#lines + 1] = "  (none)"
		lines[#lines + 1] = ""
		return
	end

	for _, entry in ipairs(entries) do
		local marker = entry.is_current and "*" or " "
		local current_text = entry.is_current and " (current)" or ""
		local line = (" %s %s%s"):format(marker, entry.name, current_text)
		lines[#lines + 1] = line
		line_entries[#lines] = entry
	end
	lines[#lines + 1] = ""
end

---@param entries GitflowBranchEntry[]
local function render(entries)
	local local_entries, remote_entries = git_branch.partition(entries)
	local lines = {
		"Gitflow Branches",
		"",
	}
	local line_entries = {}

	append_section("Local", local_entries, lines, line_entries)
	append_section("Remote", remote_entries, lines, line_entries)

	ui.buffer.update("branch", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, BRANCH_HIGHLIGHT_NS, 0, -1)
	vim.api.nvim_buf_add_highlight(bufnr, BRANCH_HIGHLIGHT_NS, "GitflowTitle", 0, 0, -1)

	for line_no, line in ipairs(lines) do
		if line == "Local" or line == "Remote" then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				BRANCH_HIGHLIGHT_NS,
				"GitflowHeader",
				line_no - 1,
				0,
				-1
			)
		end
	end

	for line_no, entry in pairs(line_entries) do
		local group = nil
		if entry.is_current then
			group = "GitflowBranchCurrent"
		elseif entry.is_remote then
			group = "GitflowBranchRemote"
		end

		if group then
			vim.api.nvim_buf_add_highlight(bufnr, BRANCH_HIGHLIGHT_NS, group, line_no - 1, 0, -1)
		end
	end
end

---@return GitflowBranchEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

function M.refresh()
	git_branch.list({}, function(err, entries)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render(entries or {})
	end)
end

function M.fetch_remotes()
	git_branch.fetch(nil, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(result_message(result, "Fetched remote branches"), vim.log.levels.INFO)
		M.refresh()
	end)
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	M.refresh()
end

function M.switch_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No branch selected", vim.log.levels.WARN)
		return
	end

	if entry.is_current then
		utils.notify(("Already on '%s'"):format(entry.name), vim.log.levels.INFO)
		return
	end

	local function switch_to_entry()
		git_branch.switch(entry, {}, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(result_message(result, ("Switched to %s"):format(entry.name)), vim.log.levels.INFO)
			M.refresh()
		end)
	end

	if entry.is_remote then
		git_branch.fetch(entry.remote, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			switch_to_entry()
		end)
		return
	end

	switch_to_entry()
end

function M.create_branch()
	local selected = entry_under_cursor()
	ui.input.prompt({
		prompt = "New branch name: ",
	}, function(name)
		local branch_name = vim.trim(name)
		if branch_name == "" then
			utils.notify("Branch name cannot be empty", vim.log.levels.WARN)
			return
		end

		local function run_create(base)
			git_branch.create(branch_name, base, {}, function(err, result)
				if err then
					utils.notify(err, vim.log.levels.ERROR)
					return
				end
				utils.notify(
					result_message(result, ("Created branch '%s'"):format(branch_name)),
					vim.log.levels.INFO
				)
				M.refresh()
			end)
		end

		if not selected then
			run_create(nil)
			return
		end

		local confirmed = ui.input.confirm(
			("Create '%s' from '%s'?"):format(branch_name, selected.name),
			{ choices = { "&Yes", "&No" }, default_choice = 1 }
		)
		if confirmed then
			run_create(selected.name)
			return
		end
		run_create(nil)
	end)
end

---@param force boolean
function M.delete_under_cursor(force)
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No branch selected", vim.log.levels.WARN)
		return
	end

	if entry.is_remote then
		utils.notify("Remote branch deletion is not supported in this panel", vim.log.levels.WARN)
		return
	end
	if entry.is_current then
		utils.notify("Cannot delete the current branch", vim.log.levels.WARN)
		return
	end

	local function run_delete(delete_force)
		git_branch.delete(entry.name, delete_force, {}, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				result_message(result, ("Deleted branch '%s'"):format(entry.name)),
				vim.log.levels.INFO
			)
			M.refresh()
		end)
	end

	if force then
		local confirmed = ui.input.confirm(
			("Force delete branch '%s'?"):format(entry.name),
			{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
		)
		if confirmed then
			run_delete(true)
		end
		return
	end

	git_branch.list_merged({}, function(err, merged)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		local is_merged = merged and merged[entry.name] == true
		if is_merged then
			run_delete(false)
			return
		end

		local confirmed = ui.input.confirm(
			("Branch '%s' is not merged. Force delete?"):format(entry.name),
			{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
		)
		if confirmed then
			run_delete(true)
		end
	end)
end

function M.rename_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No branch selected", vim.log.levels.WARN)
		return
	end
	if entry.is_remote then
		utils.notify("Remote branches cannot be renamed", vim.log.levels.WARN)
		return
	end

	ui.input.prompt({
		prompt = ("Rename branch '%s' to: "):format(entry.name),
		default = entry.name,
	}, function(new_name)
		local trimmed = vim.trim(new_name)
		if trimmed == "" then
			utils.notify("Branch name cannot be empty", vim.log.levels.WARN)
			return
		end
		if trimmed == entry.name then
			utils.notify("Branch name unchanged", vim.log.levels.INFO)
			return
		end

		git_branch.rename(entry.name, trimmed, {}, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				result_message(result, ("Renamed '%s' to '%s'"):format(entry.name, trimmed)),
				vim.log.levels.INFO
			)
			M.refresh()
		end)
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("branch")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("branch")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
