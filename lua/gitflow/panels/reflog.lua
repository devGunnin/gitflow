local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_reflog = require("gitflow.git.reflog")
local git_branch = require("gitflow.git.branch")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local icons = require("gitflow.icons")

---@class GitflowReflogPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowReflogEntry>
---@field cfg GitflowConfig|nil

local M = {}

---@type GitflowReflogPanelState
M.state = {
	line_entries = {},
	cfg = nil,
}

local QUICK_SELECT_KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

local P = panel.new({
	name = "reflog",
	title = "Gitflow Reflog",
	filetype = "gitflowreflog",
	loading = "Loading reflog…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "checkout", essential = true, run = function()
			M.checkout_under_cursor()
		end },
		{ key = "1-9", keys = QUICK_SELECT_KEYS, desc = "quick checkout",
			run = function(key)
				M.select_by_position(tonumber(key))
			end },
		-- "reset", not "hard reset": the prompt offers soft/mixed/hard.
		{ key = "H", desc = "reset", destructive = true, run = function()
			M.reset_under_cursor()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

local function emit_post_operation()
	vim.api.nvim_exec_autocmds(
		"User", { pattern = "GitflowPostOperation" }
	)
end

---Choose a per-row accent icon based on the reflog action.
---@param action string
---@return string
local function action_icon(action)
	if action == "checkout" then
		return icons.get("branch", "current")
	elseif action == "reset" then
		return icons.get("git_state", "modified")
	elseif action == "merge" or action == "rebase" then
		return icons.get("ui", "merge")
	end
	return icons.get("git_state", "commit")
end

---@param entries GitflowReflogEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local B = P:begin_render()

	-- Summary bar: entry count + current branch context.
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("git_state", "commit") .. "  ", "GitflowSectionIcon" },
		{
			("%d entr%s"):format(#entries, #entries == 1 and "y" or "ies"),
			"GitflowSectionTitle",
		},
		{ components.separators.field .. icons.get("branch", "current") .. " ",
			"GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	local line_entries = {}

	components.section(
		B,
		icons.get("git_state", "commit"),
		("History (%d)"):format(#entries)
	)

	if #entries == 0 then
		components.empty(B, "no reflog entries")
	else
		for idx, entry in ipairs(entries) do
			-- Quick-access marker for the first 9 entries; keep the literal
			-- "[N] <sha>" token contiguous so 1-9 selection stays discoverable.
			local marker = idx <= 9 and ("[%d] "):format(idx) or "    "
			local sha = entry.short_sha or ""
			local selector = entry.selector or ""

			-- Split "<action>: <rest>" so the action word can be accented
			-- while keeping the literal "commit:"/"checkout:"/"reset:" text.
			local action = entry.action or ""
			local desc = entry.description or ""
			local action_text, rest_text
			if action ~= "" and vim.startswith(desc, action .. ":") then
				action_text = action .. ":"
				rest_text = desc:sub(#action_text + 1)
			end

			local icon = action_icon(action)
			local chunks = {
				{ components.spacing.gutter, nil },
				{ icon ~= "" and (icon .. "  ") or "", "GitflowMeta" },
				{ marker, "GitflowNumber" },
				{ sha, "GitflowReflogHash" },
				{ components.spacing.gutter, nil },
				{ selector, "GitflowMetaKey" },
				{ components.spacing.gutter, nil },
			}
			if action_text then
				chunks[#chunks + 1] = { action_text, "GitflowReflogAction" }
				chunks[#chunks + 1] = { rest_text, "GitflowCardTitle" }
			else
				chunks[#chunks + 1] = { desc, "GitflowCardTitle" }
			end

			local line_no = B:push(chunks)
			line_entries[line_no] = entry
		end
	end

	P:push_hints(B)

	P:paint(B, line_entries)
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

---@param position integer
---@return GitflowReflogEntry|nil
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

---@param entry GitflowReflogEntry
local function execute_checkout(entry)
	local confirmed = ui.input.confirm(
		("Checkout %s? This will detach HEAD."):format(
			entry.short_sha
		)
	)
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
		git_reflog.list({}, function(err, entries)
			if not P:is_active(request_id) then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				P:render_error("Could not read the reflog", { detail = err,
					hint = "r retries" })
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
	execute_checkout(entry)
end

---@param position integer
function M.select_by_position(position)
	local entry = entry_by_position(position)
	if not entry then
		utils.notify(
			("No reflog entry at position %d"):format(position),
			vim.log.levels.WARN
		)
		return
	end
	execute_checkout(entry)
end

function M.reset_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No reflog entry selected", vim.log.levels.WARN
		)
		return
	end

	local _, choice = ui.input.confirm(
		("Reset to %s?"):format(entry.short_sha),
		{
			choices = { "&Soft", "&Mixed", "&Hard", "&Cancel" },
			default_choice = 4,
		}
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
	P:close()
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
