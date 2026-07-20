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
gh.ensure_prerequisites()
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

-- Verify Review Comments header uses the section-title highlight. The
-- UI/UX overhaul renamed the PR detail section headers from GitflowHeader
-- to GitflowSectionTitle.
local prs_hl_ns = vim.api.nvim_get_namespaces().gitflow_prs_hl
assert_true(prs_hl_ns ~= nil, "prs highlight namespace should exist")
local rc_header_line = find_line(pr_view_lines, "Review Comments")
assert_true(
	line_has_highlight(pr_view_buf, prs_hl_ns, rc_header_line,
		"GitflowSectionTitle"),
	"Review Comments header should use GitflowSectionTitle"
)

-- NOTE: the original single-buffer PR review panel that the remainder of
-- this test exercised (a "review" buffer rendering raw `diff --git` text
-- with cursor-based file/hunk navigation) was replaced by the dedicated
-- tabpage review UI in the UI/UX overhaul. That behaviour no longer exists
-- and is now covered by scripts/test_review_loop.lua and
-- scripts/test_stage8_windows.lua, so the obsolete assertions were removed.

vim.ui.input = original_input
vim.env.PATH = original_path
print("Stage 5 smoke tests passed")
