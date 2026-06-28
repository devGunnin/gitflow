local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_reset = require("gitflow.git.reset")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")
local status_panel = require("gitflow.panels.status")

---@class GitflowResetPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowResetEntry>
---@field merge_base_sha string|nil
---@field cfg GitflowConfig|nil

local M = {}
local RESET_FLOAT_TITLE = "  Gitflow Reset  "
local RESET_FLOAT_FOOTER =
	" <CR> select · 1-9 jump · S soft reset · H hard reset · r refresh · q close "
local RESET_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_reset_hl")

---@type GitflowResetPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	merge_base_sha = nil,
	cfg = nil,
}

local function refresh_status_panel_if_open()
	if status_panel.is_open() then
		status_panel.refresh()
	end
end

local function emit_post_operation()
	vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("reset", {
			filetype = "gitflowreset",
			lines = { "Loading commits..." },
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
			name = "reset",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = RESET_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and RESET_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "reset",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.select_under_cursor()
	end, { buffer = bufnr, silent = true })

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			M.select_by_position(i)
		end, { buffer = bufnr, silent = true, nowait = true })
	end

	vim.keymap.set("n", "S", function()
		M.reset_under_cursor("soft")
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "H", function()
		M.reset_under_cursor("hard")
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowResetEntry[]
---@param merge_base_sha string|nil
---@param current_branch string
local function render(entries, merge_base_sha, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	components.header(B, "Gitflow Reset", render_opts)

	-- Summary bar: reset context + current branch.
	B:push({
		{ "  ", nil },
		{ icons.get("palette", "reset") .. "  ", "GitflowSectionIcon" },
		{ "Reset", "GitflowSectionTitle" },
		{ "     " .. icons.get("branch", "current") .. " ", "GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	local line_entries = {}

	if #entries == 0 then
		components.empty(B, "no commits found")
	else
		components.section(
			B,
			icons.get("git_state", "commit"),
			("Commits (%d)"):format(#entries)
		)

		local commit_icon = icons.get("git_state", "commit")
		for idx, entry in ipairs(entries) do
			-- HEAD (first row) has no position marker; subsequent rows show
			-- the [N] jump target offset from HEAD.
			local position_marker = ""
			if idx >= 2 and idx <= 10 then
				position_marker = ("[%d] "):format(idx - 1)
			end

			local is_merge_base = merge_base_sha ~= nil
				and (
					entry.sha:sub(1, #merge_base_sha) == merge_base_sha
					or merge_base_sha:sub(1, #entry.sha) == entry.sha
				)

			local summary = entry.summary or ""
			if entry.short_sha ~= "" and vim.startswith(summary, entry.short_sha) then
				summary = vim.trim(summary:sub(#entry.short_sha + 1))
			end
			local line_no = B:push({
				{ " ", nil },
				{ position_marker, "GitflowNumber" },
				{ commit_icon .. "  ", "GitflowLogHash" },
				{ entry.short_sha, "GitflowLogHash" },
				{ summary ~= "" and ("  " .. summary) or "", "GitflowCardTitle" },
			})
			line_entries[line_no] = entry

			-- The merge-base row gets a full-width accent so it stands out as
			-- the point where the current branch diverges.
			if is_merge_base then
				B:hl(line_no, 0, -1, "GitflowResetMergeBase")
			end
		end
	end

	ui.buffer.update("reset", B.lines)
	M.state.line_entries = line_entries
	M.state.merge_base_sha = merge_base_sha

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	B:apply(bufnr, RESET_HIGHLIGHT_NS)
	components.cursorline(M.state.winid, true)
end

---@return GitflowResetEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---Find the entry at the given position (1-indexed, offset from HEAD).
---Position 1 maps to the 2nd entry (HEAD~1) since HEAD is a no-op target.
---@param position integer
---@return GitflowResetEntry|nil
local function entry_by_position(position)
	local sorted_lines = {}
	for line_no, _ in pairs(M.state.line_entries) do
		sorted_lines[#sorted_lines + 1] = line_no
	end
	table.sort(sorted_lines)

	local actual = position + 1
	if actual < 1 or actual > #sorted_lines then
		return nil
	end
	return M.state.line_entries[sorted_lines[actual]]
end

---Prompt user for soft/hard and execute reset.
---@param entry GitflowResetEntry
---@param mode "soft"|"hard"|nil  if provided, skip the confirm prompt
local function execute_reset(entry, mode)
	if mode then
		local label = mode == "hard" and "HARD" or "soft"
		local confirmed = ui.input.confirm(
			("Reset %s to %s %s?\n\nThis will %s."):format(
				label,
				entry.short_sha,
				entry.summary,
				mode == "hard"
					and "DISCARD all changes after this commit"
					or "keep changes as uncommitted"
			),
			{
				choices = { "&Reset", "&Cancel" },
				default_choice = mode == "hard" and 2 or 1,
			}
		)
		if not confirmed then
			return
		end

		git_reset.reset(entry.sha, mode, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			local output = git.output(result)
			if output == "" then
				output = ("Reset %s to %s"):format(mode, entry.short_sha)
			end
			utils.notify(output, vim.log.levels.INFO)
			M.close()
			refresh_status_panel_if_open()
			emit_post_operation()
		end)
		return
	end

	local _, choice_idx = ui.input.confirm(
		("Reset to %s %s?"):format(entry.short_sha, entry.summary),
		{
			choices = { "&Soft", "&Hard", "&Cancel" },
			default_choice = 1,
		}
	)

	if choice_idx == 1 then
		execute_reset(entry, "soft")
	elseif choice_idx == 2 then
		execute_reset(entry, "hard")
	end
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
		git_reset.list_commits({
			count = cfg.git.log.count,
		}, function(log_err, entries)
			if log_err then
				utils.notify(log_err, vim.log.levels.ERROR)
				return
			end

			git_reset.find_merge_base({}, function(_, merge_base)
				render(entries or {}, merge_base, branch or "(unknown)")
			end)
		end)
	end)
end

function M.select_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No commit selected", vim.log.levels.WARN)
		return
	end
	execute_reset(entry)
end

---@param position integer
function M.select_by_position(position)
	local entry = entry_by_position(position)
	if not entry then
		utils.notify(
			("No commit at position %d"):format(position),
			vim.log.levels.WARN
		)
		return
	end
	execute_reset(entry)
end

---@param mode "soft"|"hard"
function M.reset_under_cursor(mode)
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No commit selected", vim.log.levels.WARN)
		return
	end
	execute_reset(entry, mode)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("reset")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("reset")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.merge_base_sha = nil
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
