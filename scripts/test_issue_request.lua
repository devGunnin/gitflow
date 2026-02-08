local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(message, vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

local issue_request = require("gitflow.workflow.issue_request")

local issue_only = issue_request.classify({
	title = "Create issues for staged rollout",
	body = "Please create issues for all stages. Do not solve with a PR.",
})
assert_equals(issue_only.should_create_pr, false, "issue-only request should skip PR")
assert_equals(issue_only.reason, "explicit_no_pr", "explicit no-PR directive should win")

local issue_catalog = issue_request.classify({
	title = "Issue plan for release",
	body = "Create issues for milestones and assign labels.",
})
assert_equals(issue_catalog.should_create_pr, false, "issue plan should not open a PR")
assert_equals(
	issue_catalog.reason,
	"issue_only_intent",
	"issue plan should be treated as issue-only"
)

local fix_request = issue_request.classify({
	title = "Fix stash panel key mapping",
	body = "Implement a fix and add a regression test.",
})
assert_equals(fix_request.should_create_pr, true, "code fix requests should create PRs")

local mixed_request = issue_request.classify({
	title = "Create issues and implement stage command parser",
	body = "Create issues for docs, but also implement parser updates in Lua.",
})
assert_equals(
	mixed_request.should_create_pr,
	true,
	"mixed requests with code changes should create PRs"
)

local task_type_override = issue_request.classify({
	task_type = "issue_agent",
	body = "open PR if needed",
})
assert_equals(
	task_type_override.should_create_pr,
	false,
	"issue task type should suppress PR creation"
)
assert_equals(
	task_type_override.reason,
	"issue_only_task_type",
	"issue task type should return explicit reason"
)

assert_true(not issue_request.should_create_pr({
	prompt = "Create issues only, no PR.",
}), "should_create_pr helper should mirror classify result")

local ok, err = pcall(function()
	issue_request.classify("create issues")
end)
assert_true(not ok, "non-table request should raise an error")
assert_true(
	tostring(err):find("request must be a table", 1, true) ~= nil,
	"error should explain request type requirement"
)

print("issue request PR policy tests passed")
