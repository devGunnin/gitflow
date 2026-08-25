local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_stash = require("gitflow.git.stash")
local git_branch = require("gitflow.git.branch")
local status_panel = require("gitflow.panels.status")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local icons = require("gitflow.icons")

---@class GitflowStashPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowStashEntry>
---@field cfg GitflowConfig|nil

local M = {}

---@type GitflowStashPanelState
M.state = {
	line_entries = {},
	cfg = nil,
}

local P = panel.new({
	name = "stash",
	title = "Gitflow Stash",
	filetype = "gitflowstash",
	loading = "Loading stash list…",
	state = M.state,
	keymaps = {
		{ key = "A", desc = "apply", essential = true, run = function()
			M.apply_under_cursor()
		end },
		{ key = "P", desc = "pop", run = function()
			M.pop_under_cursor()
		end },
		{ key = "D", desc = "drop", destructive = true, run = function()
			M.drop_under_cursor()
		end },
		{ key = "S", desc = "stash", run = function()
			M.push_with_prompt()
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

---@param entries GitflowStashEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local B = P:begin_render()

	local stash_icon = icons.get("git_state", "staged")

	-- Stash count + current-branch summary bar.
	B:push({
		{ components.spacing.gutter, nil },
		{ stash_icon .. "  ", "GitflowSectionIcon" },
		{ ("%d stash entr%s"):format(#entries, #entries == 1 and "y" or "ies"), "GitflowSectionTitle" },
		{ components.separators.field .. icons.get("branch", "current") .. " ",
			"GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	local line_entries = {}

	components.section(B, stash_icon, ("Stash Entries (%d)"):format(#entries))
	if #entries == 0 then
		components.empty(B, "no stash entries")
	else
		for _, entry in ipairs(entries) do
			-- The ref chunk ("stash@{0}") carries GitflowStashRef so the span
			-- lands exactly on the ref portion; the description follows it dim.
			local line_no = B:push({
				{ components.spacing.gutter, nil },
				{ stash_icon .. "  ", "GitflowSectionIcon" },
				{ entry.ref, "GitflowStashRef" },
				{ components.spacing.gutter, nil },
				{ components.maybe_text(entry.description), "GitflowCardTitle" },
			})
			line_entries[line_no] = entry
		end
	end

	B:blank()
	P:push_hints(B, nil, { blank_before = false })
	components.branch_footer(B, current_branch)

	P:paint(B, line_entries)
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
	if not P:ensure_window(cfg) then
		return
	end
	M.refresh()
end

function M.push_with_prompt()
	ui.input.prompt({
		multiline = true,
		title = "Stash message (optional)",
		draft_key = "stash:push:message",
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
	local request_id = P:next_request()
	git_branch.current({}, function(_, branch)
		if not P:is_active(request_id) then
			return
		end
		git_stash.list({}, function(err, entries)
			if not P:is_active(request_id) then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				P:render_error("Could not list stash entries", { detail = err,
					hint = "r retries" })
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
		refresh_status_panel_if_open()
	end)
end

function M.apply_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No stash entry selected", vim.log.levels.WARN)
		return
	end

	git_stash.apply({ index = entry.index }, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(output_or_default(result), vim.log.levels.INFO)
		-- no M.refresh() — stash entry is still there
		refresh_status_panel_if_open()
	end)
end

function M.drop_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No stash entry selected", vim.log.levels.WARN)
		return
	end

	local confirmed = ui.input.confirm(
		("Drop %s?"):format(entry.ref),
		{ choices = { "&Drop", "&Cancel" }, default_choice = 2 }
	)
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
	P:close()
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
