-- scripts/test_gh_live_contract.lua — the non-stubbed read contract (#330, #429)
--
-- Every other gh-touching test drives the fixture `gh` stub, so a real
-- upstream change — a renamed/removed --json field, a wrong HTTP method, a
-- retired endpoint — would pass CI silently. #429 is what that costs: the
-- milestone list shipped as `gh api … --paginate -f state=all`, which `gh`
-- sends as POST, and real GitHub answered 422 in the user's editor while the
-- suite stayed green.
--
-- So this script calls the REAL `gh` binary — no PATH stub, unlike the specs
-- under tests/minimal_init.lua — once per distinct READ shape gitflow makes,
-- through gitflow's own production parsing path. Mutations are NOT run here;
-- their argv is pinned by scripts/test_gh_argv_contract.lua.
--
-- It skips cleanly (exit 0) only when the environment cannot support a live
-- call: gh missing/unauthenticated, a network condition, upstream 5xx, or
-- rate limiting. Anything else — most notably gh rejecting a field or method
-- this repo's production argv still uses — is the drift this test exists to
-- catch, and fails loudly.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local skipped = {}
local passed = {}

local function skip(reason)
	print(("SKIP: %s"):format(reason))
	os.exit(0)
end

local function fail(message)
	print(("FAIL: %s"):format(message))
	vim.cmd("cquit! 1")
end

-- gh.classify_failure() classifies rate limiting but not 5xx (it falls to
-- "unknown"), so an upstream outage would otherwise fail() looking like drift.
---@param output string
---@return string|nil reason
local function transient_upstream_reason(output)
	local text = (output or ""):lower()
	local status = text:match("%(http (%d%d%d)%)")
	if status and status:sub(1, 1) == "5" then
		return ("HTTP %s"):format(status)
	end
	if text:find("rate limit", 1, true) or text:find("rate_limited", 1, true) then
		return "rate limit"
	end
	return nil
end

local gh = require("gitflow.gh")

local ok, message = gh.ensure_prerequisites()
if not ok then
	skip(("gh prerequisites not satisfied — %s"):format(message or "unknown reason"))
end

--- Run one async gh call to completion. Returns nil when the environment (not
--- the argv) is at fault, having already recorded the skip.
---@param name string
---@param invoke fun(done: fun(err: string|nil, data: any, result: table|nil))
---@return boolean ran, any data
local function live(name, invoke)
	local finished, call_err, call_data, call_result = false, nil, nil, nil
	invoke(function(err, data, result)
		call_err, call_data, call_result = err, data, result
		finished = true
	end)

	if not vim.wait(30000, function()
		return finished
	end, 50) then
		skipped[#skipped + 1] = ("%s: no response within 30s (network condition)"):format(name)
		return false, nil
	end

	local output = call_result and gh.output(call_result) or (call_err or "")
	local failed = (call_result and call_result.code ~= 0) or call_err ~= nil
	if failed then
		local kind = gh.classify_failure(output)
		if kind == "network" or kind == "auth" or kind == "rate_limit" then
			skipped[#skipped + 1] = ("%s: %s — %s"):format(name, kind, output)
			return false, nil
		end
		local transient = transient_upstream_reason(output)
		if transient then
			skipped[#skipped + 1] = ("%s: upstream %s — %s"):format(name, transient, output)
			return false, nil
		end
		fail(("%s rejected by gh/GitHub (%s) — %s"):format(name, kind, output))
		return false, nil
	end

	return true, call_data
end

---@param name string
---@param condition boolean
---@param detail string
local function expect(name, condition, detail)
	if not condition then
		fail(("%s: %s"):format(name, detail))
	end
end

--- Assert every listed key is present on `value` with the given lua type.
---@param name string
---@param value any
---@param fields table<string, string>
local function expect_fields(name, value, fields)
	expect(name, type(value) == "table", ("expected a table, got %s"):format(type(value)))
	for field, expected_type in pairs(fields) do
		local actual = value[field]
		-- vim.NIL is how a JSON null decodes: the field IS present upstream.
		if actual ~= vim.NIL then
			expect(
				name,
				type(actual) == expected_type,
				("field %q is %s, expected %s"):format(field, type(actual), expected_type)
			)
		end
	end
end

---@param name string
---@param value any
local function expect_array(name, value)
	expect(name, type(value) == "table", ("expected an array, got %s"):format(type(value)))
	expect(name, value[1] ~= nil or #value == 0, "expected an array, got an object")
end

local function record(name)
	passed[#passed + 1] = name
end

-- ── issues ──────────────────────────────────────────────────────────────

local gh_issues = require("gitflow.gh.issues")

local issue_number
local ran, issues = live("gh issue list", function(done)
	gh_issues.list({ state = "all", limit = 5 }, nil, done)
end)
if ran then
	expect_array("gh issue list", issues)
	for _, issue in ipairs(issues) do
		expect_fields("gh issue list", issue, {
			number = "number", title = "string", state = "string",
			labels = "table", assignees = "table", author = "table",
			updatedAt = "string",
		})
		issue_number = issue_number or issue.number
	end
	record("gh issue list")
end

if issue_number then
	local viewed
	ran, viewed = live("gh issue view", function(done)
		gh_issues.view(issue_number, nil, done)
	end)
	if ran then
		expect_fields("gh issue view", viewed, {
			number = "number", title = "string", body = "string",
			state = "string", labels = "table", assignees = "table",
			author = "table", comments = "table", createdAt = "string",
			updatedAt = "string",
		})
		record("gh issue view")
	end
else
	skipped[#skipped + 1] = "gh issue view: this repo has no issues"
end

-- The #429 regression: `-f` without `-X GET` makes this a POST to
-- create-a-milestone, which GitHub answers 422 — never a decodable array.
local milestones
ran, milestones = live("gh api milestones", function(done)
	gh_issues.list_milestones({ state = "all" }, nil, done)
end)
if ran then
	expect_array("gh api milestones", milestones)
	for _, milestone in ipairs(milestones) do
		expect_fields("gh api milestones", milestone, {
			title = "string", state = "string", number = "number",
		})
	end
	record("gh api milestones")
end

-- ── pull requests ───────────────────────────────────────────────────────

local gh_prs = require("gitflow.gh.prs")

local pr_number
local prs
ran, prs = live("gh pr list", function(done)
	gh_prs.list({ state = "all", limit = 5 }, nil, done)
end)
if ran then
	expect_array("gh pr list", prs)
	for _, pr in ipairs(prs) do
		expect_fields("gh pr list", pr, {
			number = "number", title = "string", state = "string",
			isDraft = "boolean", labels = "table", author = "table",
			assignees = "table", headRefName = "string",
			baseRefName = "string", updatedAt = "string",
		})
		pr_number = pr_number or pr.number
	end
	record("gh pr list")
end

ran = live("gh pr list (links)", function(done)
	gh_prs.list_links({ state = "all", limit = 5 }, nil, done)
end)
if ran then
	record("gh pr list (links)")
end

if pr_number then
	local viewed
	ran, viewed = live("gh pr view", function(done)
		gh_prs.view(pr_number, nil, done)
	end)
	if ran then
		expect_fields("gh pr view", viewed, {
			number = "number", title = "string", body = "string",
			state = "string", isDraft = "boolean", labels = "table",
			author = "table", assignees = "table", headRefName = "string",
			headRefOid = "string", baseRefName = "string", reviews = "table",
			reviewRequests = "table", comments = "table", files = "table",
			createdAt = "string", updatedAt = "string",
		})
		record("gh pr view")
	end

	ran = live("gh pr diff", function(done)
		gh_prs.diff(pr_number, nil, function(err, text, result)
			done(err, text, result)
		end)
	end)
	if ran then
		record("gh pr diff")
	end

	local files
	ran, files = live("gh api pulls/files", function(done)
		gh_prs.list_files(pr_number, nil, done)
	end)
	if ran then
		expect_array("gh api pulls/files", files)
		for _, file in ipairs(files) do
			expect_fields("gh api pulls/files", file, {
				filename = "string", status = "string",
				additions = "number", deletions = "number",
			})
		end
		record("gh api pulls/files")
	end

	local commits
	ran, commits = live("gh api pulls/commits", function(done)
		gh_prs.list_commits(pr_number, nil, done)
	end)
	if ran then
		expect_array("gh api pulls/commits", commits)
		for _, commit in ipairs(commits) do
			expect_fields("gh api pulls/commits", commit, { sha = "string", commit = "table" })
		end
		record("gh api pulls/commits")
	end

	local review_comments
	ran, review_comments = live("gh api pulls/comments", function(done)
		gh_prs.review_comments(pr_number, nil, done)
	end)
	if ran then
		expect_array("gh api pulls/comments", review_comments)
		record("gh api pulls/comments")
	end

	local reviews
	ran, reviews = live("gh api pulls/reviews", function(done)
		gh_prs.list_reviews(pr_number, nil, done)
	end)
	if ran then
		expect_array("gh api pulls/reviews", reviews)
		record("gh api pulls/reviews")
	end
else
	skipped[#skipped + 1] = "gh pr view/diff + pulls/* api: this repo has no pull requests"
end

-- ── actions ─────────────────────────────────────────────────────────────

local gh_actions = require("gitflow.gh.actions")

local run_id
local runs
ran, runs = live("gh run list", function(done)
	gh_actions.list({ limit = 5 }, nil, function(err, value)
		done(err, value, err and { code = 1, stdout = "", stderr = err } or { code = 0 })
	end)
end)
if ran then
	expect_array("gh run list", runs)
	for _, run in ipairs(runs) do
		-- gh/actions.lua normalizes the payload, so a renamed upstream field
		-- surfaces here as a zeroed id rather than a missing key.
		expect(
			"gh run list",
			type(run.id) == "number" and run.id > 0,
			"normalized run has no databaseId"
		)
		expect("gh run list", type(run.status) == "string", "normalized run has no status")
		run_id = run_id or run.id
	end
	record("gh run list")
end

if run_id then
	local detail
	ran, detail = live("gh run view", function(done)
		gh_actions.view(run_id, nil, function(err, value)
			done(err, value, err and { code = 1, stdout = "", stderr = err } or { code = 0 })
		end)
	end)
	if ran then
		expect("gh run view", type(detail) == "table", "expected a run table")
		expect("gh run view", detail.id == run_id, "run view returned a different run")
		expect(
			"gh run view",
			detail.log_error == nil,
			("`gh run view --log-failed` failed: %s"):format(tostring(detail.log_error))
		)
		record("gh run view (+ --log-failed)")
	end
else
	skipped[#skipped + 1] = "gh run view: this repo has no workflow runs"
end

local workflows
ran, workflows = live("gh workflow list", function(done)
	gh_actions.workflow_list(nil, function(err, value)
		done(err, value, err and { code = 1, stdout = "", stderr = err } or { code = 0 })
	end)
end)
if ran then
	expect_array("gh workflow list", workflows)
	for _, workflow in ipairs(workflows) do
		expect(
			"gh workflow list",
			type(workflow.id) == "number" and workflow.id > 0,
			"normalized workflow has no id"
		)
		expect("gh workflow list", workflow.path ~= "", "normalized workflow has no path")
	end
	record("gh workflow list")
end

-- ── labels ──────────────────────────────────────────────────────────────

local gh_labels = require("gitflow.gh.labels")

local labels
ran, labels = live("gh label list", function(done)
	gh_labels.list({ limit = 100 }, nil, done)
end)
if ran then
	expect_array("gh label list", labels)
	for _, label in ipairs(labels) do
		expect_fields("gh label list", label, {
			name = "string", color = "string",
			description = "string", isDefault = "boolean",
		})
	end
	record("gh label list")
end

-- ── raw reads outside the gh/ modules ───────────────────────────────────

local raw_reads = {
	{
		name = "gh api user -q .login",
		args = { "api", "user", "-q", ".login" },
		check = function(stdout)
			return vim.trim(stdout):match("^[%w%-]+$") ~= nil,
				("expected a bare login, got %q"):format(vim.trim(stdout))
		end,
	},
	{
		name = "gh repo view --json nameWithOwner",
		args = { "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" },
		check = function(stdout)
			return vim.trim(stdout):match("^[^/%s]+/[^/%s]+$") ~= nil,
				("expected owner/repo, got %q"):format(vim.trim(stdout))
		end,
	},
	{
		-- lua/gitflow/completion/assignees.lua
		name = "gh api assignees",
		args = {
			"api", "repos/{owner}/{repo}/assignees", "--jq", ".[].login", "--paginate",
		},
		check = function()
			return true
		end,
	},
}

for _, read in ipairs(raw_reads) do
	local stdout
	local completed = live(read.name, function(done)
		gh.run(read.args, {}, function(result)
			stdout = result.stdout or ""
			done(nil, nil, result)
		end)
	end)
	if completed then
		local valid, detail = read.check(stdout)
		expect(read.name, valid, detail or "unexpected output shape")
		record(read.name)
	end
end

-- ── verdict ─────────────────────────────────────────────────────────────

if #passed == 0 then
	skip("no read shape could be checked live — " .. table.concat(skipped, "; "))
end

for _, reason in ipairs(skipped) do
	print(("  skipped: %s"):format(reason))
end
print(("PASS: gh live read contract — %d shape(s) verified against real GitHub"):format(#passed))
