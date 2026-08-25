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

-- CI runs this suite under `${{ github.token }}` — a repo-installation token
-- with no user identity, so `/user` (and anything else `@me`-scoped) 403s
-- there even though a real user's `gh` sails through. GitHub's own wording
-- for that gap is stable, so treat it as an environment limit like
-- no-auth/network/5xx/rate-limit, not as drift in this repo's argv.
---@param output string
---@return string|nil reason
local function integration_token_reason(output)
	local text = (output or ""):lower()
	if text:find("resource not accessible by integration", 1, true) then
		return "no user identity for this token (installation/integration token)"
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
		local no_identity = integration_token_reason(output)
		if no_identity then
			skipped[#skipped + 1] = ("%s: %s — %s"):format(name, no_identity, output)
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

--- Every field check below loops `for _, x in ipairs(value)`, so an empty
--- array — a real, valid response — asserts nothing. Shapes where that is
--- likely on this repo either search a few known-good candidates for a
--- non-empty answer or skip explicitly; never record a pass on an unchecked
--- empty array.

--- Try `invoke` against each of `candidates` until one yields a non-empty
--- array, so a field assertion runs against real data instead of silently
--- passing over `[]` (#429 audit, M5).
---@param name string
---@param candidates integer[]
---@param invoke fun(candidate: integer, done: fun(err: string|nil, data: any, result: table|nil))
---@return boolean ran  false only when the environment (not the data) failed
---@return table data  possibly empty when no candidate had a non-empty answer
local function live_nonempty(name, candidates, invoke)
	for _, candidate in ipairs(candidates) do
		local ran_one, data = live(name, function(done)
			invoke(candidate, done)
		end)
		if not ran_one then
			return false, {}
		end
		if type(data) == "table" and #data > 0 then
			return true, data
		end
	end
	return true, {}
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
	if #milestones == 0 then
		-- An empty array proves the call is not the #429 shape (that 422s,
		-- it doesn't decode), but the field assertions below never run on it.
		skipped[#skipped + 1] = "gh api milestones: repo has no milestones — field shapes unverified"
	else
		for _, milestone in ipairs(milestones) do
			expect_fields("gh api milestones", milestone, {
				title = "string", state = "string", number = "number",
			})
		end
	end
	record("gh api milestones")
end

-- ── pull requests ───────────────────────────────────────────────────────

local gh_prs = require("gitflow.gh.prs")

local pr_number
local pr_numbers = {}
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
		pr_numbers[#pr_numbers + 1] = pr.number
	end
	record("gh pr list")
end

-- panels/issues.lua's linked-PR cue parses number/body/headRefName off this
-- shape (gh/prs.lua linked_issue_numbers).
local links
ran, links = live("gh pr list (links)", function(done)
	gh_prs.list_links({ state = "all", limit = 5 }, nil, done)
end)
if ran then
	expect_array("gh pr list (links)", links)
	if #links == 0 then
		skipped[#skipped + 1] = "gh pr list (links): repo has no pull requests — field shapes unverified"
	else
		for _, pr in ipairs(links) do
			expect_fields("gh pr list (links)", pr, {
				number = "number", title = "string", state = "string",
				body = "string", headRefName = "string",
			})
		end
	end
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

	local diff_text
	ran, diff_text = live("gh pr diff", function(done)
		gh_prs.diff(pr_number, nil, function(err, text, result)
			done(err, text, result)
		end)
	end)
	if ran then
		expect(
			"gh pr diff",
			type(diff_text) == "string" and #diff_text > 0,
			("expected a non-empty diff, got %s of length %d"):format(
				type(diff_text), #(diff_text or "")
			)
		)
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

	-- Search the fetched PRs for one with actual review comments/reviews:
	-- the field checks below (review/threads.lua, panels/prs.lua parsing)
	-- only run against a non-empty array.
	local review_comments
	ran, review_comments = live_nonempty(
		"gh api pulls/comments", pr_numbers, function(number, done)
			gh_prs.review_comments(number, nil, done)
		end
	)
	if ran then
		expect_array("gh api pulls/comments", review_comments)
		if #review_comments == 0 then
			skipped[#skipped + 1] =
				"gh api pulls/comments: no PR among the last 5 has review comments — field shapes unverified"
		else
			for _, c in ipairs(review_comments) do
				-- review/threads.lua:50-66 parses all of these off the raw comment.
				expect_fields("gh api pulls/comments", c, {
					id = "number", path = "string", body = "string", user = "table",
				})
				expect(
					"gh api pulls/comments",
					c.line == nil or c.line == vim.NIL or type(c.line) == "number",
					("field \"line\" is %s, expected number, null, or absent"):format(type(c.line))
				)
				-- Present only on replies — a root comment omits it entirely.
				expect(
					"gh api pulls/comments",
					c.in_reply_to_id == nil or c.in_reply_to_id == vim.NIL
						or type(c.in_reply_to_id) == "number",
					("field \"in_reply_to_id\" is %s, expected number, null, or absent"):format(
						type(c.in_reply_to_id)
					)
				)
			end
		end
		record("gh api pulls/comments")
	end

	local reviews
	ran, reviews = live_nonempty(
		"gh api pulls/reviews", pr_numbers, function(number, done)
			gh_prs.list_reviews(number, nil, done)
		end
	)
	if ran then
		expect_array("gh api pulls/reviews", reviews)
		if #reviews == 0 then
			skipped[#skipped + 1] =
				"gh api pulls/reviews: no PR among the last 5 has reviews — field shapes unverified"
		else
			for _, review in ipairs(reviews) do
				-- review/submit.lua respond_to_review reads user.login off
				-- the latest review; nothing else in gitflow parses this shape.
				expect_fields("gh api pulls/reviews", review, { user = "table" })
			end
		end
		record("gh api pulls/reviews")
	end
else
	skipped[#skipped + 1] = "gh pr view/diff + pulls/* api: this repo has no pull requests"
end

-- ── actions ─────────────────────────────────────────────────────────────

local gh_actions = require("gitflow.gh.actions")

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
	end
	record("gh run list")
end

-- `gh run view --log-failed` refuses a run still in progress, and inside CI
-- the latest run is always the one currently executing this very suite —
-- self-defeating if picked. Target a completed run instead, preferring one
-- that failed so the assertion below exercises real log content.
local run_id
local completed_runs
ran, completed_runs = live("gh run list (completed)", function(done)
	gh_actions.list({ status = "completed", limit = 20 }, nil, function(err, value)
		done(err, value, err and { code = 1, stdout = "", stderr = err } or { code = 0 })
	end)
end)
if ran then
	for _, run in ipairs(completed_runs) do
		if run.conclusion == "failure" then
			run_id = run.id
			break
		end
	end
	run_id = run_id or (completed_runs[1] and completed_runs[1].id)
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
		local log_error = detail.log_error and tostring(detail.log_error) or nil
		if log_error and log_error:lower():find("still in progress", 1, true) then
			-- Defence in depth: even a run gh reports "completed" can race
			-- with log availability. Skip rather than fail on that race.
			skipped[#skipped + 1] = ("gh run view --log-failed: %s"):format(log_error)
		else
			expect(
				"gh run view",
				log_error == nil,
				("`gh run view --log-failed` failed: %s"):format(tostring(log_error))
			)
			record("gh run view (+ --log-failed)")
		end
	end
else
	skipped[#skipped + 1] = "gh run view: this repo has no completed workflow runs"
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
		-- lua/gitflow/completion/assignees.lua parses this as one login per
		-- line (jq already projected `.login`, not JSON).
		name = "gh api assignees",
		args = {
			"api", "repos/{owner}/{repo}/assignees", "--jq", ".[].login", "--paginate",
		},
		check = function(stdout)
			local text = vim.trim(stdout)
			if text == "" then
				return true -- no assignable users is a valid answer
			end
			for _, line in ipairs(vim.split(text, "\n", { trimempty = true })) do
				local name = vim.trim(line)
				if name ~= "" and not name:match("^[%w%-]+$") then
					return false, ("expected a bare login per line, got %q"):format(name)
				end
			end
			return true
		end,
	},
	{
		-- lua/gitflow/completion/labels.lua — a distinct read shape (wider
		-- --limit, narrower --json) run outside the gh/labels.lua module.
		name = "gh label list --json name (completion)",
		args = { "label", "list", "--json", "name", "--limit", "200" },
		check = function(stdout)
			local decoded_ok, decoded = pcall(vim.json.decode, stdout)
			if not decoded_ok or type(decoded) ~= "table" then
				return false, ("expected a JSON array, got %q"):format(stdout)
			end
			for _, label in ipairs(decoded) do
				if type(label.name) ~= "string" then
					return false, "expected each label to have a string name"
				end
			end
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
