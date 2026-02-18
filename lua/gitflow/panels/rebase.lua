local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_rebase = require("gitflow.git.rebase")
local git_branch = require("gitflow.git.branch")
local git_conflict = require("gitflow.git.conflict")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local list_picker = require("gitflow.ui.list_picker")
local status_panel = require("gitflow.panels.status")

---@class GitflowRebasePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowRebaseEntry>
---@field entries GitflowRebaseEntry[]
---@field base_ref string|nil
---@field current_branch string|nil
---@field stage "base"|"todo"
---@field cfg GitflowConfig|nil
---@field picker_request_id integer
---@field refresh_request_id integer

local M = {}
local REBASE_FLOAT_TITLE = "Gitflow Interactive Rebase"
local REBASE_FLOAT_FOOTER =
	"<CR> cycle  p/r/e/s/f/d actions  J/K move  X execute  q close"
local REBASE_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_rebase_hl")

local ACTIONS = { "pick", "reword", "edit", "squash", "fixup", "drop" }

local ACTION_HIGHLIGHTS = {
	pick = "GitflowRebasePick",
	reword = "GitflowRebaseReword",
	edit = "GitflowRebaseEdit",
	squash = "GitflowRebaseSquash",
	fixup = "GitflowRebaseFixup",
	drop = "GitflowRebaseDrop",
}

---@type GitflowRebasePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	entries = {},
	base_ref = nil,
	current_branch = nil,
	stage = "base",
	cfg = nil,
	picker_request_id = 0,
	refresh_request_id = 0,
}

local function next_picker_request_id()
	M.state.picker_request_id = (M.state.picker_request_id or 0) + 1
	return M.state.picker_request_id
end

---@param request_id integer
---@return boolean
local function is_active_picker_request(request_id)
	return M.state.picker_request_id == request_id
		and M.is_open()
end

local function next_refresh_request_id()
	M.state.refresh_request_id = (M.state.refresh_request_id or 0) + 1
	return M.state.refresh_request_id
end

---@param request_id integer
---@param base_ref string
---@return boolean
local function is_active_refresh_request(request_id, base_ref)
	return M.state.refresh_request_id == request_id
		and M.is_open()
		and M.state.stage == "todo"
		and M.state.base_ref == base_ref
end

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

---Cycle an action forward through the ACTIONS list.
---@param current string
---@return string
local function next_action(current)
	for i, action in ipairs(ACTIONS) do
		if action == current then
			return ACTIONS[(i % #ACTIONS) + 1]
		end
	end
	return "pick"
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("rebase", {
			filetype = "gitflowrebase",
			lines = { "Loading branches..." },
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
			name = "rebase",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = REBASE_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and REBASE_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "rebase",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	-- Action cycling
	vim.keymap.set("n", "<CR>", function()
		M.cycle_action()
	end, { buffer = bufnr, silent = true })

	-- Direct action keys
	vim.keymap.set("n", "p", function()
		M.set_action("pick")
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.set_action("reword")
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "e", function()
		M.set_action("edit")
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "s", function()
		M.set_action("squash")
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "f", function()
		M.set_action("fixup")
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "d", function()
		M.set_action("drop")
	end, { buffer = bufnr, silent = true, nowait = true })

	-- Reorder
	vim.keymap.set("n", "J", function()
		M.move_down()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "K", function()
		M.move_up()
	end, { buffer = bufnr, silent = true, nowait = true })

	-- Execute
	vim.keymap.set("n", "X", function()
		M.execute()
	end, { buffer = bufnr, silent = true, nowait = true })

	-- Base branch picker
	vim.keymap.set("n", "b", function()
		M.show_base_picker()
	end, { buffer = bufnr, silent = true, nowait = true })

	-- Close
	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---Render the interactive rebase todo list.
local function render_todo()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Interactive Rebase", render_opts
	)
	local line_entries = {}
	local entry_highlights = {}

	-- Base ref header
	local base_header = ("Base: %s"):format(
		M.state.base_ref or "(none)"
	)
	lines[#lines + 1] = ui_render.entry(base_header)
	entry_highlights[#lines] = "GitflowBranchCurrent"
	lines[#lines + 1] = ui_render.separator(render_opts)

	if #M.state.entries == 0 then
		lines[#lines + 1] = ui_render.empty(
			"no commits found for rebase"
		)
	else
		for _, entry in ipairs(M.state.entries) do
			local commit_icon = icons.get("git_state", "commit")
			local action_label = ("%-6s"):format(entry.action)
			local line_text = ("%s %s %s"):format(
				action_label, commit_icon, entry.short_sha
			)
			if entry.subject ~= "" then
				line_text = ("%s %s"):format(
					line_text, entry.subject
				)
			end
			lines[#lines + 1] = ui_render.entry(line_text)
			line_entries[#lines] = entry
			entry_highlights[#lines] =
				ACTION_HIGHLIGHTS[entry.action]
				or "GitflowRebasePick"
		end
	end

	local footer_lines = ui_render.panel_footer(
		M.state.current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("rebase", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, REBASE_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)

	-- Apply hash highlights
	for line_no, entry in pairs(line_entries) do
		local line_text = lines[line_no] or ""
		local sha_start = line_text:find(entry.short_sha, 1, true)
		if sha_start then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				REBASE_HIGHLIGHT_NS,
				"GitflowRebaseHash",
				line_no - 1,
				sha_start - 1,
				sha_start - 1 + #entry.short_sha
			)
		end
	end
end

---Find the index in M.state.entries for the entry under the cursor.
---@return integer|nil
local function entry_index_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local entry = M.state.line_entries[line]
	if not entry then
		return nil
	end
	for i, e in ipairs(M.state.entries) do
		if e == entry then
			return i
		end
	end
	return nil
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	M.state.stage = "base"
	ensure_window(cfg)
	M.show_base_picker()
end

function M.show_base_picker()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local request_id = next_picker_request_id()
	git_branch.list({}, function(err, branches)
		if not is_active_picker_request(request_id) then
			return
		end

		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		if not branches or #branches == 0 then
			utils.notify(
				"No branches found",
				vim.log.levels.WARN
			)
			return
		end

		local items = {}
		for _, branch in ipairs(branches) do
			if not branch.name:match("/HEAD$") then
				items[#items + 1] = { name = branch.name }
			end
		end

		vim.schedule(function()
			if not is_active_picker_request(request_id) then
				return
			end

			list_picker.open({
				items = items,
				title = "Select Rebase Base",
				multi_select = false,
				on_submit = function(selected)
					if not is_active_picker_request(request_id) then
						return
					end

					if #selected > 0 then
						next_picker_request_id()
						M.state.base_ref = selected[1]
						M.state.stage = "todo"
						M.refresh()
					end
				end,
				on_cancel = function()
					if not is_active_picker_request(request_id) then
						return
					end

					if M.state.stage == "base" then
						M.close()
					end
				end,
			})
		end)
	end)
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	if M.state.stage == "base" or not M.state.base_ref then
		M.show_base_picker()
		return
	end

	local base_ref = M.state.base_ref
	local request_id = next_refresh_request_id()
	git_branch.current({}, function(_, branch)
		if not is_active_refresh_request(request_id, base_ref) then
			return
		end

		local current_branch = branch or "(unknown)"
		git_rebase.list_commits(
			base_ref,
			{ count = cfg.git.log.count },
			function(err, entries)
				if not is_active_refresh_request(
					request_id, base_ref
				) then
					return
				end

				if err then
					utils.notify(err, vim.log.levels.ERROR)
					return
				end
				M.state.current_branch = current_branch
				M.state.entries = entries or {}
				render_todo()
			end
		)
	end)
end

---Cycle the action of the commit under the cursor.
function M.cycle_action()
	if M.state.stage ~= "todo" then
		return
	end
	local idx = entry_index_under_cursor()
	if not idx then
		utils.notify(
			"No commit selected", vim.log.levels.WARN
		)
		return
	end
	M.state.entries[idx].action = next_action(
		M.state.entries[idx].action
	)
	render_todo()
end

---Set a specific action on the commit under the cursor.
---@param action string
function M.set_action(action)
	if M.state.stage ~= "todo" then
		return
	end
	local idx = entry_index_under_cursor()
	if not idx then
		utils.notify(
			"No commit selected", vim.log.levels.WARN
		)
		return
	end
	M.state.entries[idx].action = action
	render_todo()
end

---Move the commit under the cursor down in the list.
function M.move_down()
	if M.state.stage ~= "todo" then
		return
	end
	local idx = entry_index_under_cursor()
	if not idx or idx >= #M.state.entries then
		return
	end
	local entries = M.state.entries
	entries[idx], entries[idx + 1] = entries[idx + 1], entries[idx]
	render_todo()
	-- Move cursor down to follow the entry
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		local cur = vim.api.nvim_win_get_cursor(M.state.winid)
		vim.api.nvim_win_set_cursor(
			M.state.winid, { cur[1] + 1, cur[2] }
		)
	end
end

---Move the commit under the cursor up in the list.
function M.move_up()
	if M.state.stage ~= "todo" then
		return
	end
	local idx = entry_index_under_cursor()
	if not idx or idx <= 1 then
		return
	end
	local entries = M.state.entries
	entries[idx], entries[idx - 1] = entries[idx - 1], entries[idx]
	render_todo()
	-- Move cursor up to follow the entry
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		local cur = vim.api.nvim_win_get_cursor(M.state.winid)
		vim.api.nvim_win_set_cursor(
			M.state.winid, { cur[1] - 1, cur[2] }
		)
	end
end

---Execute the interactive rebase with confirmation.
function M.execute()
	if M.state.stage ~= "todo" then
		utils.notify(
			"Select a base branch first",
			vim.log.levels.WARN
		)
		return
	end

	local cfg = M.state.cfg
	if not cfg then
		return
	end

	if #M.state.entries == 0 then
		utils.notify(
			"No commits to rebase", vim.log.levels.WARN
		)
		return
	end

	-- Build preview
	local preview = git_rebase.build_todo(M.state.entries)
	local confirm_msg = ("Execute rebase onto %s?\n\n%s"):format(
		M.state.base_ref, preview
	)

	ui.input.confirm(confirm_msg, function(confirmed)
		if not confirmed then
			return
		end

		utils.notify(
			("Rebasing onto %s..."):format(M.state.base_ref),
			vim.log.levels.INFO
		)

		git_rebase.start_interactive(
			M.state.base_ref,
			M.state.entries,
			{},
			function(err, result)
				if err then
					local output = git.output(result) or err
					local parsed =
						git_conflict
						.parse_conflicted_paths_from_output(
							output
						)
					if #parsed > 0 then
						utils.notify(
							("Rebase has conflicts:\n%s")
								:format(
									table.concat(parsed, "\n")
								),
							vim.log.levels.ERROR
						)
						local conflict_panel =
							require("gitflow.panels.conflict")
						refresh_status_panel_if_open()
						conflict_panel.open(cfg)
					else
						utils.notify(
							err, vim.log.levels.ERROR
						)
					end
					return
				end

				local output = git.output(result)
				if output == "" then
					output = "Rebase completed successfully"
				end
				utils.notify(output, vim.log.levels.INFO)
				refresh_status_panel_if_open()
				emit_post_operation()
				M.close()
			end
		)
	end)
end

function M.close()
	next_picker_request_id()
	next_refresh_request_id()

	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("rebase")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("rebase")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.entries = {}
	M.state.base_ref = nil
	M.state.current_branch = nil
	M.state.stage = "base"
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
