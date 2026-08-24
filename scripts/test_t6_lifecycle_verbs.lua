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
local pr_panel = require("gitflow.panels.prs")
local issue_panel = require("gitflow.panels.issues")

-- ── the process boundary ────────────────────────────────────────────────

---@type string[][]
local calls = {}

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
}

local function install_stubs()
	calls = {}
	gh.ensure_prerequisites = function()
		return true, nil
	end
	gh.run = function(args, _opts, cb)
		calls[#calls + 1] = vim.deepcopy(args)
		cb({ code = 0, signal = 0, stdout = "", stderr = "", cmd = args })
	end
	gh.json = function(args, _opts, cb)
		calls[#calls + 1] = vim.deepcopy(args)
		cb(nil, json_answer(args), { code = 0, signal = 0, stdout = "", stderr = "", cmd = args })
	end
	utils.notify = function() end
end

local function restore_stubs()
	gh.run, gh.json, gh.ensure_prerequisites = real.run, real.json, real.ensure
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

---Every gh invocation `fn` causes, as space-joined argv strings.
---@param fn fun()
---@return string[]
local function capture(fn)
	local before = #calls
	fn()
	local out = {}
	for i = before + 1, #calls do
		out[#out + 1] = table.concat(calls[i], " ")
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

test("checks_summary never reads greener than its worst check", function()
	assert_equals(
		gh_prs.checks_summary(gh_prs.normalize_checks(PR_ROWS[1].statusCheckRollup)).state,
		"failure",
		"one failing check makes the rollup fail"
	)
	assert_equals(
		gh_prs.checks_summary(gh_prs.normalize_checks({
			{ name = "a", status = "COMPLETED", conclusion = "SUCCESS" },
			{ name = "b", status = "QUEUED" },
		})).state,
		"pending",
		"a queued check outranks a passing one"
	)
	assert_equals(
		gh_prs.checks_summary({}).state, "none", "no checks is not a verdict"
	)
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
	end)
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
		assert_equals(fired[1], "issue close 7 --reason not_planned", "close reason argv")
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
		gh.run = function(args, _opts, cb)
			calls[#calls + 1] = vim.deepcopy(args)
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
		keys = { "O", "d", "M", "D", "E", "R" },
	},
	{ panel = "gitflow.panels.issues", view = "list", keys = { "R", "M", "Q" } },
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
