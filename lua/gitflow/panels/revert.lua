local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_revert = require("gitflow.git.revert")
local git_branch = require("gitflow.git.branch")
local git_conflict = require("gitflow.git.conflict")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local status_panel = require("gitflow.panels.status")

---@class GitflowRevertPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowRevertEntry>
---@field merge_base_sha string|nil
---@field cfg GitflowConfig|nil

local M = {}

---@type GitflowRevertPanelState
M.state = {
	line_entries = {},
	merge_base_sha = nil,
	cfg = nil,
}

local POSITION_KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

local P = panel.new({
	name = "revert",
	title = "Gitflow Revert",
	filetype = "gitflowrevert",
	loading = "Loading commits…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "revert", essential = true, run = function()
			M.select_under_cursor()
		end },
		{ key = "1-9", keys = POSITION_KEYS, desc = "by position",
			run = function(key)
				M.select_by_position(tonumber(key))
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
	vim.api.nvim_exec_autocmds(
		"User", { pattern = "GitflowPostOperation" }
	)
end

---@param entries GitflowRevertEntry[]
---@param merge_base_sha string|nil
---@param current_branch string
local function render(entries, merge_base_sha, current_branch)
	local B = P:begin_render()

	-- Commit-count + branch summary bar.
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("git_state", "commit") .. "  ", "GitflowSectionIcon" },
		{
			("%d commit%s"):format(#entries, #entries == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ components.separators.field .. icons.get("branch", "current") .. " ",
			"GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	local line_entries = {}

	components.section(
		B, icons.get("git_state", "commit"), ("Commits (%d)"):format(#entries)
	)

	if #entries == 0 then
		components.empty(B, "no commits found")
	else
		for idx, entry in ipairs(entries) do
			local position_marker = ""
			if idx <= 9 then
				position_marker = ("[%d] "):format(idx)
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
				{ icons.get("git_state", "commit") .. "  ", "GitflowLogHash" },
				{ entry.short_sha .. components.spacing.gutter, "GitflowLogHash" },
				{ summary, "GitflowCardTitle" },
			})
			line_entries[line_no] = entry

			if is_merge_base then
				B:hl(line_no, 0, -1, "GitflowRevertMergeBase")
			end
		end
	end

	P:push_hints(B)

	if P:paint(B, line_entries) then
		M.state.merge_base_sha = merge_base_sha
	end
end

---@return GitflowRevertEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---Find the Nth entry (1-indexed) from the line_entries map.
---@param position integer
---@return GitflowRevertEntry|nil
local function entry_by_position(position)
	local sorted_lines = {}
	for line_no, _ in pairs(M.state.line_entries) do
		sorted_lines[#sorted_lines + 1] = line_no
	end
	table.sort(sorted_lines)

	if position < 1 or position > #sorted_lines then
		return nil
	end
	return M.state.line_entries[sorted_lines[position]]
end

---Confirm and execute git revert for a commit.
---@param entry GitflowRevertEntry
local function execute_revert(entry)
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local confirmed = ui.input.confirm(
		("Revert commit %s %s?\n\n"
			.. "This will create a new commit that undoes"
			.. " the changes."):format(
			entry.short_sha,
			entry.summary
		),
		{
			choices = { "&Revert", "&Cancel" },
			default_choice = 1,
		}
	)
	if not confirmed then
		return
	end

	git_revert.revert(entry.sha, function(err, result)
		if err then
			local output = git.output(result) or err
			local parsed =
				git_conflict.parse_conflicted_paths_from_output(
					output
				)
			if #parsed > 0 then
				utils.notify(
					("Revert has conflicts:\n%s"):format(
						table.concat(parsed, "\n")
					),
					vim.log.levels.ERROR
				)
				local conflict_panel =
					require("gitflow.panels.conflict")
				refresh_status_panel_if_open()
				conflict_panel.open(cfg)
			else
				git_conflict.list(
					{},
					function(c_err, conflicted)
						if c_err
							or #(conflicted or {}) == 0
						then
							utils.notify(
								err,
								vim.log.levels.ERROR
							)
							return
						end
						utils.notify(
							("Revert has"
								.. " conflicts:\n%s"):format(
								table.concat(
									conflicted, "\n"
								)
							),
							vim.log.levels.ERROR
						)
						local cp =
							require(
								"gitflow.panels.conflict"
							)
						refresh_status_panel_if_open()
						cp.open(cfg)
					end
				)
			end
			return
		end

		local output = git.output(result)
		if output == "" then
			output = ("Reverted %s"):format(entry.short_sha)
		end
		utils.notify(output, vim.log.levels.INFO)
		M.close()
		refresh_status_panel_if_open()
		emit_post_operation()
	end)
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
		git_revert.list_commits({
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

			git_revert.find_merge_base(
				{},
				function(_, merge_base)
					if not P:is_active(request_id) then
						return
					end
					render(
						entries or {},
						merge_base,
						branch or "(unknown)"
					)
				end
			)
		end)
	end)
end

function M.select_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No commit selected", vim.log.levels.WARN
		)
		return
	end
	execute_revert(entry)
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
	execute_revert(entry)
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
