local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_diff = require("gitflow.git.diff")

---@class GitflowDiffPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field request table|nil

local M = {}

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

	M.state.winid = ui.window.open_split({
		name = "diff",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})

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
local function render(_title, text)
	local lines = to_lines(text)
	ui.buffer.update("diff", lines)
end

---@param cfg GitflowConfig
---@param request table
function M.open(cfg, request)
	M.state.request = vim.deepcopy(request)
	ensure_window(cfg)

	git_diff.get(request, function(err, output)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		render(request_to_title(request), output or "")
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
