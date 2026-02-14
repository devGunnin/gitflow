local ui = require("gitflow.ui")
local ui_render = require("gitflow.ui.render")
local utils = require("gitflow.utils")
local git_diff = require("gitflow.git.diff")
local git_branch = require("gitflow.git.branch")

---@class GitflowDiffPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field request table|nil

local M = {}
local DIFF_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_diff_hl")
local DIFF_FLOAT_TITLE = "Gitflow Diff"
local DIFF_FLOAT_FOOTER = "r refresh  q close"

---@type GitflowDiffPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	request = nil,
}

---@param text string
---@return string[]
local function to_lines(text)
	if text == "" then
		return { "(no diff output)" }
	end
	return vim.split(text, "\n", { plain = true })
end

---@param request table
---@return string
local function request_to_title(request)
	if request.commit then
		return ("Gitflow Diff (%s)"):format(request.commit:sub(1, 8))
	end
	if request.staged then
		if request.path then
			return ("Gitflow Diff --staged (%s)"):format(request.path)
		end
		return "Gitflow Diff --staged"
	end
	if request.path then
		return ("Gitflow Diff (%s)"):format(request.path)
	end
	return "Gitflow Diff"
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("diff", {
			filetype = "diff",
			lines = { "Loading diff..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("filetype", "diff", { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "diff",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = DIFF_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and DIFF_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "diff",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		if M.state.request then
			M.open(cfg, M.state.request)
		end
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param _title string
---@param text string
---@param current_branch string
local function render(title, text, current_branch)
	local diff_lines = to_lines(text)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(title, render_opts)
	for _, line in ipairs(diff_lines) do
		lines[#lines + 1] = line
	end
	local footer_lines = ui_render.panel_footer(current_branch, nil, render_opts)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end
	ui.buffer.update("diff", lines)

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local entry_highlights = {}

	for idx, line in ipairs(diff_lines) do
		local group = nil
		if vim.startswith(line, "diff --git")
			or vim.startswith(line, "index ")
			or vim.startswith(line, "--- ")
			or vim.startswith(line, "+++ ")
		then
			group = "GitflowHeader"
		elseif vim.startswith(line, "@@") then
			group = "GitflowModified"
		elseif vim.startswith(line, "+") and not vim.startswith(line, "+++") then
			group = "GitflowAdded"
		elseif vim.startswith(line, "-") and not vim.startswith(line, "---") then
			group = "GitflowRemoved"
		end
		if group then
			entry_highlights[idx + 2] = group
		end
	end

	ui_render.apply_panel_highlights(bufnr, DIFF_HIGHLIGHT_NS, lines, {
		footer_line = #lines,
		entry_highlights = entry_highlights,
	})
end

---@param cfg GitflowConfig
---@param request table
function M.open(cfg, request)
	M.state.request = vim.deepcopy(request)
	ensure_window(cfg)

	git_branch.current({}, function(_, branch)
		git_diff.get(request, function(err, output)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end

			render(request_to_title(request), output or "", branch or "(unknown)")
		end)
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("diff")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("diff")
	end

	M.state.winid = nil
	M.state.bufnr = nil
	M.state.request = nil
end

return M
