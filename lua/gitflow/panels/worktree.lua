local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_worktree = require("gitflow.git.worktree")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local list_picker = require("gitflow.ui.list_picker")

---@class GitflowWorktreePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field source_winid integer|nil
---@field line_entries table<integer, GitflowWorktreeEntry>
---@field cfg GitflowConfig|nil

local M = {}
local WT_FLOAT_TITLE = "Gitflow Worktree"
local WT_FLOAT_FOOTER =
	"<CR> switch  a add  d remove  r refresh  q close"
local WT_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_worktree_hl")

---@type GitflowWorktreePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	source_winid = nil,
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
		bufnr = ui.buffer.create("worktree", {
			filetype = "gitflowworktree",
			lines = { "Loading worktrees..." },
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
			name = "worktree",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = WT_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and WT_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "worktree",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.switch_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "a", function()
		M.add_worktree()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "d", function()
		M.remove_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowWorktreeEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Worktree", render_opts
	)
	local line_entries = {}
	local entry_highlights = {}
	local path_highlights = {}

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty(
			"no worktrees found"
		)
	else
		for _, entry in ipairs(entries) do
			local branch_icon = icons.get(
				"branch", "branch_local"
			)
			local branch_text = entry.branch
				or "(detached)"
			if entry.is_bare then
				branch_text = "(bare)"
			end

			local display = ("%s %s  %s  %s"):format(
				branch_icon,
				branch_text,
				entry.short_sha,
				entry.path
			)
			local rendered_line = ui_render.entry(display)
			lines[#lines + 1] = rendered_line
			line_entries[#lines] = entry

			if entry.branch == current_branch then
				entry_highlights[#lines] =
					"GitflowWorktreeActive"
			end

			local path_start = rendered_line:find(
				entry.path, 1, true
			)
			if path_start then
				path_highlights[#lines] = {
					start_col = path_start - 1,
					end_col = path_start - 1 + #entry.path,
				}
			end
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("worktree", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, WT_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)

	for line_no, cols in pairs(path_highlights) do
		vim.api.nvim_buf_add_highlight(
			bufnr,
			WT_HIGHLIGHT_NS,
			"GitflowWorktreePath",
			line_no - 1,
			cols.start_col,
			cols.end_col
		)
	end
end

---@return GitflowWorktreeEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@return integer|nil
local function resolve_switch_target_win()
	local panel_winid = M.state.winid
	local source_winid = M.state.source_winid
	if source_winid
		and vim.api.nvim_win_is_valid(source_winid)
		and source_winid ~= panel_winid
	then
		return source_winid
	end

	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if winid ~= panel_winid
			and vim.api.nvim_win_is_valid(winid)
		then
			return winid
		end
	end

	return panel_winid
end

---@param cfg GitflowConfig
function M.open(cfg)
	local current_win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_is_valid(current_win)
		and current_win ~= M.state.winid
	then
		M.state.source_winid = current_win
	end

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
		git_worktree.list({}, function(err, entries)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			render(
				entries or {},
				branch or "(unknown)"
			)
		end)
	end)
end

function M.switch_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No worktree selected", vim.log.levels.WARN
		)
		return
	end

	if entry.is_bare then
		utils.notify(
			"Cannot switch to bare worktree",
			vim.log.levels.WARN
		)
		return
	end

	local confirmed = ui.input.confirm(
		("Switch directory to worktree at %s?"):format(
			entry.path
		),
		{
			choices = { "&Switch", "&Cancel" },
			default_choice = 1,
		}
	)
	if not confirmed then
		return
	end

	local target_winid = resolve_switch_target_win()
	local ok, switch_err = pcall(function()
		if target_winid
			and vim.api.nvim_win_is_valid(target_winid)
		then
			vim.api.nvim_win_call(target_winid, function()
				vim.cmd.cd(entry.path)
				vim.cmd.lcd(entry.path)
			end)
			return
		end
		vim.cmd.cd(entry.path)
		vim.cmd.lcd(entry.path)
	end)
	if not ok then
		utils.notify(
			("Failed to switch to worktree '%s': %s"):format(
				entry.path,
				tostring(switch_err)
			),
			vim.log.levels.ERROR
		)
		return
	end

	utils.notify(
		("Switched to worktree: %s"):format(entry.path),
		vim.log.levels.INFO
	)
	M.close()
	emit_post_operation()
end

---@param branch string
local function prompt_for_worktree_path(branch)
	ui.input.prompt({
		prompt = "Worktree path: ",
	}, function(path)
		local trimmed_path = vim.trim(path)
		if trimmed_path == "" then
			utils.notify(
				"Path cannot be empty",
				vim.log.levels.WARN
			)
			return
		end

		git_worktree.add(trimmed_path, branch, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			local output = git.output(result)
			if output == "" then
				output = ("Created worktree at %s"):format(
					trimmed_path
				)
			end
			utils.notify(output, vim.log.levels.INFO)
			M.refresh()
			emit_post_operation()
		end)
	end)
end

function M.add_worktree()
	git_branch.list({}, function(err, entries)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		local local_branches = git_branch.partition(
			entries or {}
		)
		if #local_branches == 0 then
			utils.notify(
				"No local branches found",
				vim.log.levels.WARN
			)
			return
		end

		local items = {}
		for _, branch in ipairs(local_branches) do
			items[#items + 1] = { name = branch.name }
		end

		vim.schedule(function()
			if not M.state.bufnr
				or not vim.api.nvim_buf_is_valid(M.state.bufnr)
			then
				return
			end

			list_picker.open({
				items = items,
				title = "Select Worktree Branch",
				multi_select = false,
				on_submit = function(selected)
					if #selected == 0 then
						return
					end
					prompt_for_worktree_path(selected[1])
				end,
			})
		end)
	end)
end

function M.remove_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No worktree selected", vim.log.levels.WARN
		)
		return
	end

	if entry.is_main then
		utils.notify(
			"Cannot remove the main worktree",
			vim.log.levels.WARN
		)
		return
	end

	local confirmed = ui.input.confirm(
		("Remove worktree at %s?"):format(entry.path),
		{
			choices = { "&Remove", "&Cancel" },
			default_choice = 2,
		}
	)
	if not confirmed then
		return
	end

	git_worktree.remove(entry.path, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		local output = git.output(result)
		if output == "" then
			output = ("Removed worktree at %s"):format(
				entry.path
			)
		end
		utils.notify(output, vim.log.levels.INFO)
		M.refresh()
		emit_post_operation()
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("worktree")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("worktree")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.source_winid = nil
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
