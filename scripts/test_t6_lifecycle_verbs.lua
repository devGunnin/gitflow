-- scripts/test_t6_lifecycle_verbs.lua — T6 (gf-pr-issue-lifecycle).
--
-- Everything here drives the real panel → gh-module → argv path, stubbing only
-- the process boundary (`gh.run` / `gh.json`) and the prompts. What it pins:
--   * every new mutating verb fires the EXACT gh argv on confirm, and fires
--     nothing at all on decline;
--   * the single-flight guard refuses a second press while one is in flight;
--   * a verb never fires against a repo the rows on screen did not come from;
--   * statusCheckRollup renders with per-check state (#423);
--   * a 429 / rate-limit failure classifies as its own kind, not "permission".

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, failed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " — " .. tostring(err))
	end
end

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(
				message, vim.inspect(expected), vim.inspect(actual)
			),
			2
		)
	end
end

local gitflow = require("gitflow")
gitflow.setup({
	ui = { default_layout = "split", split = { orientation = "vertical", size = 60 } },
})
local cfg = require("gitflow.config").current

local gh = require("gitflow.gh")
local gh_prs = require("gitflow.gh.prs")
local gh_issues = require("gitflow.gh.issues")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local list_picker = require("gitflow.ui.list_picker")
local form = require("gitflow.ui.form")
local git_branch = require("gitflow.git.branch")
local assignee_comp = require("gitflow.completion.assignees")
local pr_panel = require("gitflow.panels.prs")
local issue_panel = require("gitflow.panels.issues")

-- ── the process boundary ────────────────────────────────────────────────

---Every spawn the stubs saw, in order. `cwd` is where the process would start
---— an explicit `cwd` in the run options wins over the live one, which is
---exactly what a wrapper `gh` logs as its own pwd — and `bound` is the cwd the
---call NAMED, nil where it merely inherited whatever was live. A bound spawn
---cannot land in the wrong repo; an inherited one only happens to be right.
---
---One row per spawn, not three parallel arrays: a stub that appended to only
---one of them slid every later row's cwd by one, silently.
---@type { argv: string[], cwd: string, bound: string|nil }[]
local spawns = {}

local PR_ROWS = {
	{
		number = 12,
		title = "Add the thing",
		state = "OPEN",
		isDraft = false,
		headRefName = "feat/thing",
		baseRefName = "main",
		author = { login = "octocat" },
		statusCheckRollup = {
			{ __typename = "CheckRun", name = "build", status = "COMPLETED", conclusion = "SUCCESS" },
			{ __typename = "CheckRun", name = "lint", status = "COMPLETED", conclusion = "FAILURE" },
			{ __typename = "StatusContext", context = "legacy/ci", state = "PENDING" },
		},
	},
}

local ISSUE_ROWS = {
	{
		number = 7,
		title = "Something is broken",
		state = "OPEN",
		author = { login = "octocat" },
		labels = {},
		assignees = {},
	},
}

local ISSUE_DETAIL = {
	number = 7,
	title = "Something is broken",
	state = "OPEN",
	body = "details",
	labels = {},
	assignees = {},
	author = { login = "octocat" },
	comments = {
		{
			author = { login = "octocat" },
			body = "first thought",
			url = "https://github.com/o/r/issues/7#issuecomment-4242",
		},
	},
}

local MILESTONES = {
	{ number = 1, title = "v2", state = "open" },
	{ number = 2, title = "v1", state = "closed" },
}

---What a stubbed `gh.json` answers for a given argv.
---@param args string[]
---@return any
local function json_answer(args)
	local joined = table.concat(args, " ")
	if joined:find("^pr list") then
		if joined:find("body", 1, true) then
			-- the narrow linked-PR slice
			return { { number = 12, title = "Add the thing", state = "OPEN",
				body = "Closes #7", headRefName = "feat/thing" } }
		end
		return PR_ROWS
	end
	if joined:find("^pr view") then
		return vim.tbl_extend("force", vim.deepcopy(PR_ROWS[1]), {
			body = "why", reviews = {}, reviewRequests = {}, comments = {}, files = {},
		})
	end
	if joined:find("^issue list") then
		return ISSUE_ROWS
	end
	if joined:find("^issue view") then
		return vim.deepcopy(ISSUE_DETAIL)
	end
	if joined:find("milestones", 1, true) then
		return MILESTONES
	end
	return {}
end

local real = {
	run = gh.run,
	json = gh.json,
	ensure = gh.ensure_prerequisites,
	notify = utils.notify,
	confirm = input.confirm,
	prompt = input.prompt,
	picker = list_picker.open,
	vim_confirm = vim.fn.confirm,
	form_open = form.open,
	branch_create = git_branch.create,
	branch_list = git_branch.list,
	assignee_candidates = assignee_comp.list_repo_assignee_candidates,
}

---@param args string[]
---@param opts GitflowGitRunOpts|nil
local function record(args, opts)
	local bound = opts and opts.cwd or nil
	spawns[#spawns + 1] = {
		argv = vim.deepcopy(args),
		cwd = bound or vim.fn.getcwd(),
		bound = bound,
	}
end

local function install_stubs()
	spawns = {}
	gh.ensure_prerequisites = function()
		return true, nil
	end
	gh.run = function(args, opts, cb)
		record(args, opts)
		cb({ code = 0, signal = 0, stdout = "", stderr = "", cmd = args })
	end
	gh.json = function(args, opts, cb)
		record(args, opts)
		cb(nil, json_answer(args), { code = 0, signal = 0, stdout = "", stderr = "", cmd = args })
	end
	utils.notify = function() end
end

local function restore_stubs()
	gh.run, gh.json, gh.ensure_prerequisites = real.run, real.json, real.ensure
	form.open, git_branch.create = real.form_open, real.branch_create
	git_branch.list = real.branch_list
	assignee_comp.list_repo_assignee_candidates = real.assignee_candidates
	utils.notify = real.notify
	input.confirm, input.prompt = real.confirm, real.prompt
	list_picker.open = real.picker
	vim.fn.confirm = real.vim_confirm
end

---Answer `input.confirm` with a fixed index. 1 is "yes" for a two-choice gate.
---@param index integer
local function stub_confirm(index)
	input.confirm = function()
		return index == 1, index
	end
end

---Answer the raw `vim.fn.confirm` used by the merge-strategy prompt.
---@param index integer
local function stub_vim_confirm(index)
	vim.fn.confirm = function()
		return index
	end
end

---Every gh invocation `fn` causes, with its argv joined for comparison.
---@param fn fun()
---@return { argv: string, cwd: string, bound: string|nil }[]
local function capture_rows(fn)
	local before = #spawns
	fn()
	local out = {}
	for i = before + 1, #spawns do
		out[#out + 1] = {
			argv = table.concat(spawns[i].argv, " "),
			cwd = spawns[i].cwd,
			bound = spawns[i].bound,
		}
	end
	return out
end

---Every gh invocation `fn` causes, as space-joined argv strings.
---@param fn fun()
---@return string[]
local function capture(fn)
	local out = {}
	for _, row in ipairs(capture_rows(fn)) do
		out[#out + 1] = row.argv
	end
	return out
end

---Every gh invocation `fn` causes that would run in `cwd`. Must be zero for the
---repo we moved to.
---@param cwd string
---@param fn fun()
---@return string[]
local function capture_in(cwd, fn)
	local out = {}
	for _, row in ipairs(capture_rows(fn)) do
		if row.cwd == cwd then
			out[#out + 1] = row.argv
		end
	end
	return out
end

---@param bufnr integer
---@return string
local function buffer_text(bufnr)
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---Put the cursor on the panel's first selectable row, the way a user would
---before pressing a verb key.
---@param mod table
---@param map_name string
local function focus_first(mod, map_name)
	local line
	for line_no in pairs(mod.state[map_name]) do
		if not line or line_no < line then
			line = line_no
		end
	end
	assert_true(line ~= nil, ("panel has no %s to focus"):format(map_name))
	vim.api.nvim_set_current_win(mod.state.winid)
	vim.api.nvim_win_set_cursor(mod.state.winid, { line, 0 })
end

---Open the PR panel on the stub rows with the cursor on PR #12.
local function open_prs()
	pr_panel.close()
	pr_panel.state.cache = nil
	pr_panel.open(cfg)
	focus_first(pr_panel, "line_entries")
end

---Open the issue panel on the stub rows with the cursor on issue #7.
local function open_issues()
	issue_panel.close()
	issue_panel.state.cache = nil
	issue_panel.state.links, issue_panel.state.links_key = {}, nil
	issue_panel.open(cfg)
	focus_first(issue_panel, "line_entries")
end

-- ── 1. rate-limit classification ────────────────────────────────────────

test("a throttled gh call classifies as rate_limit, not permission", function()
	-- Both shapes GitHub actually answers with: a spent primary quota (403)
	-- and a secondary/abuse limit (403 or 429).
	local cases = {
		"gh: API rate limit exceeded for user ID 1234. (HTTP 403)",
		"gh: You have exceeded a secondary rate limit and have been"
			.. " temporarily blocked from content creation. (HTTP 403)",
		"gh: Too Many Requests (HTTP 429)",
	}
	for _, output in ipairs(cases) do
		assert_equals(
			gh.classify_failure(output), "rate_limit",
			("classify_failure(%q)"):format(output)
		)
	end
end)

test("a plain permission failure is still permission", function()
	assert_equals(
		gh.classify_failure("gh: You must have repository read permissions. (HTTP 403)"),
		"permission",
		"a 403 without rate-limit wording must not read as throttling"
	)
end)

test("a rate-limited failure gets its own actionable hint", function()
	local hint = gh.failure_hint("rate_limit")
	assert_true(hint ~= nil, "rate_limit must carry a recovery step")
	assert_true(
		hint:lower():find("rate limit", 1, true) ~= nil,
		("the hint must name the condition: %q"):format(hint)
	)
	assert_true(
		hint ~= gh.failure_hint("permission"),
		"throttling and a missing scope must not share a message"
	)
end)

test("a throttled call keeps the cached auth verdict; a rejected token drops it",
	function()
		-- gh.run clears the cached prerequisite verdict only for an auth-shaped
		-- failure. Being throttled is not the token going stale, and re-probing
		-- would spend another request against the same exhausted quota.
		local git = require("gitflow.git")
		local real_git_run, real_ensure = git.run, gh.ensure_prerequisites
		local real_state = vim.deepcopy(gh.state)
		local output = ""
		git.run = function(_cmd, _opts, on_exit)
			on_exit({ code = 1, signal = 0, stdout = "", stderr = output, cmd = {} })
		end

		local ok, err = pcall(function()
			gh.state.checked, gh.state.available, gh.state.authenticated =
				true, true, true
			output = "gh: API rate limit exceeded for user ID 1. (HTTP 403)"
			gh.run({ "pr", "list" }, {}, function() end)
			assert_true(
				gh.state.checked,
				"a throttle must not force another `gh auth status` probe"
			)

			output = "gh: Bad credentials (HTTP 401)"
			gh.run({ "pr", "list" }, {}, function() end)
			assert_true(
				not gh.state.checked,
				"a rejected token must still invalidate the cached verdict"
			)
		end)

		git.run = real_git_run
		gh.ensure_prerequisites = real_ensure
		gh.state = real_state
		assert_true(ok, tostring(err))
	end)

-- ── 2. status checks (#423) ─────────────────────────────────────────────

test("normalize_checks flattens check runs and commit statuses alike", function()
	local checks = gh_prs.normalize_checks(PR_ROWS[1].statusCheckRollup)
	assert_equals(#checks, 3, "all three rollup nodes should survive")
	assert_equals(checks[1].name, "build", "a CheckRun keeps its name")
	assert_equals(checks[1].state, "success", "SUCCESS maps to success")
	assert_equals(checks[2].state, "failure", "FAILURE maps to failure")
	assert_equals(checks[3].name, "legacy/ci", "a StatusContext is named by context")
	assert_equals(checks[3].state, "pending", "PENDING maps to pending")
end)

test("an in-flight check run reports pending, not unknown", function()
	local checks = gh_prs.normalize_checks({
		{ name = "build", status = "IN_PROGRESS", conclusion = nil },
	})
	assert_equals(checks[1].state, "pending", "a running check is pending")
end)

---@type { name: string, rollup: table, state: string, why: string }[]
local CHECK_VERDICT_CASES = {
	{
		name = "mixed: one failure among passes",
		rollup = {
			{ name = "a", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "b", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "c", status = "COMPLETED", conclusion = "FAILURE" },
		},
		state = "failure",
		why = "one failing check makes the rollup fail",
	},
	{
		name = "pending only",
		rollup = { { name = "a", status = "QUEUED" }, { name = "b", status = "IN_PROGRESS" } },
		state = "pending",
		why = "nothing has decided yet",
	},
	{
		name = "pending alongside a pass",
		rollup = {
			{ name = "a", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "b", status = "QUEUED" },
		},
		state = "pending",
		why = "a queued check outranks a passing one",
	},
	{
		name = "zero checks",
		rollup = {},
		state = "none",
		why = "no checks is not a verdict",
	},
	{
		name = "legacy commit status failing beside an Actions pass",
		rollup = {
			{ __typename = "CheckRun", name = "build", status = "COMPLETED", conclusion = "SUCCESS" },
			{ __typename = "StatusContext", context = "legacy/ci", state = "FAILURE" },
		},
		state = "failure",
		why = "a commit status counts the same as a check run",
	},
	{
		name = "cancelled beside a pass",
		rollup = {
			{ name = "a", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "b", status = "COMPLETED", conclusion = "CANCELLED" },
		},
		state = "cancelled",
		why = "gh pr checks counts a cancelled run as failing, so it cannot read green",
	},
	{
		name = "completed with a null conclusion beside a pass",
		rollup = {
			{ name = "a", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "b", status = "COMPLETED", conclusion = vim.NIL },
		},
		state = "unknown",
		why = "a check we cannot read is not evidence of a pass",
	},
	{
		name = "cancelled only",
		rollup = { { name = "a", status = "COMPLETED", conclusion = "CANCELLED" } },
		state = "cancelled",
		why = "a cancelled check is a check, not an absence of one",
	},
	{
		name = "skipped only",
		rollup = { { name = "a", status = "COMPLETED", conclusion = "SKIPPED" } },
		state = "skipped",
		why = "checks that decide nothing must not read as zero checks",
	},
	{
		name = "unmapped conclusion only",
		rollup = { { name = "a", status = "COMPLETED", conclusion = "SOMETHING_NEW" } },
		state = "unknown",
		why = "a conclusion outside the map is unknown, not absent",
	},
}

test("checks_summary never reads greener than its worst check", function()
	for _, case in ipairs(CHECK_VERDICT_CASES) do
		local summary = gh_prs.checks_summary(gh_prs.normalize_checks(case.rollup))
		assert_equals(summary.state, case.state, ("%s: %s"):format(case.name, case.why))
		assert_equals(
			summary.total, #case.rollup,
			("%s: every node should be counted"):format(case.name)
		)
	end
	assert_equals(
		gh_prs.checks_summary(gh_prs.normalize_checks(PR_ROWS[1].statusCheckRollup)).state,
		"failure",
		"the panel fixture's rollup fails on its one failing check"
	)
end)

test("a non-empty check set never renders the zero-checks verdict", function()
	for _, case in ipairs(CHECK_VERDICT_CASES) do
		if #case.rollup > 0 then
			assert_true(
				gh_prs.checks_summary(gh_prs.normalize_checks(case.rollup)).state ~= "none",
				("%s rendered \"Checks (%d) — none\""):format(case.name, #case.rollup)
			)
		end
	end
end)

test("the PR list card shows per-state check counts", function()
	install_stubs()
	local ok, err = pcall(function()
		open_prs()
		local text = buffer_text(pr_panel.state.bufnr)
		assert_true(
			text:find("checks", 1, true) ~= nil,
			("the card should carry a checks chip: %q"):format(text)
		)
		assert_true(
			text:find("✓1", 1, true) ~= nil and text:find("✗1", 1, true) ~= nil,
			("per-state counts should be visible: %q"):format(text)
		)
		-- Counts alone let the card read greener than its worst check, and
		-- this is the surface m/D/M are pressed from.
		assert_true(
			text:find("failure", 1, true) ~= nil,
			("the card should carry the verdict: %q"):format(text)
		)
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("a cancelled check never renders as a benign skip on the card", function()
	install_stubs()
	local original = PR_ROWS[1].statusCheckRollup
	PR_ROWS[1].statusCheckRollup = {
		{ __typename = "CheckRun", name = "a", status = "COMPLETED", conclusion = "CANCELLED" },
		{ __typename = "CheckRun", name = "b", status = "COMPLETED", conclusion = "SKIPPED" },
	}
	local ok, err = pcall(function()
		open_prs()
		local text = buffer_text(pr_panel.state.bufnr)
		assert_true(
			text:find("cancelled", 1, true) ~= nil,
			("the card should name the cancelled verdict: %q"):format(text)
		)
		assert_true(
			text:find("⊗1", 1, true) ~= nil and text:find("⊘1", 1, true) ~= nil,
			("cancelled and skipped must not share a glyph: %q"):format(text)
		)
	end)
	PR_ROWS[1].statusCheckRollup = original
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("the PR detail view lists every check with its state", function()
	install_stubs()
	local ok, err = pcall(function()
		pr_panel.close()
		pr_panel.state.cache = nil
		pr_panel.open_view(12, cfg)
		local text = buffer_text(pr_panel.state.bufnr)
		assert_true(
			text:find("Checks (3)", 1, true) ~= nil,
			("the detail should have a checks section: %q"):format(text)
		)
		for _, name in ipairs({ "build", "lint", "legacy/ci" }) do
			assert_true(
				text:find(name, 1, true) ~= nil,
				("check %q should be named in the detail: %q"):format(name, text)
			)
		end
		assert_true(
			text:find("failure", 1, true) ~= nil,
			("per-check state should be rendered, not just the name: %q"):format(text)
		)
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

-- ── 3. every new mutating verb: exact argv on accept, nothing on decline ──

---@class GitflowT6VerbCase
---@field name string
---@field open fun()
---@field before (fun())|nil  extra stubbing for this verb's prompts
---@field press fun()
---@field argv string  the exact gh argv the verb must fire

---@type GitflowT6VerbCase[]
local VERB_CASES = {
	{
		name = "pr reopen",
		open = open_prs,
		press = function() pr_panel.reopen_under_cursor() end,
		argv = "pr reopen 12",
	},
	{
		name = "pr draft toggle",
		open = open_prs,
		press = function() pr_panel.toggle_draft_under_cursor() end,
		argv = "pr ready 12 --undo",
	},
	{
		name = "pr merge",
		open = open_prs,
		before = function() stub_vim_confirm(2) end,
		press = function() pr_panel.merge_under_cursor() end,
		argv = "pr merge 12 --squash",
	},
	{
		name = "pr merge with --delete-branch",
		open = open_prs,
		before = function() stub_vim_confirm(1) end,
		press = function() pr_panel.merge_delete_branch_under_cursor() end,
		argv = "pr merge 12 --merge --delete-branch",
	},
	{
		name = "pr close",
		open = open_prs,
		press = function() pr_panel.close_pr_under_cursor() end,
		argv = "pr close 12",
	},
	{
		name = "issue reopen",
		open = open_issues,
		press = function() issue_panel.reopen_under_cursor() end,
		argv = "issue reopen 7",
	},
}

for _, case in ipairs(VERB_CASES) do
	test(("%s: confirming fires exactly one gh call"):format(case.name), function()
		install_stubs()
		local ok, err = pcall(function()
			stub_confirm(1)
			if case.before then
				case.before()
			end
			case.open()
			local fired = capture(case.press)
			assert_true(#fired >= 1, ("%s fired no gh call"):format(case.name))
			assert_equals(fired[1], case.argv, ("%s argv"):format(case.name))
		end)
		pr_panel.close()
		issue_panel.close()
		pr_panel.state.cache, issue_panel.state.cache = nil, nil
		restore_stubs()
		assert_true(ok, tostring(err))
	end)

	test(("%s: declining fires no gh call at all"):format(case.name), function()
		install_stubs()
		local ok, err = pcall(function()
			if case.before then
				case.before()
			end
			-- The panel must already be on screen before the gate is armed to
			-- decline, or the open's own fetches would count as the verb's.
			stub_confirm(1)
			case.open()
			stub_confirm(2)
			local fired = capture(case.press)
			assert_equals(
				#fired, 0,
				("%s fired %s after the confirm was declined"):format(
					case.name, vim.inspect(fired)
				)
			)
		end)
		pr_panel.close()
		issue_panel.close()
		pr_panel.state.cache, issue_panel.state.cache = nil, nil
		restore_stubs()
		assert_true(ok, tostring(err))
	end)
end

test("pr auto-merge: enabling queues the merge with --auto", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_prs()
		-- direction prompt answers "Enable" (1), strategy prompt "Squash" (2),
		-- and the gate confirms.
		stub_vim_confirm(2)
		local fired = capture(function()
			pr_panel.auto_merge_under_cursor()
		end)
		assert_equals(fired[1], "pr merge 12 --squash --auto", "auto-merge argv")
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("pr auto-merge: disabling cancels the queued merge", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_prs()
		-- Direction prompt answers "Disable" (2); the gate that follows is a
		-- plain yes/no, which stub_confirm(2) would decline — so answer the
		-- direction with index 2 and the gate with index 1 in turn.
		local answers, seen = { 2, 1 }, 0
		input.confirm = function()
			seen = seen + 1
			local index = answers[seen] or 1
			return index == 1, index
		end
		local fired = capture(function()
			pr_panel.auto_merge_under_cursor()
		end)
		assert_equals(fired[1], "pr merge 12 --disable-auto", "disable-auto argv")
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("pr auto-merge: cancelling the direction prompt fires nothing", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_prs()
		stub_confirm(3)
		local fired = capture(function()
			pr_panel.auto_merge_under_cursor()
		end)
		assert_equals(#fired, 0, "cancelling auto-merge must fire no gh call")
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("pr reviewers: a +/- patch fires one edit with both flags", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_prs()
		input.prompt = function(_opts, on_confirm)
			on_confirm("+alice,-bob")
		end
		local fired = capture(function()
			pr_panel.edit_reviewers_under_cursor()
		end)
		assert_equals(
			fired[1], "pr edit 12 --add-reviewer alice --remove-reviewer bob",
			"reviewer patch argv"
		)
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue close: the reason reaches gh", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issues()
		-- Reason prompt answers "Not planned" (2), then the gate confirms.
		local answers, seen = { 2, 1 }, 0
		input.confirm = function()
			seen = seen + 1
			local index = answers[seen] or 1
			return index == 1, index
		end
		local fired = capture(function()
			issue_panel.close_under_cursor()
		end)
		-- gh's --reason enum is {completed|not planned|duplicate}; it rejects
		-- the API's own `not_planned` spelling the panel still speaks.
		assert_equals(fired[1], "issue close 7 --reason not planned", "close reason argv")
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue close: cancelling the reason prompt fires nothing", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issues()
		stub_confirm(3)
		local fired = capture(function()
			issue_panel.close_under_cursor()
		end)
		assert_equals(#fired, 0, "cancelling the reason must fire no gh call")
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue milestone: picking one lists milestones then edits the issue", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issues()
		list_picker.open = function(opts)
			opts.on_submit({ "v2" })
		end
		local fired = capture(function()
			issue_panel.set_milestone_under_cursor()
		end)
		assert_true(
			fired[1]:find("milestones", 1, true) ~= nil,
			("the picker should be fed from the repo's milestones: %s"):format(fired[1])
		)
		assert_equals(fired[2], "issue edit 7 --milestone v2", "milestone edit argv")
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue milestone: choosing (none) clears it", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issues()
		list_picker.open = function(opts)
			opts.on_submit({ "(none)" })
		end
		local fired = capture(function()
			issue_panel.set_milestone_under_cursor()
		end)
		assert_equals(fired[2], "issue edit 7 --remove-milestone", "clear-milestone argv")
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue milestone: declining the gate fires no edit", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issues()
		list_picker.open = function(opts)
			opts.on_submit({ "v2" })
		end
		stub_confirm(2)
		local fired = capture(function()
			issue_panel.set_milestone_under_cursor()
		end)
		assert_equals(#fired, 1, "only the milestone listing may run")
		assert_true(
			fired[1]:find("milestones", 1, true) ~= nil,
			"the one call must be the read, not the edit"
		)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

-- ── issue comment edit / delete (detail view) ───────────────────────────

---Open issue #7's detail view with the cursor on its one comment.
local function open_issue_comment()
	issue_panel.close()
	issue_panel.state.cache = nil
	issue_panel.open_view(7, cfg)
	focus_first(issue_panel, "line_comments")
end

test("issue comment edit: fires a PATCH on the comment's REST id", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issue_comment()
		input.prompt = function(_opts, on_confirm)
			on_confirm("second thought")
		end
		local fired = capture(function()
			issue_panel.edit_comment_under_cursor()
		end)
		assert_equals(
			fired[1],
			"api repos/{owner}/{repo}/issues/comments/4242 --method PATCH"
				.. " -f body=second thought",
			"comment edit argv"
		)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue comment edit: declining fires nothing", function()
	install_stubs()
	local ok, err = pcall(function()
		open_issue_comment()
		input.prompt = function(_opts, on_confirm)
			on_confirm("second thought")
		end
		stub_confirm(2)
		local fired = capture(function()
			issue_panel.edit_comment_under_cursor()
		end)
		assert_equals(#fired, 0, "a declined comment edit must fire nothing")
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue comment delete: fires a DELETE on the comment's REST id", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issue_comment()
		local fired = capture(function()
			issue_panel.delete_comment_under_cursor()
		end)
		assert_equals(
			fired[1],
			"api repos/{owner}/{repo}/issues/comments/4242 --method DELETE",
			"comment delete argv"
		)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("issue comment delete: declining fires nothing", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_issue_comment()
		stub_confirm(2)
		local fired = capture(function()
			issue_panel.delete_comment_under_cursor()
		end)
		assert_equals(#fired, 0, "a declined comment delete must fire nothing")
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("a comment with no addressable id is refused, not guessed at", function()
	assert_equals(
		gh_issues.comment_rest_id({ url = "https://github.com/o/r/issues/7" }), nil,
		"a url without the comment fragment carries no id"
	)
	assert_equals(
		gh_issues.comment_rest_id({ id = "IC_kwDOabc" }), nil,
		"a GraphQL node id is not a REST id"
	)
	assert_equals(
		gh_issues.comment_rest_id({
			url = "https://github.com/o/r/issues/7#issuecomment-99",
		}),
		99,
		"the REST id comes out of the url fragment"
	)
end)

-- ── 4. single-flight ────────────────────────────────────────────────────

test("a second press while a mutation is in flight fires nothing", function()
	install_stubs()
	local ok, err = pcall(function()
		stub_confirm(1)
		open_prs()
		-- Hold the mutation open so the guard is still armed on the second press.
		local held
		gh.run = function(args, opts, cb)
			record(args, opts)
			held = cb
		end
		local first = capture(function()
			pr_panel.reopen_under_cursor()
		end)
		assert_equals(#first, 1, "the first press should fire once")
		local second = capture(function()
			pr_panel.reopen_under_cursor()
		end)
		assert_equals(#second, 0, "a double-press must not fire a second mutation")
		held({ code = 0, signal = 0, stdout = "", stderr = "", cmd = {} })
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

-- ── 5. scope: a verb never fires against another repo ────────────────────

test("a detail view loaded elsewhere refuses to mutate after a cd", function()
	install_stubs()
	local original_cwd = vim.fn.getcwd()
	local repo_a, repo_b = vim.fn.tempname(), vim.fn.tempname()
	vim.fn.mkdir(repo_a, "p")
	vim.fn.mkdir(repo_b, "p")

	local ok, err = pcall(function()
		stub_confirm(1)
		vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
		pr_panel.close()
		pr_panel.state.cache = nil
		pr_panel.open_view(12, cfg)
		assert_equals(pr_panel.state.mode, "view", "the detail should be open")

		vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
		local fired = capture(function()
			pr_panel.close_pr_under_cursor()
		end)
		assert_equals(
			#fired, 0,
			("a verb fired against repo B on repo A's detail: %s"):format(vim.inspect(fired))
		)
	end)

	vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
	pr_panel.close()
	pr_panel.state.cache = nil
	vim.fn.delete(repo_a, "rf")
	vim.fn.delete(repo_b, "rf")
	restore_stubs()
	assert_true(ok, tostring(err))
end)

---Run `fn` with the cwd in a throwaway directory pair, restoring both after.
---@param fn fun(repo_a: string, repo_b: string)
local function with_two_repos(fn)
	local original_cwd = vim.fn.getcwd()
	local repo_a, repo_b = vim.fn.tempname(), vim.fn.tempname()
	vim.fn.mkdir(repo_a, "p")
	vim.fn.mkdir(repo_b, "p")
	local ok, err = pcall(fn, repo_a, repo_b)
	vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
	vim.fn.delete(repo_a, "rf")
	vim.fn.delete(repo_b, "rf")
	assert_true(ok, tostring(err))
end

---Hold every gh answer so a `cd` can be slipped into the round trip. Returns
---a release function that answers everything issued so far, in order.
---@return fun()
local function hold_gh_answers()
	local held, next_index = {}, 1
	gh.json = function(args, opts, cb)
		record(args, opts)
		held[#held + 1] = function()
			cb(nil, json_answer(args), { code = 0, signal = 0, stdout = "", stderr = "", cmd = args })
		end
	end
	gh.run = function(args, opts, cb)
		record(args, opts)
		held[#held + 1] = function()
			cb({ code = 0, signal = 0, stdout = "", stderr = "", cmd = args })
		end
	end
	return function()
		while next_index <= #held do
			local release = held[next_index]
			next_index = next_index + 1
			release()
		end
	end
end

test("a PR detail that lands after a cd is not painted and arms no verb", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			stub_confirm(1)
			stub_vim_confirm(1)
			pr_panel.close()
			pr_panel.state.cache = nil
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))

			local release = hold_gh_answers()
			pr_panel.open_view(12, cfg)
			-- The fetch is in flight; the repo moves under it.
			vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
			release()

			local text = buffer_text(pr_panel.state.bufnr)
			assert_true(
				text:find("Add the thing", 1, true) == nil,
				("repo A's PR was painted in repo B: %q"):format(text)
			)
			assert_equals(pr_panel.state.active_pr, nil, "no PR may be left actionable")
			assert_equals(pr_panel.state.view_cwd, nil, "no scope stamp may survive")

			local verbs = {
				["merge+delete branch"] = pr_panel.merge_delete_branch_under_cursor,
				["auto-merge"] = pr_panel.auto_merge_under_cursor,
				["close"] = pr_panel.close_pr_under_cursor,
			}
			for name, press in pairs(verbs) do
				local fired = capture(press)
				assert_equals(
					#fired, 0,
					("%s fired against repo B: %s"):format(name, vim.inspect(fired))
				)
			end
		end)
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("an issue detail that lands after a cd is not painted and arms no verb", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			stub_confirm(1)
			issue_panel.close()
			issue_panel.state.cache = nil
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))

			local release = hold_gh_answers()
			issue_panel.open_view(7, cfg)
			vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
			release()

			local text = buffer_text(issue_panel.state.bufnr)
			assert_true(
				text:find("Something is broken", 1, true) == nil,
				("repo A's issue was painted in repo B: %q"):format(text)
			)
			assert_equals(issue_panel.state.active_issue, nil, "no issue may be left actionable")
			assert_equals(issue_panel.state.view_cwd, nil, "no scope stamp may survive")

			local verbs = {
				["close"] = issue_panel.close_under_cursor,
				["delete comment"] = issue_panel.delete_comment_under_cursor,
				["edit comment"] = issue_panel.edit_comment_under_cursor,
			}
			for name, press in pairs(verbs) do
				local fired = capture(press)
				assert_equals(
					#fired, 0,
					("%s fired against repo B: %s"):format(name, vim.inspect(fired))
				)
			end
		end)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("a cd between the prompt and the spawn cancels the mutation", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			stub_confirm(1)
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			issue_panel.close()
			issue_panel.state.cache = nil
			issue_panel.open_view(7, cfg)
			focus_first(issue_panel, "line_comments")

			-- The comment body prompt is async: answer it from repo B.
			input.prompt = function(_opts, on_confirm)
				vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
				on_confirm("second thought")
			end
			local fired = capture(function()
				issue_panel.edit_comment_under_cursor()
			end)
			assert_equals(
				#fired, 0,
				("the edit reached repo B: %s"):format(vim.inspect(fired))
			)
		end)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

---The cwd string vim reports for `dir`: a scope comparison is string
---equality, and a tempname path need not be what `getcwd()` answers.
---@param dir string
---@return string
local function canonical(dir)
	local before = vim.fn.getcwd()
	vim.cmd("cd " .. vim.fn.fnameescape(dir))
	local resolved = vim.fn.getcwd()
	vim.cmd("cd " .. vim.fn.fnameescape(before))
	return resolved
end

---Answer an `input.prompt` from `repo`. Prompts are async, so this is the
---window a `cd` — a timer, an autocmd, the user — can slip through.
---@param repo string
local function prompt_answered_from(repo)
	input.prompt = function(_opts, on_confirm)
		vim.cmd("cd " .. vim.fn.fnameescape(repo))
		on_confirm("+someone")
	end
end

---Same, for the async edit form.
---@param repo string
local function form_submitted_from(repo)
	form.open = function(opts)
		vim.cmd("cd " .. vim.fn.fnameescape(repo))
		opts.on_submit({ title = "REPO-A TITLE", body = "REPO-A BODY" })
	end
end

---Drive each form/prompt verb twice: answered in place it must still reach
---`gh` in repo A (no over-refusal), answered after a `cd` it must reach repo B
---zero times — the wrong-repo count a wrapper `gh` logs.
---
---`reopen` runs before every single drive, and both failure lists are reported
---together: a verb that leaves the panel bound to repo B otherwise makes each
---verb after it find no target and be recorded as vacuous, and the first
---assertion to fire then names one hole while hiding the rest.
---@param panel table
---@param reopen fun()  reset the panel under the repo the drive starts in
---@param verbs table[]  { name, press, arm }
---@param repo_a string
---@param repo_b string
local function assert_verbs_stay_in_scope(panel, reopen, verbs, repo_a, repo_b)
	local cwd_a, cwd_b = canonical(repo_a), canonical(repo_b)
	local vacuous, offenders = {}, {}
	for _, verb in ipairs(verbs) do
		local name, press, arm = verb[1], verb[2], verb[3]

		vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
		reopen()
		arm(repo_a)
		if #capture_in(cwd_a, press) == 0 then
			vacuous[#vacuous + 1] = name
		end

		vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
		reopen()
		arm(repo_b)
		local fired = capture_in(cwd_b, press)
		if #fired > 0 then
			offenders[#offenders + 1] = ("%s → %s"):format(name, table.concat(fired, "; "))
		end
	end
	assert_true(panel.is_open(), "the panel should still be open")

	local problems = {}
	if #offenders > 0 then
		problems[#problems + 1] =
			("these verbs reached repo B: %s"):format(table.concat(offenders, " | "))
	end
	if #vacuous > 0 then
		problems[#problems + 1] =
			("these verbs never reached gh at all, so their guard is untested: %s")
				:format(table.concat(vacuous, ", "))
	end
	assert_true(#problems == 0, table.concat(problems, " || "))
end

test("no PR form or prompt verb reaches the repo cd'd to while it was open", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			open_prs()
			assert_verbs_stay_in_scope(pr_panel, open_prs, {
				{ "comment", pr_panel.comment_under_cursor, prompt_answered_from },
				{ "labels", pr_panel.edit_labels_under_cursor, prompt_answered_from },
				{ "assignees", pr_panel.edit_assignees_under_cursor, prompt_answered_from },
				{ "reviewers", pr_panel.edit_reviewers_under_cursor, prompt_answered_from },
				{ "edit title/body", pr_panel.edit_under_cursor, form_submitted_from },
			}, repo_a, repo_b)
		end)
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("no issue form or prompt verb reaches the repo cd'd to while it was open", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			open_issues()
			assert_verbs_stay_in_scope(issue_panel, open_issues, {
				{ "comment", issue_panel.comment_under_cursor, prompt_answered_from },
				{ "labels", issue_panel.edit_labels_under_cursor, prompt_answered_from },
				{ "assignees", issue_panel.edit_assignees_under_cursor, prompt_answered_from },
				{ "edit title/body", issue_panel.edit_under_cursor, form_submitted_from },
			}, repo_a, repo_b)

			-- Branch creation is git, not gh, but it is the same class: repo
			-- A's issue must not name a branch in repo B.
			local cwd_b = canonical(repo_b)
			local created = {}
			git_branch.create = function(name, _base, opts, cb)
				created[#created + 1] = {
					name = name,
					cwd = opts and opts.cwd or vim.fn.getcwd(),
				}
				cb(nil)
			end
			for _, target in ipairs({ repo_a, repo_b }) do
				vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
				open_issues()
				prompt_answered_from(target)
				issue_panel.create_branch_under_cursor()
			end
			local in_b = {}
			for _, entry in ipairs(created) do
				if entry.cwd == cwd_b then
					in_b[#in_b + 1] = entry.name
				end
			end
			assert_equals(
				#in_b, 0,
				("create branch reached repo B: %s"):format(table.concat(in_b, ", "))
			)
			assert_true(#created > 0, "the in-place branch create should still run")
		end)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("focus leaving a window-scoped panel during a fetch does not discard it", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			-- The global cwd is repo B; the panel's own window is :lcd'd to
			-- repo A, which is where its fetch runs. Merely focusing another
			-- window must not read as "the repository changed".
			vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
			pr_panel.close()
			pr_panel.state.cache = nil
			pr_panel.open_view(12, cfg)
			vim.api.nvim_set_current_win(pr_panel.state.winid)
			vim.cmd("lcd " .. vim.fn.fnameescape(repo_a))
			local cwd_a = vim.fn.getcwd()

			local other
			for _, winid in ipairs(vim.api.nvim_list_wins()) do
				if winid ~= pr_panel.state.winid then
					other = winid
				end
			end
			assert_true(other ~= nil, "the test needs a second window to focus")

			local release = hold_gh_answers()
			pr_panel.open_view(12, cfg)
			vim.api.nvim_set_current_win(other)
			release()

			local text = buffer_text(pr_panel.state.bufnr)
			assert_true(
				text:find("Add the thing", 1, true) ~= nil,
				("a good fetch was thrown away on a focus change: %q"):format(text)
			)
			assert_equals(pr_panel.state.view_cwd, cwd_a, "the scope stamp should be the panel's")
			vim.api.nvim_set_current_win(pr_panel.state.winid)
			vim.cmd("lcd " .. vim.fn.fnameescape(repo_b))
		end)
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("a target whose repo already moved is refused before the gate is raised", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			issue_panel.close()
			issue_panel.state.cache = nil
			issue_panel.open_view(7, cfg)
			focus_first(issue_panel, "line_comments")

			local gated = 0
			input.confirm = function()
				gated = gated + 1
				return true, 1
			end
			prompt_answered_from(repo_b)
			issue_panel.edit_comment_under_cursor()
			-- A gate that can only be declined into nothing is worse than no
			-- gate: it asks about an action that was never going to be sent.
			assert_equals(gated, 0, "the operator was asked to authorise a dead mutation")
		end)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

---The create form's two prep sources that do not go through the gh stub: a
---real `git` spawn, and the completion cache's own synchronous `gh`. Records
---the cwd each `git_branch.list` was bound to.
---@param branch_cwds table[]
local function stub_create_prep(branch_cwds)
	git_branch.list = function(opts, cb)
		branch_cwds[#branch_cwds + 1] = {
			cwd = opts and opts.cwd or vim.fn.getcwd(),
			bound = opts and opts.cwd or nil,
		}
		cb(nil, { { name = "main", is_remote = false } })
	end
	assignee_comp.list_repo_assignee_candidates = function()
		return { "alice" }
	end
end

---Press `c` and run the create flow through to the form's submit, answering it
---from `submit_from`. The prep fetches fan out through two `vim.schedule`
---hops, so the loop has to be pumped before the form exists.
---@param panel table
---@param submit_from string
---@return boolean  whether the form was reached
local function drive_create(panel, submit_from)
	local submitted = false
	form.open = function(opts)
		vim.cmd("cd " .. vim.fn.fnameescape(submit_from))
		submitted = true
		opts.on_submit({ title = "REPO-A TITLE", body = "REPO-A BODY" })
	end
	panel.create_interactive()
	vim.wait(2000, function()
		return submitted
	end)
	return submitted
end

---`c` builds its whole payload — base branch, labels, reviewers, assignees, the
---`Closes #n` numbers — out of one repo's data, and had no scope machinery at
---all: the create landed wherever the cwd had drifted to, dragging `gh`'s
---push-and-retry into that repo's origin with it.
---@param name string
---@param panel table
---@param reopen fun()
---@param created_argv string  argv prefix the successful create must produce
local function assert_create_stays_in_scope(name, panel, reopen, created_argv)
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			local branch_cwds = {}
			stub_create_prep(branch_cwds)
			local cwd_a, cwd_b = canonical(repo_a), canonical(repo_b)

			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			reopen()
			local in_place = capture_in(cwd_a, function()
				assert_true(
					drive_create(panel, repo_a),
					("the %s form never opened"):format(name)
				)
			end)
			local filed = false
			for _, argv in ipairs(in_place) do
				filed = filed or argv:find(created_argv, 1, true) == 1
			end
			assert_true(
				filed,
				("%s never reached gh in its own repo: %s"):format(name, vim.inspect(in_place))
			)

			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			reopen()
			local moved = capture_in(cwd_b, function()
				assert_true(
					drive_create(panel, repo_b),
					("the %s form never opened"):format(name)
				)
			end)
			assert_equals(
				#moved, 0,
				("%s reached repo B: %s"):format(name, vim.inspect(moved))
			)

			for _, entry in ipairs(branch_cwds) do
				assert_equals(
					entry.bound, cwd_a,
					"the base-branch list must be bound to the form's own repo"
				)
			end
		end)
	end)
	panel.close()
	panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end

test("a PR created after a cd files nothing in the repo moved to", function()
	assert_create_stays_in_scope("PR create", pr_panel, open_prs, "pr create")
end)

test("an issue created after a cd files nothing in the repo moved to", function()
	assert_create_stays_in_scope("issue create", issue_panel, open_issues, "issue create")
end)

test("the label fallback's whole chain runs in the repo the labels were chosen in",
	function()
		install_stubs()
		local ok, err = pcall(function()
			with_two_repos(function(repo_a, repo_b)
				local cwd_a, cwd_b = canonical(repo_a), canonical(repo_b)
				vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
				open_prs()

				-- `gh pr edit` answers with the Projects-classic deprecation, so
				-- the api fallback spawns one process per label — and the cwd
				-- moves under the chain, as a timer or an autocmd can.
				gh.run = function(args, opts, cb)
					record(args, opts)
					if args[1] == "pr" and args[2] == "edit" then
						cb({
							code = 1,
							signal = 0,
							stdout = "",
							stderr = "Projects (classic) is being deprecated",
							cmd = args,
						})
						return
					end
					vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
					cb({ code = 0, signal = 0, stdout = "", stderr = "", cmd = args })
				end

				input.prompt = function(_opts, on_confirm)
					on_confirm("+newlabel,-old1,-old2")
				end

				local in_a, in_b = 0, {}
				for _, row in ipairs(capture_rows(pr_panel.edit_labels_under_cursor)) do
					-- The post-mutation refresh legitimately rebinds to wherever
					-- the operator now is; the label chain itself must not.
					if row.argv:find("^pr edit") or row.argv:find("^api") then
						if row.cwd == cwd_a then
							in_a = in_a + 1
						elseif row.cwd == cwd_b then
							in_b[#in_b + 1] = row.argv
						end
					end
				end
				assert_equals(
					#in_b, 0,
					("the label chain reached repo B: %s"):format(vim.inspect(in_b))
				)
				assert_equals(
					in_a, 4,
					"the edit, the POST and both DELETEs should all run in repo A"
				)
			end)
		end)
		pr_panel.close()
		pr_panel.state.cache = nil
		restore_stubs()
		assert_true(ok, tostring(err))
	end)

test("a PR detail's two fetches come from one repository", function()
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, repo_b)
			-- The panel window is `:lcd`'d to repo A while the global cwd is
			-- repo B, so moving focus off it hands the next spawn repo B — the
			-- window the review-comments call used to inherit.
			vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
			pr_panel.close()
			pr_panel.state.cache = nil
			pr_panel.open_view(12, cfg)
			vim.api.nvim_set_current_win(pr_panel.state.winid)
			vim.cmd("lcd " .. vim.fn.fnameescape(repo_a))
			local cwd_a = vim.fn.getcwd()

			local other
			for _, winid in ipairs(vim.api.nvim_list_wins()) do
				if winid ~= pr_panel.state.winid then
					other = winid
				end
			end
			assert_true(other ~= nil, "the test needs a second window to focus")

			local rows = capture_rows(function()
				local release = hold_gh_answers()
				pr_panel.open_view(12, cfg)
				vim.api.nvim_set_current_win(other)
				release()
			end)

			local detail = {}
			for _, row in ipairs(rows) do
				if row.argv:find("^pr view") or row.argv:find("/comments", 1, true) then
					detail[#detail + 1] = row
				end
			end
			assert_equals(#detail, 2, "the detail should fetch the PR and its review comments")
			for _, row in ipairs(detail) do
				assert_equals(
					row.cwd, cwd_a,
					("a mixed-repo record: %q ran outside the panel's repo"):format(row.argv)
				)
			end

			vim.api.nvim_set_current_win(pr_panel.state.winid)
			vim.cmd("lcd " .. vim.fn.fnameescape(repo_b))
		end)
	end)
	pr_panel.close()
	pr_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

---Every spawn a panel action causes must NAME the repo it runs in. A spawn
---that merely inherits the live cwd is right only by timing, which is what
---three rounds of hand-placed checks kept missing at a new call site.
---@param panel table
---@param reopen fun()
---@param verbs table[]  { name, press, arm }
local function assert_every_spawn_is_bound(panel, reopen, verbs)
	install_stubs()
	local ok, err = pcall(function()
		with_two_repos(function(repo_a, _repo_b)
			local branch_cwds = {}
			stub_create_prep(branch_cwds)
			stub_confirm(1)
			stub_vim_confirm(1)
			-- The milestone verb spawns again from inside the picker's submit.
			list_picker.open = function(opts)
				opts.on_submit({ "v2" })
			end
			local cwd_a = canonical(repo_a)

			local unbound = {}
			for _, verb in ipairs(verbs) do
				local name, press, arm = verb[1], verb[2], verb[3]
				vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
				reopen()
				arm(repo_a)
				local rows = capture_rows(press)
				assert_true(#rows > 0, ("%s spawned nothing at all"):format(name))
				for _, row in ipairs(rows) do
					if row.bound ~= cwd_a then
						unbound[#unbound + 1] = ("%s → %s (cwd=%s)")
							:format(name, row.argv, tostring(row.bound))
					end
				end
			end
			assert_true(
				#unbound == 0,
				("these spawns named no repository: %s"):format(table.concat(unbound, " | "))
			)
		end)
	end)
	panel.close()
	panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end

---Verbs whose only prompt is the confirm gate, already answered by stub_confirm.
---@param _repo string
local function no_prompt(_repo)
end

test("every spawn a PR verb causes names the repo it runs in", function()
	assert_every_spawn_is_bound(pr_panel, open_prs, {
		{ "refresh", pr_panel.refresh, no_prompt },
		{ "view", function()
			pr_panel.open_view(12, cfg)
		end, no_prompt },
		{ "comment", pr_panel.comment_under_cursor, prompt_answered_from },
		{ "labels", pr_panel.edit_labels_under_cursor, prompt_answered_from },
		{ "assignees", pr_panel.edit_assignees_under_cursor, prompt_answered_from },
		{ "reviewers", pr_panel.edit_reviewers_under_cursor, prompt_answered_from },
		{ "edit title/body", pr_panel.edit_under_cursor, form_submitted_from },
		{ "merge", pr_panel.merge_under_cursor, no_prompt },
		{ "merge+delete branch", pr_panel.merge_delete_branch_under_cursor, no_prompt },
		{ "auto-merge", pr_panel.auto_merge_under_cursor, no_prompt },
		{ "close", pr_panel.close_pr_under_cursor, no_prompt },
		{ "reopen", pr_panel.reopen_under_cursor, no_prompt },
		{ "draft", pr_panel.toggle_draft_under_cursor, no_prompt },
		{ "checkout", pr_panel.checkout_under_cursor, no_prompt },
		{ "create", function()
			drive_create(pr_panel, vim.fn.getcwd())
		end, no_prompt },
	})
end)

test("every spawn an issue verb causes names the repo it runs in", function()
	assert_every_spawn_is_bound(issue_panel, open_issues, {
		{ "refresh", issue_panel.refresh, no_prompt },
		{ "view", function()
			issue_panel.open_view(7, cfg)
		end, no_prompt },
		{ "comment", issue_panel.comment_under_cursor, prompt_answered_from },
		{ "labels", issue_panel.edit_labels_under_cursor, prompt_answered_from },
		{ "assignees", issue_panel.edit_assignees_under_cursor, prompt_answered_from },
		{ "edit title/body", issue_panel.edit_under_cursor, form_submitted_from },
		{ "close", issue_panel.close_under_cursor, no_prompt },
		{ "reopen", issue_panel.reopen_under_cursor, no_prompt },
		{ "milestone", issue_panel.set_milestone_under_cursor, no_prompt },
		{ "create", function()
			drive_create(issue_panel, vim.fn.getcwd())
		end, no_prompt },
	})
end)

test("every destructive confirm names the repository it will act on", function()
	install_stubs()
	local seen = {}
	local ok, err = pcall(function()
		input.confirm = function(message)
			seen[#seen + 1] = message
			return false, 2
		end
		stub_vim_confirm(1)
		open_prs()
		pr_panel.merge_delete_branch_under_cursor()
		pr_panel.close_pr_under_cursor()
		open_issues()
		issue_panel.close_under_cursor()

		assert_true(#seen > 0, "no gate was reached")
		local label = ("Repository: %s"):format(gh.repo_label())
		for _, message in ipairs(seen) do
			-- The reason prompts that precede a gate are not gates themselves.
			if message:find("?", 1, true) then
				assert_true(
					message:find(label, 1, true) ~= nil,
					("a gate did not name the repo: %q"):format(message)
				)
			end
		end
	end)
	pr_panel.close()
	issue_panel.close()
	pr_panel.state.cache, issue_panel.state.cache = nil, nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("repo_label resolves the repo gh will act on, or names the directory", function()
	local original_cwd = vim.fn.getcwd()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local ok, err = pcall(function()
		vim.fn.system({ "git", "-C", dir, "init" })
		assert_equals(vim.v.shell_error, 0, "the fixture repo should initialize")
		vim.cmd("cd " .. vim.fn.fnameescape(dir))
		assert_equals(gh.repo_label(), vim.fn.getcwd(), "no origin: name the directory")

		vim.fn.system({
			"git", "-C", dir, "remote", "add", "origin",
			"git@github.com:octo/thing.git",
		})
		assert_equals(gh.repo_label(), "octo/thing", "an ssh remote yields owner/repo")

		vim.fn.system({
			"git", "-C", dir, "remote", "set-url", "origin",
			"https://github.com/octo/thing.git",
		})
		assert_equals(gh.repo_label(), "octo/thing", "an https remote yields owner/repo")
		assert_equals(gh.repo_label(dir), "octo/thing", "an explicit cwd resolves the same")

		-- The ordinary fork checkout: gh acts on upstream, not on your fork.
		vim.fn.system({
			"git", "-C", dir, "remote", "add", "upstream",
			"https://github.com/canonical/thing.git",
		})
		assert_equals(gh.repo_label(), "canonical/thing", "gh prefers upstream over origin")

		-- `gh repo set-default` writes gh-resolved, and it wins outright.
		vim.fn.system({
			"git", "-C", dir, "config", "remote.origin.gh-resolved",
			"other-owner/other-repo",
		})
		assert_equals(
			gh.repo_label(), "other-owner/other-repo",
			"a gh repo set-default override outranks every remote"
		)
		vim.fn.system({ "git", "-C", dir, "config", "--unset", "remote.origin.gh-resolved" })

		-- Hosts gh does not serve, and paths that are not owner/repo, must
		-- name the directory rather than assert a slug gh will never act on.
		vim.fn.system({ "git", "-C", dir, "remote", "remove", "upstream" })
		vim.fn.system({
			"git", "-C", dir, "remote", "set-url", "origin",
			"git@my-work-alias:octo/thing.git",
		})
		assert_equals(gh.repo_label(), vim.fn.getcwd(), "an ssh alias is not a GitHub host")
		vim.fn.system({
			"git", "-C", dir, "remote", "set-url", "origin",
			"git@gitlab.com:grp/sub/proj.git",
		})
		assert_equals(gh.repo_label(), vim.fn.getcwd(), "a nested group is not owner/repo")
	end)
	vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
	vim.fn.delete(dir, "rf")
	assert_true(ok, tostring(err))
end)

-- ── 6. issue search + linked-PR cue ─────────────────────────────────────

test("the search prompt reaches gh as --search", function()
	install_stubs()
	local ok, err = pcall(function()
		open_issues()
		input.prompt = function(_opts, on_confirm)
			on_confirm("is:open label:bug")
		end
		local fired = capture(function()
			issue_panel.search()
		end)
		assert_true(#fired >= 1, "search should refetch")
		assert_true(
			fired[1]:find("--search is:open label:bug", 1, true) ~= nil,
			("the query should reach gh: %s"):format(fired[1])
		)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("an empty search answer clears the query", function()
	install_stubs()
	local ok, err = pcall(function()
		open_issues()
		input.prompt = function(_opts, on_confirm)
			on_confirm("bug")
		end
		issue_panel.search()
		input.prompt = function(_opts, on_confirm)
			on_confirm("")
		end
		local fired = capture(function()
			issue_panel.search()
		end)
		assert_equals(issue_panel.state.fetch.search, nil, "the query should be cleared")
		assert_true(
			fired[1]:find("--search", 1, true) == nil,
			("no --search should be sent once cleared: %s"):format(fired[1])
		)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

test("linked_issue_numbers reads closing keywords and the branch convention", function()
	assert_equals(
		table.concat(gh_prs.linked_issue_numbers({ body = "Closes #7\nFixes #9" }), ","),
		"7,9",
		"both closing keywords should be picked up"
	)
	assert_equals(
		table.concat(gh_prs.linked_issue_numbers({ body = "see #7" }), ","),
		"",
		"a bare mention is not a link"
	)
	assert_equals(
		table.concat(
			gh_prs.linked_issue_numbers({ body = "", headRefName = "381-do-a-thing" }), ","
		),
		"381",
		"gitflow's branch-from-issue name is a link"
	)
end)

test("the issues panel cues an issue a PR closes", function()
	install_stubs()
	local ok, err = pcall(function()
		open_issues()
		local text = buffer_text(issue_panel.state.bufnr)
		assert_true(
			text:find("#12", 1, true) ~= nil,
			("issue #7 should be cued with PR #12: %q"):format(text)
		)
	end)
	issue_panel.close()
	issue_panel.state.cache = nil
	issue_panel.state.links, issue_panel.state.links_key = {}, nil
	restore_stubs()
	assert_true(ok, tostring(err))
end)

-- ── 7. hint bars advertise every new verb ───────────────────────────────

---Find a panel module's private `P`, the same way test_panel_base.lua does.
---@param modname string
---@return table
local function panel_object(modname)
	local mod = require(modname)
	for _, fn in pairs(mod) do
		if type(fn) == "function" then
			local index = 1
			while true do
				local name, value = debug.getupvalue(fn, index)
				if not name then
					break
				end
				if name == "P" and type(value) == "table" and value.ns then
					return value
				end
				index = index + 1
			end
		end
	end
	error(("could not find the panel object of %s"):format(modname))
end

---@type { panel: string, view: string, keys: string[] }[]
local HINT_CASES = {
	{
		panel = "gitflow.panels.prs",
		view = "list",
		keys = { "O", "t", "M", "D", "E", "R" },
	},
	{ panel = "gitflow.panels.issues", view = "list", keys = { "R", "T", "Q" } },
	{ panel = "gitflow.panels.issues", view = "view", keys = { "e", "d" } },
}

for _, case in ipairs(HINT_CASES) do
	test(("%s (%s): every new verb has a hint entry"):format(case.panel, case.view),
		function()
			local P = panel_object(case.panel)
			local advertised = {}
			for _, hint in ipairs(P:hints(case.view)) do
				advertised[hint[1]] = true
			end
			for _, key in ipairs(case.keys) do
				assert_true(
					advertised[key] == true,
					("%s should advertise %q in the %s view"):format(
						case.panel, key, case.view
					)
				)
			end
		end)
end

test("the irreversible merge variants are tagged destructive", function()
	local P = panel_object("gitflow.panels.prs")
	local destructive = {}
	for _, entry in ipairs(P:keymap_entries("list")) do
		destructive[entry.key] = entry.destructive == true
	end
	for _, key in ipairs({ "D", "M", "x" }) do
		assert_true(
			destructive[key] == true,
			("%q is irreversible and must be tagged destructive"):format(key)
		)
	end
	-- Plain merge stays the panel's primary verb (T3's narrow-bar contract).
	assert_true(
		destructive["m"] == false,
		"m merge must not be dropped ahead of the conveniences"
	)
end)

test("the new destructive merge variants elide before the core verbs", function()
	local P = panel_object("gitflow.panels.prs")
	local narrow = P:footer("list", 60)
	assert_true(
		narrow:find("merge+del", 1, true) == nil
			and narrow:find("auto-merge", 1, true) == nil,
		("a 60-column bar kept an irreversible merge variant: %q"):format(narrow)
	)
end)

print(("T6 lifecycle-verb tests: %d/%d passed"):format(passed, passed + failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
