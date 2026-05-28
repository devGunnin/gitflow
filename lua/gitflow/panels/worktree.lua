local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_worktree = require("gitflow.git.worktree")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")

---@class GitflowWorktreePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowWorktreeEntry>
---@field cfg GitflowConfig|nil

local M = {}
local WORKTREE_FLOAT_TITLE = "Gitflow Worktrees"
local WORKTREE_FLOAT_FOOTER =
	"a add  d remove  D force-remove  p prune  <CR> switch  r refresh  q close"
local WORKTREE_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_worktree_hl")

---@type GitflowWorktreePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
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

---@param entry GitflowWorktreeEntry
---@param is_current boolean
---@return string
local function format_entry(entry, is_current)
	local icon = icons.get(
		"branch", is_current and "current" or "local_branch"
	)
	local ref
	if entry.is_bare then
		ref = "(bare)"
	elseif entry.is_detached then
		ref = ("(detached %s)"):format(entry.sha:sub(1, 8))
	elseif entry.branch then
		ref = entry.branch
	else
		ref = "(unknown)"
	end

	local display_path = vim.fn.fnamemodify(entry.path, ":~")
	local markers = {}
	if is_current then
		markers[#markers + 1] = "[current]"
	end
	if entry.is_locked then
		markers[#markers + 1] = "[locked]"
	end
	if entry.is_prunable then
		markers[#markers + 1] = "[prunable]"
	end
	local marker_part = #markers > 0
		and ("  " .. table.concat(markers, " ")) or ""

	return ("%s %s  ->  %s%s"):format(icon, ref, display_path, marker_part)
end

---@param entries GitflowWorktreeEntry[]
local function render(entries)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Worktrees", render_opts
	)
	local line_entries = {}
	local entry_highlights = {}
	local cwd = cwd_abs()

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty("no worktrees found")
	else
		for _, entry in ipairs(entries) do
			local is_current = normalize(entry.path) == cwd
			lines[#lines + 1] = ui_render.entry(
				format_entry(entry, is_current)
			)
			line_entries[#lines] = entry

			if is_current then
				entry_highlights[#lines] = "GitflowWorktreeCurrent"
			elseif entry.is_prunable then
				entry_highlights[#lines] = "GitflowWorktreePrunable"
			elseif entry.is_locked then
				entry_highlights[#lines] = "GitflowWorktreeLocked"
			end
		end
	end

	local footer_lines = ui_render.panel_footer(
		nil,
		nil,
		render_opts
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
		bufnr, WORKTREE_HIGHLIGHT_NS, lines, {
			entry_highlights = entry_highlights,
		}
	)
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
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	git_worktree.list({}, function(err, entries)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render(entries or {})
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

function M.add_worktree()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	-- 1) Where the worktree lives on disk.
	ui.input.prompt(
		{ prompt = "New worktree path: " },
		function(path)
			if not path or vim.trim(path) == "" then
				return
			end
			path = vim.trim(path)

			-- 2) Optional new branch to create for this worktree. Leaving
			--    this empty switches to the "check out an existing ref" path.
			--    (Cancelling with <Esc> aborts entirely — on_confirm only
			--    fires for a typed value, including the empty string.)
			ui.input.prompt(
				{ prompt = "New branch name (empty = check out existing): " },
				function(new_branch)
					new_branch = new_branch and vim.trim(new_branch) or ""

					if new_branch ~= "" then
						-- 3a) Creating a branch: ask what to base it on.
						ui.input.prompt(
							{
								prompt = ("Base '%s' on (branch/commit, empty = HEAD): ")
									:format(new_branch),
							},
							function(base)
								local opts = { new_branch = new_branch }
								if base and vim.trim(base) ~= "" then
									opts.ref = vim.trim(base)
								end
								run_add(path, opts)
							end
						)
					else
						-- 3b) Checking out an existing ref (or, if empty, let
						--     git create a branch named after the folder).
						ui.input.prompt(
							{
								prompt = "Check out (branch/commit, empty = new branch from HEAD): ",
							},
							function(ref)
								local opts = {}
								if ref and vim.trim(ref) ~= "" then
									opts.ref = vim.trim(ref)
								end
								run_add(path, opts)
							end
						)
					end
				end
			)
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

	git_worktree.remove(entry.path, { force = force }, function(err)
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
	end)
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

	-- Change Neovim's working directory so subsequent gitflow operations
	-- (which resolve the repo via cwd) target the selected worktree.
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
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
