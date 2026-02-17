local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local config = require("gitflow.config")

---@class GitflowBranchPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field line_entries table<integer, GitflowBranchEntry>
---@field view_mode "list"|"graph"
---@field graph_lines GitflowGraphLine[]|nil
---@field graph_current string|nil
---@field refresh_token integer

local M = {}
local BRANCH_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_branch_hl")
local GRAPH_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_branch_graph_hl")
local BRANCH_FLOAT_TITLE = "Gitflow Branches"
local LIST_FOOTER =
	"<CR> switch  c create  d delete  D force delete  m merge"
	.. "  r rename  R refresh  f fetch  G graph  q close"
local GRAPH_FOOTER =
	"R refresh  f fetch  G list  q close"

---@type GitflowBranchPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	line_entries = {},
	view_mode = "list",
	graph_lines = nil,
	graph_current = nil,
	refresh_token = 0,
}

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

---@return string
local function current_footer()
	if M.state.view_mode == "graph" then
		return GRAPH_FOOTER
	end
	return LIST_FOOTER
end

---@param bufnr integer|nil
local function clear_graph_highlights(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, GRAPH_HIGHLIGHT_NS, 0, -1)
end

---@return integer
local function next_refresh_token()
	M.state.refresh_token = (M.state.refresh_token or 0) + 1
	return M.state.refresh_token
end

---@param token integer
---@param expected_view "list"|"graph"
---@return boolean
local function is_current_refresh(token, expected_view)
	if token ~= M.state.refresh_token then
		return false
	end
	if M.state.view_mode ~= expected_view then
		return false
	end
	local bufnr = M.state.bufnr
	return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("branch", {
			filetype = "gitflowbranch",
			lines = { "Loading branches..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "branch",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = BRANCH_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and current_footer() or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "branch",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	local key = config.resolve_panel_key(cfg, "branch", "switch", "<CR>")
	vim.keymap.set("n", key, function()
		M.switch_under_cursor()
	end, { buffer = bufnr, silent = true })

	key = config.resolve_panel_key(cfg, "branch", "create", "c")
	vim.keymap.set("n", key, function()
		M.create_branch()
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "delete", "d")
	vim.keymap.set("n", key, function()
		M.delete_under_cursor(false)
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "force_delete", "D")
	vim.keymap.set("n", key, function()
		M.delete_under_cursor(true)
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "rename", "r")
	vim.keymap.set("n", key, function()
		M.rename_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "refresh", "R")
	vim.keymap.set("n", key, function()
		M.refresh_with_fetch()
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "fetch", "f")
	vim.keymap.set("n", key, function()
		M.fetch_remotes()
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "merge", "m")
	vim.keymap.set("n", key, function()
		M.merge_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "toggle_graph", "G")
	vim.keymap.set("n", key, function()
		M.toggle_view()
	end, { buffer = bufnr, silent = true, nowait = true })

	key = config.resolve_panel_key(cfg, "branch", "close", "q")
	vim.keymap.set("n", key, function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param title string
---@param entries GitflowBranchEntry[]
---@param lines string[]
---@param line_entries table<integer, GitflowBranchEntry>
---@param render_opts table
local function append_section(title, entries, lines, line_entries, render_opts)
	local section_title, section_separator = ui_render.section(title, nil, render_opts)
	lines[#lines + 1] = section_title
	lines[#lines + 1] = section_separator
	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty()
		lines[#lines + 1] = ""
		return
	end

	for _, entry in ipairs(entries) do
		local marker
		if entry.is_current then
			marker = icons.get("branch", "current")
		elseif entry.is_remote then
			marker = icons.get("branch", "remote")
		else
			marker = icons.get("branch", "local_branch")
		end
		local current_text = entry.is_current and " (current)" or ""
		local line = ui_render.entry(
			("%s %s%s"):format(marker, entry.name, current_text)
		)
		lines[#lines + 1] = line
		line_entries[#lines] = entry
	end
	lines[#lines + 1] = ""
end

---@param entries GitflowBranchEntry[]
local function render_list(entries)
	local local_entries, remote_entries = git_branch.partition(entries)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Branches", render_opts)
	local line_entries = {}

	append_section("Local", local_entries, lines, line_entries, render_opts)
	append_section("Remote", remote_entries, lines, line_entries, render_opts)

	ui.buffer.update("branch", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	clear_graph_highlights(bufnr)

	local entry_highlights = {}

	for line_no, line in ipairs(lines) do
		if line == "Local" or line == "Remote" then
			entry_highlights[line_no] = "GitflowHeader"
		end
	end

	for line_no, entry in pairs(line_entries) do
		if entry.is_current then
			entry_highlights[line_no] = "GitflowBranchCurrent"
		elseif entry.is_remote then
			entry_highlights[line_no] = "GitflowBranchRemote"
		end
	end

	ui_render.apply_panel_highlights(bufnr, BRANCH_HIGHLIGHT_NS, lines, {
		entry_highlights = entry_highlights,
	})
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
				vim.api.nvim_buf_add_highlight(
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
			vim.api.nvim_buf_add_highlight(
				bufnr,
				GRAPH_HIGHLIGHT_NS,
				"GitflowGraphHash",
				line_idx,
				row.hash_start,
				row.hash_end
			)
		end

		if row.subject_start and row.subject_end then
			vim.api.nvim_buf_add_highlight(
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
			vim.api.nvim_buf_add_highlight(
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
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}

	local rows, lane_width = build_graph_rows(graph_entries, current_branch)
	local lines = ui_render.panel_header("Branch Flowchart", render_opts)
	local column_line = #lines + 1
	local lane_header = pad_graph_text("Flow", lane_width)
	lines[#lines + 1] = ("  %s  Commit    Message / Branches"):format(lane_header)
	lines[#lines + 1] = ui_render.separator(render_opts)

	local first_row_line = #lines + 1
	for _, row in ipairs(rows) do
		lines[#lines + 1] = row.line
	end
	if #rows == 0 then
		lines[#lines + 1] = ui_render.empty("No commits to visualize")
	end

	ui.buffer.update("branch", lines)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	clear_graph_highlights(bufnr)

	ui_render.apply_panel_highlights(bufnr, BRANCH_HIGHLIGHT_NS, lines, {
		entry_highlights = {
			[column_line] = "GitflowHeader",
		},
	})

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
	local refresh_token = next_refresh_token()
	git_branch.list({}, function(err, entries)
		if not is_current_refresh(refresh_token, "list") then
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_list(entries or {})
	end)
end

function M.refresh_graph()
	local refresh_token = next_refresh_token()
	git_branch.graph({}, function(err, graph_entries, current_branch)
		if not is_current_refresh(refresh_token, "graph") then
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		M.state.graph_lines = graph_entries
		M.state.graph_current = current_branch
		render_graph(graph_entries or {}, current_branch)
	end)
end

---@param show_success_message boolean
local function fetch_then_refresh(show_success_message)
	git_branch.fetch(nil, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		if show_success_message then
			utils.notify(
				result_message(result, "Fetched remote branches"),
				vim.log.levels.INFO
			)
		end
		M.refresh()
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

	-- Update float footer if applicable
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		local ok, win_cfg = pcall(vim.api.nvim_win_get_config, M.state.winid)
		if ok and win_cfg and win_cfg.relative and win_cfg.relative ~= "" then
			local cfg = M.state.cfg
			local footer_enabled = cfg
				and cfg.ui
				and cfg.ui.float
				and cfg.ui.float.footer
			if footer_enabled and vim.fn.has("nvim-0.10") == 1 then
				pcall(vim.api.nvim_win_set_config, M.state.winid, {
					footer = current_footer(),
				})
			end
		end
	end

	M.refresh()
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	M.refresh()
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
			run_delete(false)
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
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("branch")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("branch")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.view_mode = "list"
	M.state.graph_lines = nil
	M.state.graph_current = nil
	M.state.refresh_token = (M.state.refresh_token or 0) + 1
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
