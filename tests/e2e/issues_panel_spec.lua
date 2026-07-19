--- tests/e2e/issues_panel_spec.lua — issues panel derivation pipeline
---
--- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/issues_panel_spec.lua
---
--- Covers the fetch-once / derive-locally strategy: the panel issues a single
--- broad `gh issue list` and derives what it renders from cache + filters.

local T = _G.T
local cfg = _G.TestConfig

local issues_panel = require("gitflow.panels.issues")
local gh_issues = require("gitflow.gh.issues")
local derive = require("gitflow.issues.derive")
local ui = require("gitflow.ui")

local GH_LOG = vim.fn.tempname()

---Reset the recorded `gh` invocation log. Drains first so a job left in
---flight by an earlier test cannot land in the fresh log.
local function reset_gh_log()
	T.drain_jobs()
	vim.fn.delete(GH_LOG)
	vim.env.GITFLOW_GH_LOG = GH_LOG
end

---@return string[]  recorded `gh` argument lines
local function gh_calls()
	if vim.fn.filereadable(GH_LOG) == 0 then
		return {}
	end
	return vim.fn.readfile(GH_LOG)
end

---@param needle string
---@return integer
local function gh_call_count(needle)
	local count = 0
	for _, line in ipairs(gh_calls()) do
		if line:find(needle, 1, true) then
			count = count + 1
		end
	end
	return count
end

---Open the panel and wait until the first card is rendered.
---@param filters table|nil
---@return integer bufnr
local function open_and_wait(filters)
	T.cleanup_panels()
	-- Sort and grouping persist for the session by design; reset them so each
	-- test starts from the documented defaults regardless of run order.
	issues_panel.state.cache = nil
	issues_panel.state.sort = { key = "updated", direction = "desc" }
	issues_panel.state.group_by = "none"
	issues_panel.state.collapsed = {}
	issues_panel.open(cfg, filters)
	T.wait_until(function()
		local bufnr = ui.buffer.get("issues")
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return false
		end
		return issues_panel.state.cache ~= nil
			and T.find_line(T.buf_lines(bufnr), "Setup CI pipeline") ~= nil
	end, "issues panel should render a list", 5000)
	return ui.buffer.get("issues")
end

---@return string[]
local function panel_lines()
	local bufnr = ui.buffer.get("issues")
	T.assert_true(
		bufnr and vim.api.nvim_buf_is_valid(bufnr),
		"issues buffer should exist"
	)
	return T.buf_lines(bufnr)
end

---@param lines string[]
---@param needle string
---@return boolean
local function has_line(lines, needle)
	return T.find_line(lines, needle) ~= nil
end

---@param bufnr integer
---@param lhs string
---@return table|nil
local function buf_map(bufnr, lhs)
	local target = vim.api.nvim_replace_termcodes(lhs, true, true, true)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == target then
			return map
		end
	end
	return nil
end

-- Fixture shorthand for the pure-derivation tests.
local ISSUE_A = {
	number = 1,
	title = "Setup CI pipeline",
	state = "OPEN",
	labels = { { name = "enhancement" } },
	assignees = { { login = "octocat" } },
	milestone = { title = "v1.0" },
	updatedAt = "2026-02-08T00:00:00Z",
}
local ISSUE_B = {
	number = 2,
	title = "Fix rendering glitch",
	state = "OPEN",
	labels = { { name = "bug" } },
	assignees = {},
	updatedAt = "2026-02-07T12:00:00Z",
}
local ISSUE_C = {
	number = 3,
	title = "Update README",
	state = "CLOSED",
	labels = { { name = "documentation" }, { name = "bug" } },
	assignees = {},
	milestone = { title = "v1.0" },
	updatedAt = "2026-02-06T09:00:00Z",
}
local ALL_ISSUES = { ISSUE_A, ISSUE_B, ISSUE_C }

---@param issues table[]
---@return integer[]
local function numbers_of(issues)
	local out = {}
	for _, issue in ipairs(issues) do
		out[#out + 1] = issue.number
	end
	return out
end

T.run_suite("issues_panel_spec", {

	-- ── #388 pure derivation ───────────────────────────────────────────

	["state filter keeps only matching issues"] = function()
		T.assert_deep_equals(
			numbers_of(derive.filter(ALL_ISSUES, { state = "open" })),
			{ 1, 2 },
			"open filter should drop the closed issue"
		)
		T.assert_deep_equals(
			numbers_of(derive.filter(ALL_ISSUES, { state = "closed" })),
			{ 3 },
			"closed filter should keep only the closed issue"
		)
		T.assert_deep_equals(
			numbers_of(derive.filter(ALL_ISSUES, { state = "all" })),
			{ 1, 2, 3 },
			"all should keep everything"
		)
	end,

	["label filter ANDs comma-separated names"] = function()
		T.assert_deep_equals(
			numbers_of(derive.filter(ALL_ISSUES, { state = "all", label = "bug" })),
			{ 2, 3 },
			"single label should match any issue carrying it"
		)
		T.assert_deep_equals(
			numbers_of(derive.filter(
				ALL_ISSUES, { state = "all", label = "bug,documentation" }
			)),
			{ 3 },
			"multiple labels should be ANDed"
		)
	end,

	["assignee filter matches case-insensitively"] = function()
		T.assert_deep_equals(
			numbers_of(derive.filter(ALL_ISSUES, { state = "all", assignee = "OctoCat" })),
			{ 1 },
			"assignee match should ignore case"
		)
	end,

	["gh server selectors are not evaluated client-side"] = function()
		T.assert_true(
			derive.is_server_selector("@me"),
			"@me should be recognised as a server-side selector"
		)
		T.assert_false(
			derive.is_server_selector("octocat"),
			"a plain login is not a server-side selector"
		)
		T.assert_deep_equals(
			numbers_of(derive.filter(ALL_ISSUES, { state = "all", assignee = "@me" })),
			{ 1, 2, 3 },
			"@me must be left to the server, not silently dropping every issue"
		)
	end,

	["distinct values feed the filter pickers"] = function()
		T.assert_deep_equals(
			derive.distinct_values(ALL_ISSUES, "label"),
			{ "bug", "documentation", "enhancement" },
			"labels should be de-duplicated and sorted"
		)
		T.assert_deep_equals(
			derive.distinct_values(ALL_ISSUES, "milestone"),
			{ "v1.0" },
			"milestones should be de-duplicated"
		)
	end,

	["cycle wraps and restarts from unknown values"] = function()
		local values = { "a", "b", "c" }
		T.assert_equals(derive.cycle(values, "a"), "b", "should advance")
		T.assert_equals(derive.cycle(values, "c"), "a", "should wrap around")
		T.assert_equals(derive.cycle(values, "zz"), "a", "unknown should restart")
	end,

	-- ── #388 panel fetch strategy ──────────────────────────────────────

	["panel fetches once with a broad query"] = function()
		reset_gh_log()
		open_and_wait()

		T.assert_equals(
			gh_call_count("issue list"), 1,
			"opening the panel should issue exactly one issue list call"
		)
		local call = nil
		for _, line in ipairs(gh_calls()) do
			if line:find("issue list", 1, true) then
				call = line
			end
		end
		T.assert_contains(call, "--state all", "the fetch should be state-agnostic")
		T.assert_contains(call, "--limit", "the fetch should carry a generous limit")
		T.assert_true(
			call:find("--label", 1, true) == nil,
			"labels must be filtered client-side, not server-side"
		)
	end,

	["filter changes re-render without another gh call"] = function()
		reset_gh_log()
		open_and_wait()
		T.assert_equals(gh_call_count("issue list"), 1, "one fetch so far")

		local open_lines = panel_lines()
		T.assert_true(
			has_line(open_lines, "Update README") == false,
			"the closed issue should be hidden under the default open filter"
		)

		issues_panel.state.filters.state = "all"
		issues_panel.rerender()

		local all_lines = panel_lines()
		T.assert_true(
			has_line(all_lines, "Update README"),
			"switching to state=all should reveal the closed issue"
		)
		T.assert_equals(
			gh_call_count("issue list"), 1,
			"deriving from the cache must not refetch"
		)
	end,

	-- ── #385 milestone data ────────────────────────────────────────────

	["gh list requests milestone and forwards the flag"] = function()
		reset_gh_log()
		local err = T.wait_async(function(done)
			gh_issues.list({ milestone = "v1.0" }, {}, function(list_err)
				done(list_err)
			end)
		end)
		T.assert_equals(err, nil, "gh issue list should succeed")

		local call = gh_calls()[1]
		T.assert_contains(call, "milestone", "the json field set should ask for milestone")
		T.assert_contains(call, "--milestone v1.0", "the milestone flag should be forwarded")
	end,

	["cards and detail view show the milestone"] = function()
		reset_gh_log()
		open_and_wait({ state = "all" })

		local lines = panel_lines()
		local card = T.find_line(lines, "Setup CI pipeline")
		T.assert_true(card ~= nil, "the milestoned issue should render")
		T.assert_contains(
			lines[card + 1], "milestone: v1.0",
			"the card meta line should carry the milestone title"
		)

		local without = T.find_line(lines, "Fix rendering glitch")
		T.assert_true(without ~= nil, "the issue without a milestone should render")
		T.assert_contains(
			lines[without + 1], "milestone: -",
			"a missing milestone should render as -"
		)

		issues_panel.open_view(1, cfg)
		T.wait_until(function()
			return T.find_line(panel_lines(), "Milestone:") ~= nil
		end, "detail view should show a Milestone row", 5000)
		local detail = panel_lines()
		T.assert_contains(
			detail[T.find_line(detail, "Milestone:")], "v1.0",
			"the detail view should carry the milestone title"
		)
		T.drain_jobs()
	end,

	["milestone filter derives from the cache"] = function()
		T.assert_deep_equals(
			numbers_of(derive.filter(
				ALL_ISSUES, { state = "all", milestone = "v1.0" }
			)),
			{ 1, 3 },
			"milestone filter should keep only issues in that milestone"
		)
		T.assert_deep_equals(
			numbers_of(derive.filter(
				ALL_ISSUES, { state = "all", milestone = "v2.0" }
			)),
			{},
			"an unmatched milestone should keep nothing"
		)
	end,

	-- ── #386 interactive filter bar ────────────────────────────────────

	["filter keymaps are bound on the panel buffer"] = function()
		local bufnr = open_and_wait()
		for _, lhs in ipairs({ "f", "X" }) do
			T.assert_true(
				buf_map(bufnr, lhs) ~= nil,
				("%s should be mapped on the issues buffer"):format(lhs)
			)
		end
	end,

	["state cycles open -> closed -> all without refetching"] = function()
		reset_gh_log()
		open_and_wait()
		T.assert_equals(
			issues_panel.state.filters.state, "open", "should start on open"
		)

		issues_panel.cycle_state()
		T.assert_equals(issues_panel.state.filters.state, "closed", "open -> closed")
		T.assert_true(
			has_line(panel_lines(), "Update README"),
			"the closed issue should now be listed"
		)

		issues_panel.cycle_state()
		T.assert_equals(issues_panel.state.filters.state, "all", "closed -> all")
		issues_panel.cycle_state()
		T.assert_equals(issues_panel.state.filters.state, "open", "all -> open")

		T.assert_equals(
			gh_call_count("issue list"), 1,
			"cycling the state filter must not refetch"
		)
	end,

	["summary bar reflects every active filter"] = function()
		open_and_wait({ state = "all" })
		issues_panel.state.filters.label = "bug"
		issues_panel.state.filters.assignee = "octocat"
		issues_panel.state.filters.milestone = "v1.0"
		issues_panel.rerender()

		local lines = panel_lines()
		local bar = T.find_line(lines, "issue")
		T.assert_true(bar ~= nil, "the summary bar should render")
		for _, needle in ipairs({
			"state all", "label bug", "assignee octocat", "milestone v1.0",
		}) do
			T.assert_contains(lines[bar], needle, "summary bar should show " .. needle)
		end
	end,

	["clearing filters resets to open issues"] = function()
		open_and_wait({ state = "all" })
		issues_panel.state.filters.label = "bug"
		issues_panel.state.filters.milestone = "v1.0"
		issues_panel.rerender()

		issues_panel.clear_filters()

		T.assert_deep_equals(
			issues_panel.state.filters, { state = "open" },
			"clearing should leave only the default open state"
		)
		local lines = panel_lines()
		T.assert_true(
			has_line(lines, "Setup CI pipeline"),
			"open issues should be listed again"
		)
		T.assert_false(
			has_line(lines, "Update README"),
			"the closed issue should be hidden again"
		)
	end,

	-- ── #387 client-side sorting ───────────────────────────────────────

	["sort orders by each supported key"] = function()
		local all = { state = "all" }
		T.assert_deep_equals(
			numbers_of(derive.apply(ALL_ISSUES, all, { key = "number", direction = "asc" })),
			{ 1, 2, 3 },
			"number ascending"
		)
		T.assert_deep_equals(
			numbers_of(derive.apply(ALL_ISSUES, all, { key = "number", direction = "desc" })),
			{ 3, 2, 1 },
			"number descending"
		)
		T.assert_deep_equals(
			numbers_of(derive.apply(ALL_ISSUES, all, { key = "updated", direction = "desc" })),
			{ 1, 2, 3 },
			"most recently updated first"
		)
		T.assert_deep_equals(
			numbers_of(derive.apply(ALL_ISSUES, all, { key = "title", direction = "asc" })),
			{ 2, 1, 3 },
			"title ascending: Fix, Setup, Update"
		)
	end,

	["issues without a milestone sort last ascending"] = function()
		T.assert_deep_equals(
			numbers_of(derive.apply(
				ALL_ISSUES, { state = "all" }, { key = "milestone", direction = "asc" }
			)),
			{ 1, 3, 2 },
			"the unmilestoned issue should trail the v1.0 ones"
		)
	end,

	["an unknown sort key falls back to the default"] = function()
		T.assert_deep_equals(
			numbers_of(derive.apply(ALL_ISSUES, { state = "all" }, { key = "bogus" })),
			numbers_of(derive.apply(ALL_ISSUES, { state = "all" }, nil)),
			"an unknown key should behave like the default sort"
		)
	end,

	["s cycles the sort and S flips direction, in place"] = function()
		reset_gh_log()
		open_and_wait({ state = "all" })
		issues_panel.state.sort = { key = "updated", direction = "desc" }
		issues_panel.rerender()

		T.assert_contains(
			panel_lines()[T.find_line(panel_lines(), "issue")],
			"sort updated desc",
			"summary bar should show the active sort"
		)

		issues_panel.cycle_sort()
		T.assert_equals(issues_panel.state.sort.key, "number", "updated -> number")

		issues_panel.toggle_sort_direction()
		T.assert_equals(issues_panel.state.sort.direction, "asc", "desc -> asc")

		local lines = panel_lines()
		local first = T.find_line(lines, "Setup CI pipeline")
		local last = T.find_line(lines, "Update README")
		T.assert_true(
			first ~= nil and last ~= nil and first < last,
			"number ascending should list #1 before #3"
		)
		T.assert_equals(
			gh_call_count("issue list"), 1,
			"sorting must not refetch"
		)
	end,

	["sort survives a refresh"] = function()
		open_and_wait({ state = "all" })
		issues_panel.state.sort = { key = "title", direction = "asc" }
		issues_panel.rerender()

		issues_panel.refresh()
		T.wait_until(function()
			return T.find_line(panel_lines(), "Setup CI pipeline") ~= nil
		end, "refresh should re-render the list", 5000)
		T.drain_jobs()

		T.assert_deep_equals(
			issues_panel.state.sort, { key = "title", direction = "asc" },
			"a refetch should not reset the session sort"
		)
	end,

	-- ── #390 grouped rendering ─────────────────────────────────────────

	["grouping buckets issues and trails the empty group"] = function()
		local sorted = derive.apply(
			ALL_ISSUES, { state = "all" }, { key = "number", direction = "asc" }
		)
		local groups = derive.group(sorted, "milestone")

		T.assert_equals(#groups, 2, "v1.0 and the milestone-less bucket")
		T.assert_equals(groups[1].key, "v1.0", "named group first")
		T.assert_deep_equals(
			numbers_of(groups[1].issues), { 1, 3 }, "v1.0 holds #1 and #3"
		)
		T.assert_equals(groups[2].key, "", "the empty bucket comes last")
		T.assert_deep_equals(
			numbers_of(groups[2].issues), { 2 }, "#2 has no milestone"
		)
		T.assert_equals(
			derive.empty_group_label("milestone"), "No milestone",
			"the empty milestone bucket should be labelled"
		)
		T.assert_equals(
			derive.empty_group_label("assignee"), "Unassigned",
			"the empty assignee bucket should read Unassigned"
		)
	end,

	["an issue with several labels appears in each label group"] = function()
		local groups = derive.group(
			derive.filter(ALL_ISSUES, { state = "all" }), "label"
		)
		local by_key = {}
		for _, group in ipairs(groups) do
			by_key[group.key] = numbers_of(group.issues)
		end
		T.assert_deep_equals(by_key.bug, { 2, 3 }, "bug covers #2 and #3")
		T.assert_deep_equals(by_key.documentation, { 3 }, "documentation covers #3")
		T.assert_deep_equals(by_key.enhancement, { 1 }, "enhancement covers #1")
	end,

	["grouping renders headers with counts and composes with filters"] = function()
		reset_gh_log()
		open_and_wait({ state = "all" })
		issues_panel.state.group_by = "none"
		issues_panel.state.collapsed = {}
		issues_panel.cycle_group_by()

		T.assert_equals(
			issues_panel.state.group_by, "milestone", "none -> milestone"
		)
		local lines = panel_lines()
		T.assert_true(
			has_line(lines, "v1.0 (2)"),
			"the milestone section header should carry its count"
		)
		T.assert_true(
			has_line(lines, "No milestone (1)"),
			"the empty bucket should render with its count"
		)
		T.assert_contains(
			lines[T.find_line(lines, "issue")], "group milestone",
			"summary bar should show the grouping"
		)

		-- Grouping must compose with an active filter.
		issues_panel.state.filters.state = "open"
		issues_panel.rerender()
		local open_lines = panel_lines()
		T.assert_true(
			has_line(open_lines, "v1.0 (1)"),
			"filtering to open issues should shrink the v1.0 group to #1"
		)
		T.assert_false(
			has_line(open_lines, "Update README"),
			"the closed issue should be filtered out of its group"
		)
		T.assert_equals(
			gh_call_count("issue list"), 1, "grouping must not refetch"
		)
	end,

	["collapsing a group hides its cards"] = function()
		open_and_wait({ state = "all" })
		issues_panel.state.group_by = "milestone"
		issues_panel.state.collapsed = {}
		issues_panel.rerender()
		T.assert_true(
			has_line(panel_lines(), "Setup CI pipeline"),
			"the group should start expanded"
		)

		local bufnr = ui.buffer.get("issues")
		local header = T.find_line(T.buf_lines(bufnr), "v1.0 (")
		T.assert_true(header ~= nil, "the v1.0 header should render")
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_win_set_cursor(0, { header, 0 })
		issues_panel.toggle_group_under_cursor()

		local collapsed = panel_lines()
		T.assert_true(
			has_line(collapsed, "v1.0 ("),
			"the header should survive collapsing"
		)
		T.assert_false(
			has_line(collapsed, "Setup CI pipeline"),
			"collapsing should hide the group's cards"
		)

		vim.api.nvim_win_set_cursor(0, { T.find_line(collapsed, "v1.0 ("), 0 })
		issues_panel.toggle_group_under_cursor()
		T.assert_true(
			has_line(panel_lines(), "Setup CI pipeline"),
			"toggling again should expand the group"
		)

		issues_panel.state.group_by = "none"
		issues_panel.rerender()
	end,

	["group keymaps are bound on the panel buffer"] = function()
		local bufnr = open_and_wait()
		for _, lhs in ipairs({ "s", "S", "G", "<Tab>" }) do
			T.assert_true(
				buf_map(bufnr, lhs) ~= nil,
				("%s should be mapped on the issues buffer"):format(lhs)
			)
		end
	end,

	["refresh refetches from GitHub"] = function()
		reset_gh_log()
		open_and_wait()
		T.assert_equals(gh_call_count("issue list"), 1, "one fetch so far")

		issues_panel.refresh()
		T.wait_until(function()
			return gh_call_count("issue list") >= 2
		end, "refresh should issue a second fetch", 5000)
		T.drain_jobs()
	end,
})
