local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_worktree = require("gitflow.git.worktree")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")
local list_picker = require("gitflow.ui.list_picker")

---@class GitflowWorktreeEnrichment
---@field subject string|nil
---@field rel_time string|nil
---@field is_dirty boolean

---@class GitflowWorktreePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowWorktreeEntry>
---@field cfg GitflowConfig|nil
---@field enrichment table<string, GitflowWorktreeEnrichment>
---@field enrich_gen integer

local M = {}
local WORKTREE_FLOAT_TITLE = "  Gitflow Worktrees  "
local WORKTREE_FLOAT_FOOTER =
	" a add · d/D remove · m move · L lock · p prune"
	.. " · <CR> switch · r refresh · q close "
local WORKTREE_HINTS = {
	{ "<CR>", "switch" },
	{ "a", "add" },
	{ "d/D", "remove" },
	{ "m", "move" },
	{ "L", "lock" },
	{ "p", "prune" },
	{ "r", "refresh" },
	{ "q", "close" },
}
local WORKTREE_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_worktree_hl")
local WORKTREE_AUGROUP =
	vim.api.nvim_create_augroup("GitflowWorktreePanel", { clear = true })

---@type GitflowWorktreePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
	enrichment = {},
	enrich_gen = 0,
}

local function emit_post_operation()
	vim.api.nvim_exec_autocmds(
		"User", { pattern = "GitflowPostOperation" }
	)
end

---Absolute, normalized path of the current working directory.
---@return string
local function cwd_abs()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
end

---@param path string
---@return string
local function normalize(path)
	return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("worktree", {
			filetype = "gitflowworktree",
			lines = components.loading_lines("Loading worktrees…"),
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
			title = WORKTREE_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and WORKTREE_FLOAT_FOOTER or nil,
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

	vim.keymap.set("n", "a", function()
		M.add_worktree()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "d", function()
		M.remove_under_cursor(false)
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "D", function()
		M.remove_under_cursor(true)
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "m", function()
		M.move_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "L", function()
		M.toggle_lock_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "p", function()
		M.prune()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "<CR>", function()
		M.switch_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---Resolve the display ref for a worktree entry (branch / detached / bare).
---The detached form keeps the literal "detached" substring tests rely on.
---@param entry GitflowWorktreeEntry
---@return string
local function entry_ref(entry)
	if entry.is_bare then
		return "(bare)"
	elseif entry.is_detached then
		return ("detached %s"):format(
			entry.sha and entry.sha:sub(1, 8) or "?"
		)
	elseif entry.branch then
		return entry.branch
	end
	return "(unknown)"
end

---Paint the buffer with a single styled state block (loading / error) sharing
---the rendered panel's header chrome so transitions don't flicker.
---@param paint fun(B: GitflowRenderBuilder)
local function render_state(paint)
	local render_opts = { bufnr = M.state.bufnr, winid = M.state.winid }
	local B = ui_render.builder()
	components.header(B, "Gitflow Worktrees", render_opts)
	B:blank()
	paint(B)
	ui.buffer.update("worktree", B.lines)
	M.state.line_entries = {}
	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, WORKTREE_HIGHLIGHT_NS)
end

local function render_loading()
	render_state(function(B)
		components.loading(B, "Loading worktrees…")
	end)
end

---@param message string
local function render_error(message)
	render_state(function(B)
		components.error_state(B, "Could not list worktrees", {
			detail = message,
			hint = "Press r to retry · q to close",
		})
	end)
end

---Render the worktree list. Each entry occupies 2–3 lines:
---  Line 1 — icon + ref + status badges ([current] [locked] [prunable] ~)
---  Line 2 — dim: short-sha · subject · rel_time · ~/path
---  Line 3 — (optional) lock or prune reason
---All card lines map to the entry in line_entries so actions work from
---any line within a card. A blank line separates cards for readability.
---@param entries GitflowWorktreeEntry[]
local function render(entries)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local cwd = cwd_abs()

	local current_ref
	for _, entry in ipairs(entries) do
		if normalize(entry.path) == cwd then
			current_ref = entry_ref(entry)
		end
	end

	local B = ui_render.builder()
	components.header(B, "Gitflow Worktrees", render_opts)

	B:push({
		{ "  ", nil },
		{ icons.get("branch", "current") .. "  ", "GitflowSectionIcon" },
		{
			("%d worktree%s"):format(#entries, #entries == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ "     " .. icons.get("branch", "current") .. " ", "GitflowMetaKey" },
		{ current_ref or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	components.section(
		B,
		icons.get("branch", "local_branch"),
		("Worktrees (%d)"):format(#entries)
	)

	local line_entries = {}
	if #entries == 0 then
		components.empty(B, "No worktrees yet", {
			hint = "Press a to add a worktree.",
		})
	else
		for _, entry in ipairs(entries) do
			local is_current = normalize(entry.path) == cwd
			local ref = entry_ref(entry)
			local display_path = vim.fn.fnamemodify(entry.path, ":~")
			local enrich = M.state.enrichment[entry.path]

			local icon_name = is_current and "current" or "local_branch"
			local ref_group = "GitflowChip"
			if is_current then
				ref_group = "GitflowWorktreeCurrent"
			elseif entry.is_prunable then
				ref_group = "GitflowWorktreePrunable"
			elseif entry.is_locked then
				ref_group = "GitflowWorktreeLocked"
			end

			-- Line 1: icon + branch/ref + state badges
			local line1_chunks = {
				{ " ", nil },
				{ icons.get("branch", icon_name) .. "  ", ref_group },
				{ ref, ref_group },
			}
			if is_current then
				line1_chunks[#line1_chunks + 1] =
					{ "  [current]", "GitflowWorktreeCurrent" }
			end
			if entry.is_locked then
				line1_chunks[#line1_chunks + 1] =
					{ "  [locked]", "GitflowWorktreeLocked" }
			end
			if entry.is_prunable then
				line1_chunks[#line1_chunks + 1] =
					{ "  [prunable]", "GitflowWorktreePrunable" }
			end
			if enrich and enrich.is_dirty then
				line1_chunks[#line1_chunks + 1] =
					{ "  ~", "GitflowWorktreeDirty" }
			end

			local line1 = B:push(line1_chunks)
			line_entries[line1] = entry

			-- Line 2: sha · subject · rel_time · path (dim meta row)
			local short_sha = (entry.sha ~= "" and entry.sha:sub(1, 7)) or nil
			local line2_chunks = { { "       ", nil } }

			if entry.is_bare then
				line2_chunks[#line2_chunks + 1] =
					{ display_path, "GitflowMeta" }
			else
				if short_sha then
					line2_chunks[#line2_chunks + 1] =
						{ short_sha, "GitflowMeta" }
				end
				if enrich and enrich.subject and enrich.subject ~= "" then
					local prefix = short_sha and "  " or ""
					line2_chunks[#line2_chunks + 1] =
						{ prefix .. enrich.subject, "GitflowMeta" }
				end
				if enrich and enrich.rel_time and enrich.rel_time ~= "" then
					line2_chunks[#line2_chunks + 1] =
						{ "  ·  " .. enrich.rel_time, "GitflowRelTime" }
				end
				line2_chunks[#line2_chunks + 1] =
					{ "  ·  " .. display_path, "GitflowMeta" }
			end

			local line2 = B:push(line2_chunks)
			line_entries[line2] = entry

			-- Line 3 (optional): lock or prune reason
			if entry.is_locked and entry.lock_reason then
				local line3 = B:push({
					{ "       Locked: ", "GitflowWorktreeLocked" },
					{ entry.lock_reason, "GitflowMeta" },
				})
				line_entries[line3] = entry
			elseif entry.is_prunable and entry.prune_reason then
				local line3 = B:push({
					{ "       Prunable: ", "GitflowWorktreePrunable" },
					{ entry.prune_reason, "GitflowMeta" },
				})
				line_entries[line3] = entry
			end

			B:blank()
		end
	end

	components.split_hint_bar(B, render_opts, WORKTREE_HINTS)

	ui.buffer.update("worktree", B.lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, WORKTREE_HIGHLIGHT_NS)
	components.cursorline(M.state.winid, true)
end

---Fire async enrichment for each non-bare worktree: commit subject + relative
---time (one git-log call) and dirty status (git-status --porcelain). Both
---calls are batched in parallel; a single re-render fires once ALL complete.
---A generation counter discards results from superseded refreshes.
---@param entries GitflowWorktreeEntry[]
local function enrich_entries(entries)
	local enrichable = {}
	for _, entry in ipairs(entries) do
		if not entry.is_bare
			and entry.path ~= ""
			and vim.fn.isdirectory(entry.path) == 1
		then
			enrichable[#enrichable + 1] = entry
		end
	end

	if #enrichable == 0 then
		return
	end

	M.state.enrich_gen = M.state.enrich_gen + 1
	local gen = M.state.enrich_gen

	local pending = #enrichable * 2
	local enrichment = {}
	for _, entry in ipairs(enrichable) do
		enrichment[entry.path] = {}
	end

	local function done()
		pending = pending - 1
		if pending > 0 or gen ~= M.state.enrich_gen then
			return
		end
		M.state.enrichment = enrichment
		-- Re-render with the same entries list — card structure is stable
		-- (same line count per entry) so cursor position is preserved.
		if M.is_open() then
			render(entries)
		end
	end

	for _, entry in ipairs(enrichable) do
		-- Commit subject + relative time in one log call.
		git.git(
			{ "log", "-1", "--format=%s%x1F%ar" },
			{ cwd = entry.path },
			function(result)
				if result.code == 0 then
					local out = vim.trim(result.stdout or "")
					if out ~= "" then
						local sep = out:find("\x1F", 1, true)
						local subject, rel_time
						if sep then
							subject = out:sub(1, sep - 1)
							rel_time = vim.trim(out:sub(sep + 1))
						else
							subject = out
						end
						-- Guard against multi-line output (e.g. test stubs).
						enrichment[entry.path].subject =
							subject and subject:match("^([^\n]*)")
						enrichment[entry.path].rel_time = rel_time
					end
				end
				done()
			end
		)

		-- Dirty indicator: any output from --porcelain means uncommitted changes.
		git.git(
			{ "status", "--porcelain" },
			{ cwd = entry.path },
			function(result)
				if result.code == 0 then
					enrichment[entry.path].is_dirty =
						vim.trim(result.stdout or "") ~= ""
				end
				done()
			end
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

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	render_loading()

	vim.api.nvim_clear_autocmds({ group = WORKTREE_AUGROUP })
	vim.api.nvim_create_autocmd("User", {
		group = WORKTREE_AUGROUP,
		pattern = "GitflowPostOperation",
		callback = function()
			if M.is_open() then
				M.refresh()
			end
		end,
	})

	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	-- Invalidate any in-flight enrichment from the previous load.
	M.state.enrich_gen = M.state.enrich_gen + 1
	M.state.enrichment = {}

	git_worktree.list({}, function(err, entries)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			render_error(err)
			return
		end
		local list = entries or {}
		render(list)
		enrich_entries(list)
	end)
end

---Run the worktree add and report the outcome.
---@param path string
---@param opts table  { ref?, new_branch?, force?, detach? }
local function run_add(path, opts)
	git_worktree.add(path, opts, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		local detail
		if opts.new_branch then
			detail = ("new branch '%s'%s"):format(
				opts.new_branch,
				opts.ref and (" from " .. opts.ref) or " from HEAD"
			)
		elseif opts.ref then
			detail = ("checked out %s"):format(opts.ref)
		else
			detail = "new branch from HEAD"
		end
		utils.notify(
			("Created worktree at %s (%s)"):format(path, detail),
			vim.log.levels.INFO
		)
		M.refresh()
		emit_post_operation()
	end)
end

---Open a searchable picker of branches (plus HEAD) and call `on_pick` with
---the chosen ref. Cancelling the picker aborts silently.
---@param title string
---@param on_pick fun(ref: string)
local function pick_base_ref(title, on_pick)
	git_branch.list({}, function(err, entries)
		local items = {
			{ name = "HEAD", description = "current commit" },
		}
		if not err and entries then
			for _, entry in ipairs(entries) do
				local desc
				if entry.is_remote then
					desc = "remote"
				elseif entry.is_current then
					desc = "local · current"
				else
					desc = "local"
				end
				items[#items + 1] = {
					name = entry.name,
					description = desc,
				}
			end
		end

		list_picker.open({
			title = title,
			items = items,
			multi_select = false,
			on_submit = function(selected)
				local ref = selected and selected[1]
				if not ref or ref == "" then
					return
				end
				on_pick(ref)
			end,
			on_cancel = function() end,
		})
	end)
end

function M.add_worktree()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	ui.input.prompt(
		{ prompt = "New worktree path: " },
		function(path)
			if not path or vim.trim(path) == "" then
				return
			end
			path = vim.trim(path)

			pick_base_ref("Base worktree on", function(base)
				ui.input.prompt(
					{
						prompt = ("New branch name (empty = check out '%s'): ")
							:format(base),
					},
					function(new_branch)
						new_branch = new_branch and vim.trim(new_branch) or ""
						local opts = { ref = base }
						if new_branch ~= "" then
							opts.new_branch = new_branch
						end
						run_add(path, opts)
					end
				)
			end)
		end
	)
end

---@param force boolean
function M.remove_under_cursor(force)
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No worktree selected", vim.log.levels.WARN)
		return
	end

	if normalize(entry.path) == cwd_abs() then
		utils.notify(
			"Cannot remove the worktree you are currently in",
			vim.log.levels.WARN
		)
		return
	end

	if entry.is_locked and not force then
		utils.notify(
			"Worktree is locked — press L to unlock, or D to force-remove",
			vim.log.levels.WARN
		)
		return
	end

	local prompt = force
		and ("Force-remove worktree '%s'? (discards changes)"):format(entry.path)
		or ("Remove worktree '%s'?"):format(entry.path)
	local confirmed = ui.input.confirm(
		prompt,
		{ choices = { "&Remove", "&Cancel" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	git_worktree.remove(
		entry.path,
		{ force = force, force_locked = entry.is_locked },
		function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Removed worktree '%s'"):format(entry.path),
				vim.log.levels.INFO
			)
			M.refresh()
			emit_post_operation()
		end
	)
end

--- Lock or unlock the worktree under the cursor (toggles based on state).
function M.toggle_lock_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No worktree selected", vim.log.levels.WARN)
		return
	end

	if entry.is_locked then
		git_worktree.unlock(entry.path, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Unlocked worktree '%s'"):format(entry.path),
				vim.log.levels.INFO
			)
			M.refresh()
		end)
		return
	end

	ui.input.prompt(
		{
			multiline = true,
			title = "Worktree lock reason (optional)",
			draft_key = ("worktree:%s:lock-reason"):format(entry.path),
		},
		function(reason)
			local opts = {}
			if reason and vim.trim(reason) ~= "" then
				opts.reason = vim.trim(reason)
			end
			git_worktree.lock(entry.path, opts, function(err)
				if err then
					utils.notify(err, vim.log.levels.ERROR)
					return
				end
				utils.notify(
					("Locked worktree '%s'"):format(entry.path),
					vim.log.levels.INFO
				)
				M.refresh()
			end)
		end
	)
end

--- Move the worktree under the cursor to a new path.
function M.move_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No worktree selected", vim.log.levels.WARN)
		return
	end
	if entry.is_bare then
		utils.notify("Cannot move a bare worktree", vim.log.levels.WARN)
		return
	end
	if normalize(entry.path) == cwd_abs() then
		utils.notify(
			"Cannot move the worktree you are currently in",
			vim.log.levels.WARN
		)
		return
	end

	ui.input.prompt(
		{ prompt = ("Move '%s' to: "):format(entry.path), default = entry.path },
		function(dest)
			if not dest or vim.trim(dest) == "" then
				return
			end
			dest = vim.trim(dest)
			if normalize(dest) == normalize(entry.path) then
				return
			end
			git_worktree.move(entry.path, dest, {}, function(err)
				if err then
					utils.notify(err, vim.log.levels.ERROR)
					return
				end
				utils.notify(
					("Moved worktree to %s"):format(dest),
					vim.log.levels.INFO
				)
				M.refresh()
				emit_post_operation()
			end)
		end
	)
end

function M.prune()
	git_worktree.prune({}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify("Pruned stale worktree entries", vim.log.levels.INFO)
		M.refresh()
		emit_post_operation()
	end)
end

function M.switch_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No worktree selected", vim.log.levels.WARN)
		return
	end
	if entry.is_bare then
		utils.notify("Cannot switch into a bare worktree", vim.log.levels.WARN)
		return
	end
	if vim.fn.isdirectory(entry.path) ~= 1 then
		utils.notify(
			("Worktree path no longer exists: %s"):format(entry.path),
			vim.log.levels.ERROR
		)
		return
	end

	local ok = pcall(vim.cmd, "cd " .. vim.fn.fnameescape(entry.path))
	if not ok then
		utils.notify(
			("Failed to switch to %s"):format(entry.path),
			vim.log.levels.ERROR
		)
		return
	end

	utils.notify(
		("Switched to worktree %s"):format(vim.fn.fnamemodify(entry.path, ":~")),
		vim.log.levels.INFO
	)
	M.refresh()
	emit_post_operation()
end

function M.close()
	pcall(vim.api.nvim_clear_autocmds, { group = WORKTREE_AUGROUP })

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
	M.state.line_entries = {}
	M.state.enrichment = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
