local ui = require("gitflow.ui")
local components = require("gitflow.ui.components")
local panel = require("gitflow.ui.panel")
local devicons = require("gitflow.ui.devicons")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_log = require("gitflow.git.log")
local git_status = require("gitflow.git.status")
local git_branch = require("gitflow.git.branch")
local conflict_panel = require("gitflow.panels.conflict")
local icons = require("gitflow.icons")

---@class GitflowStatusPanelOpts
---@field on_commit fun()|nil
---@field on_open_diff fun(request: table, entry: table|nil)|nil

---@class GitflowStatusFileLineEntry
---@field kind "file"
---@field entry GitflowStatusEntry
---@field diff_staged boolean

---@class GitflowStatusCommitLineEntry
---@field kind "commit"
---@field entry GitflowLogEntry
---@field pushable boolean

---@alias GitflowStatusLineEntry GitflowStatusFileLineEntry|GitflowStatusCommitLineEntry

---@class GitflowStatusUpstream
---@field full_name string
---@field remote string
---@field branch string

---@class GitflowStatusPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field opts GitflowStatusPanelOpts
---@field line_entries table<integer, GitflowStatusLineEntry>
---@field request_id integer

local M = {}
local STATUS_NO_UPSTREAM_HEADER = "Outgoing / Incoming"

---@type GitflowStatusPanelState
M.state = {
	cfg = nil,
	opts = {},
	line_entries = {},
	-- Cached commit-section data from the last full refresh, so staging /
	-- unstaging (which never changes commits or upstream) can repaint from a
	-- single `git status` call instead of re-running upstream + two git logs
	-- on every keypress (#362).
	last = nil,
}

local P = panel.new({
	name = "status",
	title = "Gitflow Status",
	filetype = "gitflowstatus",
	loading = "Loading git status…",
	state = M.state,
	keymaps = {
		{ key = "s/u", keys = { "s", "u" }, desc = "stage/unstage",
			essential = true, run = function(key)
				if key == "u" then
					M.unstage_under_cursor()
				else
					M.stage_under_cursor()
				end
			end },
		{ key = "V then s/u", keys = { "s", "u" }, mode = "x", desc = "batch",
			run = function(key)
				if key == "u" then
					M.unstage_visual()
				else
					M.stage_visual()
				end
			end },
		{ key = "a/A", keys = { "a", "A" }, desc = "all", run = function(key)
			if key == "A" then
				M.unstage_all()
			else
				M.stage_all()
			end
		end },
		{ key = "<CR>", desc = "open", run = function()
			M.open_file_under_cursor()
		end },
		{ key = "cc", desc = "commit", essential = true, run = function()
			if M.state.opts.on_commit then
				M.state.opts.on_commit()
			else
				utils.notify("Commit handler is not configured", vim.log.levels.WARN)
			end
		end },
		{ key = "dd", desc = "diff", run = function()
			M.open_diff_under_cursor()
		end },
		{ key = "cx", desc = "conflict", run = function()
			M.open_conflict_under_cursor()
		end },
		{ key = "X", desc = "discard changes", destructive = true, run = function()
			M.revert_under_cursor()
		end },
		{ key = "p", desc = "push", run = function()
			M.push_under_cursor()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

-- Porcelain codes that indicate an unmerged (conflicted) path.
local UNMERGED_STATUS = {
	DD = true, AU = true, UD = true, UA = true,
	DU = true, AA = true, UU = true,
}

---@param B GitflowRenderBuilder
---@param title string
---@param entries GitflowStatusEntry[]
---@param line_entries table<integer, GitflowStatusLineEntry>
---@param diff_staged boolean
local function append_file_section(B, title, entries, line_entries, diff_staged)
	components.section(B, icons.get("git_state", diff_staged and "staged" or "unstaged"), title)
	if #entries == 0 then
		components.empty(B, "(none)")
		B:blank()
		return
	end

	for _, entry in ipairs(entries) do
		local status = entry.index_status .. entry.worktree_status
		local is_conflict = UNMERGED_STATUS[status]
			or entry.index_status == "U"
			or entry.worktree_status == "U"

		local state_hl
		if is_conflict then
			state_hl = "GitflowRemoved"
		elseif entry.untracked then
			state_hl = "GitflowUntracked"
		elseif diff_staged then
			state_hl = "GitflowStaged"
		else
			state_hl = "GitflowModified"
		end

		local glyph, glyph_hl = devicons.get(entry.path)
		local dir, name = entry.path:match("^(.*/)([^/]+)$")
		dir = dir or ""
		name = name or entry.path

		-- ●  <ft-icon>  [CODE  ]<dir><name>
		local chunks = {
			{ components.spacing.gutter, nil },
			{ "\u{25cf}  ", state_hl },
			{ glyph .. "  ", glyph_hl },
		}
		-- Conflicted files keep the raw porcelain code (e.g. "UU  path") so it
		-- stays discoverable and obviously unresolved.
		if is_conflict then
			chunks[#chunks + 1] = { status .. "  ", "GitflowRemoved" }
		end
		chunks[#chunks + 1] = { dir, "GitflowMeta" }
		chunks[#chunks + 1] = { name, "GitflowCardTitle" }

		local line_no = B:push(chunks)
		line_entries[line_no] = {
			kind = "file",
			entry = entry,
			diff_staged = diff_staged,
		}
	end
	B:blank()
end

---@param B GitflowRenderBuilder
---@param title string
---@param entries GitflowLogEntry[]
---@param line_entries table<integer, GitflowStatusLineEntry>
---@param pushable boolean|table<string, boolean>
local function append_commit_section(B, title, entries, line_entries, pushable)
	components.section(B, icons.get("git_state", "commit"), title)
	if #entries == 0 then
		components.empty(B, "(none)")
		B:blank()
		return
	end

	for _, entry in ipairs(entries) do
		local entry_pushable = false
		if type(pushable) == "boolean" then
			entry_pushable = pushable
		elseif type(pushable) == "table" then
			entry_pushable = pushable[entry.sha] == true
		end

		local sha = entry.short_sha or (entry.sha and tostring(entry.sha):sub(1, 7)) or ""
		local summary = entry.summary or ""
		-- Strip a leading SHA already embedded in the summary, if present.
		if sha ~= "" then
			summary = summary:gsub("^" .. vim.pesc(sha) .. "%s*", "")
		end
		local line_no = B:push({
			{ components.spacing.gutter, nil },
			{ icons.get("git_state", "commit") .. "  ", "GitflowLogHash" },
			{ sha ~= "" and (sha .. "  ") or "", "GitflowLogHash" },
			{ summary, "GitflowCardTitle" },
		})
		line_entries[line_no] = {
			kind = "commit",
			entry = entry,
			pushable = entry_pushable,
		}
	end
	B:blank()
end

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = git.output(result)
	if output == "" then
		return ("git %s failed"):format(action)
	end
	return ("git %s failed: %s"):format(action, output)
end

---@param output string
---@return boolean
local function output_mentions_no_upstream(output)
	local normalized = output:lower()
	if normalized:find("no upstream configured", 1, true) then
		return true
	end
	if normalized:find("no upstream", 1, true) then
		return true
	end
	if normalized:find("does not point to a branch", 1, true) then
		return true
	end
	return false
end

---@param cb fun(err: string|nil, upstream: GitflowStatusUpstream|nil)
local function resolve_upstream(cb)
	git.git({
		"rev-parse",
		"--abbrev-ref",
		"--symbolic-full-name",
		"@{upstream}",
	}, {}, function(result)
		if result.code ~= 0 then
			local output = git.output(result)
			if output_mentions_no_upstream(output) then
				cb(nil, nil)
				return
			end
			cb(error_from_result(result, "rev-parse @{upstream}"), nil)
			return
		end

		local full_name = vim.trim(result.stdout or "")
		if full_name == "" then
			cb(nil, nil)
			return
		end

		local remote, branch = full_name:match("^([^/]+)/(.+)$")
		if not remote or not branch then
			cb(("Could not parse upstream branch from '%s'"):format(full_name), nil)
			return
		end

		cb(nil, {
			full_name = full_name,
			remote = remote,
			branch = branch,
		})
	end)
end

---@return GitflowStatusLineEntry|nil
local function entry_under_cursor()
	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	if vim.api.nvim_get_current_buf() ~= bufnr then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	return M.state.line_entries[cursor[1]]
end

---@return GitflowStatusFileLineEntry|nil
local function file_entry_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry or line_entry.kind ~= "file" then
		return nil
	end
	return line_entry
end

---@return GitflowStatusCommitLineEntry|nil
local function commit_entry_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry or line_entry.kind ~= "commit" then
		return nil
	end
	return line_entry
end

---@param grouped GitflowStatusGroups
---@param outgoing_entries GitflowLogEntry[]
---@param incoming_entries GitflowLogEntry[]
---@param upstream_name string|nil
---@param current_branch string
local function render(grouped, outgoing_entries, incoming_entries, upstream_name, current_branch)
	if not P:is_open() then
		return
	end

	-- Remember the commit-section data so a files-only refresh can reuse it
	-- without re-querying upstream + git log (#362).
	M.state.last = {
		-- The cwd this was true for: git resolves the repo from it, so an
		-- unkeyed reopen would paint another repository's files.
		cwd = vim.fn.getcwd(),
		grouped = grouped,
		outgoing = outgoing_entries,
		incoming = incoming_entries,
		upstream_name = upstream_name,
		branch = current_branch,
	}

	local B = P:begin_render()

	-- Branch + change-count summary bar.
	local total_changes = #grouped.staged + #grouped.unstaged + #grouped.untracked
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("branch", "current") .. "  ", "GitflowSectionIcon" },
		{ current_branch ~= "" and current_branch or "(detached)", "GitflowSectionTitle" },
		{
			upstream_name
				and (components.separators.field .. components.glyphs.arrow
					.. " " .. upstream_name) or "",
			"GitflowMeta",
		},
		{
			total_changes == 0
				and (components.separators.field .. "working tree clean")
				or (components.separators.field .. "%d change%s"):format(
					total_changes, total_changes == 1 and "" or "s"
				),
			total_changes == 0 and "GitflowReviewApproved" or "GitflowMeta",
		},
	})
	B:blank()

	local line_entries = {}

	append_file_section(B, ("Staged (%d)"):format(#grouped.staged), grouped.staged, line_entries, true)
	append_file_section(B, ("Unstaged (%d)"):format(#grouped.unstaged), grouped.unstaged, line_entries, false)
	append_file_section(B, ("Untracked (%d)"):format(#grouped.untracked), grouped.untracked, line_entries, false)

	if upstream_name then
		-- One section per direction: outgoing commits were listed twice before
		-- (a "Commit History" copy of the same entries), doubling every row.
		local flow = ("oldest %s newest"):format(components.glyphs.arrow)
		append_commit_section(
			B, ("Outgoing (%s, not on %s)"):format(flow, upstream_name),
			outgoing_entries, line_entries, true
		)
		append_commit_section(
			B, ("Incoming (%s, only on %s)"):format(flow, upstream_name),
			incoming_entries, line_entries, false
		)
	else
		components.section(B, icons.get("branch", "remote"), STATUS_NO_UPSTREAM_HEADER)
		components.empty(B, "No upstream branch — push will set it automatically")
		B:blank()
	end

	P:push_hints(B)

	P:paint(B, line_entries)
end

--- True once a newer refresh has started, meaning this chain's result is stale
--- and belongs to nobody. Checked before error reporting so a superseded chain
--- stays silent, while a failure in the current chain still surfaces.
---@param request_id integer
---@return boolean
local function superseded(request_id)
	return not P:is_active(request_id)
end

---@param err string|nil
local function notify_if_error(err)
	if err then
		utils.notify(err, vim.log.levels.ERROR)
		return true
	end
	return false
end

---Refresh-chain failure: notify AND paint the panel, so a fetch that died is
---never left looking like one still in flight.
---@param err string|nil
---@return boolean handled
local function refresh_failed(err)
	if not err then
		return false
	end
	utils.notify(err, vim.log.levels.ERROR)
	P:render_error("Could not read repository status", {
		detail = err,
		hint = "r retries",
	})
	return true
end

local function emit_post_operation()
	vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })
end


-- ── optimistic staging ─────────────────────────────────────────────────
-- `git add` / `git reset` on one file almost always succeeds, and the answer
-- is two subprocesses away. So the file moves between sections the moment the
-- key is pressed, and the real `git status` reconciles a moment later; a
-- failure puts it back and says why, so the panel never sits on a wrong list.

---@param entry GitflowStatusEntry
---@return boolean
local function is_unmerged(entry)
	local status = entry.index_status .. entry.worktree_status
	return UNMERGED_STATUS[status] == true
		or entry.index_status == "U"
		or entry.worktree_status == "U"
end

---@param list GitflowStatusEntry[]
---@param path string
---@return GitflowStatusEntry[]
local function without_path(list, path)
	local out = {}
	for _, item in ipairs(list) do
		if item.path ~= path then
			out[#out + 1] = item
		end
	end
	return out
end

---@param list GitflowStatusEntry[]
---@param entry GitflowStatusEntry
---@return GitflowStatusEntry[]
local function with_entry(list, entry)
	local out = without_path(list, entry.path)
	out[#out + 1] = entry
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	return out
end

---What `git add` leaves in the index for this path.
---@param entry GitflowStatusEntry
---@return GitflowStatusEntry
local function as_staged(entry)
	local index = entry.index_status
	if entry.untracked then
		index = "A"
	elseif entry.worktree_status ~= " " and entry.worktree_status ~= "" then
		index = entry.worktree_status
	end
	return vim.tbl_extend("force", {}, entry, {
		untracked = false, staged = true, unstaged = false,
		index_status = index, worktree_status = " ",
	})
end

---What `git reset` leaves for this path: a file the index had only just
---added goes back to untracked, anything else back to unstaged.
---@param entry GitflowStatusEntry
---@return GitflowStatusEntry
local function as_unstaged(entry)
	if entry.untracked or entry.index_status == "A" then
		return vim.tbl_extend("force", {}, entry, {
			untracked = true, staged = false, unstaged = false,
			index_status = "?", worktree_status = "?",
		})
	end
	local worktree = entry.index_status
	if worktree == " " or worktree == "" then
		worktree = entry.worktree_status
	end
	return vim.tbl_extend("force", {}, entry, {
		untracked = false, staged = false, unstaged = true,
		index_status = " ", worktree_status = worktree,
	})
end

---Repaint from the last render's data with `grouped` swapped in.
---@param grouped GitflowStatusGroups
local function repaint_groups(grouped)
	local last = M.state.last
	if not last or not P:is_open() then
		return
	end
	render(grouped, last.outgoing or {}, last.incoming or {},
		last.upstream_name, last.branch or "(unknown)")
end

---Move `entries` between the sections the pending git command will move them
---between, and repaint from memory.
---@param entries GitflowStatusEntry[]
---@param staging boolean  true for `git add`, false for `git reset`
---@return fun()|nil  the undo, or nil when there is nothing safe to guess
local function optimistic_move(entries, staging)
	local last = M.state.last
	local previous = last and last.grouped
	if type(previous) ~= "table" then
		return nil
	end
	local next_groups = {
		staged = previous.staged, unstaged = previous.unstaged,
		untracked = previous.untracked,
	}
	for _, entry in ipairs(entries) do
		-- A conflicted path is not a two-section move; leave it to git.
		if is_unmerged(entry) then
			return nil
		end
		local moved = staging and as_staged(entry) or as_unstaged(entry)
		if staging then
			next_groups = {
				staged = with_entry(next_groups.staged, moved),
				unstaged = without_path(next_groups.unstaged, entry.path),
				untracked = without_path(next_groups.untracked, entry.path),
			}
		elseif moved.untracked then
			next_groups = {
				staged = without_path(next_groups.staged, entry.path),
				unstaged = without_path(next_groups.unstaged, entry.path),
				untracked = with_entry(next_groups.untracked, moved),
			}
		else
			next_groups = {
				staged = without_path(next_groups.staged, entry.path),
				unstaged = with_entry(next_groups.unstaged, moved),
				untracked = without_path(next_groups.untracked, entry.path),
			}
		end
	end
	repaint_groups(next_groups)
	return function()
		repaint_groups(previous)
	end
end

---@param operation fun(cb: fun(err: string|nil))
---@param optimistic fun():(fun()|nil)|nil  paint the expected outcome now,
---   returning the undo to run if the operation fails
local function run_status_operation(operation, optimistic)
	local revert = optimistic and optimistic() or nil
	operation(function(err)
		if err and revert then
			revert()
		end
		if notify_if_error(err) then
			return
		end
		emit_post_operation()
		-- Staging doesn't change commits/upstream → cheap files-only repaint.
		M.refresh({ files_only = true })
	end)
end

---@param cfg GitflowConfig
---@param opts GitflowStatusPanelOpts|nil
function M.open(cfg, opts)
	M.state.cfg = cfg
	M.state.opts = opts or {}

	if not P:ensure_window(cfg) then
		return
	end

	-- Paint what was last true for this repo in the first frame, then refresh
	-- underneath. Five subprocesses of "Loading git status…" is the longest
	-- open-to-content gap in the plugin; the prs/issues/labels/actions panels
	-- already open this way.
	local last = M.state.last
	if last and last.grouped and last.cwd == vim.fn.getcwd() then
		render(last.grouped, last.outgoing or {}, last.incoming or {},
			last.upstream_name, last.branch or "(unknown)")
	end
	M.refresh()
end

---@param opts { files_only?: boolean }|nil
function M.refresh(opts)
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	-- This refresh owns a generation; every callback below abandons its work if
	-- a newer refresh has since started.
	local generation = P:next_request()

	-- Fast path: staging/unstaging only moves files between sections; the
	-- commit history and upstream are unchanged, so reuse the cached commit
	-- data and just re-read `git status` (#362). One subprocess instead of
	-- five (branch + status + upstream + two git logs).
	local cached = M.state.last
	if cached and cached.cwd ~= vim.fn.getcwd() then
		cached = nil
	end
	if opts and opts.files_only and cached then
		local last = cached
		git_status.fetch({}, function(err, _, grouped)
			if superseded(generation) then
				return
			end
			if refresh_failed(err) then
				return
			end
			render(grouped, last.outgoing or {}, last.incoming or {},
				last.upstream_name, last.branch or "(unknown)")
		end)
		return
	end

	git_branch.current({}, function(_, branch)
		if superseded(generation) then
			return
		end
		git_status.fetch({}, function(err, _, grouped)
			if superseded(generation) then
				return
			end
			if refresh_failed(err) then
				return
			end

			local current_branch = branch or "(unknown)"

			resolve_upstream(function(upstream_err, upstream)
				if superseded(generation) then
					return
				end
				if refresh_failed(upstream_err) then
					return
				end

				if not upstream then
					render(grouped, {}, {}, nil, current_branch)
					return
				end

				git_log.list({
					count = cfg.git.log.count,
					format = cfg.git.log.format,
					reverse = true,
					range = ("%s..HEAD"):format(upstream.full_name),
				}, function(outgoing_err, outgoing_entries)
					if superseded(generation) then
						return
					end
					if refresh_failed(outgoing_err) then
						return
					end

					git_log.list({
						count = cfg.git.log.count,
						format = cfg.git.log.format,
						reverse = true,
						range = ("HEAD..%s"):format(upstream.full_name),
					}, function(incoming_err, incoming_entries)
						if superseded(generation) then
							return
						end
						if refresh_failed(incoming_err) then
							return
						end

						render(
							grouped,
							outgoing_entries or {},
							incoming_entries or {},
							upstream.full_name,
							current_branch
						)
					end)
				end)
			end)
		end)
	end)
end

function M.stage_under_cursor()
	local line_entry = file_entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	run_status_operation(function(done)
		local entry = line_entry.entry
		git_status.stage_file(entry.path, {}, function(err)
			done(err)
		end)
	end, function()
		return optimistic_move({ line_entry.entry }, true)
	end)
end

function M.unstage_under_cursor()
	local line_entry = file_entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	run_status_operation(function(done)
		local entry = line_entry.entry
		git_status.unstage_file(entry.path, {}, function(err)
			done(err)
		end)
	end, function()
		return optimistic_move({ line_entry.entry }, false)
	end)
end

--- Collect the file entries covered by the current visual-line selection.
---@return GitflowStatusFileLineEntry[]
local function file_entries_in_visual_range()
	local a = vim.fn.line("v")
	local b = vim.fn.line(".")
	if a > b then
		a, b = b, a
	end
	local out = {}
	for line = a, b do
		local le = M.state.line_entries[line]
		if le and le.kind == "file" then
			out[#out + 1] = le
		end
	end
	return out
end

--- Stage every selected file in one go, then repaint once.
---@param stage boolean  true = stage, false = unstage
local function batch_stage_visual(stage)
	local entries = file_entries_in_visual_range()
	-- Leave visual mode now that we've captured the range.
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false
	)
	if #entries == 0 then
		utils.notify("No files in selection", vim.log.levels.WARN)
		return
	end

	local files = {}
	for _, le in ipairs(entries) do
		files[#files + 1] = le.entry
	end
	local revert = optimistic_move(files, stage)

	local pending, failed = #entries, false
	local function on_one(err)
		if err then
			failed = true
			utils.notify(err, vim.log.levels.ERROR)
		end
		pending = pending - 1
		if pending == 0 then
			-- One failure among many: put the whole selection back rather
			-- than leave a list that is right about some rows and wrong
			-- about others. The refresh below settles it either way.
			if failed and revert then
				revert()
			end
			emit_post_operation()
			M.refresh({ files_only = true })
		end
	end

	for _, le in ipairs(entries) do
		if stage then
			git_status.stage_file(le.entry.path, {}, on_one)
		else
			git_status.unstage_file(le.entry.path, {}, on_one)
		end
	end
end

--- Stage all files in the visual selection (V then s).
function M.stage_visual()
	batch_stage_visual(true)
end

--- Unstage all files in the visual selection (V then u).
function M.unstage_visual()
	batch_stage_visual(false)
end

function M.stage_all()
	run_status_operation(function(done)
		git_status.stage_all({}, function(err)
			done(err)
		end)
	end)
end

function M.unstage_all()
	run_status_operation(function(done)
		git_status.unstage_all({}, function(err)
			done(err)
		end)
	end)
end

function M.open_diff_under_cursor()
	local line_entry = entry_under_cursor()
	if not line_entry then
		utils.notify("No item selected", vim.log.levels.WARN)
		return
	end

	if M.state.opts.on_open_diff then
		if line_entry.kind == "file" then
			local entry = line_entry.entry
			M.state.opts.on_open_diff({
				path = entry.path,
				staged = line_entry.diff_staged,
			}, entry)
			return
		end

		local commit = line_entry.entry
		M.state.opts.on_open_diff({
			commit = commit.sha,
		}, commit)
		return
	end

	utils.notify("Diff handler is not configured", vim.log.levels.WARN)
end

function M.push_under_cursor()
	local line_entry = commit_entry_under_cursor()
	if not line_entry or not line_entry.pushable then
		utils.notify("No outgoing commit selected", vim.log.levels.WARN)
		return
	end

	resolve_upstream(function(err, upstream)
		if notify_if_error(err) then
			return
		end
		if not upstream then
			utils.notify("No upstream branch configured for current branch", vim.log.levels.WARN)
			return
		end

		local commit = line_entry.entry
		local confirmed = ui.input.confirm(
			("Push commits through %s to %s?"):format(commit.short_sha, upstream.full_name),
			{ choices = { "&Push", "&Cancel" }, default_choice = 2 }
		)
		if not confirmed then
			return
		end

		local refspec = ("%s:refs/heads/%s"):format(commit.sha, upstream.branch)
		git.git({ "push", upstream.remote, refspec }, {}, function(push_result)
			if push_result.code ~= 0 then
				utils.notify(error_from_result(push_result, "push"), vim.log.levels.ERROR)
				return
			end

			local output = git.output(push_result)
			if output == "" then
				output = ("Pushed through %s"):format(commit.short_sha)
			end
			utils.notify(output, vim.log.levels.INFO)
			emit_post_operation()
			M.refresh()
		end)
	end)
end

function M.revert_under_cursor()
	local line_entry = file_entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	local entry = line_entry.entry
	local confirmed = ui.input.confirm(
		("Revert all uncommitted changes for '%s'?"):format(entry.path),
		{ choices = { "&Revert", "&Cancel" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	git_status.revert_file(entry.path, { untracked = entry.untracked }, function(err)
		if notify_if_error(err) then
			return
		end
		utils.notify(("Reverted changes in '%s'"):format(entry.path), vim.log.levels.INFO)
		emit_post_operation()
		M.refresh()
	end)
end

---@param entry GitflowStatusEntry
---@return boolean
local function is_conflicted(entry)
	return entry.index_status == "U" or entry.worktree_status == "U"
end

function M.open_conflict_under_cursor()
	local line_entry = file_entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	local entry = line_entry.entry
	if not is_conflicted(entry) then
		utils.notify(("'%s' is not in a conflict state"):format(entry.path), vim.log.levels.WARN)
		return
	end

	if not M.state.cfg then
		utils.notify("Status panel is not configured", vim.log.levels.WARN)
		return
	end

	conflict_panel.open(M.state.cfg, { path = entry.path })
end

function M.open_file_under_cursor()
	local line_entry = file_entry_under_cursor()
	if not line_entry then
		utils.notify("No file selected", vim.log.levels.WARN)
		return
	end

	local entry = line_entry.entry
	git.git({ "rev-parse", "--show-toplevel" }, {}, function(result)
		if result.code ~= 0 then
			utils.notify("Could not resolve git root", vim.log.levels.ERROR)
			return
		end

		local root = vim.trim(result.stdout)
		local abs_path = root .. "/" .. entry.path
		M.close()
		vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
	end)
end

function M.close()
	P:close()
	M.state.cfg = nil
	M.state.line_entries = {}
	-- state.last survives the close on purpose: it is what the next open
	-- paints in its first frame. It carries the cwd it was true for, so it
	-- can only ever be reused in the repo it came from.
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
