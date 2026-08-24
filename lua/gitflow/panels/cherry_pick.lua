local git = require("gitflow.git")
local utils = require("gitflow.utils")
local git_cherry_pick = require("gitflow.git.cherry_pick")
local git_branch = require("gitflow.git.branch")
local git_conflict = require("gitflow.git.conflict")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
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
---@field request_id integer

local M = {}

---@type GitflowCherryPickPanelState
M.state = {
	line_entries = {},
	source_branch = nil,
	current_branch = nil,
	stage = "branch",
	cfg = nil,
	picker_request_id = 0,
}

local POSITION_KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

local P = panel.new({
	name = "cherry_pick",
	title = "Gitflow Cherry Pick",
	filetype = "gitflowcherrypick",
	loading = "Loading branches…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "pick", run = function()
			M.select_under_cursor()
		end },
		{ key = "1-9", keys = POSITION_KEYS, hint = false, run = function(key)
			M.select_by_position(tonumber(key))
		end },
		{ key = "B", desc = "into branch", run = function()
			M.cherry_pick_into_branch()
		end },
		{ key = "b", desc = "branches", run = function()
			M.show_branch_picker()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

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

---A refresh belongs to the (stage, source branch) it started under: a result
---for a branch the user has since switched away from must be dropped.
---@param request_id integer
---@param source_branch string
---@return boolean
local function is_active_refresh_request(request_id, source_branch)
	return P:is_active(request_id)
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

---@param commits GitflowCherryPickEntry[]
---@param source_branch string
---@param current_branch string
local function render_commits(commits, source_branch, current_branch)
	local B = P:begin_render()

	-- Summary bar: commit count + the branch we're picking onto.
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("git_state", "commit") .. "  ", "GitflowSectionIcon" },
		{
			("%d commit%s"):format(#commits, #commits == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ components.separators.field .. icons.get("branch", "current") .. " onto ",
			"GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	-- Source section header (HARD INVARIANT: a header line containing
	-- "Source: <branch>" highlighted GitflowCherryPickBranch, then a separator).
	local source_label = ("Source: %s"):format(source_branch)
	components.section(B, icons.get("branch", "remote"), source_label, {
		title_hl = "GitflowCherryPickBranch",
	})

	local line_entries = {}
	if #commits == 0 then
		components.empty(B, "no unique commits on this branch")
	else
		for idx, entry in ipairs(commits) do
			local summary = display_summary(entry)
			local marker = idx <= 9 and ("[%d] "):format(idx) or ""
			local chunks = {
				{ components.spacing.gutter, nil },
				{ marker, "GitflowNumber" },
				{ icons.get("git_state", "commit") .. "  ", "GitflowLogHash" },
				{ entry.short_sha, "GitflowCherryPickHash" },
			}
			if summary ~= "" then
				chunks[#chunks + 1] = { components.spacing.gutter .. summary, "GitflowCardTitle" }
			end
			local line_no = B:push(chunks)
			line_entries[line_no] = entry
		end
	end

	B:blank()
	P:push_hints(B, nil, { blank_before = false })

	if P:paint(B) then
		M.state.line_entries = line_entries
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
	if not P:ensure_window(cfg) then
		return
	end
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
	local request_id = P:next_request()
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
					P:render_error("Could not list commits to pick", {
						detail = err, hint = "r retries",
					})
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
	git_cherry_pick.list_target_branches({}, function(err, branches)
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

						git_cherry_pick.create_branch_and_cherry_pick(
							entry.sha,
							target,
							source,
							{},
							function(cp_err, cp_result, branch_name)
								if cp_err then
									if not cp_result then
										utils.notify(
											cp_err,
											vim.log.levels.ERROR
										)
										return
									end

									local output =
										git.output(cp_result)
										or cp_err
									local parsed =
										git_conflict
										.parse_conflicted_paths_from_output(
											output
										)
									if #parsed > 0 then
										utils.notify(
											("Cherry-pick on"
												.. " %s has"
												.. " conflicts"):format(
													branch_name
												),
											vim.log.levels.ERROR
										)
										local cp =
											require(
												"gitflow.panels.conflict"
											)
										refresh_status_panel_if_open()
										cp.open(cfg)
									else
										git_conflict.list(
											{},
											function(c_err, conflicted)
												if c_err
													or #(
														conflicted
														or {}
													) == 0
												then
													utils.notify(
														cp_err,
														vim.log.levels.ERROR
													)
													return
												end
												utils.notify(
													("Cherry-pick on"
														.. " %s has"
														.. " conflicts:\n%s")
														:format(
															branch_name,
															table.concat(
																conflicted,
																"\n"
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

								utils.notify(
									("Cherry-picked"
										.. " %s into new"
										.. " branch %s"):format(
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
	P:close()
	M.state.line_entries = {}
	M.state.source_branch = nil
	M.state.current_branch = nil
	M.state.stage = "branch"
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
