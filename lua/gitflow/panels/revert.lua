local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_revert = require("gitflow.git.revert")
local git_branch = require("gitflow.git.branch")
local git_conflict = require("gitflow.git.conflict")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local status_panel = require("gitflow.panels.status")

---@class GitflowRevertPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowRevertEntry>
---@field merge_base_sha string|nil
---@field cfg GitflowConfig|nil

local M = {}
local REVERT_FLOAT_TITLE = "Gitflow Revert"
local REVERT_FLOAT_FOOTER =
	"<CR> revert  1-9 by position  r refresh  q close"
local REVERT_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_revert_hl")

---@type GitflowRevertPanelState
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
		bufnr = ui.buffer.create("revert", {
			filetype = "gitflowrevert",
			lines = { "Loading commits..." },
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
			name = "revert",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = REVERT_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and REVERT_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "revert",
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

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowRevertEntry[]
---@param merge_base_sha string|nil
---@param current_branch string
local function render(entries, merge_base_sha, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Revert", render_opts
	)
	local line_entries = {}
	local entry_highlights = {}

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty("no commits found")
	else
		for idx, entry in ipairs(entries) do
			local commit_icon = icons.get("git_state", "commit")
			local position_marker = ""
			if idx <= 9 then
				position_marker = ("[%d] "):format(idx)
			end
			lines[#lines + 1] = ui_render.entry(
				("%s%s %s %s"):format(
					position_marker,
					commit_icon,
					entry.short_sha,
					entry.summary
				)
			)
			line_entries[#lines] = entry

			if merge_base_sha
				and entry.sha:sub(1, #merge_base_sha)
					== merge_base_sha
			then
				entry_highlights[#lines] =
					"GitflowRevertMergeBase"
			elseif merge_base_sha
				and merge_base_sha:sub(1, #entry.sha)
					== entry.sha
			then
				entry_highlights[#lines] =
					"GitflowRevertMergeBase"
			end
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("revert", lines)
	M.state.line_entries = line_entries
	M.state.merge_base_sha = merge_base_sha

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, REVERT_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)
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
	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	git_branch.current({}, function(_, branch)
		git_revert.list_commits({
			count = cfg.git.log.count,
		}, function(log_err, entries)
			if log_err then
				utils.notify(log_err, vim.log.levels.ERROR)
				return
			end

			git_revert.find_merge_base(
				{},
				function(_, merge_base)
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
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("revert")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("revert")
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
