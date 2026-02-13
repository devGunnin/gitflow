local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_log = require("gitflow.git.log")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")

---@class GitflowLogPanelOpts
---@field on_open_commit fun(commit_sha: string)|nil

---@class GitflowLogPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowLogEntry>
---@field cfg GitflowConfig|nil
---@field opts GitflowLogPanelOpts

local M = {}
local LOG_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_log_hl")
local LOG_FLOAT_TITLE = "Gitflow Log"
local LOG_KEY_HINTS = {
	{ key = "<CR>", label = "open commit diff" },
	{ key = "r", label = "refresh" },
	{ key = "q", label = "close" },
}
local LOG_FLOAT_FOOTER = ui.render.format_key_hints(LOG_KEY_HINTS)

---@type GitflowLogPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
	opts = {},
}

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("log", {
			filetype = "gitflowlog",
			lines = { "Loading git log..." },
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
			name = "log",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = LOG_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and LOG_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "log",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.open_commit_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowLogEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local lines = {
		"Gitflow Log",
		"",
	}
	local line_entries = {}

	if #entries == 0 then
		lines[#lines + 1] = "(no commits found)"
	else
		for _, entry in ipairs(entries) do
			local commit_icon = icons.get("git_state", "commit")
			lines[#lines + 1] = ("%s %s %s"):format(commit_icon, entry.short_sha, entry.summary)
			line_entries[#lines] = entry
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ("Current branch: %s"):format(current_branch)
	local show_window_footer = M.state.cfg
		and M.state.cfg.ui.default_layout == "float"
		and M.state.cfg.ui.float.footer
	local inline_footer = show_window_footer and "" or ui.render.format_key_hints(LOG_KEY_HINTS)
	if inline_footer ~= "" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = inline_footer
	end

	ui.buffer.update("log", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local line_groups = {}
	for line_no, _ in pairs(line_entries) do
		line_groups[line_no] = "GitflowModified"
	end

	ui.render.apply_panel_highlights(bufnr, LOG_HIGHLIGHT_NS, {
		title_line = 1,
		footer_line = #lines - (inline_footer ~= "" and 2 or 0),
		line_groups = line_groups,
	})
end

---@return GitflowLogEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param cfg GitflowConfig
---@param opts GitflowLogPanelOpts|nil
function M.open(cfg, opts)
	M.state.cfg = cfg
	M.state.opts = opts or {}

	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	git_branch.current({}, function(_, branch)
		git_log.list({
			count = cfg.git.log.count,
			format = cfg.git.log.format,
		}, function(err, entries)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			render(entries, branch or "(unknown)")
		end)
	end)
end

function M.open_commit_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No commit selected", vim.log.levels.WARN)
		return
	end

	if M.state.opts.on_open_commit then
		M.state.opts.on_open_commit(entry.sha)
		return
	end

	utils.notify("Commit open handler is not configured", vim.log.levels.WARN)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("log")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("log")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
end

return M
