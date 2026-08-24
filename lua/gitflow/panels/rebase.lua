local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_rebase = require("gitflow.git.rebase")
local git_branch = require("gitflow.git.branch")
local git_conflict = require("gitflow.git.conflict")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local status_panel = require("gitflow.panels.status")

---@class GitflowRebasePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowRebaseEntry>
---@field entries GitflowRebaseEntry[]
---@field base_ref string|nil
---@field current_branch string|nil
---@field stage "base"|"normal"|"todo"
---@field cfg GitflowConfig|nil
---@field picker_request_id integer
---@field request_id integer
---@field focused_line integer|nil
---@field preview_winid integer|nil
---@field preview_bufnr integer|nil
---@field base_line_branches table<integer, GitflowBranchEntry>

local M = {}

---@type GitflowRebasePanelState
M.state = {
	line_entries = {},
	entries = {},
	base_ref = nil,
	current_branch = nil,
	stage = "base",
	cfg = nil,
	picker_request_id = 0,
	focused_line = nil,
	preview_winid = nil,
	preview_bufnr = nil,
	base_line_branches = {},
}

---@type table<string, string>  action key -> rebase action
local ACTION_KEYS = {
	p = "pick", r = "reword", e = "edit",
	s = "squash", f = "fixup", d = "drop",
}

local P = panel.new({
	name = "rebase",
	title = "Gitflow Rebase",
	filetype = "gitflowrebase",
	loading = "Loading branches…",
	state = M.state,
	keymaps = {
		-- <CR> means "pick this base" in the base stage and "cycle the action"
		-- in the todo stage; one binding routes, two entries word it per view.
		{ key = "<CR>", desc = "cycle", views = { "todo" }, run = function()
			if M.state.stage == "base" then
				M.select_base_branch()
			else
				M.cycle_action()
			end
		end },
		{ key = "<CR>", desc = "select", views = { "base" }, bind = false,
			run = function()
				M.select_base_branch()
			end },
		{ key = "p/r/e/s/f/d", keys = { "p", "r", "e", "s", "f", "d" },
			desc = "action", views = { "todo" }, run = function(key)
				M.set_action(ACTION_KEYS[key])
			end },
		{ key = "J/K", keys = { "J", "K" }, desc = "move", views = { "todo" },
			run = function(key)
				if key == "J" then
					M.move_down()
				else
					M.move_up()
				end
			end },
		{ key = "X", desc = "execute", views = { "todo", "normal" },
			essential = true, run = function()
				M.execute()
			end },
		{ key = "i", desc = "interactive", views = { "normal" }, run = function()
			M.switch_to_interactive()
		end },
		{ key = "P", desc = "preview", views = { "todo", "normal" },
			run = function()
				M.toggle_preview()
			end },
		{ key = "b", desc = "base", views = { "todo", "normal" }, run = function()
			M.show_base_picker()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

local ACTIONS = { "pick", "reword", "edit", "squash", "fixup", "drop" }

local ACTION_HIGHLIGHTS = {
	pick   = "GitflowRebasePick",
	reword = "GitflowRebaseReword",
	edit   = "GitflowRebaseEdit",
	squash = "GitflowRebaseSquash",
	fixup  = "GitflowRebaseFixup",
	drop   = "GitflowRebaseDrop",
}

local ACTION_GLYPHS = {
	pick   = "●",
	reword = "~",
	edit   = "≡",
	squash = "⊕",
	fixup  = "⊙",
	drop   = "✗",
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

---A refresh belongs to the (stage, base ref) it started under; anything else
---is a superseded result and must not paint.
---@param request_id integer
---@param base_ref string
---@return boolean
local function is_active_refresh_request(request_id, base_ref)
	return P:is_active(request_id)
		and (M.state.stage == "todo" or M.state.stage == "normal")
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

local render_todo           -- forward declaration; defined after ensure_window
local render_normal         -- forward declaration; defined after render_todo
local refresh_float_footer  -- forward declaration; defined before render_base_picker

---Open the panel window and wire the focus-follows-cursor repaint. The
---autocmd is registered once per buffer, alongside the base's own setup.
---@param cfg GitflowConfig
---@return boolean opened
local function ensure_window(cfg)
	local fresh_buffer = not P:is_open()
	if not P:ensure_window(cfg, { view = M.state.stage }) then
		return false
	end
	if not fresh_buffer then
		return true
	end

	local bufnr = M.state.bufnr
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = bufnr,
		callback = function()
			if vim.api.nvim_get_current_buf() ~= bufnr then
				return
			end
			local line = vim.api.nvim_win_get_cursor(0)[1]
			if line == M.state.focused_line then
				return
			end
			M.state.focused_line = line
			if M.state.stage == "todo" then
				render_todo()
			elseif M.state.stage == "normal" then
				render_normal()
			else
				return
			end
			if M.state.preview_winid
				and vim.api.nvim_win_is_valid(M.state.preview_winid)
			then
				M.refresh_preview()
			end
		end,
	})
	return true
end

---Render the interactive rebase todo list.
render_todo = function()
	local B = P:begin_render("Gitflow Interactive Rebase")

	local commit_icon = icons.get("git_state", "commit")
	local branch_icon = icons.get("branch", "current")
	local base_icon = icons.get("branch", "remote")
	local count = #M.state.entries
	local current_branch = (M.state.current_branch
		and M.state.current_branch ~= "")
		and M.state.current_branch or "(unknown)"

	-- Summary bar: commit count + current branch context.
	B:push({
		{ components.spacing.gutter, nil },
		{ commit_icon .. "  ", "GitflowSectionIcon" },
		{
			("%d commit%s"):format(count, count == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ components.separators.field .. branch_icon .. " ", "GitflowMetaKey" },
		{ current_branch, "GitflowBranchCurrent" },
	})

	-- Base ref as a meta_row (item 4).
	components.meta_row(B, "Base:", {
		{ base_icon .. " ", "GitflowSectionIcon" },
		{ M.state.base_ref or "(none)", "GitflowBranchCurrent" },
	}, { width = 7 })
	B:blank()

	-- Snapshot the previous line_entries for the detail bar lookup below
	-- (we update M.state.line_entries at the end of this function).
	local prev_line_entries = M.state.line_entries
	local line_entries = {}

	components.section(B, commit_icon, ("Commits (%d)"):format(count))
	if count == 0 then
		components.empty(B, "no commits found for rebase")
	else
		for _, entry in ipairs(M.state.entries) do
			local action_group = ACTION_HIGHLIGHTS[entry.action]
				or "GitflowRebasePick"
			local glyph = ACTION_GLYPHS[entry.action] or "●"
			-- squash/fixup items are indented under their pick target
			-- (item 6: squash/fixup chain indentation).
			local is_chain = entry.action == "squash"
				or entry.action == "fixup"
			local edge, gutter = components.spacing.edge, components.spacing.gutter
			local lead = is_chain and (edge .. gutter) or edge
			local lead2 = is_chain and (components.spacing.indent .. gutter .. edge)
				or (components.spacing.indent .. edge)

			-- Line 1: glyph badge + sha + subject (items 1 & 2).
			local line1 = B:push({
				{ lead, nil },
				{ glyph .. " ", action_group },
				{ ("%-6s"):format(entry.action) .. "  ", action_group },
				{ commit_icon .. " ", "GitflowRebaseHash" },
				{ entry.short_sha, "GitflowRebaseHash" },
				{ components.spacing.gutter .. (entry.subject or ""), "GitflowCardTitle" },
			})
			line_entries[line1] = entry

			-- Line 2: author + relative time, dimmed (item 1).
			local line2 = B:push({
				{ lead2, nil },
				{ entry.author or "", "GitflowMeta" },
				{ " · ", "GitflowMetaKey" },
				{ entry.relative_time or "", "GitflowMeta" },
			})
			line_entries[line2] = entry
		end
	end

	-- Detail bar: shows author/time/subject for the focused commit (item 8).
	B:blank()
	local focused_entry = prev_line_entries
		and prev_line_entries[M.state.focused_line]
	if focused_entry then
		B:push({
			{ components.spacing.gutter, nil },
			{ commit_icon .. " ", "GitflowSectionIcon" },
			{ focused_entry.author or "", "GitflowMeta" },
			{ " " .. components.glyphs.bullet .. " ", "GitflowMetaKey" },
			{ focused_entry.relative_time or "", "GitflowMeta" },
			{ components.separators.field, nil },
			{ focused_entry.subject or "", "GitflowCardTitle" },
		})
	else
		B:push({
			{ components.spacing.gutter .. components.spacing.edge, nil },
			{ "move cursor to a commit to inspect", "GitflowMeta" },
		})
	end

	P:push_hints(B, "todo")

	if P:paint(B) then
		M.state.line_entries = line_entries
	end
	refresh_float_footer()
end

---Render the plain (non-interactive) rebase preview: a read-only list of the
---commits that will be replayed onto the base branch.
render_normal = function()
	local B = P:begin_render()

	local commit_icon = icons.get("git_state", "commit")
	local branch_icon = icons.get("branch", "current")
	local base_icon = icons.get("branch", "remote")
	local count = #M.state.entries
	local current_branch = (M.state.current_branch
		and M.state.current_branch ~= "")
		and M.state.current_branch or "(unknown)"

	-- Summary bar: commit count + current branch context.
	B:push({
		{ components.spacing.gutter, nil },
		{ commit_icon .. "  ", "GitflowSectionIcon" },
		{
			("%d commit%s"):format(count, count == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ components.separators.field .. branch_icon .. " ", "GitflowMetaKey" },
		{ current_branch, "GitflowBranchCurrent" },
	})

	components.meta_row(B, "Base:", {
		{ base_icon .. " ", "GitflowSectionIcon" },
		{ M.state.base_ref or "(none)", "GitflowBranchCurrent" },
	}, { width = 7 })
	B:blank()

	local line_entries = {}
	components.section(B, commit_icon, ("Commits (%d)"):format(count))
	if count == 0 then
		components.empty(B, "no commits to replay onto base")
	else
		for _, entry in ipairs(M.state.entries) do
			-- Line 1: sha + subject.
			local line1 = B:push({
				{ components.spacing.edge, nil },
				{ commit_icon .. " ", "GitflowRebaseHash" },
				{ entry.short_sha, "GitflowRebaseHash" },
				{ components.spacing.gutter .. (entry.subject or ""), "GitflowCardTitle" },
			})
			line_entries[line1] = entry

			-- Line 2: author + relative time, dimmed.
			local line2 = B:push({
				{ components.spacing.indent .. components.spacing.edge, nil },
				{ entry.author or "", "GitflowMeta" },
				{ " " .. components.glyphs.bullet .. " ", "GitflowMetaKey" },
				{ entry.relative_time or "", "GitflowMeta" },
			})
			line_entries[line2] = entry
		end
	end

	B:blank()
	B:push({
		{ components.spacing.gutter, nil },
		{ "i", "GitflowMetaKey" },
		{ " switches to interactive rebase", "GitflowMeta" },
	})

	P:push_hints(B, "normal")

	if P:paint(B) then
		M.state.line_entries = line_entries
	end
	refresh_float_footer()
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

---@return integer|nil
local function ensure_preview_buffer()
	if M.state.preview_bufnr
		and vim.api.nvim_buf_is_valid(M.state.preview_bufnr)
	then
		return M.state.preview_bufnr
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "diff", { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	M.state.preview_bufnr = bufnr
	return bufnr
end

---Fetch and display `git show` for the currently focused commit in the preview
---window. No-ops when the preview buffer or focused entry is absent.
function M.refresh_preview()
	local entry = M.state.line_entries
		and M.state.line_entries[M.state.focused_line]
	local preview_bufnr = M.state.preview_bufnr
	if not entry
		or not preview_bufnr
		or not vim.api.nvim_buf_is_valid(preview_bufnr)
	then
		return
	end
	git.git(
		{ "show", "--stat", "--patch", entry.sha },
		{},
		function(result)
			if not vim.api.nvim_buf_is_valid(preview_bufnr) then
				return
			end
			local lines = vim.split(result.stdout or "", "\n")
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(preview_bufnr) then
					return
				end
				vim.api.nvim_set_option_value(
					"modifiable", true, { buf = preview_bufnr }
				)
				vim.api.nvim_buf_set_lines(
					preview_bufnr, 0, -1, false, lines
				)
				vim.api.nvim_set_option_value(
					"modifiable", false, { buf = preview_bufnr }
				)
			end)
		end
	)
end

---Toggle the diff-preview float for the focused commit (item 9).
---Opens a side float showing `git show <sha>`; pressing P again closes it.
function M.toggle_preview()
	if M.state.stage ~= "todo" and M.state.stage ~= "normal" then
		return
	end
	if M.state.preview_winid
		and vim.api.nvim_win_is_valid(M.state.preview_winid)
	then
		vim.api.nvim_win_close(M.state.preview_winid, true)
		M.state.preview_winid = nil
		return
	end

	local entry = M.state.line_entries
		and M.state.line_entries[M.state.focused_line]
	if not entry then
		utils.notify("Move cursor to a commit first", vim.log.levels.WARN)
		return
	end

	local preview_bufnr = ensure_preview_buffer()
	local columns = vim.o.columns
	local lines_h = vim.o.lines - vim.o.cmdheight
	local width = math.floor(columns * 0.48)
	local height = math.floor(lines_h * 0.72)
	local col = math.floor(columns * 0.51)
	local row = math.floor((lines_h - height) / 2)

	local preview_winid = vim.api.nvim_open_win(preview_bufnr, false, {
		relative = "editor",
		style = "minimal",
		width = width,
		height = height,
		row = row,
		col = col,
		border = "rounded",
		title = " git show ",
		title_pos = "center",
		zindex = 200,
	})
	vim.api.nvim_set_option_value(
		"winhighlight",
		"NormalFloat:GitflowNormal,FloatBorder:GitflowBorder"
			.. ",FloatTitle:GitflowTitle",
		{ win = preview_winid }
	)
	M.state.preview_winid = preview_winid

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(preview_winid),
		once = true,
		callback = function()
			if M.state.preview_winid == preview_winid then
				M.state.preview_winid = nil
			end
			if M.state.preview_bufnr
				and vim.api.nvim_buf_is_valid(M.state.preview_bufnr)
			then
				pcall(
					vim.api.nvim_buf_delete,
					M.state.preview_bufnr,
					{ force = true }
				)
			end
			M.state.preview_bufnr = nil
		end,
	})

	M.refresh_preview()
end

---Update the float window footer to match the current stage.
refresh_float_footer = function()
	P:refresh_footer(M.state.stage)
end

---Render the branch list into the rebase panel for the "base" picker stage.
---@param branches GitflowBranchEntry[]
local function render_base_picker(branches)
	local B = P:begin_render("Gitflow Interactive Rebase")

	local branch_icon = icons.get("branch", "current")
	components.section(B, branch_icon, "Select Base Branch")

	local local_entries, remote_entries = git_branch.partition(branches)
	local base_line_branches = {}

	local function append_branch_section(title, entries)
		if #entries == 0 then
			return
		end
		B:push({
			{ components.spacing.gutter .. title, "GitflowSectionTitle" },
		})
		B:raw(
			components.spacing.gutter
				.. string.rep(components.glyphs.rule, math.max(8, #title + 2)),
			"GitflowSeparator"
		)
		for _, entry in ipairs(entries) do
			local icon, group
			if entry.is_current then
				icon = icons.get("branch", "current")
				group = "GitflowBranchCurrent"
			elseif entry.is_remote then
				icon = icons.get("branch", "remote")
				group = "GitflowBranchRemote"
			else
				icon = icons.get("branch", "local_branch")
				group = "GitflowCardTitle"
			end
			local chunks = {
				{ components.spacing.indent, nil },
				{ (icon ~= "" and icon .. "  " or ""), group },
				{ entry.name, group },
			}
			if entry.is_current then
				chunks[#chunks + 1] = {
					components.spacing.gutter .. "(current)", "GitflowMeta",
				}
			end
			local line_no = B:push(chunks)
			base_line_branches[line_no] = entry
		end
		B:blank()
	end

	append_branch_section("Local", local_entries)
	append_branch_section("Remote", remote_entries)

	P:push_hints(B, "base")

	if P:paint(B) then
		M.state.base_line_branches = base_line_branches
	end
	refresh_float_footer()
end

---Confirm the branch under the cursor as the rebase base and switch to the
---todo view.
function M.select_base_branch()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local branch = M.state.base_line_branches
		and M.state.base_line_branches[line]
	if not branch then
		utils.notify("Move cursor to a branch first", vim.log.levels.WARN)
		return
	end
	next_picker_request_id()
	M.state.base_ref = branch.name
	M.state.stage = "normal"
	M.refresh()
end

---Switch from the plain rebase preview into the interactive editor, reusing the
---commits already loaded for the current base.
function M.switch_to_interactive()
	if M.state.stage ~= "normal" then
		return
	end
	M.state.stage = "todo"
	render_todo()
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	M.state.stage = "base"
	if not ensure_window(cfg) then
		return
	end
	M.show_base_picker()
end

function M.show_base_picker()
	if not M.state.cfg then
		return
	end

	M.state.stage = "base"
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
			utils.notify("No branches found", vim.log.levels.WARN)
			return
		end

		local filtered = {}
		for _, branch in ipairs(branches) do
			if not branch.name:match("/HEAD$") then
				filtered[#filtered + 1] = branch
			end
		end

		vim.schedule(function()
			if not is_active_picker_request(request_id) then
				return
			end
			render_base_picker(filtered)
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
	local request_id = P:next_request()
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
					P:render_error("Could not list commits to rebase", {
						detail = err, hint = "b picks another base",
						view = M.state.stage,
					})
					return
				end
				M.state.current_branch = current_branch
				M.state.entries = entries or {}
				if M.state.stage == "todo" then
					render_todo()
				else
					render_normal()
				end
			end
		)
	end)
end

---Prompt for a new commit message when an entry is marked `reword`, storing it
---on the entry (and updating the displayed subject). Without a captured message
---a reword would silently reuse the original message, so this makes `r` do what
---the user expects. Cancelling reverts the action to `pick`.
---@param idx integer
local function prompt_reword_message(idx)
	local entry = M.state.entries[idx]
	if not entry then
		return
	end
	ui.input.prompt({
		prompt = "Reword: ",
		default = entry.message or entry.subject or "",
	}, function(value)
		local trimmed = vim.trim(value or "")
		if trimmed == "" then
			entry.action = "pick"
			entry.message = nil
		else
			entry.action = "reword"
			entry.message = trimmed
			entry.subject = trimmed
		end
		render_todo()
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
	local next = next_action(M.state.entries[idx].action)
	M.state.entries[idx].action = next
	if next == "reword" then
		prompt_reword_message(idx)
		return
	end
	M.state.entries[idx].message = nil
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
	if action == "reword" then
		prompt_reword_message(idx)
		return
	end
	M.state.entries[idx].message = nil
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
	local cur = vim.api.nvim_win_get_cursor(M.state.winid or 0)
	render_todo()
	-- Each card is 2 lines; step down by 2 to follow the moved entry.
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		local new_line = math.min(
			cur[1] + 2,
			vim.api.nvim_buf_line_count(M.state.bufnr or 0)
		)
		vim.api.nvim_win_set_cursor(M.state.winid, { new_line, cur[2] })
		M.state.focused_line = new_line
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
	local cur = vim.api.nvim_win_get_cursor(M.state.winid or 0)
	render_todo()
	-- Each card is 2 lines; step up by 2 to follow the moved entry.
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		local new_line = math.max(cur[1] - 2, 1)
		vim.api.nvim_win_set_cursor(M.state.winid, { new_line, cur[2] })
		M.state.focused_line = new_line
	end
end

---Shared handler for a failed rebase: route conflicts to the conflict panel,
---otherwise surface the error.
---@param cfg GitflowConfig
---@param err string
---@param result GitflowGitResult
local function on_rebase_failure(cfg, err, result)
	local output = git.output(result) or err
	local parsed =
		git_conflict.parse_conflicted_paths_from_output(output)
	if #parsed > 0 then
		utils.notify(
			("Rebase has conflicts:\n%s"):format(
				table.concat(parsed, "\n")
			),
			vim.log.levels.ERROR
		)
		local conflict_panel = require("gitflow.panels.conflict")
		refresh_status_panel_if_open()
		conflict_panel.open(cfg)
	else
		utils.notify(err, vim.log.levels.ERROR)
	end
end

---Shared handler for a successful rebase.
---@param result GitflowGitResult
local function on_rebase_success(result)
	local output = git.output(result)
	if output == "" then
		output = "Rebase completed successfully"
	end
	utils.notify(output, vim.log.levels.INFO)
	refresh_status_panel_if_open()
	emit_post_operation()
	M.close()
end

---Execute a plain (non-interactive) rebase of the current branch onto the base.
function M.execute_plain()
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

	local current_branch = (M.state.current_branch
		and M.state.current_branch ~= "")
		and M.state.current_branch or "current branch"
	local confirm_msg = ("Rebase %s onto %s?"):format(
		current_branch, M.state.base_ref
	)
	if not ui.input.confirm(confirm_msg) then
		return
	end

	utils.notify(
		("Rebasing onto %s..."):format(M.state.base_ref),
		vim.log.levels.INFO
	)

	git_rebase.start(M.state.base_ref, {}, function(err, result)
		if err then
			on_rebase_failure(cfg, err, result)
			return
		end
		on_rebase_success(result)
	end)
end

---Execute the interactive rebase with confirmation.
function M.execute_interactive()
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

	local confirmed = ui.input.confirm(confirm_msg)
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
				on_rebase_failure(cfg, err, result)
				return
			end
			on_rebase_success(result)
		end
	)
end

---Execute the rebase, dispatching to the plain or interactive path based on the
---current stage.
function M.execute()
	if M.state.stage == "normal" then
		M.execute_plain()
		return
	end
	if M.state.stage ~= "todo" then
		utils.notify(
			"Select a base branch first",
			vim.log.levels.WARN
		)
		return
	end
	M.execute_interactive()
end

function M.close()
	next_picker_request_id()

	if M.state.preview_winid
		and vim.api.nvim_win_is_valid(M.state.preview_winid)
	then
		vim.api.nvim_win_close(M.state.preview_winid, true)
		M.state.preview_winid = nil
	end
	if M.state.preview_bufnr
		and vim.api.nvim_buf_is_valid(M.state.preview_bufnr)
	then
		pcall(
			vim.api.nvim_buf_delete,
			M.state.preview_bufnr,
			{ force = true }
		)
		M.state.preview_bufnr = nil
	end

	P:close()

	M.state.line_entries = {}
	M.state.entries = {}
	M.state.base_ref = nil
	M.state.current_branch = nil
	M.state.stage = "base"
	M.state.focused_line = nil
	M.state.base_line_branches = {}
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
