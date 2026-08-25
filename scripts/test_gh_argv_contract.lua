-- scripts/test_gh_argv_contract.lua — the exact argv every gh call builds (#429)
--
-- Mutations cannot be probed against real GitHub the way
-- scripts/test_gh_live_contract.lua probes reads, so their argv is pinned
-- here instead: every entry below was checked against `gh <cmd> --help` and
-- the GitHub REST docs, and a 404-target probe confirmed each `gh api` path
-- routes to the intended operation.
--
-- Two properties this file exists to hold:
--   * the HTTP method GitHub will actually use. `gh api` with any -f/-F
--     defaults to POST, so a list endpoint needs an explicit `-X GET` — the
--     #429 bug was exactly that, and the fixture stub had blessed it.
--   * flag spellings gh itself validates, e.g. `--reason "not planned"`,
--     which gh rejects as `not_planned`.
--
-- No process is spawned: gitflow.git.run is replaced with a recorder, so this
-- runs offline and deterministically.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local failures = {}

---@param message string
local function record_failure(message)
	failures[#failures + 1] = message
end

-- ── recorder ────────────────────────────────────────────────────────────

local git = require("gitflow.git")
local gh = require("gitflow.gh")

local recorded
-- Queued scripted results, consumed in order; anything past the queue
-- succeeds. Lets a test drive a fallback path that only opens on failure.
local scripted = {}

git.run = function(cmd, opts, on_exit)
	recorded = { cmd = vim.deepcopy(cmd), stdin = opts and opts.stdin or nil }
	local next_result = table.remove(scripted, 1)
		or { code = 0, stdout = "{}", stderr = "" }
	on_exit({
		code = next_result.code, signal = 0,
		stdout = next_result.stdout or "", stderr = next_result.stderr or "",
		cmd = cmd,
	})
end

-- The lazy probe must stay off this path: pre-seed the verdict rather than
-- letting ensure_prerequisites() shell out to `gh auth status`.
gh.state = { checked = true, available = true, authenticated = true, message = nil }

local gh_issues = require("gitflow.gh.issues")
local gh_prs = require("gitflow.gh.prs")
local gh_labels = require("gitflow.gh.labels")
local gh_actions = require("gitflow.gh.actions")

---@param cmd string[]
---@return string
local function render(cmd)
	local parts = {}
	for _, arg in ipairs(cmd) do
		parts[#parts + 1] = arg:find("%s") and ("%q"):format(arg) or arg
	end
	return table.concat(parts, " ")
end

---@param name string
---@param expected string[]
---@param invoke fun()
local function expect_argv(name, expected, invoke)
	recorded = nil
	local ok, err = pcall(invoke)
	if not ok then
		record_failure(("%s: raised %s"):format(name, tostring(err)))
		return
	end
	if not recorded then
		record_failure(("%s: no gh invocation was recorded"):format(name))
		return
	end
	local actual = recorded.cmd
	if not vim.deep_equal(actual, expected) then
		record_failure(("%s:\n    expected: %s\n    actual:   %s"):format(
			name, render(expected), render(actual)
		))
	end
end

---@param name string
---@param invoke fun()
local function expect_refused(name, invoke)
	recorded = nil
	local ok = pcall(invoke)
	if ok then
		record_failure(("%s: expected a refusal, but the call went through"):format(name))
	end
	if recorded then
		record_failure(("%s: refused calls must not reach gh (ran %s)"):format(
			name, render(recorded.cmd)
		))
	end
end

--- A rejected REST path number (a URL/branch fed to a `gh api` path builder)
--- must be a VISIBLE, handled error delivered through the callback — never a
--- raise, which several of these builders are reached from inside another
--- call's async callback, where an uncaught raise is a traceback in the
--- user's editor rather than a caught one (#H1 audit).
---@param name string
---@param invoke fun(cb: fun(err: string|nil, ...: unknown))
local function expect_number_guard_error(name, invoke)
	recorded = nil
	local delivered_err
	local ok, raised = pcall(invoke, function(err)
		delivered_err = err
	end)
	if not ok then
		record_failure(("%s: raised %s — must deliver through the callback instead"):format(
			name, tostring(raised)
		))
		return
	end
	if recorded then
		record_failure(("%s: a rejected number must not reach gh (ran %s)"):format(
			name, render(recorded.cmd)
		))
	end
	if not delivered_err then
		record_failure(("%s: expected an error delivered through the callback"):format(name))
	end
end

local function noop() end

-- ── the effective HTTP method of a `gh api` argv ────────────────────────

--- What `gh api` will actually send: an explicit -X/--method wins, otherwise
--- any body flag makes it POST, else GET. Mirrors gh's own rule.
---@param cmd string[]
---@return string|nil method  nil when this is not a `gh api` call
local function api_method(cmd)
	if cmd[1] ~= "gh" or cmd[2] ~= "api" then
		return nil
	end
	local has_body = false
	for index = 3, #cmd do
		local arg = cmd[index]
		if arg == "-X" or arg == "--method" then
			return (cmd[index + 1] or ""):upper()
		end
		if arg == "-f" or arg == "-F" or arg == "--field"
			or arg == "--raw-field" or arg == "--input"
		then
			has_body = true
		end
	end
	return has_body and "POST" or "GET"
end

---@param cmd string[]
---@return boolean
local function has_flag(cmd, flag)
	for _, arg in ipairs(cmd) do
		if arg == flag then
			return true
		end
	end
	return false
end

-- ── issues ──────────────────────────────────────────────────────────────

local ISSUE_LIST_FIELDS =
	"number,title,state,labels,assignees,milestone,author,updatedAt"
local ISSUE_VIEW_FIELDS =
	"number,title,body,state,labels,assignees,milestone,author,comments,createdAt,updatedAt"

expect_argv("issue list", {
	"gh", "issue", "list", "--json", ISSUE_LIST_FIELDS,
	"--state", "all", "--label", "bug", "--assignee", "octocat",
	"--milestone", "v2", "--search", "sort:created-asc", "--limit", "50",
}, function()
	gh_issues.list({
		state = "all", label = "bug", assignee = "octocat",
		milestone = "v2", search = "sort:created-asc", limit = 50,
	}, nil, noop)
end)

expect_argv("issue view", {
	"gh", "issue", "view", "7", "--json", ISSUE_VIEW_FIELDS,
}, function()
	gh_issues.view(7, nil, noop)
end)

expect_argv("issue create", {
	"gh", "issue", "create", "--title", "t", "--body", "b",
	"--label", "bug,docs", "--assignee", "octocat",
}, function()
	gh_issues.create({
		title = "t", body = "b", labels = { "bug", "docs" },
		assignees = { "octocat" },
	}, nil, noop)
end)

expect_argv("issue comment", {
	"gh", "issue", "comment", "7", "--body", "hello",
}, function()
	gh_issues.comment(7, "hello", nil, noop)
end)

-- gh validates --reason itself: its enum is {completed|not planned|duplicate},
-- and it rejects the API's own `not_planned` spelling outright (#429 audit).
expect_argv("issue close (completed)", {
	"gh", "issue", "close", "7", "--reason", "completed",
}, function()
	gh_issues.close(7, { reason = "completed" }, nil, noop)
end)

expect_argv("issue close (not planned)", {
	"gh", "issue", "close", "7", "--reason", "not planned",
}, function()
	gh_issues.close(7, { reason = "not_planned" }, nil, noop)
end)

expect_argv("issue close (not-planned spelling)", {
	"gh", "issue", "close", "7", "--reason", "not planned",
}, function()
	gh_issues.close(7, { reason = "not-planned" }, nil, noop)
end)

expect_refused("issue close (bogus reason)", function()
	gh_issues.close(7, { reason = "wontfix" }, nil, noop)
end)

expect_argv("issue reopen", { "gh", "issue", "reopen", "7" }, function()
	gh_issues.reopen(7, nil, noop)
end)

expect_argv("issue edit", {
	"gh", "issue", "edit", "7", "--title", "t", "--body", "b",
	"--add-label", "bug", "--remove-label", "docs",
	"--add-assignee", "octocat", "--remove-assignee", "hubot",
	"--milestone", "v2",
}, function()
	gh_issues.edit(7, {
		title = "t", body = "b", add_labels = { "bug" },
		remove_labels = { "docs" }, add_assignees = { "octocat" },
		remove_assignees = { "hubot" }, milestone = "v2",
	}, nil, noop)
end)

expect_argv("issue edit (remove milestone)", {
	"gh", "issue", "edit", "7", "--remove-milestone",
}, function()
	gh_issues.edit(7, { remove_milestone = true }, nil, noop)
end)

-- THE #429 REGRESSION. Without `-X GET`, `-f state=all` makes this a POST and
-- GitHub routes it to create-a-milestone: 422, every time, in a real editor.
expect_argv("api milestones (list)", {
	"gh", "api", "repos/{owner}/{repo}/milestones", "-X", "GET",
	"--paginate", "-f", "state=all",
}, function()
	gh_issues.list_milestones({ state = "all" }, nil, noop)
end)

expect_argv("api issue comment (edit)", {
	"gh", "api", "repos/{owner}/{repo}/issues/comments/42",
	"--method", "PATCH", "-f", "body=fixed",
}, function()
	gh_issues.edit_comment(42, "fixed", nil, noop)
end)

expect_argv("api issue comment (delete)", {
	"gh", "api", "repos/{owner}/{repo}/issues/comments/42", "--method", "DELETE",
}, function()
	gh_issues.delete_comment(42, nil, noop)
end)

expect_refused("api issue comment (non-numeric id)", function()
	gh_issues.delete_comment("IC_kwDO", nil, noop)
end)

-- `gh issue view --json comments` hands back a GraphQL node id; only the
-- comment url carries the REST id these endpoints need.
local rest_id = gh_issues.comment_rest_id({
	id = "IC_kwDORLBzl88AAAABQWhWIQ",
	url = "https://github.com/o/r/issues/428#issuecomment-5392324129",
})
if rest_id ~= 5392324129 then
	record_failure(("comment_rest_id: expected 5392324129, got %s"):format(tostring(rest_id)))
end
if gh_issues.comment_rest_id({ id = "IC_kwDO" }) ~= nil then
	record_failure("comment_rest_id: a payload without a url must yield nil, not a guess")
end

-- ── pull requests ───────────────────────────────────────────────────────

local PR_LIST_FIELDS = "number,title,state,isDraft,labels,author,assignees,"
	.. "headRefName,baseRefName,updatedAt,mergedAt,statusCheckRollup"
local PR_VIEW_FIELDS = "number,title,body,state,isDraft,labels,author,"
	.. "assignees,headRefName,headRefOid,baseRefName,reviews,reviewRequests,"
	.. "comments,files,statusCheckRollup,mergedAt,createdAt,updatedAt"

expect_argv("pr list", {
	"gh", "pr", "list", "--json", PR_LIST_FIELDS, "--state", "all",
	"--base", "main", "--head", "topic", "--search", "review:required",
	"--limit", "50",
}, function()
	gh_prs.list({
		state = "all", base = "main", head = "topic",
		search = "review:required", limit = 50,
	}, nil, noop)
end)

expect_argv("pr list (links)", {
	"gh", "pr", "list", "--json", "number,title,state,body,headRefName",
	"--state", "open", "--limit", "100",
}, function()
	gh_prs.list_links({ state = "open", limit = 100 }, nil, noop)
end)

expect_argv("pr view", {
	"gh", "pr", "view", "9", "--json", PR_VIEW_FIELDS,
}, function()
	gh_prs.view(9, nil, noop)
end)

expect_argv("pr diff", { "gh", "pr", "diff", "9" }, function()
	gh_prs.diff(9, nil, noop)
end)

expect_argv("pr create", {
	"gh", "pr", "create", "--title", "t", "--body", "b",
	"--base", "main", "--head", "topic", "--draft",
	"--reviewer", "octocat", "--label", "bug",
}, function()
	gh_prs.create({
		title = "t", body = "b", base = "main", head = "topic",
		draft = true, reviewers = { "octocat" }, labels = { "bug" },
	}, nil, noop)
end)

expect_argv("pr comment", {
	"gh", "pr", "comment", "9", "--body", "hello",
}, function()
	gh_prs.comment(9, "hello", nil, noop)
end)

for _, strategy in ipairs({ "merge", "squash", "rebase" }) do
	expect_argv(("pr merge (--%s)"):format(strategy), {
		"gh", "pr", "merge", "9", "--" .. strategy, "--auto", "--delete-branch",
	}, function()
		gh_prs.merge(9, {
			strategy = strategy, auto = true, delete_branch = true,
		}, nil, noop)
	end)
end

expect_refused("pr merge (bogus strategy)", function()
	gh_prs.merge(9, { strategy = "fast-forward" }, nil, noop)
end)

expect_argv("pr merge (--disable-auto)", {
	"gh", "pr", "merge", "9", "--disable-auto",
}, function()
	gh_prs.disable_auto_merge(9, nil, noop)
end)

expect_argv("pr ready", { "gh", "pr", "ready", "9" }, function()
	gh_prs.set_draft(9, false, nil, noop)
end)

expect_argv("pr ready --undo", { "gh", "pr", "ready", "9", "--undo" }, function()
	gh_prs.set_draft(9, true, nil, noop)
end)

expect_argv("pr checkout", { "gh", "pr", "checkout", "9" }, function()
	gh_prs.checkout(9, nil, noop)
end)

expect_argv("pr close", { "gh", "pr", "close", "9" }, function()
	gh_prs.close(9, nil, noop)
end)

expect_argv("pr reopen", { "gh", "pr", "reopen", "9" }, function()
	gh_prs.reopen(9, nil, noop)
end)

expect_argv("pr edit", {
	"gh", "pr", "edit", "9", "--title", "t", "--body", "b",
	"--add-label", "bug", "--remove-label", "docs",
	"--add-assignee", "octocat", "--remove-assignee", "hubot",
	"--add-reviewer", "reviewer", "--remove-reviewer", "old",
}, function()
	gh_prs.edit(9, {
		title = "t", body = "b", add_labels = { "bug" },
		remove_labels = { "docs" }, add_assignees = { "octocat" },
		remove_assignees = { "hubot" }, add_reviewers = { "reviewer" },
		remove_reviewers = { "old" },
	}, nil, noop)
end)

for _, mode in ipairs({
	{ "approve", "--approve" },
	{ "request_changes", "--request-changes" },
	{ "comment", "--comment" },
}) do
	expect_argv(("pr review (%s)"):format(mode[1]), {
		"gh", "pr", "review", "9", mode[2], "--body", "b",
	}, function()
		gh_prs.review(9, mode[1], "b", nil, noop)
	end)
end

expect_refused("pr review (bogus mode)", function()
	gh_prs.review(9, "lgtm", "b", nil, noop)
end)

expect_argv("api pulls/files", {
	"gh", "api", "repos/{owner}/{repo}/pulls/9/files", "--paginate",
}, function()
	gh_prs.list_files(9, nil, noop)
end)

expect_argv("api pulls/commits", {
	"gh", "api", "repos/{owner}/{repo}/pulls/9/commits", "--paginate",
}, function()
	gh_prs.list_commits(9, nil, noop)
end)

expect_argv("api pulls/comments (list)", {
	"gh", "api", "repos/{owner}/{repo}/pulls/9/comments", "--paginate",
}, function()
	gh_prs.review_comments(9, nil, noop)
end)

expect_argv("api pulls/reviews (list)", {
	"gh", "api", "repos/{owner}/{repo}/pulls/9/reviews", "--paginate",
}, function()
	gh_prs.list_reviews(9, nil, noop)
end)

expect_argv("api pulls/comments (delete)", {
	"gh", "api", "repos/{owner}/{repo}/pulls/comments/42", "--method", "DELETE",
}, function()
	gh_prs.delete_review_comment(9, 42, nil, noop)
end)

expect_argv("api pulls/comments (file comment)", {
	"gh", "api", "repos/{owner}/{repo}/pulls/9/comments", "--method", "POST",
	"-f", "path=a.lua", "-f", "body=note", "-f", "commit_id=deadbeef",
	"-f", "subject_type=file",
}, function()
	gh_prs.create_file_comment(9, "deadbeef", "a.lua", "note", nil, noop)
end)

expect_argv("api pulls/comments (reply)", {
	"gh", "api", "repos/{owner}/{repo}/pulls/9/comments/42/replies",
	"--method", "POST", "-f", "body=@octocat done",
}, function()
	gh_prs.reply_to_review_comment(9, 42, "@octocat done", nil, noop)
end)

expect_argv("api pulls/reviews (submit)", {
	"gh", "api", "repos/{owner}/{repo}/pulls/9/reviews",
	"--method", "POST", "--input", "-",
}, function()
	gh_prs.submit_review(9, "approve", "ship it", {
		{ path = "a.lua", body = "n", line = 3, side = "RIGHT" },
	}, nil, noop)
end)

-- The review batch must travel as a JSON body: `comments` is an array, which
-- no -f/-F field can carry.
if recorded and recorded.stdin then
	local decoded = vim.json.decode(recorded.stdin)
	if decoded.event ~= "APPROVE" then
		record_failure(("submit_review: event is %s, expected APPROVE"):format(
			tostring(decoded.event)
		))
	end
	if type(decoded.comments) ~= "table" or decoded.comments[1] == nil then
		record_failure("submit_review: comments did not survive as a JSON array")
	end
else
	record_failure("submit_review: nothing was written to stdin")
end

-- A REST path segment must be a number; `gh pr <verb>` also accepts a URL or
-- branch name, which would silently build a nonsense endpoint. Rejected as a
-- delivered error, never a raise (#H1: gh_prs.view + this call is exactly
-- panels/prs.lua open_view's chain, and the second call runs inside the
-- first's async callback).
expect_number_guard_error("api pulls path (branch name as number)", function(cb)
	gh_prs.list_files("feature/x", nil, cb)
end)

-- The URL/branch form itself must still work end to end for the call that
-- accepts free text: `gh pr view` does not path-interpolate its argument.
expect_argv("pr view (branch name)", {
	"gh", "pr", "view", "feature/x", "--json", PR_VIEW_FIELDS,
}, function()
	gh_prs.view("feature/x", nil, noop)
end)

-- The label-only `gh api` fallback, opened by the projects-classic
-- deprecation error `gh pr edit` returns against affected repos.
local PROJECT_CARDS_ERROR =
	"GraphQL: Projects (classic) is being deprecated"
	.. " (repository.pullRequest.projectCards)"

expect_argv("api issues/labels (fallback add)", {
	"gh", "api", "--method", "POST", "repos/{owner}/{repo}/issues/9/labels",
	"-f", "labels[]=bug", "-f", "labels[]=docs",
}, function()
	scripted = { { code = 1, stdout = "", stderr = PROJECT_CARDS_ERROR } }
	gh_prs.edit(9, { add_labels = { "bug", "docs" } }, nil, noop)
end)

expect_argv("api issues/labels (fallback remove)", {
	"gh", "api", "--method", "DELETE",
	"repos/{owner}/{repo}/issues/9/labels/needs%20triage",
}, function()
	scripted = { { code = 1, stdout = "", stderr = PROJECT_CARDS_ERROR } }
	gh_prs.edit(9, { remove_labels = { "needs triage" } }, nil, noop)
end)

-- `:Gitflow pr edit <url> add=…` reaches `gh pr edit <url>` directly — that
-- primary path takes free text end to end, no path builder involved.
expect_argv("pr edit (branch name, primary path)", {
	"gh", "pr", "edit", "feature/x", "--add-label", "bug",
}, function()
	gh_prs.edit("feature/x", { add_labels = { "bug" } }, nil, noop)
end)

-- Same URL/branch input, but routed into the label-only fallback (second
-- route in the #H1 audit): the primary `gh pr edit feature/x` legitimately
-- reaches gh and fails with the deprecation error, which opens the fallback
-- — that fallback's own path-number guard must deliver its failure through
-- the callback, never raise (not `expect_number_guard_error`: a prior gh call
-- here is expected, so its "nothing reached gh" check does not apply).
do
	scripted = { { code = 1, stdout = "", stderr = PROJECT_CARDS_ERROR } }
	local delivered_err
	local ok, raised = pcall(function()
		gh_prs.edit("feature/x", { add_labels = { "bug" } }, nil, function(err)
			delivered_err = err
		end)
	end)
	local name = "api issues/labels fallback (branch name)"
	if not ok then
		record_failure(("%s: raised %s — must deliver through the callback instead"):format(
			name, tostring(raised)
		))
	elseif not delivered_err then
		record_failure(("%s: expected an error delivered through the callback"):format(name))
	end
end

-- The fallback can only re-apply labels. With a title/body/assignee edit in
-- the same batch it would report success while dropping it, so it must not
-- open at all — the original error surfaces instead.
expect_argv("pr edit (no fallback for a mixed batch)", {
	"gh", "pr", "edit", "9", "--title", "t", "--add-label", "bug",
}, function()
	scripted = { { code = 1, stdout = "", stderr = PROJECT_CARDS_ERROR } }
	gh_prs.edit(9, { title = "t", add_labels = { "bug" } }, nil, noop)
end)
scripted = {}

-- ── labels ──────────────────────────────────────────────────────────────

expect_argv("label list", {
	"gh", "label", "list", "--json", "name,color,description,isDefault",
	"--limit", "200",
}, function()
	gh_labels.list({ limit = 200 }, nil, noop)
end)

expect_argv("label create", {
	"gh", "label", "create", "wip", "--color", "ededed",
	"--description", "in progress",
}, function()
	gh_labels.create("wip", "#EDEDED", "in progress", nil, noop)
end)

expect_refused("label create (bad color)", function()
	gh_labels.create("wip", "not-a-hex", nil, nil, noop)
end)

expect_argv("label delete", {
	"gh", "label", "delete", "wip", "--yes",
}, function()
	gh_labels.delete("wip", nil, noop)
end)

-- ── actions ─────────────────────────────────────────────────────────────

local RUN_LIST_FIELDS = "databaseId,name,headBranch,status,conclusion,event,"
	.. "createdAt,updatedAt,url,displayTitle"
local RUN_VIEW_FIELDS = RUN_LIST_FIELDS .. ",jobs"

expect_argv("run list", {
	"gh", "run", "list", "--json", RUN_LIST_FIELDS,
	"--branch", "main", "--limit", "20", "--workflow", "e2e.yml",
	"--status", "failure", "--event", "push", "--user", "octocat",
}, function()
	gh_actions.list({
		branch = "main", limit = 20, workflow = "e2e.yml",
		status = "failure", event = "push", actor = "octocat",
	}, nil, noop)
end)

expect_argv("run view (json)", {
	"gh", "run", "view", "123", "--json", RUN_VIEW_FIELDS,
}, function()
	gh_actions.view(123, nil, noop)
end)

expect_argv("run view --log", {
	"gh", "run", "view", "123", "--log",
}, function()
	gh_actions.log(123, nil, noop)
end)

expect_argv("run view --job --log", {
	"gh", "run", "view", "123", "--job", "456", "--log",
}, function()
	gh_actions.job_log(123, 456, nil, noop)
end)

expect_argv("run rerun", { "gh", "run", "rerun", "123" }, function()
	gh_actions.rerun(123, nil, noop)
end)

expect_argv("run rerun --failed", {
	"gh", "run", "rerun", "123", "--failed",
}, function()
	gh_actions.rerun_failed(123, nil, noop)
end)

expect_argv("run rerun --job", {
	"gh", "run", "rerun", "123", "--job", "456",
}, function()
	gh_actions.rerun_job(123, 456, nil, noop)
end)

expect_argv("run cancel", { "gh", "run", "cancel", "123" }, function()
	gh_actions.cancel(123, nil, noop)
end)

expect_argv("workflow list", {
	"gh", "workflow", "list", "--json", "id,name,path,state",
}, function()
	gh_actions.workflow_list(nil, noop)
end)

expect_argv("workflow run", {
	"gh", "workflow", "run", "e2e.yml", "--ref", "main",
}, function()
	gh_actions.workflow_run("e2e.yml", "main", nil, noop)
end)

-- ── the method invariant, over every `gh api` argv above ────────────────
-- Belt to the per-call braces: no `gh api` this suite records may pair
-- --paginate with a non-GET method, whatever the call site does next.

local READ_ONLY_API_PATHS = {
	"repos/{owner}/{repo}/milestones",
	"repos/{owner}/{repo}/assignees",
}

---@param name string
---@param args string[]
---@param expected_method string
local function check_api_method(name, args, expected_method)
	recorded = nil
	gh.run(args, {}, noop)
	local cmd = recorded and recorded.cmd
	if not cmd then
		record_failure(("%s: nothing recorded"):format(name))
		return
	end
	local method = api_method(cmd)
	if method ~= expected_method then
		record_failure(("%s: effective method %s, expected %s"):format(
			name, tostring(method), expected_method
		))
	end
	if method ~= "GET" and has_flag(cmd, "--paginate") then
		record_failure(("%s: --paginate on a %s request"):format(name, method))
	end
	for _, path in ipairs(READ_ONLY_API_PATHS) do
		if cmd[3] == path and method ~= "GET" then
			record_failure(("%s: %s to read-only %s"):format(name, method, path))
		end
	end
end

check_api_method(
	"api milestones",
	{ "api", "repos/{owner}/{repo}/milestones", "-X", "GET", "--paginate", "-f", "state=all" },
	"GET"
)
check_api_method(
	"api assignees",
	{ "api", "repos/{owner}/{repo}/assignees", "--jq", ".[].login", "--paginate" },
	"GET"
)
check_api_method("api user", { "api", "user", "-q", ".login" }, "GET")

-- The shape that shipped broken, asserted as broken: if this ever reads GET,
-- the detector above has stopped detecting anything.
recorded = nil
gh.run({ "api", "repos/{owner}/{repo}/milestones", "--paginate", "-f", "state=all" }, {}, noop)
if api_method(recorded.cmd) ~= "POST" then
	record_failure("api_method: `-f` without `-X GET` must read as POST — the #429 shape")
end

-- ── verdict ─────────────────────────────────────────────────────────────

if #failures > 0 then
	for _, failure in ipairs(failures) do
		print(("FAIL: %s"):format(failure))
	end
	vim.cmd("cquit! 1")
end

print("PASS: gh argv contract — every gh invocation matches its pinned shape")
