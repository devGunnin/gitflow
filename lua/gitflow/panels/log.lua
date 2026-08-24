local utils = require("gitflow.utils")
local git_log = require("gitflow.git.log")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
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

---@type GitflowLogPanelState
M.state = {
	line_entries = {},
	cfg = nil,
	opts = {},
}

local P = panel.new({
	name = "log",
	title = "Gitflow Log",
	filetype = "gitflowlog",
	loading = "Loading git log…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "review commit", run = function()
			M.open_commit_under_cursor()
		end },
		{ key = "V", desc = "range select", run = function()
			M.mark_range_under_cursor()
		end },
		{ key = "<Esc>", run = function()
			M.clear_range()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", run = function()
			M.close()
		end },
	},
})

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
	local B = P:begin_render()

	B:push({
		{ components.spacing.gutter, nil },
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
				{
					marked and (" \u{2503} ") or (components.spacing.gutter .. " "),
					marked and "GitflowNumber" or nil,
				},
				{ icons.get("git_state", "commit") .. "  ", "GitflowLogHash" },
				{ entry.short_sha, "GitflowLogHash" },
				{ summary ~= "" and ("  " .. summary) or "", "GitflowCardTitle" },
			})
			line_entries[line_no] = entry
		end
	end

	-- Hints sit above the branch footer so the final line stays the exact
	-- "Current branch: <branch>" string other panels and tests rely on.
	P:push_hints(B)
	components.branch_footer(B, current_branch)

	if P:paint(B) then
		M.state.line_entries = line_entries
	end
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

	if not P:ensure_window(cfg) then
		return
	end
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local request_id = P:next_request()
	git_branch.current({}, function(_, branch)
		if not P:is_active(request_id) then
			return
		end
		git_log.list({
			count = cfg.git.log.count,
			format = cfg.git.log.format,
		}, function(err, entries)
			if not P:is_active(request_id) then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				P:render_error("Could not read the git log", { detail = err,
					hint = "r retries" })
				return
			end
			render(entries, branch or "(unknown)")
		end)
	end)
end

--- Drop a pending range selection (bound to <Esc>). A no-op otherwise, so
--- <Esc> keeps its normal meaning when nothing is marked.
function M.clear_range()
	if not M.state.range_start then
		return
	end
	M.state.range_start = nil
	M.state.range_marks = {}
	M.refresh()
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
	P:close()
	M.state.line_entries = {}
	M.state.range_start = nil
	M.state.range_marks = {}
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
