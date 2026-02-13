local ui = require("gitflow.ui")
local ui_render = require("gitflow.ui.render")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_stash = require("gitflow.git.stash")

---@class GitflowStashPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowStashEntry>
---@field cfg GitflowConfig|nil

local M = {}

local TITLE = "Gitflow Stash"
local FOOTER_HINTS = {
	{ key = "p", label = "Pop" },
	{ key = "d", label = "Drop" },
	{ key = "r", label = "Refresh" },
	{ key = "q", label = "Close" },
}

---@param cfg GitflowConfig
---@param bufnr integer
---@return integer
local function open_panel_window(cfg, bufnr)
	if cfg.ui.default_layout == "float" then
		return ui.window.open_float({
			name = "stash",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = ui_render.format_key_hints(FOOTER_HINTS),
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	return ui.window.open_split({
		name = "stash",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})
end

---@type GitflowStashPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
}

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("stash", {
			filetype = "gitflow",
			lines = { "Loading stash list..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = open_panel_window(cfg, bufnr)

	vim.keymap.set("n", "p", function()
		M.pop_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "d", function()
		M.drop_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowStashEntry[]
local function render(entries)
	local spec = ui_render.new()
	ui_render.title(spec, TITLE)
	ui_render.section(spec, "Entries")
	local line_entries = {}

	if #entries == 0 then
		ui_render.empty(spec, "no stash entries")
	else
		for _, entry in ipairs(entries) do
			local line = ui_render.entry(spec, ("%s %s"):format(entry.ref, entry.description))
			line_entries[line] = entry
		end
	end

	ui_render.footer(spec, FOOTER_HINTS)
	ui_render.commit("stash", spec)
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

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	git_stash.list({}, function(err, entries)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render(entries)
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

	local confirmed = vim.fn.confirm(
		("Drop %s?"):format(entry.ref),
		"&Yes\n&No",
		2
	) == 1
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

return M
