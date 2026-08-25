local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local components = require("gitflow.ui.components")
local panel = require("gitflow.ui.panel")
local form = require("gitflow.ui.form")
local gh = require("gitflow.gh")
local gh_prs = require("gitflow.gh.prs")
local gh_labels = require("gitflow.gh.labels")
local gh_issues = require("gitflow.gh.issues")
local label_completion = require("gitflow.completion.labels")
local assignee_completion = require("gitflow.completion.assignees")
local label_picker = require("gitflow.ui.label_picker")
local list_picker = require("gitflow.ui.list_picker")
local review_panel = require("gitflow.panels.review")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")

---@class GitflowPrPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filters table
---@field cache table[]|nil  raw PRs from the last successful fetch
---@field cache_key string|nil  scope the cache was filled under
---@field page integer  1-based page into `cache`, list mode only
---@field line_entries table<integer, table>
---@field mode "list"|"view"
---@field active_pr_number integer|nil
---@field active_pr table|nil  the PR the detail view is painted from
---@field view_cwd string|nil  cwd the detail view was fetched under
---@field busy string|nil  in-flight mutation, single-flight guard

local M = {}

-- Client-side page size (#283): the list is fetched in one bounded call
-- (filters.limit) but only one page is ever painted, so a large result set
-- never renders 100+ markdown cards into the buffer at once.
local PAGE_SIZE = 30
-- Create form's label picker: high enough to be the whole list on any sane
-- repo, and the fill is reported rather than silently truncating.
local LABEL_PICK_LIMIT = 1000

---@type GitflowPrPanelState
M.state = {
	cfg = nil,
	filters = {},
	cache = nil,
	cache_key = nil,
	page = 1,
	line_entries = {},
	mode = "list",
	active_pr_number = nil,
	active_pr = nil,
	view_cwd = nil,
	busy = nil,
}

-- Forward-declared: the "b" (back) keymap below closes over it before its
-- definition later in the file.
local render_list
local repaint_list_from_cache

---Scope the cache is only valid under: `gh` resolves the repo from the cwd,
---and the filters decide what the rows mean.
---@param cwd string|nil  defaults to the live cwd
---@return string
local function cache_key(cwd)
	local filters = M.state.filters
	return table.concat({
		cwd or vim.fn.getcwd(),
		filters.state or "",
		filters.base or "",
		filters.head or "",
		tostring(filters.limit or ""),
	}, "\0")
end

---The cache, but only when it was filled under the current scope. Unkeyed it
---painted another repo's PRs as actionable rows, so a mismatch drops it.
---@return table[]|nil
local function scoped_cache()
	if not M.state.cache then
		return nil
	end
	if M.state.cache_key ~= cache_key() then
		M.state.cache, M.state.cache_key = nil, nil
		return nil
	end
	return M.state.cache
end

---Repaint the list from what is already in memory. No gh call: this is what
---makes an optimistic patch and its revert visible in the same frame.
repaint_list_from_cache = function()
	if not M.is_open() or M.state.mode ~= "list" then
		return
	end
	local cached = scoped_cache()
	if cached then
		render_list(cached)
	end
end

---Replace `entry` in the cache with a copy carrying `patch`, and return the
---undo. A copy rather than an in-place write: the row object is also held by
---line_entries and by the detail view, and a guess about what GitHub will do
---must not leak into anything already pointing at it.
---@param entry table
---@param patch table
---@return fun()|nil  the undo, or nil when the row is not in the cache
local function patch_cached(entry, patch)
	local cached = M.state.cache
	if type(cached) ~= "table" then
		return nil
	end
	for index, candidate in ipairs(cached) do
		if candidate == entry then
			cached[index] = vim.tbl_extend("force", {}, entry, patch)
			return function()
				cached[index] = entry
			end
		end
	end
	return nil
end

local P = panel.new({
	name = "prs",
	title = "Gitflow Pull Requests",
	filetype = "markdown",
	loading = "Loading pull requests…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "view", views = { "list" }, essential = true,
			run = function()
				M.view_under_cursor()
			end },
		{ key = "c", desc = "create", views = { "list" }, run = function()
			M.create_interactive()
		end },
		{ key = "C", desc = "comment", hint = false, run = function()
			M.comment_under_cursor()
		end },
		{ key = "E", desc = "edit", run = function()
			M.edit_under_cursor()
		end },
		-- `m` is what the PR panel is FOR, so it is essential rather than
		-- destructive: the base drops destructive hints first, and a cramped
		-- bar must not advertise `x close` while hiding merge. The two
		-- irreversible *variants* below carry the destructive tag instead.
		{ key = "m", desc = "merge", essential = true, run = function()
			M.merge_under_cursor()
		end },
		{ key = "D", desc = "merge+del branch", destructive = true, run = function()
			M.merge_delete_branch_under_cursor()
		end },
		{ key = "M", desc = "auto-merge", destructive = true, run = function()
			M.auto_merge_under_cursor()
		end },
		-- `t`, not `d`: `d` is delete everywhere else in gitflow (branch,
		-- labels, stash, issue comments) and this toggle is reversible.
		{ key = "t", desc = "draft", run = function()
			M.toggle_draft_under_cursor()
		end },
		{ key = "o", desc = "checkout", run = function()
			M.checkout_under_cursor()
		end },
		{ key = "v", desc = "review", run = function()
			M.review_under_cursor()
		end },
		{ key = "L", desc = "labels", run = function()
			M.edit_labels_under_cursor()
		end },
		{ key = "A", desc = "assign", run = function()
			M.edit_assignees_under_cursor()
		end },
		{ key = "R", desc = "reviewers", run = function()
			M.edit_reviewers_under_cursor()
		end },
		{ key = "x", desc = "close PR", destructive = true, run = function()
			M.close_pr_under_cursor()
		end },
		{ key = "O", desc = "reopen", run = function()
			M.reopen_under_cursor()
		end },
		-- Not n/p: n is search-next in a buffer users `/` through; shadows
		-- CTRL-N/P motion instead, j/k still move. Tiered below the core verbs.
		{ key = "<C-n>", desc = "next page", views = { "list" }, run = function()
			M.next_page()
		end },
		{ key = "<C-p>", desc = "prev page", views = { "list" }, run = function()
			M.prev_page()
		end },
		{ key = "r", desc = "refresh", run = function()
			if M.state.mode == "view" and M.state.active_pr_number then
				M.open_view(M.state.active_pr_number)
				return
			end
			M.refresh()
		end },
		{ key = "b", desc = "back", views = { "view" }, hint = false,
			run = function()
				if M.state.mode ~= "view" then
					return
				end
				-- Leave view mode before the fetch: if the list load fails,
				-- `r` must retry the list, not reopen the detail.
				M.state.mode = "list"
				M.state.active_pr_number = nil
				-- Instant paint from cache (if any), then reconcile in the
				-- background — same cached-first-paint contract as M.open.
				local cached = scoped_cache()
				if cached then
					render_list(cached)
				end
				M.refresh()
			end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

---The cwd the panel's own window sees. `:lcd`/`:tcd` give a window its own
---directory, so a fetch must be judged against the panel's window rather than
---whichever one happens to be current when the answer lands.
---@return string
local function panel_cwd()
	local winid = P:render_opts().winid
	if winid and vim.api.nvim_win_is_valid(winid) then
		return vim.fn.getcwd(winid)
	end
	return vim.fn.getcwd()
end

---Run options that BIND a spawn to `scope`. `gh` and `git` resolve the
---repository from the process cwd, so naming it here makes the target a
---property of the call instead of a property of wherever the cwd happens to be
---when the process finally starts — including the second and third process of
---a chain that spawns again after a round trip.
---@param scope string  cwd the target was resolved under
---@return GitflowGitRunOpts
local function in_scope(scope)
	assert(type(scope) == "string" and scope ~= "", "a spawn must name the repo it runs in")
	return { cwd = scope }
end

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

---`vim.json.decode` turns a JSON `null` into the truthy `vim.NIL`; treat that
---(and Lua `nil`) as empty so it never prefills as a userdata address.
---@param value any
---@return string
local function json_text(value)
	if value == nil or value == vim.NIL then
		return ""
	end
	return (tostring(value):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

---@param pr table
---@return string
local function pr_state(pr)
	if pr.mergedAt ~= nil and pr.mergedAt ~= vim.NIL and tostring(pr.mergedAt) ~= "" then
		return "merged"
	end
	if pr.isDraft then
		return "draft"
	end
	local state = components.maybe_text(pr.state):lower()
	if state == "open" then
		return "open"
	end
	if state == "closed" then
		return "closed"
	end
	return state
end

---@param state string
---@return string
local function pr_highlight_group(state)
	if state == "open" then
		return "GitflowPROpen"
	end
	if state == "merged" then
		return "GitflowPRMerged"
	end
	if state == "draft" then
		return "GitflowPRDraft"
	end
	return "GitflowPRClosed"
end

---@param pr table
---@return string
local function pr_state_icon(state)
	return icons.get("github", "pr_" .. state)
end

-- ── status checks (#423) ────────────────────────────────────────────────
-- Same glyph/highlight vocabulary the actions panel uses for a run, so a
-- green tick means the same thing wherever CI state appears. Cancelled is the
-- one divergence: `gh pr checks` counts it as failing, and the merge keys are
-- pressed from this card, so it must not read like a benign skip.

---@type table<string, string>
local CHECK_GLYPHS = {
	success = "✓",
	failure = "✗",
	pending = "●",
	skipped = "⊘",
	cancelled = "⊗",
	unknown = "?",
}

---@type table<string, string>
local CHECK_HIGHLIGHTS = {
	success = "GitflowActionsPass",
	failure = "GitflowActionsFail",
	pending = "GitflowActionsPending",
	skipped = "GitflowActionsCancelled",
	cancelled = "GitflowActionsFail",
	unknown = "Comment",
}

---Compact per-state roll-up chunks for a card's meta row, e.g.
---"checks ✓3 ✗1 ●2 failure". The verdict word is part of it: counts alone let
---a card read greener than its worst check, and this is the surface the merge
---keys are pressed from. Empty when the PR has no checks at all, so a repo
---without CI stays quiet.
---@param pr table
---@return table[]
local function check_summary_chunks(pr)
	local summary = gh_prs.checks_summary(gh_prs.normalize_checks(pr.statusCheckRollup))
	if summary.total == 0 then
		return {}
	end

	local chunks = { { components.separators.field .. "checks ", "GitflowMetaKey" } }
	for _, state in ipairs({ "success", "failure", "pending", "skipped", "cancelled", "unknown" }) do
		if summary[state] > 0 then
			chunks[#chunks + 1] = {
				("%s%d "):format(CHECK_GLYPHS[state], summary[state]),
				CHECK_HIGHLIGHTS[state],
			}
		end
	end
	chunks[#chunks + 1] = { summary.state, CHECK_HIGHLIGHTS[summary.state] or "Comment" }
	return chunks
end

---@param review table
---@return string
local function review_author(review)
	local author = components.maybe_text(
		type(review.author) == "table" and review.author.login or review.author
	)
	if author ~= "-" then
		return author
	end
	author = components.maybe_text(
		type(review.user) == "table" and review.user.login or review.user
	)
	if author ~= "-" then
		return author
	end
	return "unknown"
end

---@param pr table
---@return string
local function join_assignee_names(pr)
	local assignees = pr.assignees or {}
	if type(assignees) ~= "table" or #assignees == 0 then
		return "-"
	end

	local names = {}
	for _, assignee in ipairs(assignees) do
		if type(assignee) == "table" and assignee.login then
			names[#names + 1] = assignee.login
		elseif type(assignee) == "string" then
			names[#names + 1] = assignee
		end
	end
	if #names == 0 then
		return "-"
	end
	return table.concat(names, ", ")
end

---Slice `list` to page `page` (clamped) at PAGE_SIZE.
---@param list table[]
---@param page integer
---@return table[] slice, integer page, integer total_pages
local function paginate(list, page)
	local total = #list
	local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
	page = math.min(math.max(1, page), total_pages)
	local start_index = (page - 1) * PAGE_SIZE + 1
	local end_index = math.min(total, page * PAGE_SIZE)
	local slice = {}
	for index = start_index, end_index do
		slice[#slice + 1] = list[index]
	end
	return slice, page, total_pages
end

---@param prs table[]
render_list = function(prs)
	local page_items, page, total_pages = paginate(prs, M.state.page)
	M.state.page = page

	local B = P:begin_render()

	local summary = {
		{ components.spacing.gutter, nil },
		{ icons.get("github", "pr_open") .. "  ", "GitflowSectionIcon" },
		{ ("PRs (%d)"):format(#prs), "GitflowSectionTitle" },
		{ components.separators.field .. "state ", "GitflowMetaKey" },
		{ components.maybe_text(M.state.filters.state), "GitflowMeta" },
	}
	if M.state.filters.base then
		summary[#summary + 1] = { components.separators.field .. "base ", "GitflowMetaKey" }
		summary[#summary + 1] = { components.maybe_text(M.state.filters.base), "GitflowMeta" }
	end
	if total_pages > 1 then
		summary[#summary + 1] = { components.separators.field .. "page ", "GitflowMetaKey" }
		summary[#summary + 1] = { ("%d/%d"):format(page, total_pages), "GitflowMeta" }
	end
	B:push(summary)
	B:blank()

	local line_entries = {}
	if #prs == 0 then
		components.empty(B, "no pull requests match these filters")
	else
		local width = components.content_width(P:render_opts())
		for _, pr in ipairs(page_items) do
			local number = tostring(pr.number or "?")
			local state = pr_state(pr)
			local state_icon = pr_state_icon(state)
			local title = components.maybe_text(pr.title)
			local time = components.relative_time(pr.updatedAt)
			local left = ("  %s  #%s  "):format(state_icon, number)
			local left_w = vim.fn.strdisplaywidth(left)
			local time_w = vim.fn.strdisplaywidth(time)
			local title_max = math.max(8, width - left_w - time_w - 2)
			title = components.truncate(title, title_max)
			local gap = math.max(
				2, width - left_w - vim.fn.strdisplaywidth(title) - time_w
			)
			local title_group = (state == "merged" or state == "closed")
				and "GitflowCardTitleDim" or "GitflowCardTitle"
			local title_line = B:push({
				{ components.spacing.gutter, nil },
				{ state_icon .. "  ", pr_highlight_group(state) },
				{ "#" .. number, "GitflowNumber" },
				{ "  ", nil },
				{ title, title_group },
				{ string.rep(" ", gap), nil },
				{ time, "GitflowRelTime" },
			})

			local meta = {
				{ components.spacing.indent, nil },
				{ icons.get("ui", "ref") .. " ", "GitflowMeta" },
				{ components.maybe_text(pr.headRefName), "GitflowChip" },
				{ " " .. components.glyphs.arrow .. " ", "GitflowMeta" },
				{ components.maybe_text(pr.baseRefName), "GitflowChip" },
				{ components.separators.field .. icons.get("ui", "author") .. " ", "GitflowMeta" },
				{ pr.author and components.maybe_text(pr.author.login) or "\u{2014}", "GitflowAuthor" },
				{ components.separators.field .. "labels: ", "GitflowMetaKey" },
			}
			for _, chunk in ipairs(components.label_chunks(pr.labels)) do
				meta[#meta + 1] = chunk
			end
			local assignees = join_assignee_names(pr)
			if assignees ~= "-" then
				meta[#meta + 1] =
					{ components.separators.field .. icons.get("ui", "author") .. " ", "GitflowMeta" }
				meta[#meta + 1] = { assignees, "GitflowChip" }
			end
			for _, chunk in ipairs(check_summary_chunks(pr)) do
				meta[#meta + 1] = chunk
			end
			local meta_line = B:push(meta)

			line_entries[title_line] = pr
			line_entries[meta_line] = pr
			B:blank()
		end
	end

	P:push_hints(B, "list")

	M.state.mode = "list"
	M.state.active_pr_number = nil
	M.state.active_pr = nil
	M.state.view_cwd = nil
	if not P:paint(B, line_entries) then
		-- Never leave the new mode paired with the old map.
		P:clear_entry_maps()
	end
	P:refresh_footer("list")

	-- P:paint already turned cursorline on; just place it on the first card.
	local first_line = nil
	for line_no in pairs(line_entries) do
		if not first_line or line_no < first_line then
			first_line = line_no
		end
	end
	if first_line and M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		pcall(vim.api.nvim_win_set_cursor, M.state.winid, { first_line, 0 })
	end
end

---@param pr table
---@param review_comments table[]|nil
---@param view_cwd string  cwd the detail was FETCHED under, not the live one
local function render_view(pr, review_comments, view_cwd)
	local view_state = pr_state(pr)
	local view_icon = pr_state_icon(view_state)
	local B = P:begin_render(
		("PR #%s: %s"):format(components.maybe_text(pr.number), components.maybe_text(pr.title))
	)
	B:blank()

	components.meta_row(B, "Title:", { { components.maybe_text(pr.title), "GitflowCardTitle" } })
	components.meta_row(B, "State:", {
		{ view_icon .. " " .. view_state, pr_highlight_group(view_state) },
	})
	components.meta_row(B, "Author:", {
		{ pr.author and components.maybe_text(pr.author.login) or "\u{2014}", "GitflowAuthor" },
	})
	components.meta_row(B, "Refs:", {
		{ components.maybe_text(pr.headRefName), "GitflowChip" },
		{ " " .. components.glyphs.arrow .. " ", "GitflowMeta" },
		{ components.maybe_text(pr.baseRefName), "GitflowChip" },
	})
	components.meta_row(B, "Labels:", components.label_chunks(pr.labels))
	components.meta_row(B, "Assignees:", { { join_assignee_names(pr), "GitflowChip" } })
	B:blank()

	local n_reviews = type(pr.reviews) == "table" and #pr.reviews or 0
	local n_files = type(pr.files) == "table" and #pr.files or 0
	local n_reqs = type(pr.reviewRequests) == "table" and #pr.reviewRequests or 0
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("ui", "check") .. " ", "GitflowCount" },
		{ ("%d file%s changed"):format(n_files, n_files == 1 and "" or "s"), "GitflowMeta" },
		{ components.separators.inline, "GitflowHintSep" },
		{ ("%d review%s"):format(n_reviews, n_reviews == 1 and "" or "s"), "GitflowMeta" },
		{ components.separators.inline, "GitflowHintSep" },
		{ ("%d requested"):format(n_reqs), "GitflowMeta" },
	})
	B:blank()

	local checks = gh_prs.normalize_checks(pr.statusCheckRollup)
	if #checks > 0 then
		local summary = gh_prs.checks_summary(checks)
		components.section(
			B, icons.get("ui", "check"),
			("Checks (%d) — %s"):format(summary.total, summary.state),
			{ title_hl = CHECK_HIGHLIGHTS[summary.state] or "GitflowSectionTitle" }
		)
		for _, check in ipairs(checks) do
			B:push({
				{ components.spacing.indent, nil },
				{ (CHECK_GLYPHS[check.state] or "?") .. "  ", CHECK_HIGHLIGHTS[check.state] or "Comment" },
				{ check.name, "GitflowChip" },
				{ components.separators.field, nil },
				{ check.description, CHECK_HIGHLIGHTS[check.state] or "Comment" },
			})
		end
		B:blank()
	end

	components.section(B, icons.get("ui", "comment"), "Body")
	local body_lines = split_lines(tostring(pr.body or ""))
	if #body_lines == 0 then
		components.empty(B, "(no description)")
	else
		for _, body_line in ipairs(body_lines) do
			B:raw(components.spacing.indent .. body_line)
		end
	end
	B:blank()

	local reviews = pr.reviews or {}
	if type(reviews) == "table" and #reviews > 0 then
		components.section(B, icons.get("github", "review_approved"), "Reviews")
		for _, review in ipairs(reviews) do
			local author = review_author(review)
			local state = components.maybe_text(review.state)
			local submitted_at = components.maybe_text(review.submittedAt)
			local header = ("@%s [%s]"):format(author, state)
			if submitted_at ~= "-" then
				header = ("%s (%s)"):format(header, submitted_at)
			end
			B:raw(("%s:"):format(header), "GitflowReviewAuthor")
			local review_message_lines = split_lines(tostring(review.body or ""))
			if #review_message_lines == 0 then
				B:raw(components.spacing.gutter .. ">> (empty)", "GitflowReviewComment")
			else
				for _, review_body_line in ipairs(review_message_lines) do
					B:raw(("%s>> %s"):format(components.spacing.gutter, review_body_line), "GitflowReviewComment")
				end
			end
			B:blank()
		end
	end

	local comments = pr.comments or {}
	local comment_count = type(comments) == "table" and #comments or 0
	components.section(B, icons.get("ui", "comment"), ("Comments (%d)"):format(comment_count))
	if comment_count == 0 then
		components.empty(B, "(none)")
	else
		for _, comment in ipairs(comments) do
			local author = comment.author
				and components.maybe_text(comment.author.login) or "unknown"
			B:push({
				{ components.spacing.indent, nil },
				{ icons.get("ui", "author") .. " ", "GitflowMeta" },
				{ author .. ":", "GitflowAuthor" },
			})
			local comment_lines = split_lines(tostring(comment.body or ""))
			if #comment_lines == 0 then
				components.empty(B, "(empty)")
			else
				for _, comment_line in ipairs(comment_lines) do
					B:raw(components.spacing.indent .. components.spacing.gutter .. comment_line)
				end
			end
			B:blank()
		end
	end

	local rc = review_comments or {}
	if type(rc) == "table" and #rc > 0 then
		components.section(B, icons.get("ui", "comment"), "Review Comments")
		for _, c in ipairs(rc) do
			local author = review_author(c)
			local path = components.maybe_text(c.path)
			B:raw(("@%s on %s:"):format(author, path), "GitflowReviewAuthor")
			local cbody = split_lines(tostring(c.body or ""))
			if #cbody == 0 then
				B:raw(components.spacing.gutter .. ">> (empty)", "GitflowReviewComment")
			else
				for _, bl in ipairs(cbody) do
					B:raw(("%s>> %s"):format(components.spacing.gutter, bl), "GitflowReviewComment")
				end
			end
			B:blank()
		end
	end

	P:push_hints(B, "view")

	M.state.mode = "view"
	M.state.active_pr_number = tonumber(pr.number)
	M.state.active_pr = pr
	-- gh resolves the repo from the cwd; a verb must never fire against a
	-- repo this detail did not come from. Stamped with the cwd the fetch was
	-- ISSUED under — re-reading it here would take it from the losing side of
	-- a `cd` that raced the round trip.
	M.state.view_cwd = view_cwd
	P:paint(B)
	-- No rows in the detail view: drop whatever the list left behind.
	P:clear_entry_maps()
	P:refresh_footer("view")
	components.cursorline(M.state.winid, false)
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		pcall(vim.api.nvim_win_set_cursor, M.state.winid, { 1, 0 })
	end
end

---@return table|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---Refuse an async continuation whose target the user can no longer see:
---prompts and forms are async, so the cwd can move between choosing the target
---and submitting, and acting on rows from a repo you have left is a surprise
---even when the spawn itself lands in the right place. Where the process runs
---is `in_scope`'s job, not this one's.
---@param scope string  cwd the target was resolved under
---@return boolean
local function scope_intact(scope)
	if scope == vim.fn.getcwd() then
		return true
	end
	utils.notify(
		"Repository changed since this was selected — nothing was sent",
		vim.log.levels.ERROR
	)
	return false
end

---The PR a keypress acts on, resolved at press time — never a number cached
---from an older paint. Returns nil when nothing is selected, or when the rows
---on screen belong to a repo we have since left.
---@return table|nil pr
---@return string|nil scope  cwd the target is valid under
local function target_pr()
	local cwd = vim.fn.getcwd()
	if M.state.mode == "view" then
		if M.state.view_cwd ~= cwd then
			return nil, nil
		end
		return M.state.active_pr, cwd
	end
	if not scoped_cache() then
		return nil, nil
	end
	return entry_under_cursor(), cwd
end

---Run a confirm-gated, single-flight mutation. Declining fires no `gh` call
---at all; a second press while one is in flight is refused rather than
---queued, so a double-tap can never merge twice.
---@class GitflowGhMutation
---@field confirm_message string  names exactly what will happen
---@field in_progress_message string
---@field done_message string
---@field scope string  cwd the target was resolved under
---@field call fun(run_opts: GitflowGitRunOpts, cb: fun(err: string|nil))
---@field optimistic fun():(fun()|nil)|nil  patch the cached PR to the outcome
---   the call almost always has, and return the undo to run if it fails
---@param opts GitflowGhMutation
local function perform_mutation(opts)
	assert(type(opts.scope) == "string", "a mutation must carry the scope it was chosen under")
	if M.state.busy then
		utils.notify(
			("Already busy: %s — wait for it to finish"):format(M.state.busy),
			vim.log.levels.WARN
		)
		return
	end

	-- Before the prompt: never ask the operator to authorise something that
	-- was never going to be sent.
	if not scope_intact(opts.scope) then
		return
	end

	-- The repo is named here rather than by each gate: `gh` resolves it from
	-- the cwd, so which repo is about to be hit is part of every prompt. Named
	-- from the target's scope — the live cwd would name the repo we moved to.
	local confirmed = input.confirm(
		("%s\nRepository: %s"):format(opts.confirm_message, gh.repo_label(opts.scope)),
		{ choices = { "&Yes", "&No" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	-- The confirm itself can be async; re-check before the spawn.
	if not scope_intact(opts.scope) then
		return
	end

	M.state.busy = opts.in_progress_message
	utils.notify(opts.in_progress_message .. "…", vim.log.levels.INFO)

	-- Paint the outcome now and reconcile when the call lands. A failure puts
	-- the row back and says so, so the panel never sits on a wrong state.
	local revert = opts.optimistic and opts.optimistic() or nil
	if revert then
		repaint_list_from_cache()
	end

	-- The scope is handed to the call rather than left for it to remember: a
	-- mutation that spawns again after a round trip must land in the same repo.
	opts.call(in_scope(opts.scope), function(err)
		M.state.busy = nil
		if err then
			if revert then
				revert()
				repaint_list_from_cache()
			end
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(opts.done_message, vim.log.levels.INFO)
		-- Closed under the mutation: nothing to repaint, and a refresh here
		-- would spend a gh call on a buffer that is gone.
		if not M.is_open() then
			return
		end
		if M.state.mode == "view" and M.state.active_pr_number then
			M.open_view(M.state.active_pr_number)
		else
			M.refresh()
		end
	end)
end

---Drop a detail fetch whose repo moved under it: no paint, and no state a
---verb could act on.
---@param number integer|string
local function abandon_view(number)
	M.state.active_pr, M.state.active_pr_number, M.state.view_cwd = nil, nil, nil
	utils.notify(
		("PR #%s was loaded in another repository — not shown"):format(tostring(number)),
		vim.log.levels.WARN
	)
	P:render_error("Repository changed while loading", {
		detail = ("PR #%s belongs to the repository you left."):format(tostring(number)),
		hint = "r loads this repository's pull requests",
		view = "view",
	})
end

---@param cfg GitflowConfig
---@param filters table|nil
function M.open(cfg, filters)
	M.state.cfg = cfg
	M.state.filters = vim.tbl_extend("force", {
		state = "open",
		base = nil,
		head = nil,
		limit = 100,
	}, filters or {})
	M.state.page = 1

	if not P:ensure_window(cfg, { view = "list" }) then
		return
	end
	-- Instant paint from what we already have (if any), then reconcile below.
	local cached = scoped_cache()
	if cached then
		render_list(cached)
	end
	M.refresh()
end

function M.refresh()
	if not M.state.cfg then
		return
	end

	local request_id = P:next_request()
	-- The scope this fetch is issued under: the fetch is bound to it, and a cwd
	-- or filter change while it is in flight must not stamp its rows as
	-- belonging to the new scope.
	local requested_cwd = vim.fn.getcwd()
	local requested_key = cache_key(requested_cwd)
	if not scoped_cache() then
		P:render_loading("Loading pull requests…")
	end
	gh_prs.list(M.state.filters, in_scope(requested_cwd), function(err, prs)
		if not P:is_active(request_id) then
			return
		end
		-- Scope moved under the fetch: these rows describe somewhere we
		-- left, so drop them and re-issue under the scope live now.
		if requested_key ~= cache_key() then
			M.state.cache, M.state.cache_key = nil, nil
			M.refresh()
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			-- Drop the cache and paint the failure even when rows are on
			-- screen: stale rows left actionable resolve verbs against a
			-- fetch that failed.
			M.state.cache, M.state.cache_key = nil, nil
			P:render_error("Failed to load pull requests", {
				detail = err,
				hint = "r retries",
				view = "list",
			})
			return
		end
		M.state.cache = prs or {}
		M.state.cache_key = requested_key
		M.state.page = 1
		render_list(M.state.cache)
	end)
end

---@param number integer|string
---@param cfg GitflowConfig|nil
function M.open_view(number, cfg)
	if cfg then
		M.state.cfg = cfg
	end
	if not M.state.cfg then
		return
	end
	if not P:ensure_window(M.state.cfg, { view = "view" }) then
		return
	end

	local request_id = P:next_request()
	-- The scope this fetch is issued under. A `cd` during the round trip makes
	-- the answer describe a repo we left, and painting it would arm every
	-- verb against the new one.
	local requested_cwd = vim.fn.getcwd()
	P:render_loading(("Loading PR #%s…"):format(tostring(number)))
	gh_prs.view(number, in_scope(requested_cwd), function(err, pr)
		if not P:is_active(request_id) then
			return
		end
		if requested_cwd ~= panel_cwd() then
			abandon_view(number)
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			P:render_error("Failed to load pull request", {
				detail = err,
				hint = "b returns to the list",
				view = "view",
			})
			return
		end
		-- Bound to the same scope as the `pr view` above: the two answers are
		-- painted as one record, so they must not come from two repositories.
		gh_prs.review_comments(number, in_scope(requested_cwd), function(rc_err, rc)
			if not P:is_active(request_id) then
				return
			end
			if requested_cwd ~= panel_cwd() then
				abandon_view(number)
				return
			end
			render_view(pr or {}, not rc_err and rc or nil, requested_cwd)
		end)
	end)
end

function M.view_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	M.open_view(entry.number)
end

---Advance to the next page of the cached list. List mode only.
function M.next_page()
	local cached = M.state.mode == "list" and scoped_cache() or nil
	if not cached then
		return
	end
	local _, _, total_pages = paginate(cached, M.state.page)
	if M.state.page >= total_pages then
		utils.notify("No more pull requests", vim.log.levels.WARN)
		return
	end
	M.state.page = M.state.page + 1
	render_list(cached)
end

---Return to the previous page of the cached list. List mode only.
function M.prev_page()
	local cached = M.state.mode == "list" and scoped_cache() or nil
	if not cached then
		return
	end
	if M.state.page <= 1 then
		utils.notify("Already on the first page", vim.log.levels.WARN)
		return
	end
	M.state.page = M.state.page - 1
	render_list(cached)
end

local function parse_csv_input(value)
	local items = {}
	for _, part in ipairs(vim.split(value or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(part)
		if trimmed ~= "" then
			items[#items + 1] = trimmed
		end
	end
	return items
end

---@param entries GitflowBranchEntry[]|nil
---@return { name: string }[]
local function build_base_branch_items(entries)
	local items = {}
	local seen = {}

	local function add(name)
		local normalized = vim.trim(name or "")
		if normalized == "" or seen[normalized] then
			return
		end
		seen[normalized] = true
		items[#items + 1] = { name = normalized }
	end

	for _, entry in ipairs(entries or {}) do
		if not entry.is_remote then
			add(entry.name)
		end
	end

	-- Fallback for unusual repos with no local branches available.
	if #items == 0 then
		for _, entry in ipairs(entries or {}) do
			if entry.is_remote and entry.remote and entry.short_name ~= "HEAD" then
				add(entry.short_name)
			end
		end
	end

	return items
end

---@param value string
---@return string[], string[]
local function parse_label_patch(value)
	local add = {}
	local remove = {}
	for _, token in ipairs(vim.split(value or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if trimmed == "" then
			goto continue
		end
		if vim.startswith(trimmed, "+") then
			add[#add + 1] = vim.trim(trimmed:sub(2))
		elseif vim.startswith(trimmed, "-") then
			remove[#remove + 1] = vim.trim(trimmed:sub(2))
		else
			add[#add + 1] = trimmed
		end
		::continue::
	end
	return add, remove
end

---Pick the default base branch for a new PR: prefer `main`, then `master`.
---Returns "" when neither is available so the field stays empty.
---@param branch_names string[]
---@return string
local function default_base_branch(branch_names)
	local seen = {}
	for _, name in ipairs(branch_names or {}) do
		seen[name] = true
	end
	if seen["main"] then
		return "main"
	end
	if seen["master"] then
		return "master"
	end
	return ""
end

---Build list-picker items for open issues, sorted newest-first (highest issue
---number at the top): name is the `#<number>` token used as the stored value,
---description carries the title for display + search.
---@param issues table[]|nil
---@return { name: string, description: string }[]
local function build_issue_items(issues)
	local sorted = {}
	for _, issue in ipairs(issues or {}) do
		if issue and issue.number ~= nil then
			sorted[#sorted + 1] = issue
		end
	end
	table.sort(sorted, function(left, right)
		return tonumber(left.number) > tonumber(right.number)
	end)

	local items = {}
	for _, issue in ipairs(sorted) do
		items[#items + 1] = {
			name = ("#%s"):format(tostring(issue.number)),
			description = vim.trim(tostring(issue.title or "")),
		}
	end
	return items
end

---Extract issue numbers from a CSV of `#<number>` tokens (as produced by the
---issue picker), preserving order and dropping duplicates.
---@param value string
---@return string[]
local function parse_issue_numbers(value)
	local numbers = {}
	local seen = {}
	for _, token in ipairs(parse_csv_input(value)) do
		local number = tostring(token):match("#?(%d+)")
		if number and not seen[number] then
			seen[number] = true
			numbers[#numbers + 1] = number
		end
	end
	return numbers
end

---Append `Closes #<n>` linking keywords to a PR body for each selected issue
---that the body does not already reference. Returns the augmented body.
---@param body string
---@param issue_numbers string[]
---@return string
local function apply_issue_links(body, issue_numbers)
	local text = body or ""
	local additions = {}
	for _, number in ipairs(issue_numbers) do
		if not text:find("#" .. number .. "%f[%D]") then
			additions[#additions + 1] = ("Closes #%s"):format(number)
		end
	end
	if #additions == 0 then
		return text
	end
	local closing = table.concat(additions, "\n")
	if vim.trim(text) == "" then
		return closing
	end
	return text .. "\n\n" .. closing
end

function M.create_interactive()
	if not M.state.cfg then
		return
	end

	-- The repo this form is being built for. Every field below is fetched from
	-- it — base branches, labels, reviewers, the issue numbers the body will
	-- close — so the create must be filed there and nowhere else.
	local scope = vim.fn.getcwd()

	local function names_completer(names)
		return function(lead)
			local query = vim.trim(tostring(lead or "")):lower()
			local out = {}
			for _, name in ipairs(names) do
				if query == "" or tostring(name):lower():find(query, 1, true) then
					out[#out + 1] = name
				end
			end
			return out
		end
	end

	local function open_form(available_labels, branch_items, assignee_items, issue_items)
		local label_names = {}
		for _, label in ipairs(available_labels) do
			if type(label) == "table" and label.name then
				label_names[#label_names + 1] = label.name
			end
		end
		local branch_names = {}
		for _, item in ipairs(branch_items) do
			if type(item) == "table" and item.name then
				branch_names[#branch_names + 1] = item.name
			end
		end
		local reviewer_names = {}
		for _, item in ipairs(assignee_items) do
			if type(item) == "table" and item.name then
				reviewer_names[#reviewer_names + 1] = item.name
			end
		end
		local issue_names = {}
		for _, item in ipairs(issue_items) do
			if type(item) == "table" and item.name then
				issue_names[#issue_names + 1] = item.name
			end
		end

		form.open({
			title = "Create Pull Request",
			draft_key = "pr:create",
			fields = {
				{
					name = "Title",
					key = "title",
					required = true,
					placeholder = "Short, descriptive summary",
				},
				{
					name = "Body",
					key = "body",
					multiline = true,
					placeholder = "Describe the change… (Markdown supported)",
				},
				{
					name = "Base branch",
					key = "base",
					default = default_base_branch(branch_names),
					complete = names_completer(branch_names),
					picker = function(ctx)
						list_picker.open({
							title = "Select Base Branch",
							items = branch_items,
							selected = ctx.value ~= ""
								and { ctx.value } or {},
							multi_select = false,
							on_submit = function(selected)
								if #selected > 0 then
									ctx.set_value(selected[1])
								end
							end,
						})
					end,
				},
				{
					name = "Closes issues (comma-separated)",
					key = "issues",
					complete = names_completer(issue_names),
					picker = function(ctx)
						list_picker.open({
							title = "Link Issues (Closes)",
							items = issue_items,
							selected = parse_csv_input(ctx.value),
							multi_select = true,
							on_submit = function(selected)
								ctx.set_value(
									table.concat(selected, ",")
								)
							end,
						})
					end,
				},
				{
					name = "Reviewers (comma-separated)",
					key = "reviewers",
					complete = names_completer(reviewer_names),
					picker = function(ctx)
						list_picker.open({
							title = "Select Reviewers",
							items = assignee_items,
							selected = parse_csv_input(ctx.value),
							multi_select = true,
							on_submit = function(selected)
								ctx.set_value(
									table.concat(selected, ",")
								)
							end,
						})
					end,
				},
				{
					name = "Labels",
					key = "labels",
					complete = names_completer(label_names),
					picker = function(ctx)
						label_picker.open({
							title = "PR Labels",
							labels = available_labels,
							selected = parse_csv_input(ctx.value),
							on_submit = function(selected_labels)
								ctx.set_value(
									table.concat(selected_labels, ",")
								)
							end,
						})
					end,
				},
			},
			on_submit = function(values)
				-- The form is async: filing repo A's title, base, reviewers,
				-- labels and `Closes #n` into a repo the operator has since
				-- moved to would mean a PR nothing on screen described.
				if not scope_intact(scope) then
					return
				end

				local body = apply_issue_links(
					values.body or "",
					parse_issue_numbers(values.issues or "")
				)
				gh_prs.create({
					title = values.title,
					body = body,
					base = vim.trim(values.base or ""),
					reviewers = parse_csv_input(values.reviewers),
					labels = parse_csv_input(values.labels),
				}, in_scope(scope), function(err, response)
					if err then
						utils.notify(err, vim.log.levels.ERROR)
						return
					end
					local message = response and response.url
						and ("Created PR: %s"):format(response.url)
						or "Pull request created"
					utils.notify(message, vim.log.levels.INFO)
					M.refresh()
					if M.state.winid
						and vim.api.nvim_win_is_valid(M.state.winid)
					then
						vim.api.nvim_set_current_win(M.state.winid)
					end
				end)
			end,
		})
	end

	local loaded = { labels = nil, branches = nil, assignees = nil, issues = nil }
	local pending = 4

	local function try_open()
		pending = pending - 1
		if pending > 0 then
			return
		end
		vim.schedule(function()
			open_form(
				loaded.labels or {},
				loaded.branches or {},
				loaded.assignees or {},
				loaded.issues or {}
			)
		end)
	end

	gh_labels.list({ limit = LABEL_PICK_LIMIT }, in_scope(scope), function(err, labels)
		if err then
			utils.notify(
				("Failed to load labels: %s"):format(err),
				vim.log.levels.WARN
			)
		end
		loaded.labels = type(labels) == "table" and labels or {}
		if #loaded.labels >= LABEL_PICK_LIMIT then
			utils.notify(
				("Offering the first %d labels only"):format(LABEL_PICK_LIMIT),
				vim.log.levels.WARN
			)
		end
		try_open()
	end)

	git_branch.list(in_scope(scope), function(err, entries)
		if err then
			utils.notify(
				("Failed to load branches: %s"):format(err),
				vim.log.levels.WARN
			)
		end
		loaded.branches = build_base_branch_items(entries)
		try_open()
	end)

	gh_issues.list({ state = "open", limit = 1000 }, in_scope(scope), function(err, issues)
		if err then
			utils.notify(
				("Failed to load issues: %s"):format(err),
				vim.log.levels.WARN
			)
		end
		loaded.issues = build_issue_items(
			type(issues) == "table" and issues or {}
		)
		try_open()
	end)

	-- The one prep fetch that cannot be bound: it is the shared completion
	-- cache's own synchronous spawn. Names offered only; the create is bound.
	local assignee_comp = require("gitflow.completion.assignees")
	vim.schedule(function()
		local names = assignee_comp.list_repo_assignee_candidates()
		local items = {}
		for _, name in ipairs(names) do
			items[#items + 1] = { name = name }
		end
		loaded.assignees = items
		try_open()
	end)
end

---@param number integer|string
---@param scope string  cwd the PR was resolved under
local function comment_on_pr(number, scope)
	input.prompt({
		multiline = true,
		title = ("Comment on PR #%s"):format(tostring(number)),
		draft_key = ("pr:%s:comment"):format(tostring(number)),
	}, function(body)
		local normalized = vim.trim(body or "")
		if normalized == "" then
			utils.notify("Comment cannot be empty", vim.log.levels.WARN)
			return
		end

		if not scope_intact(scope) then
			return
		end

		gh_prs.comment(number, normalized, in_scope(scope), function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(("Comment posted to PR #%s"):format(tostring(number)), vim.log.levels.INFO)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

function M.comment_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	comment_on_pr(pr.number, scope)
end

function M.edit_labels_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	input.prompt({
		prompt = "Labels (+bug,-wip,docs): ",
		completion = function(arglead, _, _)
			return label_completion.complete_issue_patch(arglead)
		end,
	}, function(value)
		local add_labels, remove_labels = parse_label_patch(value)
		if #add_labels == 0 and #remove_labels == 0 then
			utils.notify("No label edits provided", vim.log.levels.WARN)
			return
		end

		if not scope_intact(scope) then
			return
		end

		gh_prs.edit(number, {
			add_labels = add_labels,
			remove_labels = remove_labels,
		}, in_scope(scope), function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(("Updated labels for PR #%s"):format(tostring(number)), vim.log.levels.INFO)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

---@param value string
---@return string[], string[]
local function parse_assignee_patch(value)
	local add = {}
	local remove = {}
	for _, token in ipairs(vim.split(value or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if trimmed == "" then
			goto continue
		end
		if vim.startswith(trimmed, "+") then
			add[#add + 1] = vim.trim(trimmed:sub(2))
		elseif vim.startswith(trimmed, "-") then
			remove[#remove + 1] = vim.trim(trimmed:sub(2))
		else
			add[#add + 1] = trimmed
		end
		::continue::
	end
	return add, remove
end

function M.edit_assignees_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	input.prompt({
		prompt = "Assignees (+user,-user,user): ",
		completion = function(arglead, _, _)
			return assignee_completion.complete_assignee_patch(arglead)
		end,
	}, function(value)
		local add_assignees, remove_assignees = parse_assignee_patch(value)
		if #add_assignees == 0 and #remove_assignees == 0 then
			utils.notify("No assignee edits provided", vim.log.levels.WARN)
			return
		end

		if not scope_intact(scope) then
			return
		end

		gh_prs.edit(number, {
			add_assignees = add_assignees,
			remove_assignees = remove_assignees,
		}, in_scope(scope), function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Updated assignees for PR #%s"):format(tostring(number)),
				vim.log.levels.INFO
			)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

---Ask which merge strategy to use. Returns nil when the user backs out.
---@param number integer|string
---@return "merge"|"squash"|"rebase"|nil
local function ask_merge_strategy(number)
	local choice = vim.fn.confirm(
		("Merge PR #%s with strategy:"):format(tostring(number)),
		"&Merge\n&Squash\n&Rebase\n&Cancel",
		1
	)
	if choice == 2 then
		return "squash"
	end
	if choice == 3 then
		return "rebase"
	end
	if choice == 1 then
		return "merge"
	end
	return nil
end

---Where a PR lands, for confirm text that names exactly what will happen.
---@param pr table
---@return string
local function refs_text(pr)
	return ("%s → %s"):format(
		components.maybe_text(pr.headRefName), components.maybe_text(pr.baseRefName)
	)
end

---@param delete_branch boolean
local function merge_selected_pr(delete_branch)
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number
	local head = components.maybe_text(pr.headRefName)
	if delete_branch and head == "-" then
		utils.notify(
			("PR #%s has no head branch on record — refusing to merge with --delete-branch")
				:format(tostring(number)),
			vim.log.levels.ERROR
		)
		return
	end

	local strategy = ask_merge_strategy(number)
	if not strategy then
		return
	end

	perform_mutation({
		scope = scope,
		confirm_message = delete_branch
			and ("Merge PR #%s (%s) by %s AND DELETE branch %s? Both are irreversible.")
				:format(tostring(number), refs_text(pr), strategy, head)
			or ("Merge PR #%s (%s) by %s? Branch %s is kept.")
				:format(tostring(number), refs_text(pr), strategy, head),
		in_progress_message = ("Merging PR #%s"):format(tostring(number)),
		done_message = delete_branch
			and ("Merged PR #%s (%s) and deleted %s"):format(tostring(number), strategy, head)
			or ("Merged PR #%s (%s)"):format(tostring(number), strategy),
		call = function(run_opts, cb)
			gh_prs.merge(number, {
				strategy = strategy,
				delete_branch = delete_branch,
			}, run_opts, cb)
		end,
	})
end

function M.merge_under_cursor()
	merge_selected_pr(false)
end

function M.merge_delete_branch_under_cursor()
	merge_selected_pr(true)
end

---Enable or cancel auto-merge. Enabling arms a merge that will happen with no
---further prompt, so the confirm spells that out.
function M.auto_merge_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	local _, choice = input.confirm(
		("Auto-merge for PR #%s (%s):"):format(tostring(number), refs_text(pr)),
		{ choices = { "&Enable", "&Disable", "&Cancel" }, default_choice = 3 }
	)
	if choice ~= 1 and choice ~= 2 then
		return
	end

	if choice == 2 then
		perform_mutation({
			scope = scope,
			confirm_message = ("Cancel the queued auto-merge for PR #%s?")
				:format(tostring(number)),
			in_progress_message = ("Disabling auto-merge for PR #%s"):format(tostring(number)),
			done_message = ("Auto-merge disabled for PR #%s"):format(tostring(number)),
			call = function(run_opts, cb)
				gh_prs.disable_auto_merge(number, run_opts, cb)
			end,
		})
		return
	end

	local strategy = ask_merge_strategy(number)
	if not strategy then
		return
	end
	perform_mutation({
		scope = scope,
		confirm_message = ("Queue PR #%s (%s) to auto-merge by %s once checks pass?"
			.. " It will then merge with no further confirmation.")
			:format(tostring(number), refs_text(pr), strategy),
		in_progress_message = ("Enabling auto-merge for PR #%s"):format(tostring(number)),
		done_message = ("Auto-merge queued for PR #%s (%s)"):format(tostring(number), strategy),
		call = function(run_opts, cb)
			gh_prs.merge(number, { strategy = strategy, auto = true }, run_opts, cb)
		end,
	})
end

function M.close_pr_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	perform_mutation({
		scope = scope,
		confirm_message = ("Close PR #%s without merging?"):format(tostring(number)),
		in_progress_message = ("Closing PR #%s"):format(tostring(number)),
		done_message = ("Closed PR #%s"):format(tostring(number)),
		optimistic = function()
			return patch_cached(pr, { state = "CLOSED" })
		end,
		call = function(run_opts, cb)
			gh_prs.close(number, run_opts, cb)
		end,
	})
end

---The inverse of `x`: bring a closed PR back.
function M.reopen_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	perform_mutation({
		scope = scope,
		confirm_message = ("Reopen PR #%s?"):format(tostring(number)),
		in_progress_message = ("Reopening PR #%s"):format(tostring(number)),
		done_message = ("Reopened PR #%s"):format(tostring(number)),
		optimistic = function()
			return patch_cached(pr, { state = "OPEN" })
		end,
		call = function(run_opts, cb)
			gh_prs.reopen(number, run_opts, cb)
		end,
	})
end

---Flip a PR between draft and ready-for-review.
function M.toggle_draft_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number
	local to_draft = not pr.isDraft

	perform_mutation({
		scope = scope,
		confirm_message = to_draft
			and ("Convert PR #%s back to a draft?"):format(tostring(number))
			or ("Mark PR #%s ready for review?"):format(tostring(number)),
		in_progress_message = to_draft
			and ("Converting PR #%s to a draft"):format(tostring(number))
			or ("Marking PR #%s ready"):format(tostring(number)),
		done_message = to_draft
			and ("PR #%s is now a draft"):format(tostring(number))
			or ("PR #%s is ready for review"):format(tostring(number)),
		optimistic = function()
			return patch_cached(pr, { isDraft = to_draft })
		end,
		call = function(run_opts, cb)
			gh_prs.set_draft(number, to_draft, run_opts, cb)
		end,
	})
end

---Edit a PR's title and body. Fetched fresh: the list cache has no body, and
---a stale one would be written straight back to GitHub.
function M.edit_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	gh_prs.view(number, in_scope(scope), function(err, fresh)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		fresh = fresh or {}

		form.open({
			title = ("Edit PR #%s"):format(tostring(number)),
			-- No draft_key: a stashed draft would outrank this fresh fetch on
			-- reopen and could push a stale body back to GitHub.
			fields = {
				{
					name = "Title",
					key = "title",
					required = true,
					default = json_text(fresh.title),
				},
				{
					name = "Body",
					key = "body",
					multiline = true,
					default = json_text(fresh.body),
					placeholder = "Describe the change… (Markdown supported)",
				},
			},
			on_submit = function(values)
				-- The form is async and there is no undo: a `cd` while it was
				-- open would write this PR's text into the other repo's #<n>.
				if not scope_intact(scope) then
					return
				end

				gh_prs.edit(number, {
					title = values.title,
					body = values.body,
				}, in_scope(scope), function(edit_err)
					if edit_err then
						utils.notify(edit_err, vim.log.levels.ERROR)
						return
					end
					utils.notify(
						("Updated PR #%s"):format(tostring(number)), vim.log.levels.INFO
					)
					if M.state.mode == "view" then
						M.open_view(number)
					else
						M.refresh()
					end
				end)
			end,
		})
	end)
end

---Add and remove reviewers with the same `+name,-name` patch grammar the
---label and assignee prompts use.
function M.edit_reviewers_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	input.prompt({
		prompt = "Reviewers (+user,-user,user): ",
		completion = function(arglead, _, _)
			return assignee_completion.complete_assignee_patch(arglead)
		end,
	}, function(value)
		local add_reviewers, remove_reviewers = parse_assignee_patch(value)
		if #add_reviewers == 0 and #remove_reviewers == 0 then
			utils.notify("No reviewer edits provided", vim.log.levels.WARN)
			return
		end

		if not scope_intact(scope) then
			return
		end

		gh_prs.edit(number, {
			add_reviewers = add_reviewers,
			remove_reviewers = remove_reviewers,
		}, in_scope(scope), function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Updated reviewers for PR #%s"):format(tostring(number)),
				vim.log.levels.INFO
			)
			if M.state.mode == "view" then
				M.open_view(number)
			else
				M.refresh()
			end
		end)
	end)
end

function M.checkout_under_cursor()
	local pr, scope = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	gh_prs.checkout(number, in_scope(scope), function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Checked out PR #%s"):format(tostring(number)), vim.log.levels.INFO)
	end)
end

function M.review_under_cursor()
	local pr = target_pr()
	if not pr then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	local number = pr.number

	if not M.state.cfg then
		utils.notify("Gitflow config unavailable for review panel", vim.log.levels.ERROR)
		return
	end

	review_panel.open(M.state.cfg, number)
end

function M.close()
	P:close()
	M.state.line_entries = {}
	M.state.mode = "list"
	M.state.active_pr_number = nil
	M.state.active_pr = nil
	M.state.view_cwd = nil
	-- `busy` deliberately survives: the in-flight mutation clears it when it
	-- lands. Clearing it here re-armed the single-flight guard mid-merge.
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
