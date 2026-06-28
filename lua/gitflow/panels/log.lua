local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_log = require("gitflow.git.log")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")

---@class GitflowLogPanelOpts
---@field on_open_commit fun(commit_sha: string)|nil

---@class GitflowLogPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowLogEntry>
---@field cfg GitflowConfig|nil
---@field opts GitflowLogPanelOpts

local M = {}
local LOG_FLOAT_TITLE = "  Gitflow Log  "
local LOG_FLOAT_FOOTER = " <CR> review commit · V range select · r refresh · q close "
local LOG_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_log_hl")

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

	vim.keymap.set("n", "V", function()
		M.mark_range_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "<Esc>", function()
		if M.state.range_start then
			M.state.range_start = nil
			M.state.range_marks = {}
			M.refresh()
		end
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entry GitflowLogEntry
---@return string
local function display_summary(entry)
	local summary = entry.summary or ""
	local short_sha = entry.short_sha or ""
	if short_sha == "" then
		return summary
	end

	if vim.startswith(summary, short_sha) then
		local remainder = summary:sub(#short_sha + 1)
		if remainder == "" then
			return ""
		end
		if remainder:match("^%s") then
			return remainder:gsub("^%s+", "")
		end
	end

	return summary
end

---@param entries GitflowLogEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	components.header(B, "Gitflow Log", render_opts)

	B:push({
		{ "  ", nil },
		{ icons.get("git_state", "commit") .. "  ", "GitflowSectionIcon" },
		{ ("%d commit%s"):format(#entries, #entries == 1 and "" or "s"), "GitflowSectionTitle" },
		{ "     " .. icons.get("branch", "current") .. " ", "GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	local line_entries = {}
	if #entries == 0 then
		components.empty(B, "no commits found")
	else
		local marks = M.state.range_marks or {}
		for _, entry in ipairs(entries) do
			local summary = display_summary(entry)
			local marked = marks[entry.sha]
			local line_no = B:push({
				{ marked and " \u{2503} " or "   ", marked and "GitflowNumber" or nil },
				{ icons.get("git_state", "commit") .. "  ", "GitflowLogHash" },
				{ entry.short_sha, "GitflowLogHash" },
				{ summary ~= "" and ("  " .. summary) or "", "GitflowCardTitle" },
			})
			line_entries[line_no] = entry
		end
	end

	B:blank()
	components.branch_footer(B, current_branch)

	ui.buffer.update("log", B.lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, LOG_HIGHLIGHT_NS)
	components.cursorline(M.state.winid, true)
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

--- Mark the commit under the cursor as the start of a range. Press <CR> on a
--- later commit to review everything between them (issue #369).
function M.mark_range_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No commit selected", vim.log.levels.WARN)
		return
	end
	if M.state.range_start == entry.sha then
		M.state.range_start = nil
		M.state.range_marks = {}
	else
		M.state.range_start = entry.sha
		M.state.range_marks = { [entry.sha] = true }
		utils.notify(
			"Range start set — <CR> on another commit to review the range (<Esc> cancels)",
			vim.log.levels.INFO
		)
	end
	M.refresh()
end

function M.open_commit_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No commit selected", vim.log.levels.WARN)
		return
	end

	local diffview = require("gitflow.panels.diffview")
	if M.state.range_start and M.state.range_start ~= entry.sha then
		-- Review the combined diff of the marked range (oldest..newest).
		diffview.open_range(M.state.cfg, M.state.range_start, entry.sha)
		M.state.range_start = nil
		M.state.range_marks = {}
		M.refresh()
		return
	end

	if M.state.opts.on_open_commit then
		M.state.opts.on_open_commit(entry.sha)
		return
	end

	diffview.open_commit(M.state.cfg, entry.sha)
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
