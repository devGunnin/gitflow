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

local function assert_deep_equals(actual, expected, message)
	if not vim.deep_equal(actual, expected) then
		error(
			("%s (expected=%s, actual=%s)"):format(message, vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

local review_loop = require("gitflow.workflow.review_loop")

assert_true(review_loop.should_restart_on_user_comment("merge_ready"), "merge_ready should restart")
assert_true(review_loop.should_restart_on_user_comment("verified"), "verified should restart")
assert_true(not review_loop.should_restart_on_user_comment("fix_required"), "fix_required should not restart")

local merge_ready_state = {
	phase = "merge_ready",
	cycle = 2,
	latest_feedback = "old",
	feedback_history = {
		{ source = "review", body = "old" },
	},
	merge_ready_at = "2026-02-07T20:00:00Z",
	verified_at = nil,
}

local restarted, reopened = review_loop.apply_user_comment(merge_ready_state, {
	body = "  please address the edge case in foo()\n",
	created_at = "2026-02-07T20:10:00Z",
})
assert_true(restarted, "merge_ready comment should restart loop")
assert_equals(reopened.phase, "fix_required", "state should move to fix_required")
assert_equals(reopened.cycle, 3, "cycle should increment")
assert_equals(
	reopened.latest_feedback,
	"please address the edge case in foo()",
	"latest feedback should be normalized"
)
assert_equals(#reopened.feedback_history, 2, "history should append new feedback")
assert_deep_equals(reopened.feedback_history[2], {
	source = "user_comment",
	body = "please address the edge case in foo()",
	created_at = "2026-02-07T20:10:00Z",
}, "new feedback entry should capture user comment")
assert_equals(reopened.merge_ready_at, nil, "merge_ready marker should be cleared")
assert_equals(reopened.verified_at, nil, "verified marker should be cleared")

assert_equals(merge_ready_state.phase, "merge_ready", "input state should not be mutated")
assert_equals(#merge_ready_state.feedback_history, 1, "input history should remain unchanged")

local verified_state = {
	phase = "verified",
	cycle = 0,
	feedback_history = {},
	verified_at = "2026-02-07T20:20:00Z",
}
local verified_restart, verified_reopened = review_loop.apply_user_comment(
	verified_state,
	"please reword the release note"
)
assert_true(verified_restart, "verified comment should restart loop")
assert_equals(verified_reopened.phase, "fix_required", "verified should move to fix_required")
assert_equals(verified_reopened.cycle, 1, "verified reopen should increment from zero")
assert_equals(
	verified_reopened.latest_feedback,
	"please reword the release note",
	"string comments should be accepted"
)

local awaiting_review_state = {
	phase = "awaiting_review",
	cycle = 4,
	feedback_history = {},
}
local no_restart, unchanged = review_loop.apply_user_comment(awaiting_review_state, "nit: rename variable")
assert_true(not no_restart, "non-terminal states should not restart")
assert_deep_equals(unchanged, awaiting_review_state, "non-terminal state should stay unchanged")

local blank_restart, blank_state = review_loop.apply_user_comment(merge_ready_state, "   \n\t ")
assert_true(not blank_restart, "blank comments should not restart")
assert_deep_equals(blank_state, merge_ready_state, "blank comments should keep state unchanged")

local ok, err = pcall(function()
	review_loop.apply_user_comment({ cycle = 1 }, "msg")
end)
assert_true(not ok, "missing phase should raise an error")
assert_true(
	tostring(err):find("state.phase must be a non%-empty string", 1) ~= nil,
	"error should explain missing phase"
)

print("review loop transition tests passed")
