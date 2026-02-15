local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")

---@class GitflowBranchPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field line_entries table<integer, GitflowBranchEntry>
---@field view_mode "list"|"graph"
---@field graph_lines GitflowGraphLine[]|nil
---@field graph_current string|nil

local M = {}
local BRANCH_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_branch_hl")
local GRAPH_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_branch_graph_hl")
local BRANCH_FLOAT_TITLE = "Gitflow Branches"
local LIST_FOOTER =
	"<CR> switch  c create  d delete  D force delete  r rename"
	.. "  R refresh  f fetch  G graph  q close"
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

	vim.keymap.set("n", "<CR>", function()
		M.switch_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "c", function()
		M.create_branch()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "d", function()
		M.delete_under_cursor(false)
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "D", function()
		M.delete_under_cursor(true)
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.rename_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "R", function()
		M.refresh_with_fetch()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "f", function()
		M.fetch_remotes()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "G", function()
		M.toggle_view()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
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

-- ── Graph colors ────────────────────────────────────────────────────
-- Cycle through colors for graph columns to distinguish branches.
local GRAPH_COLORS = {
	"GitflowGraphLine",
	"GitflowBranchCurrent",
	"GitflowDiffHunkHeader",
	"GitflowLogHash",
	"GitflowStashRef",
	"GitflowAdded",
	"GitflowRemoved",
}

---Apply per-segment highlights to graph lines using extmarks.
---@param bufnr integer
---@param lines string[]
---@param graph_entries GitflowGraphLine[]
---@param current_branch string|nil
local function apply_graph_highlights(bufnr, lines, graph_entries, current_branch)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, GRAPH_HIGHLIGHT_NS, 0, -1)

	-- Determine the header offset: lines before actual graph data starts
	local header_offset = #lines - #graph_entries

	for i, entry in ipairs(graph_entries) do
		local line_idx = header_offset + i - 1
		if line_idx < 0 or line_idx >= #lines then
			goto continue
		end

		local raw = lines[line_idx + 1]
		if not raw then
			goto continue
		end

		-- Highlight graph prefix characters with cycling colors
		local graph_len = #entry.graph
		if graph_len > 0 then
			-- Determine color based on which "column" the commit marker * is in
			local star_col = entry.graph:find("%*")
			local color_idx = star_col
				and ((star_col - 1) % #GRAPH_COLORS) + 1
				or 1
			vim.api.nvim_buf_add_highlight(
				bufnr, GRAPH_HIGHLIGHT_NS,
				GRAPH_COLORS[color_idx],
				line_idx, 0, graph_len
			)
		end

		-- Highlight commit hash
		if entry.hash then
			local hash_start = raw:find(entry.hash, graph_len + 1, true)
			if hash_start then
				vim.api.nvim_buf_add_highlight(
					bufnr, GRAPH_HIGHLIGHT_NS,
					"GitflowGraphHash",
					line_idx,
					hash_start - 1,
					hash_start - 1 + #entry.hash
				)
			end
		end

		-- Highlight decorations (branch/tag names)
		if entry.decoration and entry.decoration ~= "" then
			local deco_pattern = "(" .. vim.pesc(entry.decoration) .. ")"
			local deco_start = raw:find(deco_pattern, 1, true)
			if deco_start then
				-- Check if current branch appears in decoration
				local hl_group = "GitflowGraphDecoration"
				if current_branch
					and entry.decoration:find(current_branch, 1, true)
				then
					hl_group = "GitflowGraphCurrent"
				end
				vim.api.nvim_buf_add_highlight(
					bufnr, GRAPH_HIGHLIGHT_NS,
					hl_group,
					line_idx,
					deco_start - 1,
					deco_start - 1 + #entry.decoration + 2 -- include parens
				)
			end
		end

		::continue::
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
	local lines = ui_render.panel_header("Branch Graph", render_opts)

	for _, entry in ipairs(graph_entries) do
		lines[#lines + 1] = entry.raw
	end

	ui.buffer.update("branch", lines)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Apply standard panel highlights for header/separator
	ui_render.apply_panel_highlights(bufnr, BRANCH_HIGHLIGHT_NS, lines, {})

	-- Apply graph-specific highlights
	apply_graph_highlights(bufnr, lines, graph_entries, current_branch)
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
	git_branch.list({}, function(err, entries)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_list(entries or {})
	end)
end

function M.refresh_graph()
	git_branch.graph({}, function(err, graph_entries, current_branch)
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
			if vim.fn.has("nvim-0.10") == 1 then
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
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
