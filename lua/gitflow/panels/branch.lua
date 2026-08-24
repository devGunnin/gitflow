local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")

---@class GitflowBranchPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field line_entries table<integer, GitflowBranchEntry>
---@field view_mode "list"|"graph"
---@field graph_lines GitflowGraphLine[]|nil
---@field graph_current string|nil
---@field request_id integer

local M = {}
local GRAPH_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_branch_graph_hl")

---@type GitflowBranchPanelState
M.state = {
	cfg = nil,
	line_entries = {},
	view_mode = "list",
	graph_lines = nil,
	graph_current = nil,
}

local P = panel.new({
	name = "branch",
	title = "Gitflow Branches",
	filetype = "gitflowbranch",
	loading = "Loading branches…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "switch", views = { "list" }, essential = true,
			run = function()
			M.switch_under_cursor()
		end },
		{ key = "c", desc = "create", views = { "list" }, essential = true,
			run = function()
			M.create_branch()
		end },
		{ key = "d", desc = "delete", views = { "list" }, destructive = true,
			run = function()
			M.delete_under_cursor(false)
		end },
		{ key = "D", desc = "force delete", views = { "list" }, destructive = true,
			run = function()
				M.delete_under_cursor(true)
			end },
		{ key = "m", desc = "merge", views = { "list" }, run = function()
			M.merge_under_cursor()
		end },
		{ key = "u", desc = "update", views = { "list" }, run = function()
			M.update_under_cursor()
		end },
		-- Not `M`: that is a vim motion, and the PR panel's merge family
		-- claims it for auto-merge, which is destructive.
		{ key = "e", desc = "rename", views = { "list" }, run = function()
			M.rename_under_cursor()
		end },
		{ key = ".", desc = "current", views = { "list" }, run = function()
			M.jump_to_current()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh_with_fetch()
		end },
		{ key = "f", desc = "fetch", run = function()
			M.fetch_remotes()
		end },
		{ key = "G", desc = "graph", views = { "list" }, run = function()
			M.toggle_view()
		end },
		-- Same key, view-specific wording; bound once by the entry above.
		{ key = "G", desc = "list", views = { "graph" }, bind = false,
			run = function()
				M.toggle_view()
			end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

---@param result GitflowGitResult
---@param fallback string
---@return string
local function result_message(result, fallback)
	local output = git.output(result)
	if output == "" then
		return fallback
	end
	return output
end

---@param bufnr integer|nil
local function clear_graph_highlights(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, GRAPH_HIGHLIGHT_NS, 0, -1)
end

---A refresh belongs to the view it was started for: a result landing after
---the user toggled views must not paint over the other one.
---@param token integer
---@param expected_view "list"|"graph"
---@return boolean
local function is_current_refresh(token, expected_view)
	return P:is_active(token) and M.state.view_mode == expected_view
end

---Push a list section (Local / Remote) into the builder.
---@param B GitflowRenderBuilder
---@param icon string
---@param title string
---@param entries GitflowBranchEntry[]
---@param line_entries table<integer, GitflowBranchEntry>
local function append_section(B, icon, title, entries, line_entries)
	components.section(B, icon, title)

	if #entries == 0 then
		components.empty(B, "(none)")
		B:blank()
		return
	end

	for _, entry in ipairs(entries) do
		local entry_icon, group
		if entry.is_current then
			entry_icon = icons.get("branch", "current")
			group = "GitflowBranchCurrent"
		elseif entry.is_remote then
			entry_icon = icons.get("branch", "remote")
			group = "GitflowBranchRemote"
		else
			entry_icon = icons.get("branch", "local_branch")
			group = "GitflowCardTitle"
		end

		local chunks = {
			{ components.spacing.gutter, nil },
			{ entry_icon ~= "" and (entry_icon .. "  ") or "", group },
			{ entry.name, group },
		}
		if entry.is_current then
			chunks[#chunks + 1] = { " (current)", "GitflowMeta" }
		end
		local line_no = B:push(chunks)
		line_entries[line_no] = entry
	end
	B:blank()
end

---@param entries GitflowBranchEntry[]
local function render_list(entries)
	local local_entries, remote_entries = git_branch.partition(entries)

	local current_name
	for _, entry in ipairs(entries) do
		if entry.is_current then
			current_name = entry.name
			break
		end
	end

	local B = P:begin_render()

	-- Summary bar: branch icon + current branch + local/remote counts.
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("branch", "current") .. "  ", "GitflowSectionIcon" },
		{ current_name or "(detached)", "GitflowSectionTitle" },
		{ (components.separators.field .. "%d local"):format(#local_entries), "GitflowMeta" },
		{ "  " .. components.glyphs.bullet .. "  ", "GitflowMeta" },
		{ ("%d remote"):format(#remote_entries), "GitflowMeta" },
	})
	B:blank()

	local line_entries = {}
	append_section(
		B, icons.get("branch", "local_branch"), "Local", local_entries, line_entries
	)
	append_section(
		B, icons.get("branch", "remote"), "Remote", remote_entries, line_entries
	)

	P:push_hints(B, "list")

	clear_graph_highlights(M.state.bufnr)
	if P:paint(B) then
		M.state.line_entries = line_entries
	end
end

-- ── Graph rendering ──────────────────────────────────────────────────
local GRAPH_NODE = "\u{25CF}" -- ●

local GRAPH_LANE_GROUPS = {
	"GitflowGraphBranch1",
	"GitflowGraphBranch2",
	"GitflowGraphBranch3",
	"GitflowGraphBranch4",
	"GitflowGraphBranch5",
	"GitflowGraphBranch6",
	"GitflowGraphBranch7",
	"GitflowGraphBranch8",
}

---@class GitflowGraphBadge
---@field text string
---@field kind "ref"|"tag"
---@field is_current boolean

---@class GitflowGraphBadgeRange
---@field text string
---@field kind "ref"|"tag"
---@field is_current boolean
---@field start_col integer
---@field end_col integer

---@class GitflowGraphRenderRow
---@field line string
---@field lane_text string
---@field lane_start integer
---@field hash_start integer|nil
---@field hash_end integer|nil
---@field subject_start integer|nil
---@field subject_end integer|nil
---@field badges GitflowGraphBadgeRange[]

---@param graph string
---@return string
local function normalize_graph_text(graph)
	local line = graph or ""
	line = line:gsub("%*", GRAPH_NODE)
	line = line:gsub("|", "\u{2502}") -- │
	line = line:gsub("/", "\u{2571}") -- ╱
	line = line:gsub("\\", "\u{2572}") -- ╲
	line = line:gsub("_", "\u{2500}") -- ─
	line = line:gsub("-", "\u{2500}") -- ─
	line = line:gsub("%.", "\u{00B7}") -- ·
	return line
end

---@param text string
---@param width integer
---@return string
local function pad_graph_text(text, width)
	local missing = width - vim.fn.strdisplaywidth(text)
	if missing <= 0 then
		return text
	end
	return text .. string.rep(" ", missing)
end

---@param decoration string|nil
---@param current_branch string|nil
---@return GitflowGraphBadge[]
local function parse_graph_badges(decoration, current_branch)
	local badges = {}
	if not decoration or decoration == "" then
		return badges
	end

	---@type table<string, GitflowGraphBadge>
	local by_text = {}

	for _, token in ipairs(vim.split(decoration, ",", { trimempty = true })) do
		local raw = vim.trim(token)
		if raw ~= "" then
			local text = raw
			local is_current = false
			local head_target = raw:match("^HEAD%s*%-%>%s*(.+)$")
			if head_target then
				text = vim.trim(head_target)
				is_current = true
			elseif current_branch and raw == current_branch then
				is_current = true
			end

			if text ~= "" then
				local existing = by_text[text]
				if existing then
					existing.is_current = existing.is_current or is_current
				else
					local badge = {
						text = text,
						kind = text:find("^tag:%s*") and "tag" or "ref",
						is_current = is_current,
					}
					badges[#badges + 1] = badge
					by_text[text] = badge
				end
			end
		end
	end

	return badges
end

---@param badge GitflowGraphBadge
---@return string
local function badge_text(badge)
	if badge.is_current then
		return ("[current:%s]"):format(badge.text)
	end
	return ("[%s]"):format(badge.text)
end

---@param text string
---@return string
local function lane_group_for_text(text)
	local sum = 0
	for i = 1, #text do
		sum = (sum + text:byte(i)) % #GRAPH_LANE_GROUPS
	end
	return GRAPH_LANE_GROUPS[(sum % #GRAPH_LANE_GROUPS) + 1]
end

---@param lane_index integer
---@return string
local function lane_group_for_column(lane_index)
	return GRAPH_LANE_GROUPS[((lane_index - 1) % #GRAPH_LANE_GROUPS) + 1]
end

---@param text string
---@param char_index integer
---@return integer
local function str_byte_index(text, char_index)
	local ok, idx = pcall(vim.str_byteindex, text, char_index)
	if ok and type(idx) == "number" then
		return idx
	end
	return char_index
end

---@param graph_entries GitflowGraphLine[]
---@param current_branch string|nil
---@return GitflowGraphRenderRow[], integer
local function build_graph_rows(graph_entries, current_branch)
	local lane_width = 8
	for _, entry in ipairs(graph_entries) do
		local lane = normalize_graph_text(entry.graph or "")
		lane_width = math.max(lane_width, vim.fn.strdisplaywidth(lane))
	end

	---@type GitflowGraphRenderRow[]
	local rows = {}
	for _, entry in ipairs(graph_entries) do
		local lane = normalize_graph_text(entry.graph or "")
		if lane == "" then
			lane = " "
		end
		local lane_text = pad_graph_text(lane, lane_width)
		local line = "  " .. lane_text
		local row = {
			line = "",
			lane_text = lane_text,
			lane_start = 2,
			hash_start = nil,
			hash_end = nil,
			subject_start = nil,
			subject_end = nil,
			badges = {},
		}

		if entry.hash and entry.hash ~= "" then
			line = line .. "  " .. entry.hash
			row.hash_start = #line - #entry.hash
			row.hash_end = #line
		end

		local subject = entry.subject and vim.trim(entry.subject) or ""
		if subject ~= "" then
			line = line .. "  " .. subject
			row.subject_start = #line - #subject
			row.subject_end = #line
		end

		local badges = parse_graph_badges(entry.decoration, current_branch)
		if #badges > 0 then
			line = line .. "  "
			for idx, badge in ipairs(badges) do
				if idx > 1 then
					line = line .. " "
				end
				local label = badge_text(badge)
				local start_col = #line
				line = line .. label
				row.badges[#row.badges + 1] = {
					text = badge.text,
					kind = badge.kind,
					is_current = badge.is_current,
					start_col = start_col,
					end_col = #line,
				}
			end
		end

		row.line = line
		rows[#rows + 1] = row
	end

	return rows, lane_width
end

---Apply per-segment highlights to flowchart graph lines.
---@param bufnr integer
---@param rows GitflowGraphRenderRow[]
---@param first_row_line integer
local function apply_graph_highlights(bufnr, rows, first_row_line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, GRAPH_HIGHLIGHT_NS, 0, -1)

	for i, row in ipairs(rows) do
		local line_idx = first_row_line + i - 2
		local lane_chars = vim.fn.strchars(row.lane_text)
		for lane_idx = 1, lane_chars do
			local ch = vim.fn.strcharpart(row.lane_text, lane_idx - 1, 1)
			if ch ~= " " then
				local start_col = row.lane_start
					+ str_byte_index(row.lane_text, lane_idx - 1)
				local end_col = row.lane_start
					+ str_byte_index(row.lane_text, lane_idx)
				local hl_group = ch == GRAPH_NODE
					and "GitflowGraphNode"
					or lane_group_for_column(lane_idx)
				ui_render.highlight(
					bufnr,
					GRAPH_HIGHLIGHT_NS,
					hl_group,
					line_idx,
					start_col,
					end_col
				)
			end
		end

		if row.hash_start and row.hash_end then
			ui_render.highlight(
				bufnr,
				GRAPH_HIGHLIGHT_NS,
				"GitflowGraphHash",
				line_idx,
				row.hash_start,
				row.hash_end
			)
		end

		if row.subject_start and row.subject_end then
			ui_render.highlight(
				bufnr,
				GRAPH_HIGHLIGHT_NS,
				"GitflowGraphSubject",
				line_idx,
				row.subject_start,
				row.subject_end
			)
		end

		for _, badge in ipairs(row.badges) do
			local hl_group
			if badge.is_current then
				hl_group = "GitflowGraphCurrent"
			elseif badge.kind == "tag" then
				hl_group = "GitflowGraphDecoration"
			else
				hl_group = lane_group_for_text(badge.text)
			end
			ui_render.highlight(
				bufnr,
				GRAPH_HIGHLIGHT_NS,
				hl_group,
				line_idx,
				badge.start_col,
				badge.end_col
			)
		end
	end
end

---Render graph view from parsed graph data.
---@param graph_entries GitflowGraphLine[]
---@param current_branch string|nil
local function render_graph(graph_entries, current_branch)
	local rows, lane_width = build_graph_rows(graph_entries, current_branch)
	local B = P:begin_render("Branch Flowchart")
	local lane_header = pad_graph_text("Flow", lane_width)
	B:raw(
		("%s%s  Commit    Message / Branches"):format(
			components.spacing.gutter, lane_header
		),
		"GitflowTitle"
	)
	B:raw(ui_render.separator(P:render_opts()), "GitflowSeparator")

	local first_row_line = B:count() + 1
	for _, row in ipairs(rows) do
		B:raw(row.line)
	end
	if #rows == 0 then
		components.empty(B, "No commits to visualize")
	end

	P:push_hints(B, "graph")

	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	clear_graph_highlights(bufnr)
	if not P:paint(B) then
		return
	end

	if #rows > 0 then
		apply_graph_highlights(bufnr, rows, first_row_line)
	end
end

---@return GitflowBranchEntry|nil
local function entry_under_cursor()
	if M.state.view_mode == "graph" then
		return nil
	end
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

function M.refresh()
	if M.state.view_mode == "graph" then
		M.refresh_graph()
		return
	end
	local refresh_token = P:next_request()
	git_branch.list({}, function(err, entries)
		if not is_current_refresh(refresh_token, "list") then
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			P:render_error("Could not list branches", {
				detail = err, hint = "r retries", view = "list",
			})
			return
		end
		render_list(entries or {})
	end)
end

function M.refresh_graph()
	local refresh_token = P:next_request()
	git_branch.graph({}, function(err, graph_entries, current_branch)
		if not is_current_refresh(refresh_token, "graph") then
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			P:render_error("Could not build the branch graph", {
				detail = err, hint = "r retries", view = "graph",
			})
			return
		end
		M.state.graph_lines = graph_entries
		M.state.graph_current = current_branch
		render_graph(graph_entries or {}, current_branch)
	end)
end

---Fetch, then repaint the open panel in place (#427): seeing branches the
---fetch just brought in must never need a close/reopen.
---@param show_success_message boolean
local function fetch_then_refresh(show_success_message)
	git_branch.fetch(nil, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			if P:is_open() then
				P:render_error("Fetch failed", {
					detail = err, hint = "r retries", view = M.state.view_mode,
				})
			end
			return
		end
		if show_success_message then
			utils.notify(
				result_message(result, "Fetched remote branches"),
				vim.log.levels.INFO
			)
		end
		if P:is_open() then
			M.refresh()
		end
	end)
end

function M.refresh_with_fetch()
	fetch_then_refresh(false)
end

function M.fetch_remotes()
	fetch_then_refresh(true)
end

function M.toggle_view()
	if M.state.view_mode == "list" then
		M.state.view_mode = "graph"
	else
		M.state.view_mode = "list"
	end

	P:refresh_footer(M.state.view_mode)
	M.refresh()
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	if not P:ensure_window(cfg, { view = M.state.view_mode }) then
		return
	end
	M.refresh()
end

---Lowest rendered line holding the checked-out branch, nil when not rendered.
---@return integer|nil
local function current_branch_line()
	local target
	for line, entry in pairs(M.state.line_entries) do
		if entry.is_current and (target == nil or line < target) then
			target = line
		end
	end
	return target
end

---Move the cursor to the checked-out branch. Absent from the view (detached
---HEAD, or not listed) is an ordinary case: warn, leave the cursor put.
function M.jump_to_current()
	if M.state.view_mode == "graph" then
		utils.notify(
			"Switch to list view (G) to jump to the current branch",
			vim.log.levels.INFO
		)
		return
	end

	local bufnr = M.state.bufnr
	local winid = M.state.winid
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end

	local target = current_branch_line()
	if not target or target > vim.api.nvim_buf_line_count(bufnr) then
		utils.notify("No current branch in view", vim.log.levels.WARN)
		return
	end

	vim.api.nvim_win_set_cursor(winid, { target, 0 })
end

function M.switch_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		if M.state.view_mode == "graph" then
			utils.notify(
				"Switch to list view (G) to select branches",
				vim.log.levels.INFO
			)
		else
			utils.notify("No branch selected", vim.log.levels.WARN)
		end
		return
	end

	if entry.is_current then
		utils.notify(
			("Already on '%s'"):format(entry.name),
			vim.log.levels.INFO
		)
		return
	end

	local function switch_to_entry()
		git_branch.switch(entry, {}, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				result_message(
					result, ("Switched to %s"):format(entry.name)
				),
				vim.log.levels.INFO
			)
			M.refresh()
		end)
	end

	if entry.is_remote then
		git_branch.fetch(entry.remote, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			switch_to_entry()
		end)
		return
	end

	switch_to_entry()
end

function M.create_branch()
	local selected = entry_under_cursor()
	ui.input.prompt({
		prompt = "New branch name: ",
	}, function(name)
		local branch_name = vim.trim(name)
		if branch_name == "" then
			utils.notify("Branch name cannot be empty", vim.log.levels.WARN)
			return
		end

		local function run_create(base)
			git_branch.create(branch_name, base, {}, function(err, result)
				if err then
					utils.notify(err, vim.log.levels.ERROR)
					return
				end
				utils.notify(
					result_message(
						result,
						("Created branch '%s'"):format(branch_name)
					),
					vim.log.levels.INFO
				)
				M.refresh()
			end)
		end

		if not selected then
			run_create(nil)
			return
		end

		local confirmed = ui.input.confirm(
			("Create '%s' from '%s'?"):format(branch_name, selected.name),
			{ choices = { "&Yes", "&No" }, default_choice = 1 }
		)
		if confirmed then
			run_create(selected.name)
			return
		end
		run_create(nil)
	end)
end

---@param force boolean
function M.delete_under_cursor(force)
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No branch selected", vim.log.levels.WARN)
		return
	end

	if entry.is_remote then
		utils.notify(
			"Remote branch deletion is not supported in this panel",
			vim.log.levels.WARN
		)
		return
	end
	if entry.is_current then
		utils.notify("Cannot delete the current branch", vim.log.levels.WARN)
		return
	end

	local function run_delete(delete_force)
		git_branch.delete(entry.name, delete_force, {}, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				result_message(
					result,
					("Deleted branch '%s'"):format(entry.name)
				),
				vim.log.levels.INFO
			)
			M.refresh()
		end)
	end

	if force then
		local confirmed = ui.input.confirm(
			("Force delete branch '%s'?"):format(entry.name),
			{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
		)
		if confirmed then
			run_delete(true)
		end
		return
	end

	git_branch.list_merged({}, function(err, merged)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		local is_merged = merged and merged[entry.name] == true
		if is_merged then
			local confirmed = ui.input.confirm(
				("Delete merged branch '%s'?"):format(entry.name),
				{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
			)
			if confirmed then
				run_delete(false)
			end
			return
		end

		local confirmed = ui.input.confirm(
			("Branch '%s' is not merged. Force delete?"):format(entry.name),
			{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
		)
		if confirmed then
			run_delete(true)
		end
	end)
end

function M.rename_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No branch selected", vim.log.levels.WARN)
		return
	end
	if entry.is_remote then
		utils.notify(
			"Remote branches cannot be renamed", vim.log.levels.WARN
		)
		return
	end

	ui.input.prompt({
		prompt = ("Rename branch '%s' to: "):format(entry.name),
		default = entry.name,
	}, function(new_name)
		local trimmed = vim.trim(new_name)
		if trimmed == "" then
			utils.notify(
				"Branch name cannot be empty", vim.log.levels.WARN
			)
			return
		end
		if trimmed == entry.name then
			utils.notify("Branch name unchanged", vim.log.levels.INFO)
			return
		end

		git_branch.rename(entry.name, trimmed, {}, function(err, result)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				result_message(
					result,
					("Renamed '%s' to '%s'"):format(entry.name, trimmed)
				),
				vim.log.levels.INFO
			)
			M.refresh()
		end)
	end)
end

function M.update_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		if M.state.view_mode == "graph" then
			utils.notify(
				"Switch to list view (G) to update branches",
				vim.log.levels.INFO
			)
		else
			utils.notify("No branch selected", vim.log.levels.WARN)
		end
		return
	end

	utils.notify(
		("Updating '%s'..."):format(entry.name),
		vim.log.levels.INFO
	)
	git_branch.update(entry, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			result_message(
				result,
				("Updated '%s'"):format(entry.name)
			),
			vim.log.levels.INFO
		)
		M.refresh()
	end)
end

function M.merge_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No branch selected", vim.log.levels.WARN)
		return
	end

	if entry.is_current then
		utils.notify("Cannot merge branch into itself", vim.log.levels.WARN)
		return
	end

	local confirmed = ui.input.confirm(
		("Merge '%s' into current branch?"):format(entry.name),
		{ choices = { "&Merge", "&Cancel" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	vim.cmd({ cmd = "Gitflow", args = { "merge", entry.name } })
	vim.schedule(function()
		M.refresh()
	end)
end

function M.close()
	P:close()
	M.state.line_entries = {}
	M.state.view_mode = "list"
	M.state.graph_lines = nil
	M.state.graph_current = nil
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
