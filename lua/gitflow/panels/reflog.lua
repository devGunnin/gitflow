local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_reflog = require("gitflow.git.reflog")
local git_branch = require("gitflow.git.branch")
local ui_render = require("gitflow.ui.render")

---@class GitflowReflogPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowReflogEntry>
---@field cfg GitflowConfig|nil

local M = {}
local REFLOG_FLOAT_TITLE = "Gitflow Reflog"
local REFLOG_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_reflog_hl")
local REFLOG_FLOAT_FOOTER =
	"<CR> checkout  R reset  r refresh  q close"

---@type GitflowReflogPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
}

local function emit_post_operation()
	vim.api.nvim_exec_autocmds(
		"User", { pattern = "GitflowPostOperation" }
	)
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("reflog", {
			filetype = "gitflowreflog",
			lines = { "Loading reflog..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value(
		"modifiable", false, { buf = bufnr }
	)

	if M.state.winid
		and vim.api.nvim_win_is_valid(M.state.winid)
	then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "reflog",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = REFLOG_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and REFLOG_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "reflog",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.checkout_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "R", function()
		M.reset_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowReflogEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Reflog", render_opts
	)
	local line_entries = {}

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty("no reflog entries")
	else
		for _, entry in ipairs(entries) do
			lines[#lines + 1] = ui_render.entry(
				("%s %s %s"):format(
					entry.short_sha,
					entry.selector,
					entry.description
				)
			)
			line_entries[#lines] = entry
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("reflog", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, REFLOG_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
		}
	)

	-- Apply GitflowReflogHash to short SHA portion of each entry
	for line_no, entry in pairs(line_entries) do
		local line_text = lines[line_no] or ""
		local sha_start = line_text:find(
			entry.short_sha, 1, true
		)
		if sha_start then
			vim.api.nvim_buf_add_highlight(
				bufnr, REFLOG_HIGHLIGHT_NS,
				"GitflowReflogHash",
				line_no - 1, sha_start - 1,
				sha_start - 1 + #entry.short_sha
			)
		end
	end
end

---@return GitflowReflogEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	git_branch.current({}, function(_, branch)
		git_reflog.list({}, function(err, entries)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			render(entries or {}, branch or "(unknown)")
		end)
	end)
end

function M.checkout_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No reflog entry selected", vim.log.levels.WARN
		)
		return
	end

	local confirmed = vim.fn.confirm(
		("Checkout %s? This will detach HEAD."):format(
			entry.short_sha
		),
		"&Yes\n&No", 2
	) == 1
	if not confirmed then
		return
	end

	git_reflog.checkout(
		entry.sha, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Checked out %s (detached HEAD)"):format(
					entry.short_sha
				),
				vim.log.levels.INFO
			)
			M.refresh()
			emit_post_operation()
		end
	)
end

function M.reset_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No reflog entry selected", vim.log.levels.WARN
		)
		return
	end

	local choice = vim.fn.confirm(
		("Reset to %s?"):format(entry.short_sha),
		"&Soft\n&Mixed\n&Hard\n&Cancel", 4
	)
	if choice == 0 or choice == 4 then
		return
	end

	local modes = { "soft", "mixed", "hard" }
	local mode = modes[choice]

	git_reflog.reset(
		entry.sha, mode, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Reset --%s to %s"):format(
					mode, entry.short_sha
				),
				vim.log.levels.INFO
			)
			M.refresh()
			emit_post_operation()
		end
	)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("reflog")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("reflog")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
