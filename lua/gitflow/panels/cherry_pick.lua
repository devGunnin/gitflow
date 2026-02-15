local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_cherry_pick = require("gitflow.git.cherry_pick")
local git_branch = require("gitflow.git.branch")
local git_conflict = require("gitflow.git.conflict")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local list_picker = require("gitflow.ui.list_picker")
local status_panel = require("gitflow.panels.status")

---@class GitflowCherryPickPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowCherryPickEntry>
---@field source_branch string|nil
---@field current_branch string|nil
---@field stage "branch"|"commits"
---@field cfg GitflowConfig|nil
---@field picker_request_id integer
---@field refresh_request_id integer

local M = {}
local CP_FLOAT_TITLE = "Gitflow Cherry Pick"
local CP_FLOAT_FOOTER_COMMITS =
	"<CR> pick  B into branch  b branches  r refresh  q close"
local CP_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_cherry_pick_hl")

---@type GitflowCherryPickPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	source_branch = nil,
	current_branch = nil,
	stage = "branch",
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
---@param source_branch string
---@return boolean
local function is_active_refresh_request(request_id, source_branch)
	return M.state.refresh_request_id == request_id
		and M.is_open()
		and M.state.stage == "commits"
		and M.state.source_branch == source_branch
end

local function refresh_status_panel_if_open()
	if status_panel.is_open() then
		status_panel.refresh()
	end
end

---@param entry GitflowCherryPickEntry
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
		bufnr = ui.buffer.create("cherry_pick", {
			filetype = "gitflowcherrypick",
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
			name = "cherry_pick",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = CP_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and CP_FLOAT_FOOTER_COMMITS or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "cherry_pick",
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

	vim.keymap.set("n", "B", function()
		M.cherry_pick_into_branch()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "b", function()
		M.show_branch_picker()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param commits GitflowCherryPickEntry[]
---@param source_branch string
---@param current_branch string
local function render_commits(commits, source_branch, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Cherry Pick", render_opts
	)
	local line_entries = {}
	local entry_highlights = {}

	-- Branch section header
	local branch_header = ("Source: %s"):format(source_branch)
	lines[#lines + 1] = ui_render.entry(branch_header)
	entry_highlights[#lines] = "GitflowCherryPickBranch"
	lines[#lines + 1] = ui_render.separator(render_opts)

	if #commits == 0 then
		lines[#lines + 1] = ui_render.empty(
			"no unique commits on this branch"
		)
	else
		for idx, entry in ipairs(commits) do
			local commit_icon = icons.get("git_state", "commit")
			local position_marker = ""
			local summary = display_summary(entry)
			if idx <= 9 then
				position_marker = ("[%d] "):format(idx)
			end
			local line_text = ("%s%s %s"):format(
				position_marker,
				commit_icon,
				entry.short_sha
			)
			if summary ~= "" then
				line_text = ("%s %s"):format(line_text, summary)
			end
			lines[#lines + 1] = ui_render.entry(line_text)
			line_entries[#lines] = entry
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("cherry_pick", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, CP_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)

	for line_no, entry in pairs(line_entries) do
		local line_text = lines[line_no] or ""
		local sha_start = line_text:find(entry.short_sha, 1, true)
		if sha_start then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				CP_HIGHLIGHT_NS,
				"GitflowCherryPickHash",
				line_no - 1,
				sha_start - 1,
				sha_start - 1 + #entry.short_sha
			)
		end
	end
end

---@return GitflowCherryPickEntry|nil
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
---@return GitflowCherryPickEntry|nil
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

---@param entry GitflowCherryPickEntry
local function execute_cherry_pick(entry)
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	git_cherry_pick.cherry_pick(entry.sha, function(err, result)
		if err then
			-- Check for conflicts
			local output = git.output(result) or err
			local parsed =
				git_conflict.parse_conflicted_paths_from_output(
					output
				)
			if #parsed > 0 then
				utils.notify(
					("Cherry-pick has conflicts:\n%s"):format(
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
							("Cherry-pick has"
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
			output = ("Cherry-picked %s"):format(
				entry.short_sha
			)
		end
		utils.notify(output, vim.log.levels.INFO)
		refresh_status_panel_if_open()
		emit_post_operation()
		M.refresh()
	end)
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	M.state.stage = "branch"
	ensure_window(cfg)
	M.show_branch_picker()
end

function M.show_branch_picker()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local request_id = next_picker_request_id()
	git_cherry_pick.list_branches({}, function(err, branches)
		if not is_active_picker_request(request_id) then
			return
		end

		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		if not branches or #branches == 0 then
			utils.notify(
				"No other branches found",
				vim.log.levels.WARN
			)
			return
		end

		local items = {}
		for _, branch in ipairs(branches) do
			items[#items + 1] = { name = branch }
		end

		vim.schedule(function()
			if not is_active_picker_request(request_id) then
				return
			end

			list_picker.open({
				items = items,
				title = "Select Source Branch",
				multi_select = false,
				on_submit = function(selected)
					if not is_active_picker_request(request_id) then
						return
					end

					if #selected > 0 then
						next_picker_request_id()
						M.state.source_branch = selected[1]
						M.state.stage = "commits"
						M.refresh()
					end
				end,
				on_cancel = function()
					if not is_active_picker_request(request_id) then
						return
					end

					if M.state.stage == "branch" then
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

	if M.state.stage == "branch" or not M.state.source_branch then
		M.show_branch_picker()
		return
	end

	local source_branch = M.state.source_branch
	local request_id = next_refresh_request_id()
	git_branch.current({}, function(_, branch)
		if not is_active_refresh_request(request_id, source_branch) then
			return
		end

		local current_branch = branch or "(unknown)"
		git_cherry_pick.list_unique_commits(
			source_branch,
			{ count = cfg.git.log.count },
			function(err, entries)
				if not is_active_refresh_request(request_id, source_branch) then
					return
				end

				if err then
					utils.notify(err, vim.log.levels.ERROR)
					return
				end
				M.state.current_branch = current_branch
				render_commits(
					entries or {},
					source_branch,
					current_branch
				)
			end
		)
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
	execute_cherry_pick(entry)
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
	execute_cherry_pick(entry)
end

---Show target-branch picker, then create a new branch and cherry-pick.
---@param entry GitflowCherryPickEntry
local function show_target_branch_picker(entry)
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local source = M.state.source_branch
	if not source then
		utils.notify(
			"No source branch selected", vim.log.levels.WARN
		)
		return
	end

	local request_id = next_picker_request_id()
	git_cherry_pick.list_branches({}, function(err, branches)
		if not is_active_picker_request(request_id) then
			return
		end

		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		if not branches or #branches == 0 then
			utils.notify(
				"No target branches found",
				vim.log.levels.WARN
			)
			return
		end

		local items = {}
		for _, branch in ipairs(branches) do
			items[#items + 1] = { name = branch }
		end

		vim.schedule(function()
			if not is_active_picker_request(request_id) then
				return
			end

			list_picker.open({
				items = items,
				title = "Select Target Branch",
				multi_select = false,
				on_submit = function(selected)
					if not is_active_picker_request(
						request_id
					) then
						return
					end
					if #selected == 0 then
						return
					end

					next_picker_request_id()
					local target = selected[1]
					local new_branch =
						git_cherry_pick.auto_branch_name(
							target, source
						)

					utils.notify(
						("Cherry-picking %s into"
							.. " new branch %s..."):format(
							entry.short_sha, new_branch
						),
						vim.log.levels.INFO
					)

					git_cherry_pick
						.create_branch_and_cherry_pick(
						entry.sha, target, source, {},
						function(cp_err, _, branch_name)
							if cp_err then
								local output = cp_err
								local parsed =
									git_conflict
									.parse_conflicted_paths_from_output(
										output
									)
								if #parsed > 0 then
									utils.notify(
										("Cherry-pick on"
											.. " %s has"
											.. " conflicts"
											):format(
											branch_name
										),
										vim.log.levels
											.ERROR
									)
									local cp =
										require(
											"gitflow"
											.. ".panels"
											.. ".conflict"
										)
									refresh_status_panel_if_open()
									cp.open(cfg)
								else
									utils.notify(
										cp_err,
										vim.log.levels
											.ERROR
									)
								end
								return
							end

							utils.notify(
								("Cherry-picked"
									.. " %s into new"
									.. " branch %s"
									):format(
									entry.short_sha,
									branch_name
								),
								vim.log.levels.INFO
							)
							refresh_status_panel_if_open()
							emit_post_operation()
							M.refresh()
						end
					)
				end,
				on_cancel = function() end,
			})
		end)
	end)
end

---Trigger cherry-pick into a new auto-named branch.
---Prompts for a target branch, creates `<target>-<source>`,
---cherry-picks the selected commit onto it.
function M.cherry_pick_into_branch()
	if M.state.stage ~= "commits" then
		utils.notify(
			"Select a source branch first",
			vim.log.levels.WARN
		)
		return
	end

	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No commit selected", vim.log.levels.WARN
		)
		return
	end

	show_target_branch_picker(entry)
end

function M.close()
	next_picker_request_id()
	next_refresh_request_id()

	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("cherry_pick")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("cherry_pick")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.source_branch = nil
	M.state.current_branch = nil
	M.state.stage = "branch"
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
