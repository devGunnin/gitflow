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
			("%s (expected=%s, actual=%s)"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			),
			2
		)
	end
end

local function contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

local function wait_until(predicate, message, timeout_ms)
	local ok = vim.wait(timeout_ms or 5000, predicate, 20)
	assert_true(ok, message)
end

local function find_line(lines, needle, start_line)
	local from = start_line or 1
	for i = from, #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function find_pr_row(lines, number, title, start_line)
	local from = start_line or 1
	local number_token = ("#%s"):format(tostring(number))
	for i = from, #lines do
		if lines[i]:find(number_token, 1, true)
			and lines[i]:find(title, 1, true) then
			return i
		end
	end
	return nil
end

local function read_lines(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.fn.readfile(path)
end

local function wait_for_log_quiescence(path, stable_ticks, timeout_ms)
	local last_count = #read_lines(path)
	local stable = 0
	local ok = vim.wait(timeout_ms or 5000, function()
		local current = #read_lines(path)
		if current == last_count then
			stable = stable + 1
		else
			last_count = current
			stable = 0
		end
		return stable >= (stable_ticks or 5)
	end, 20)
	assert_true(ok, "gh log should quiesce before assertion")
	return last_count
end

local function count_lines_with(path, needle)
	local count = 0
	for _, line in ipairs(read_lines(path)) do
		if line:find(needle, 1, true) then
			count = count + 1
		end
	end
	return count
end

local function wait_for_review_refresh_cycles(path, expected, timeout_ms)
	local target = expected or 1
	local timeout = timeout_ms or 10000
	local ok = vim.wait(timeout, function()
		return count_lines_with(path, "pr view 7 --json") >= target
			and count_lines_with(path, "pr diff 7") >= target
			and count_lines_with(
				path,
				"api repos/{owner}/{repo}/pulls/7/comments"
			) >= target
	end, 20)
	assert_true(
		ok,
		("review refresh cycles should reach %d"):format(target)
	)
	return wait_for_log_quiescence(path, 10, timeout)
end

local function assert_keymaps(bufnr, required)
	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local missing = {}
	for _, lhs in ipairs(required) do
		missing[lhs] = true
	end
	for _, map in ipairs(keymaps) do
		if missing[map.lhs] ~= nil then
			missing[map.lhs] = nil
		end
	end
	for lhs, _ in pairs(missing) do
		error(("missing keymap '%s'"):format(lhs), 2)
	end
end

local function assert_visual_keymaps(bufnr, required)
	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "v")
	local missing = {}
	for _, lhs in ipairs(required) do
		missing[lhs] = true
	end
	for _, map in ipairs(keymaps) do
		if missing[map.lhs] ~= nil then
			missing[map.lhs] = nil
		end
	end
	for lhs, _ in pairs(missing) do
		error(("missing visual keymap '%s'"):format(lhs), 2)
	end
end

local function line_has_highlight(bufnr, ns, line_no, group)
	local marks = vim.api.nvim_buf_get_extmarks(
		bufnr,
		ns,
		{ line_no - 1, 0 },
		{ line_no - 1, -1 },
		{ details = true }
	)
	for _, mark in ipairs(marks) do
		local details = mark[4]
		if details and details.hl_group == group then
			return true
		end
	end
	return false
end

local stub_root = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(stub_root, "p"), 1,
	"stub root should be created"
)
local stub_bin = stub_root .. "/bin"
assert_equals(
	vim.fn.mkdir(stub_bin, "p"), 1,
	"stub bin should be created"
)
local gh_log = stub_root .. "/gh.log"

local diff_patch = table.concat({
	"diff --git a/lua/gitflow/commands.lua b/lua/gitflow/commands.lua",
	"index 1111111..2222222 100644",
	"--- a/lua/gitflow/commands.lua",
	"+++ b/lua/gitflow/commands.lua",
	"@@ -10,2 +10,3 @@ local M = {}",
	" local a = 1",
	"+local b = 2",
	"--- removed content that starts with two dashes",
	"+++ added content that starts with two pluses",
	"diff --git a/lua/gitflow/panels/prs.lua b/lua/gitflow/panels/prs.lua",
	"index 3333333..4444444 100644",
	"--- a/lua/gitflow/panels/prs.lua",
	"+++ b/lua/gitflow/panels/prs.lua",
	"@@ -20,2 +20,4 @@ local function render()",
	" line one",
	"+line two",
}, "\n")

local gh_script = [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GITFLOW_GH_LOG"

if [ "$#" -ge 1 ] && [ "$1" = "--version" ]; then
  echo "gh version 2.55.0"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com as stage5-test"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  sleep 0.1
  echo '[{"number":7,"title":"Stage5 PR","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"headRefName":"feature/stage5","baseRefName":"main","updatedAt":"2026-02-08T00:00:00Z","mergedAt":null}]'
  exit 0
fi

if [ "$#" -ge 4 ] && [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "7" ]; then
  sleep 0.1
  echo '{"number":7,"title":"Stage5 PR","body":"PR body","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"headRefName":"feature/stage5","baseRefName":"main","reviewRequests":[],"reviews":[],"comments":[],"files":[{"path":"lua/gitflow/commands.lua"},{"path":"lua/gitflow/panels/prs.lua"}]}'
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "pr" ] && [ "$2" = "diff" ] && [ "$3" = "7" ]; then
  sleep 0.1
  cat <<'EOF'
__DIFF_PATCH__
EOF
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "pr" ] && [ "$2" = "review" ] && [ "$3" = "7" ]; then
  echo "review ok"
  exit 0
fi

# B1: stub for review comments API
if [ "$#" -ge 2 ] && [ "$1" = "api" ]; then
  # Check for --method POST to distinguish review creation
  has_method_post=false
  for arg in "$@"; do
    if [ "$arg" = "POST" ]; then
      has_method_post=true
    fi
  done

  case "$2" in
    *pulls/7/comments/*/replies*)
      echo '{"id":103,"body":"reply ok"}'
      exit 0
      ;;
    *pulls/7/comments*)
      echo '[{"id":"101","path":"lua/gitflow/commands.lua","line":"11","original_line":"10","diff_hunk":"@@ -10,2 +10,3 @@ local M = {}","body":"Consider renaming this variable","user":{"login":"reviewer1"},"in_reply_to_id":null},{"id":"102","path":"lua/gitflow/commands.lua","line":"11","original_line":"10","diff_hunk":"@@ -10,2 +10,3 @@ local M = {}","body":"Agreed, needs a better name","user":{"login":"reviewer2"},"in_reply_to_id":101}]'
      exit 0
      ;;
    *pulls/7/reviews*)
      if [ "$has_method_post" = true ]; then
        echo '{"id":601,"state":"APPROVED"}'
        exit 0
      fi
      echo '[{"id":501,"state":"CHANGES_REQUESTED","body":"Needs work","user":{"login":"reviewer1"}}]'
      exit 0
      ;;
    *)
      echo "[]"
      exit 0
      ;;
  esac
fi

echo "unsupported gh args: $*" >&2
exit 1
]]

gh_script = gh_script:gsub("__DIFF_PATCH__", diff_patch)

local gh_path = stub_bin .. "/gh"
vim.fn.writefile(
	vim.split(gh_script, "\n", { plain = true }), gh_path
)
vim.fn.setfperm(gh_path, "rwxr-xr-x")

local original_path = vim.env.PATH
local original_input = vim.ui.input
vim.env.PATH = stub_bin .. ":" .. (original_path or "")
vim.env.GITFLOW_GH_LOG = gh_log

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 46,
		},
	},
})

local gh = require("gitflow.gh")
assert_true(
	gh.state.checked,
	"gh prerequisites should be checked on setup"
)
assert_true(
	gh.state.available,
	"gh should be available with stub"
)
assert_true(
	gh.state.authenticated,
	"gh auth should pass with stub"
)

local commands = require("gitflow.commands")
local pr_panel = require("gitflow.panels.prs")
local review_panel = require("gitflow.panels.review")
local buffer = require("gitflow.ui.buffer")

-- B4: verify new actions appear in completion
local pr_comp = commands.complete("", "Gitflow pr ", 0)
assert_true(
	contains(pr_comp, "review"),
	"pr completion should include review action"
)
assert_true(
	contains(pr_comp, "submit-review"),
	"pr completion should include submit-review action"
)
assert_true(
	contains(pr_comp, "respond"),
	"pr completion should include respond action"
)

commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_pr_row(lines, 7, "Stage5 PR") ~= nil
end, "pr list should render entries")

local pr_buf = buffer.get("prs")
assert_true(pr_buf ~= nil, "pr panel should open")
assert_keymaps(pr_buf, { "v" })

-- #302: verify PR detail view shows review comments
pr_panel.open_view(7, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Review Comments") ~= nil
end, "pr detail view should show Review Comments section")

local pr_view_buf = buffer.get("prs")
local pr_view_lines =
	vim.api.nvim_buf_get_lines(pr_view_buf, 0, -1, false)
assert_true(
	find_line(pr_view_lines, "reviewer1 on lua/gitflow/commands.lua:")
		~= nil,
	"pr detail should show reviewer1 review comment"
)
assert_true(
	find_line(pr_view_lines, "reviewer2 on lua/gitflow/commands.lua:")
		~= nil,
	"pr detail should show reviewer2 review comment"
)
assert_true(
	find_line(pr_view_lines, "Consider renaming this variable") ~= nil,
	"pr detail should show review comment body"
)

-- Verify Review Comments header gets GitflowHeader highlight
local prs_hl_ns = vim.api.nvim_get_namespaces().gitflow_prs_hl
assert_true(prs_hl_ns ~= nil, "prs highlight namespace should exist")
local rc_header_line = find_line(pr_view_lines, "Review Comments")
assert_true(
	line_has_highlight(pr_view_buf, prs_hl_ns, rc_header_line,
		"GitflowHeader"),
	"Review Comments header should use GitflowHeader"
)

-- Go back to list for subsequent tests
commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_pr_row(lines, 7, "Stage5 PR") ~= nil
end, "pr list should render after returning from detail view")

commands.dispatch({ "pr", "review", "7" }, cfg)
wait_until(function()
	local bufnr = buffer.get("review")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading review for PR #7") ~= nil
end, "review open should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("review")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading review for PR #7") == nil
		and find_line(lines, "diff --git ") ~= nil
end, "review panel should render title and diff")

local review_buf = buffer.get("review")
assert_true(review_buf ~= nil, "review panel should open")
assert_true(
	count_lines_with(gh_log, "pr diff 7") >= 1,
	"review refresh should call gh pr diff"
)
assert_equals(
	count_lines_with(gh_log, "pr diff 7 --patch"),
	0,
	"review refresh should not use --patch mailbox format"
)

-- ]c/[c for hunk nav per spec
-- c = inline comment, S = submit review
-- F1: <leader>t for toggle thread, <leader>b for back
-- <leader> defaults to \ in headless mode
local leader = vim.g.mapleader or "\\"
assert_keymaps(review_buf, {
	"]f", "[f", "]c", "[c",
	"a", "x", "c", "S", "R",
	"r", "q",
	leader .. "t", leader .. "b",
})

-- B2: visual mode c for multi-line comments
assert_visual_keymaps(review_buf, { "c" })

-- B1: verify existing review comments rendered
local review_lines =
	vim.api.nvim_buf_get_lines(review_buf, 0, -1, false)
assert_true(
	find_line(review_lines, "Review Comments") ~= nil,
	"review panel should show Review Comments section"
)
assert_true(
	find_line(review_lines, "Review Comments (1 threads)") ~= nil,
	"review panel should group reply comments under one thread"
)
assert_true(
	find_line(review_lines, "@reviewer1") ~= nil,
	"review panel should display reviewer1 comment"
)
assert_true(
	find_line(review_lines, "@reviewer2") ~= nil,
	"review panel should display reviewer2 reply"
)
assert_true(
	find_line(
		review_lines,
		"@reviewer1 on lua/gitflow/commands.lua:11"
	) ~= nil,
	"review thread header should include numeric line suffix"
)

-- N2: verify changed files are listed
assert_true(
	find_line(review_lines, "lua/gitflow/commands.lua") ~= nil
		and find_line(review_lines, "lua/gitflow/panels/prs.lua") ~= nil,
	"review panel should list changed files"
)

local tricky_removed_line = find_line(
	review_lines,
	"--- removed content that starts with two dashes"
)
local tricky_added_line = find_line(
	review_lines,
	"+++ added content that starts with two pluses"
)
assert_true(
	tricky_removed_line ~= nil and tricky_added_line ~= nil,
	"review panel should include tricky ---/+++ hunk content lines"
)
local review_hl_ns = vim.api.nvim_get_namespaces().gitflow_review_hl
assert_true(review_hl_ns ~= nil, "review highlight namespace should exist")
assert_true(
	line_has_highlight(
		review_buf,
		review_hl_ns,
		tricky_removed_line,
		"GitflowRemoved"
	),
	"--- hunk content line should use GitflowRemoved"
)
assert_true(
	not line_has_highlight(
		review_buf,
		review_hl_ns,
		tricky_removed_line,
		"GitflowHeader"
	),
	"--- hunk content line should not use GitflowHeader"
)
assert_true(
	line_has_highlight(
		review_buf,
		review_hl_ns,
		tricky_added_line,
		"GitflowAdded"
	),
	"+++ hunk content line should use GitflowAdded"
)
assert_true(
	not line_has_highlight(
		review_buf,
		review_hl_ns,
		tricky_added_line,
		"GitflowHeader"
	),
	"+++ hunk content line should not use GitflowHeader"
)

-- Navigation tests
vim.api.nvim_set_current_win(review_panel.state.winid)
vim.api.nvim_win_set_cursor(review_panel.state.winid, { 1, 0 })

local first_file = find_line(
	review_lines,
	"diff --git a/lua/gitflow/commands.lua"
		.. " b/lua/gitflow/commands.lua"
)
local first_hunk = find_line(
	review_lines, "@@ -10,2 +10,3 @@ local M = {}"
)
local second_file = find_line(
	review_lines,
	"diff --git a/lua/gitflow/panels/prs.lua"
		.. " b/lua/gitflow/panels/prs.lua"
)
local second_hunk = find_line(
	review_lines,
	"@@ -20,2 +20,4 @@ local function render()"
)
assert_true(
	first_file ~= nil and first_hunk ~= nil
		and second_file ~= nil and second_hunk ~= nil,
	"diff markers should exist"
)

review_panel.next_file()
assert_equals(
	vim.api.nvim_win_get_cursor(review_panel.state.winid)[1],
	first_file, "next_file should jump"
)
review_panel.next_hunk()
assert_equals(
	vim.api.nvim_win_get_cursor(review_panel.state.winid)[1],
	first_hunk, "next_hunk should jump"
)
review_panel.next_file()
assert_equals(
	vim.api.nvim_win_get_cursor(review_panel.state.winid)[1],
	second_file, "next_file should advance"
)
review_panel.prev_file()
assert_equals(
	vim.api.nvim_win_get_cursor(review_panel.state.winid)[1],
	first_file, "prev_file should jump back"
)
review_panel.prev_hunk()
assert_equals(
	vim.api.nvim_win_get_cursor(review_panel.state.winid)[1],
	second_hunk, "prev_hunk should wrap"
)

-- Move cursor back to diff area for review action tests
vim.api.nvim_win_set_cursor(
	review_panel.state.winid, { second_hunk, 0 }
)

local scripted_inputs = {
	"Looks good to me",
	"Please rename this function",
	"General review feedback",
	"Inline context note",
	"Reply to inline note",
}

vim.ui.input = function(_, on_confirm)
	local next_value = table.remove(scripted_inputs, 1)
	on_confirm(next_value)
end

review_panel.review_approve()
review_panel.review_request_changes()
review_panel.review_comment()

-- B2: inline_comment now queues instead of submitting
vim.api.nvim_win_set_cursor(
	review_panel.state.winid,
	{ second_hunk + 1, 0 }
)
review_panel.inline_comment()
assert_equals(
	#review_panel.state.pending_comments, 1,
	"inline_comment should queue a pending comment"
)
assert_equals(
	review_panel.state.pending_comments[1].body,
	"Inline context note",
	"pending comment body should match input"
)

-- re_render should use cached data and not trigger new gh calls
-- Wait for initial load + 3 async refreshes from a/x/comment submissions.
local gh_lines_before =
	wait_for_review_refresh_cycles(gh_log, 4, 10000)
review_panel.re_render()
local gh_lines_after = wait_for_log_quiescence(gh_log, 10, 10000)
assert_equals(
	gh_lines_after, gh_lines_before,
	"re_render should not trigger gh API calls"
)

-- Verify cached state is populated after initial refresh
assert_true(
	review_panel.state._cached_title ~= nil,
	"cached title should be populated after refresh"
)
assert_true(
	review_panel.state._cached_diff_text ~= nil,
	"cached diff_text should be populated after refresh"
)

-- reply_to_thread falls back to pending comment
review_panel.reply_to_thread()

commands.dispatch(
	{ "pr", "review", "7", "approve", "CLI", "approval" }, cfg
)
commands.dispatch(
	{ "pr", "review", "7", "request-changes", "Need", "tests" },
	cfg
)
commands.dispatch(
	{ "pr", "review", "7", "comment", "CLI", "comment" }, cfg
)

-- B4: test submit-review batches pending comments
-- Review panel is open for PR #7, so this should
-- call submit_review_direct which batches pending
commands.dispatch(
	{ "pr", "submit-review", "7", "approve", "LGTM" }, cfg
)

wait_until(function()
	local lines = read_lines(gh_log)
	return find_line(
			lines,
			"pr review 7 --approve --body Looks good to me"
		) ~= nil
		and find_line(
			lines,
			"pr review 7 --request-changes"
				.. " --body Please rename this function"
		) ~= nil
		and find_line(
			lines,
			"pr review 7 --comment"
				.. " --body General review feedback"
		) ~= nil
		and find_line(
			lines,
			"--comment --body Reply to inline note #1:"
		) ~= nil
		and find_line(
			lines,
			"pr review 7 --approve --body CLI approval"
		) ~= nil
		and find_line(
			lines,
			"pr review 7 --request-changes --body Need tests"
		) ~= nil
		and find_line(
			lines,
			"pr review 7 --comment --body CLI comment"
		) ~= nil
end, "review actions should invoke gh pr review with expected modes",
	10000)

-- Verify pending comments were cleared after submit-review
wait_until(function()
	return #review_panel.state.pending_comments == 0
end, "submit-review should clear pending comments", 5000)

-- toggle_thread test on comment thread lines
wait_until(function()
	local bufnr = buffer.get("review")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Review Comments") ~= nil
end, "review panel should have comments for toggle test", 3000)

local cur_review_buf = buffer.get("review")
if cur_review_buf then
	local toggle_lines = vim.api.nvim_buf_get_lines(
		cur_review_buf, 0, -1, false
	)
	local toggle_thread_line =
		find_line(toggle_lines, "@reviewer1")
	if toggle_thread_line
		and review_panel.state.winid
		and vim.api.nvim_win_is_valid(
			review_panel.state.winid
		) then
		vim.api.nvim_win_set_cursor(
			review_panel.state.winid,
			{ toggle_thread_line, 0 }
		)
		-- Should collapse the thread
		review_panel.toggle_thread()
	end
end

-- toggle_inline_comments test: verify <leader>i keymap and behavior
assert_keymaps(
	buffer.get("review"),
	{ leader .. "i" }
)

-- Default state: show_inline_comments should be true
assert_equals(
	review_panel.state.show_inline_comments, true,
	"show_inline_comments should default to true"
)

-- Find the diff line where comments are attached (line 11 in commands.lua)
local inline_buf = buffer.get("review")
assert_true(
	inline_buf ~= nil,
	"review buffer should exist for inline toggle test"
)
local ns_comments = vim.api.nvim_get_namespaces()
	.gitflow_review_comments
assert_true(
	ns_comments ~= nil,
	"gitflow_review_comments namespace should exist"
)

-- Before toggle: extmarks should include virt_lines with comment bodies
local pre_marks = vim.api.nvim_buf_get_extmarks(
	inline_buf, ns_comments, 0, -1, { details = true }
)
local pre_has_virt_lines = false
local pre_virt_lines_contain_body = false
for _, mark in ipairs(pre_marks) do
	local details = mark[4]
	if details and details.virt_lines
		and #details.virt_lines > 0 then
		pre_has_virt_lines = true
		for _, vl in ipairs(details.virt_lines) do
			for _, chunk in ipairs(vl) do
				if chunk[1]:find("Consider renaming", 1, true) then
					pre_virt_lines_contain_body = true
				end
			end
		end
		break
	end
end
assert_true(
	pre_has_virt_lines,
	"inline comments should show virt_lines by default"
)
assert_true(
	pre_virt_lines_contain_body,
	"inline virt_lines should contain comment body text by default"
)

-- Toggle inline comments off
review_panel.toggle_inline_comments()
assert_equals(
	review_panel.state.show_inline_comments, false,
	"show_inline_comments should be false after toggle"
)

-- After toggle off: extmarks should not have virt_lines
local post_marks = vim.api.nvim_buf_get_extmarks(
	inline_buf, ns_comments, 0, -1, { details = true }
)
local post_has_virt_lines = false
for _, mark in ipairs(post_marks) do
	local details = mark[4]
	if details and details.virt_lines
		and #details.virt_lines > 0 then
		post_has_virt_lines = true
		break
	end
end
assert_true(
	not post_has_virt_lines,
	"inline comments should not show virt_lines after toggle off"
)

-- Toggle inline comments on again
review_panel.toggle_inline_comments()
assert_equals(
	review_panel.state.show_inline_comments, true,
	"show_inline_comments should be true after second toggle"
)

local off_marks = vim.api.nvim_buf_get_extmarks(
	inline_buf, ns_comments, 0, -1, { details = true }
)
local off_has_virt_lines = false
for _, mark in ipairs(off_marks) do
	local details = mark[4]
	if details and details.virt_lines
		and #details.virt_lines > 0 then
		off_has_virt_lines = true
		break
	end
end
assert_true(
	off_has_virt_lines,
	"inline comments should show virt_lines after toggle on"
)

-- B3: close review panel to restore previous window
review_panel.close()
assert_true(
	not review_panel.is_open(),
	"review panel should be closed after close()"
)

commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_pr_row(lines, 7, "Stage5 PR") ~= nil
end, "pr list should be available before review handoff")

vim.api.nvim_set_current_win(pr_panel.state.winid)
local handoff_pr_buf = buffer.get("prs")
assert_true(
	handoff_pr_buf ~= nil,
	"pr panel buffer should exist for review handoff"
)
local pr_lines =
	vim.api.nvim_buf_get_lines(handoff_pr_buf, 0, -1, false)
local pr_line = find_pr_row(pr_lines, 7, "Stage5 PR")
assert_true(
	pr_line ~= nil,
	"pr list line should exist for review handoff"
)
vim.api.nvim_win_set_cursor(
	pr_panel.state.winid, { pr_line, 0 }
)
pr_panel.review_under_cursor()
wait_until(function()
	local bufnr = buffer.get("review")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading review for PR #7") == nil
		and find_line(lines, "diff --git ") ~= nil
end, "review from pr panel should open review UI")

vim.ui.input = original_input
vim.env.PATH = original_path
print("Stage 5 smoke tests passed")
