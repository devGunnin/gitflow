local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_stash = require("gitflow.git.stash")
local git_branch = require("gitflow.git.branch")
local status_panel = require("gitflow.panels.status")

---@class GitflowStashPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowStashEntry>
---@field cfg GitflowConfig|nil

local M = {}

---@type GitflowStashPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
}

local function refresh_status_panel_if_open()
	if status_panel.is_open() then
		status_panel.refresh()
	end
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("stash", {
			filetype = "gitflowstash",
			lines = { "Loading stash list..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = ui.window.open_split({
		name = "stash",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})

	vim.keymap.set("n", "P", function()
		M.pop_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "D", function()
		M.drop_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "S", function()
		M.push_with_prompt()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowStashEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local lines = {
		"Gitflow Stash",
		"P=Pop  D=Drop  S=Stash  r=Refresh  q=Close",
		"",
	}
	local line_entries = {}

	if #entries == 0 then
		lines[#lines + 1] = "(no stash entries)"
	else
		for _, entry in ipairs(entries) do
			lines[#lines + 1] = ("%s %s"):format(entry.ref, entry.description)
			line_entries[#lines] = entry
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ("Current branch: %s"):format(current_branch)

	ui.buffer.update("stash", lines)
	M.state.line_entries = line_entries
end

---@return GitflowStashEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param result GitflowGitResult
---@return string
local function output_or_default(result)
	local output = git.output(result)
	if output == "" then
		return "Completed stash operation"
	end
	return output
end

---@param output string
---@return boolean
local function output_mentions_no_local_changes(output)
	return output:lower():find("no local changes to save", 1, true) ~= nil
end

---@param result GitflowGitResult
local function notify_push_result(result)
	local output = output_or_default(result)
	if output_mentions_no_local_changes(output) then
		utils.notify(output, vim.log.levels.WARN)
		return
	end
	utils.notify(output, vim.log.levels.INFO)
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	M.refresh()
end

function M.push_with_prompt()
	vim.ui.input({
		prompt = "Stash message (optional): ",
	}, function(input)
		if input == nil then
			return
		end

		local message = vim.trim(input)
		if message == "" then
			message = nil
		end

		git_stash.push({ message = message }, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			notify_push_result(result)
			M.refresh()
			refresh_status_panel_if_open()
		end)
	end)
end

function M.refresh()
	git_branch.current({}, function(_, branch)
		git_stash.list({}, function(err, entries)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			render(entries, branch or "(unknown)")
		end)
	end)
end

function M.pop_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No stash entry selected", vim.log.levels.WARN)
		return
	end

	git_stash.pop({ index = entry.index }, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(output_or_default(result), vim.log.levels.INFO)
		M.refresh()
	end)
end

function M.drop_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No stash entry selected", vim.log.levels.WARN)
		return
	end

	local confirmed = vim.fn.confirm(("Drop %s?"):format(entry.ref), "&Yes\n&No", 2) == 1
	if not confirmed then
		return
	end

	git_stash.drop(entry.index, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(output_or_default(result), vim.log.levels.INFO)
		M.refresh()
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("stash")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("stash")
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
