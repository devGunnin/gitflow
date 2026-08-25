local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_reset = require("gitflow.git.reset")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local status_panel = require("gitflow.panels.status")

---@class GitflowResetPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowResetEntry>
---@field merge_base_sha string|nil
---@field cfg GitflowConfig|nil

local M = {}

---@type GitflowResetPanelState
M.state = {
	line_entries = {},
	merge_base_sha = nil,
	cfg = nil,
}

local JUMP_KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

local P = panel.new({
	name = "reset",
	title = "Gitflow Reset",
	filetype = "gitflowreset",
	loading = "Loading commits…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "select", essential = true, run = function()
			M.select_under_cursor()
		end },
		{ key = "1-9", keys = JUMP_KEYS, desc = "jump", run = function(key)
			M.select_by_position(tonumber(key))
		end },
		{ key = "S", desc = "soft reset", run = function()
			M.reset_under_cursor("soft")
		end },
		{ key = "H", desc = "hard reset", destructive = true, run = function()
			M.reset_under_cursor("hard")
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

local function refresh_status_panel_if_open()
	if status_panel.is_open() then
		status_panel.refresh()
	end
end

local function emit_post_operation()
	vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })
end

---@param entries GitflowResetEntry[]
---@param merge_base_sha string|nil
---@param current_branch string
local function render(entries, merge_base_sha, current_branch)
	local B = P:begin_render()

	-- Summary bar: reset context + current branch.
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("palette", "reset") .. "  ", "GitflowSectionIcon" },
		{ "Reset", "GitflowSectionTitle" },
		{ components.separators.field .. icons.get("branch", "current") .. " ",
			"GitflowMetaKey" },
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
				{ components.spacing.gutter, nil },
				{ position_marker, "GitflowNumber" },
				{ commit_icon .. "  ", "GitflowLogHash" },
				{ entry.short_sha, "GitflowLogHash" },
				{ summary ~= "" and (components.spacing.gutter .. summary) or "", "GitflowCardTitle" },
			})
			line_entries[line_no] = entry

			-- The merge-base row gets a full-width accent so it stands out as
			-- the point where the current branch diverges.
			if is_merge_base then
				B:hl(line_no, 0, -1, "GitflowResetMergeBase")
			end
		end
	end

	P:push_hints(B)

	if P:paint(B) then
		M.state.line_entries = line_entries
		M.state.merge_base_sha = merge_base_sha
	end
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
		git_reset.list_commits({
			count = cfg.git.log.count,
		}, function(log_err, entries)
			if not P:is_active(request_id) then
				return
			end
			if log_err then
				utils.notify(log_err, vim.log.levels.ERROR)
				P:render_error("Could not list commits", { detail = log_err,
					hint = "r retries" })
				return
			end

			git_reset.find_merge_base({}, function(_, merge_base)
				if not P:is_active(request_id) then
					return
				end
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
	P:close()
	M.state.line_entries = {}
	M.state.merge_base_sha = nil
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
