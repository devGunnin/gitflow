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
	issues_panel.state.cache = nil
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
