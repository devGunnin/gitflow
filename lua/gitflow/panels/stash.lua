local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_stash = require("gitflow.git.stash")
local git_branch = require("gitflow.git.branch")
local status_panel = require("gitflow.panels.status")
local ui_render = require("gitflow.ui.render")
local config = require("gitflow.config")

---@class GitflowStashPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowStashEntry>
---@field cfg GitflowConfig|nil

local M = {}
local STASH_FLOAT_TITLE = "Gitflow Stash"
local STASH_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_stash_hl")
local STASH_FLOAT_FOOTER_HINTS = {
	{ action = "pop", default = "P", label = "pop" },
	{ action = "drop", default = "D", label = "drop" },
	{ action = "stash", default = "S", label = "stash" },
	{ action = "refresh", default = "r", label = "refresh" },
	{ action = "close", default = "q", label = "close" },
}

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
---@return string
local function stash_float_footer(cfg)
	return ui_render.resolve_panel_key_hints(
		cfg, "stash", STASH_FLOAT_FOOTER_HINTS
	)
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

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "stash",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = STASH_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and stash_float_footer(cfg) or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "stash",
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
			cfg, "stash", action, default
		)
	end

	vim.keymap.set("n", pk("pop", "P"), function()
		M.pop_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("drop", "D"), function()
		M.drop_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("stash", "S"), function()
		M.push_with_prompt()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("refresh", "r"), function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("close", "q"), function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowStashEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Stash", render_opts)
	local line_entries = {}

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty("no stash entries")
	else
		for _, entry in ipairs(entries) do
			lines[#lines + 1] = ui_render.entry(("%s %s"):format(entry.ref, entry.description))
			line_entries[#lines] = entry
		end
	end
	local footer_lines = ui_render.panel_footer(current_branch, nil, render_opts)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("stash", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(bufnr, STASH_HIGHLIGHT_NS, lines, {
		footer_line = #lines,
	})

	-- Apply GitflowStashRef to stash ref portion of each entry
	for line_no, entry in pairs(line_entries) do
		local line_text = lines[line_no] or ""
		local ref_start = line_text:find(entry.ref, 1, true)
		if ref_start then
			vim.api.nvim_buf_add_highlight(
				bufnr, STASH_HIGHLIGHT_NS, "GitflowStashRef",
				line_no - 1, ref_start - 1,
				ref_start - 1 + #entry.ref
			)
		end
	end
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

---@param result GitflowGitResult
local function notify_push_result(result)
	local output = output_or_default(result)
	if git_stash.output_mentions_no_local_changes(output) then
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
