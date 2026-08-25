--- Loading a PR into the review: the network round-trips, what they are folded
--- into, and the commit scoping that swaps the source of the file list.
---
--- Nothing here blocks. Every response is checked against the file list's
--- request generation before it is spliced in, so switching PRs (or closing
--- review mode) mid-load can never mix one PR's files into another's view.

local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")
local input = require("gitflow.ui.input")
local gh_prs = require("gitflow.gh.prs")
local inline = require("gitflow.review.inline")
local cache = require("gitflow.review.cache")
local rstate = require("gitflow.review.state")
local threads = require("gitflow.review.threads")
local file_list = require("gitflow.review.file_list")
local overlay = require("gitflow.review.overlay")

local M = {}
local state = rstate.state

local PR_STATUS_MAP = {
	added = "A",
	removed = "D",
	modified = "M",
	renamed = "R",
	copied = "M",
	changed = "M",
}

---@param view table|nil
local function pull_pr_metadata(view)
	if not view then
		return
	end
	state.pr_title = vim.trim(tostring(view.title or "")) ~= ""
		and view.title or state.pr_title or "(untitled)"
	if type(view.author) == "table" and view.author.login then
		state.pr_author = view.author.login
	elseif type(view.author) == "string" then
		state.pr_author = view.author
	end
	if view.headRefName and view.headRefName ~= vim.NIL then
		state.pr_head = tostring(view.headRefName)
	end
	if view.headRefOid and view.headRefOid ~= vim.NIL then
		-- Needed as commit_id when posting file-level comments (#361).
		state.pr_head_sha = tostring(view.headRefOid)
	end
	if view.baseRefName and view.baseRefName ~= vim.NIL then
		state.pr_base = tostring(view.baseRefName)
	end

	-- Pull file list from view.files first; fall back to diff parsing.
	if type(view.files) == "table" then
		local files = {}
		for _, f in ipairs(view.files) do
			if type(f) == "table" and f.path then
				files[#files + 1] = {
					path = f.path,
					status = "M",
					additions = rstate.as_integer(f.additions),
					deletions = rstate.as_integer(f.deletions),
				}
			end
		end
		if #files > 0 then
			state.files = files
			state.files_loaded = true
		end
	end
end

--- Ingest the per-file patches returned by the GitHub pulls/.../files API.
--- This handles huge PRs that would crash `gh pr diff`: each file is processed
--- independently, and files whose patch was omitted by GitHub (because they
--- exceed the per-file size limit) are still listed but flagged as truncated.
---@param files_data table[]|nil
local function ingest_pr_files(files_data)
	local files = {}
	local file_diffs = {}
	local hunk_markers = {}
	local file_markers = {}

	for _, f in ipairs(files_data or {}) do
		if type(f) == "table" and f.filename then
			local status = PR_STATUS_MAP[tostring(f.status or "")] or "M"
			files[#files + 1] = {
				path = f.filename,
				status = status,
				additions = rstate.as_integer(f.additions),
				deletions = rstate.as_integer(f.deletions),
			}

			local patch = f.patch
			if patch == vim.NIL then
				patch = nil
			end

			local fd = {
				path = f.filename,
				status = status,
				hunks = {},
				truncated = (patch == nil) and (status ~= "A" and status ~= "D"),
			}
			if type(patch) == "string" and patch ~= "" then
				fd.hunks = inline.parse_hunks_from_patch(patch)
			end
			file_diffs[f.filename] = fd

			file_markers[#file_markers + 1] = {
				path = f.filename, status = status, line = 0,
			}
			for _, h in ipairs(fd.hunks) do
				hunk_markers[#hunk_markers + 1] = {
					path = f.filename, header = h.header, line = 0,
				}
			end
		end
	end

	state.files = files
	state.files_loaded = true
	state.file_diffs = file_diffs
	state.file_markers = file_markers
	state.hunk_markers = hunk_markers
end

--- If the PR's head branch isn't the one currently checked out, comment
--- line numbers won't match the diff (the #1 cause of "Line could not be
--- resolved"). Offer to check the PR out. Prompts at most once per session.
local function maybe_prompt_pr_checkout()
	if state._checkout_prompted then
		return
	end
	-- Never pop a modal when there's no UI attached (headless / tests).
	if #vim.api.nvim_list_uis() == 0 then
		return
	end
	local head = state.pr_head
	local number = state.pr_number
	if not head or head == "" or not number then
		return
	end

	git_branch.current({}, function(_, branch)
		if state._checkout_prompted then
			return
		end
		branch = branch and vim.trim(branch) or ""
		if branch == head then
			return -- already on the PR's branch; lines will resolve
		end
		state._checkout_prompted = true

		local confirmed = input.confirm(
			("PR #%s targets branch '%s', but you're on '%s'.\n"
			.. "Inline-comment line numbers may not resolve until the PR "
			.. "branch is checked out.\n\nCheck out '%s' now?"):format(
				tostring(number), head,
				branch ~= "" and branch or "(detached HEAD)", head
			),
			{ choices = { "&Checkout", "&Ignore" }, default_choice = 1 }
		)
		if not confirmed then
			return
		end

		gh_prs.checkout(number, {}, function(err)
			if err then
				rstate.notify_error(err)
				return
			end
			rstate.notify_info(("Checked out PR branch '%s'"):format(head))
			local active = state.active_path
			M.refresh()
			if active then
				vim.schedule(function()
					overlay.open_file(active)
				end)
			end
		end)
	end)
end

--- Sum added / deleted lines across a hunk list (for file-list +/- counts).
---@param hunks GitflowReviewHunk[]
---@return integer, integer
local function count_changes(hunks)
	local add, del = 0, 0
	for _, h in ipairs(hunks or {}) do
		for _, l in ipairs(h.lines) do
			if l.kind == "add" then
				add = add + 1
			elseif l.kind == "del" then
				del = del + 1
			end
		end
	end
	return add, del
end

--- Build state.files / file_diffs from a local `git diff base head` instead
--- of the GitHub PR files API. Used by commit-scoped review (#363).
---@param base string
---@param head string
---@param cb fun(err: string|nil)
local function build_commit_scope_diffs(base, head, cb)
	git.git(
		{ "--no-pager", "diff", "--no-color", base, head },
		{},
		function(result)
			if result.code ~= 0 then
				cb(("Could not diff %s..%s: %s\n(Check out the PR branch so "
					.. "the commits are available locally.)"):format(
					base, head, git.output(result)))
				return
			end
			local parsed = inline.parse_diff(result.stdout or "")
			local files = {}
			local file_diffs = {}
			for path, fd in pairs(parsed) do
				local add, del = count_changes(fd.hunks)
				files[#files + 1] = {
					path = path,
					status = fd.status or "M",
					additions = add,
					deletions = del,
				}
				file_diffs[path] = fd
			end
			table.sort(files, function(a, b) return a.path < b.path end)
			state.files = files
			state.files_loaded = true
			state.file_diffs = file_diffs
			cb(nil)
		end
	)
end

--- Hydrate drafts from the on-disk cache, but never over the top of drafts
--- the user has in hand: an in-memory list that is not empty is the newer
--- truth, and clobbering it would lose unsent comments.
local function hydrate_drafts(number)
	-- From here on the in-memory list is the whole truth about this PR's
	-- drafts, which is what lets the close guard trust its count.
	state.drafts_hydrated = true
	if #state.pending_comments > 0 then
		return 0
	end
	local cached = cache.load(number, state.repo_slug)
	if cached and type(cached.comments) == "table" then
		state.pending_comments = cached.comments
	end
	return #state.pending_comments
end

--- Reload the PR: metadata, changed files, remote threads and cached drafts.
function M.refresh()
	if not state.cfg or not state.pr_number then
		return
	end
	-- Which cache file the drafts live in is not known yet, and hydrating
	-- without it falls through to the blocking `repo_slug()`. Resolve first;
	-- `start` refreshes once the answer lands.
	if not state.repo_slug then
		M.start(state.pr_number)
		return
	end
	local number = state.pr_number
	local request_id = file_list.next_request()

	state.files_error = nil
	state.pr_title = state.pr_title or "(loading)"
	file_list.render()

	-- Load remote threads + cached drafts, then repaint. Shared by the
	-- whole-PR and commit-scoped paths.
	local function load_comments_and_finish()
		gh_prs.review_comments(number, {}, function(rc_err, comments)
			if not file_list.is_active(request_id, number) then
				return
			end
			if rc_err then
				rstate.notify_error("Review comments unavailable: " .. rc_err)
			elseif comments then
				state.comment_threads = threads.build(comments)
			end
			hydrate_drafts(number)

			file_list.render()
			overlay.set_banner_winbar(state.diff_winid)

			if state.active_path then
				overlay.open_file(state.active_path)
			end
		end)
	end

	gh_prs.view(number, {}, function(view_err, pr)
		if not file_list.is_active(request_id, number) then
			return
		end
		if view_err then
			rstate.notify_error(view_err)
		else
			pull_pr_metadata(pr)
			maybe_prompt_pr_checkout()
		end

		-- Commit-scoped review (#363): files come from a local git diff of
		-- the chosen commit range, not the PR-wide files API.
		if state.commit_scope then
			local scope = state.commit_scope
			build_commit_scope_diffs(scope.base, scope.head, function(derr)
				if not file_list.is_active(request_id, number) then
					return
				end
				if derr then
					state.files_loaded = true
					state.files_error = derr
					rstate.notify_error(derr)
				end
				load_comments_and_finish()
			end)
			return
		end

		gh_prs.list_files(number, {}, function(files_err, files_data)
			if not file_list.is_active(request_id, number) then
				return
			end
			if files_err then
				state.files_loaded = true
				state.files_error = files_err
				rstate.notify_error(
					"Could not load PR files list: " .. files_err)
				file_list.render()
				return
			end

			ingest_pr_files(files_data)
			load_comments_and_finish()
		end)
	end)
end

--- Resolve the repo's draft-cache slug, restore any drafts it holds, and then
--- start the first load. Called once per open: the slug decides which cache
--- file this review's drafts live in, so nothing may write a draft before it
--- is known.
---@param number integer
function M.start(number)
	cache.resolve_repo_slug(function(slug)
		if state.pr_number ~= number then
			return
		end
		state.repo_slug = slug
		local restored = hydrate_drafts(number)
		if restored > 0 then
			rstate.notify_info(
				("Restored %d pending comment(s) from disk for PR #%d"):
					format(restored, number))
		end
		file_list.render()
		M.refresh()
	end)
end

-- ── commit scoping (#363) ──────────────────────────────────────────────

--- Scope the review to a single commit or a range of commits. Lists the PR's
--- commits oldest→newest and prompts for a start then an end commit; picking
--- "Whole PR" resets the scope.
function M.scope_to_commits()
	local number = state.pr_number
	if not number then
		rstate.notify_warn("No pull request selected")
		return
	end
	gh_prs.list_commits(number, {}, function(err, commits)
		if err then
			rstate.notify_error("Could not list PR commits: " .. err)
			return
		end
		local list = {}
		for _, c in ipairs(commits or {}) do
			local sha = tostring(c.sha or "")
			if sha ~= "" then
				local msg = ""
				if type(c.commit) == "table" then
					msg = tostring(c.commit.message or "")
				end
				list[#list + 1] = {
					sha = sha,
					short = sha:sub(1, 7),
					subject = vim.split(msg, "\n", { plain = true })[1] or "",
				}
			end
		end
		if #list == 0 then
			rstate.notify_warn("This PR has no commits to scope to")
			return
		end

		local items = { { reset = true } }
		for _, c in ipairs(list) do
			items[#items + 1] = c
		end
		vim.ui.select(items, {
			prompt = "Scope to commit (pick FIRST / oldest):",
			format_item = function(it)
				if it.reset then
					return "\u{2605} Whole PR (reset scope)"
				end
				return ("%s  %s"):format(it.short, it.subject)
			end,
		}, function(choice)
			if not choice then
				return
			end
			if choice.reset then
				M.clear_commit_scope()
				return
			end
			local start_idx
			for i, c in ipairs(list) do
				if c.sha == choice.sha then
					start_idx = i
					break
				end
			end
			if not start_idx then
				return
			end

			local tail = {}
			for i = start_idx, #list do
				tail[#tail + 1] = list[i]
			end
			vim.ui.select(tail, {
				prompt = "...to commit (pick LAST / newest; same = single):",
				format_item = function(it)
					return ("%s  %s"):format(it.short, it.subject)
				end,
			}, function(end_choice)
				if not end_choice then
					return
				end
				local first = list[start_idx]
				local label = (first.sha == end_choice.sha)
					and first.short
					or ("%s..%s"):format(first.short, end_choice.short)
				M.apply_commit_scope(first.sha .. "^", end_choice.sha, label)
			end)
		end)
	end)
end

--- Apply a commit-range scope and rebuild the file list from a local diff.
---@param base string  parent of the oldest selected commit (e.g. "<sha>^")
---@param head string  newest selected commit
---@param label string  short human label for the banner
function M.apply_commit_scope(base, head, label)
	state.commit_scope = { base = base, head = head, label = label }
	state.active_path = nil
	state.active_bufnr = nil
	state.active_file_idx = nil
	local number = state.pr_number
	local request_id = file_list.next_request()
	build_commit_scope_diffs(base, head, function(err)
		if not file_list.is_active(request_id, number) then
			return
		end
		if err then
			rstate.notify_error(err)
			state.commit_scope = nil
			M.refresh()
			return
		end
		rstate.notify_info(("Review scoped to %s"):format(label))
		file_list.render()
		overlay.set_banner_winbar(state.diff_winid)
	end)
end

--- Reset a commit scope back to the whole-PR diff (#363).
function M.clear_commit_scope()
	if not state.commit_scope then
		rstate.notify_info("Already reviewing the whole PR")
		return
	end
	state.commit_scope = nil
	state.active_path = nil
	state.active_bufnr = nil
	state.active_file_idx = nil
	rstate.notify_info("Review scope reset to the whole PR")
	M.refresh()
end

return M
