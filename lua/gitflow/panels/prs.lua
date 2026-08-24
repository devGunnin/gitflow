local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local components = require("gitflow.ui.components")
local panel = require("gitflow.ui.panel")
local form = require("gitflow.ui.form")
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
}

-- Forward-declared: the "b" (back) keymap below closes over it before its
-- definition later in the file.
local render_list

---Scope the cache is only valid under: `gh` resolves the repo from the cwd,
---and the filters decide what the rows mean.
---@return string
local function cache_key()
	local filters = M.state.filters
	return table.concat({
		vim.fn.getcwd(),
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
		{ key = "m", desc = "merge", run = function()
			M.merge_under_cursor()
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
		{ key = "x", desc = "close PR", destructive = true, run = function()
			M.close_pr_under_cursor()
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

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = false })
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
		components.empty(B, "No pull requests match these filters.")
	else
		local width = components.content_width(P:render_opts())
		for _, pr in ipairs(page_items) do
			local number = tostring(pr.number or "?")
			local state = pr_state(pr)
			local state_icon = pr_state_icon(state)
			local title = components.maybe_text(pr.title)
			local time = components.relative_time(pr.updatedAt)
			local left = (" %s  #%s  "):format(state_icon, number)
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
				{ components.spacing.edge, nil },
				{ state_icon .. "  ", pr_highlight_group(state) },
				{ "#" .. number, "GitflowNumber" },
				{ "  ", nil },
				{ title, title_group },
				{ string.rep(" ", gap), nil },
				{ time, "GitflowRelTime" },
			})

			local meta = {
				{ components.spacing.gutter .. components.spacing.indent, nil },
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
			local meta_line = B:push(meta)

			line_entries[title_line] = pr
			line_entries[meta_line] = pr
			B:blank()
		end
	end

	P:push_hints(B, "list")

	M.state.mode = "list"
	M.state.active_pr_number = nil
	if P:paint(B) then
		M.state.line_entries = line_entries
	else
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
local function render_view(pr, review_comments)
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
	-- The scope this fetch is issued under: a cwd or filter change while it is
	-- in flight must not stamp its rows as belonging to the new scope.
	local requested_key = cache_key()
	if not scoped_cache() then
		P:render_loading("Loading pull requests…")
	end
	gh_prs.list(M.state.filters, {}, function(err, prs)
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
	P:render_loading(("Loading PR #%s…"):format(tostring(number)))
	gh_prs.view(number, {}, function(err, pr)
		if not P:is_active(request_id) then
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
		gh_prs.review_comments(number, {}, function(rc_err, rc)
			if not P:is_active(request_id) then
				return
			end
			render_view(pr or {}, not rc_err and rc or nil)
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
				}, {}, function(err, response)
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

	gh_labels.list({ limit = LABEL_PICK_LIMIT }, {}, function(err, labels)
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

	git_branch.list({}, function(err, entries)
		if err then
			utils.notify(
				("Failed to load branches: %s"):format(err),
				vim.log.levels.WARN
			)
		end
		loaded.branches = build_base_branch_items(entries)
		try_open()
	end)

	gh_issues.list({ state = "open", limit = 1000 }, {}, function(err, issues)
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
local function comment_on_pr(number)
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

		gh_prs.comment(number, normalized, {}, function(err)
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
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end
	comment_on_pr(number)
end

function M.edit_labels_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

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

		gh_prs.edit(number, {
			add_labels = add_labels,
			remove_labels = remove_labels,
		}, {}, function(err)
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
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

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

		gh_prs.edit(number, {
			add_assignees = add_assignees,
			remove_assignees = remove_assignees,
		}, {}, function(err)
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

function M.merge_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	local choice = vim.fn.confirm(
		("Merge PR #%s with strategy:"):format(tostring(number)),
		"&Merge\n&Squash\n&Rebase\n&Cancel",
		1
	)
	if choice == 4 or choice == 0 then
		return
	end

	local strategy = "merge"
	if choice == 2 then
		strategy = "squash"
	elseif choice == 3 then
		strategy = "rebase"
	end

	gh_prs.merge(number, strategy, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Merged PR #%s (%s)"):format(tostring(number), strategy), vim.log.levels.INFO)
		if M.state.mode == "view" then
			M.open_view(number)
		else
			M.refresh()
		end
	end)
end

---@param number integer|string
local function close_pr(number)
	gh_prs.close(number, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			("Closed PR #%s"):format(tostring(number)),
			vim.log.levels.INFO
		)
		if M.state.mode == "view" then
			M.open_view(number)
		else
			M.refresh()
		end
	end)
end

function M.close_pr_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	local confirmed = input.confirm(
		("Close PR #%s?"):format(tostring(number)),
		{ choices = { "&Yes", "&No" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	close_pr(number)
end

function M.checkout_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

	gh_prs.checkout(number, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Checked out PR #%s"):format(tostring(number)), vim.log.levels.INFO)
	end)
end

function M.review_under_cursor()
	local number = M.state.active_pr_number
	if M.state.mode == "list" then
		local entry = entry_under_cursor()
		if not entry then
			utils.notify("No pull request selected", vim.log.levels.WARN)
			return
		end
		number = entry.number
	end

	if not number then
		utils.notify("No pull request selected", vim.log.levels.WARN)
		return
	end

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
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
