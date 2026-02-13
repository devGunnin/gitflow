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

local BASE_TITLE = "Gitflow Diff"
local FOOTER_HINTS = {
	{ key = "r", label = "Refresh" },
	{ key = "q", label = "Close" },
}

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
		return {}
	end
	return vim.split(text, "\n", { plain = true })
end

---@param request table
---@return string
local function request_to_title(request)
	if request.commit then
		return ("%s (%s)"):format(BASE_TITLE, request.commit:sub(1, 8))
	end
	if request.staged then
		if request.path then
			return ("%s --staged (%s)"):format(BASE_TITLE, request.path)
		end
		return ("%s --staged"):format(BASE_TITLE)
	end
	if request.path then
		return ("%s (%s)"):format(BASE_TITLE, request.path)
	end
	return BASE_TITLE
end

---@param cfg GitflowConfig
---@param bufnr integer
---@param title string
---@return integer
local function open_panel_window(cfg, bufnr, title)
	if cfg.ui.default_layout == "float" then
		return ui.window.open_float({
			name = "diff",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = title,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and ui_render.format_key_hints(FOOTER_HINTS) or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	return ui.window.open_split({
		name = "diff",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})
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

	local title = request_to_title(M.state.request or {})
	M.state.winid = open_panel_window(cfg, bufnr, title)

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		if M.state.request then
			M.open(cfg, M.state.request)
		end
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param title string
---@param text string
---@param current_branch string
local function render(title, text, current_branch)
	local spec = ui_render.new()
	ui_render.title(spec, title)

	local lines = to_lines(text)
	if #lines == 0 then
		ui_render.empty(spec, "no diff output")
	else
		for _, line in ipairs(lines) do
			local line_number = ui_render.line(spec, line)
			if vim.startswith(line, "diff --git")
				or vim.startswith(line, "index ")
				or vim.startswith(line, "--- ")
				or vim.startswith(line, "+++ ")
			then
				ui_render.highlight(spec, line_number, "GitflowHeader")
			elseif vim.startswith(line, "@@") then
				ui_render.highlight(spec, line_number, "GitflowModified")
			elseif vim.startswith(line, "+") and not vim.startswith(line, "+++") then
				ui_render.highlight(spec, line_number, "GitflowAdded")
			elseif vim.startswith(line, "-") and not vim.startswith(line, "---") then
				ui_render.highlight(spec, line_number, "GitflowRemoved")
			end
		end
	end

	ui_render.blank(spec)
	ui_render.entry(spec, ("Current branch: %s"):format(current_branch), "GitflowMuted")
	ui_render.footer(spec, FOOTER_HINTS)
	ui_render.commit("diff", spec)
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
