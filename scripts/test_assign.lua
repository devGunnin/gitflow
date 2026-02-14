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
				message, vim.inspect(expected), vim.inspect(actual)
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

local function read_lines(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.fn.readfile(path)
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

-- ── gh stub setup ──

local stub_root = vim.fn.tempname()
assert_equals(vim.fn.mkdir(stub_root, "p"), 1, "stub root")
local stub_bin = stub_root .. "/bin"
assert_equals(vim.fn.mkdir(stub_bin, "p"), 1, "stub bin")
local gh_log = stub_root .. "/gh.log"

local gh_script = [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GITFLOW_GH_LOG"

if [ "$#" -ge 1 ] && [ "$1" = "--version" ]; then
  echo "gh version 2.55.0"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com as assign-test"
  exit 0
fi

# Collaborators list for assignee completion
if echo "$*" | grep -q "api repos/{owner}/{repo}/assignees"; then
  printf 'alice\nbob\ncharlie\n'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  sleep 0.10
  cat <<'EOISSUE'
[{"number":10,"title":"Assign test issue","state":"OPEN","labels":[{"name":"bug"}],"assignees":[{"login":"alice"}],"author":{"login":"octocat"},"updatedAt":"2026-02-10T00:00:00Z"}]
EOISSUE
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "issue" ] && [ "$2" = "view" ] && [ "$3" = "10" ]; then
  sleep 0.10
  cat <<'EOVIEW'
{"number":10,"title":"Assign test issue","body":"Body","state":"OPEN","labels":[{"name":"bug"}],"assignees":[{"login":"alice"}],"author":{"login":"octocat"},"comments":[]}
EOVIEW
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  echo "issue edit ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  sleep 0.10
  cat <<'EOPR'
[{"number":20,"title":"Assign test PR","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"assignees":[{"login":"bob"}],"headRefName":"feat/assign","baseRefName":"main","updatedAt":"2026-02-10T00:00:00Z","mergedAt":null}]
EOPR
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "20" ]; then
  sleep 0.10
  cat <<'EOPRVIEW'
{"number":20,"title":"Assign test PR","body":"PR body","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"assignees":[{"login":"bob"}],"headRefName":"feat/assign","baseRefName":"main","reviewRequests":[],"reviews":[],"comments":[],"files":[]}
EOPRVIEW
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  echo "pr edit ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "list" ]; then
  echo '[{"name":"bug","color":"ff0000","description":"Bug"}]'
  exit 0
fi

echo "unsupported gh args: $*" >&2
exit 1
]]

local gh_path = stub_bin .. "/gh"
vim.fn.writefile(vim.split(gh_script, "\n", { plain = true }), gh_path)
vim.fn.setfperm(gh_path, "rwxr-xr-x")

local original_path = vim.env.PATH
local original_notify = vim.notify
vim.env.PATH = stub_bin .. ":" .. (original_path or "")
vim.env.GITFLOW_GH_LOG = gh_log

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 44 },
	},
})

local gh = require("gitflow.gh")
assert_true(gh.state.checked, "gh should be checked")
assert_true(gh.state.authenticated, "gh should be authenticated")

local commands = require("gitflow.commands")
local buffer = require("gitflow.ui.buffer")
local issues_panel = require("gitflow.panels.issues")
local pr_panel = require("gitflow.panels.prs")

local notifications = {}
vim.notify = function(message, level, _)
	notifications[#notifications + 1] = {
		message = tostring(message),
		level = level,
	}
end

local passed = 0
local total = 0

local function test(name, fn)
	total = total + 1
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print(("  PASS: %s"):format(name))
	else
		print(("  FAIL: %s — %s"):format(name, err))
	end
end

-- ── 1. Completion module tests ──

test("assignee completion fetches collaborators", function()
	local completion = require("gitflow.completion.assignees")
	local candidates = completion.list_repo_assignee_candidates()
	assert_true(#candidates >= 3, "should fetch at least 3 collaborators")
	assert_true(contains(candidates, "alice"), "should include alice")
	assert_true(contains(candidates, "bob"), "should include bob")
	assert_true(contains(candidates, "charlie"), "should include charlie")
end)

test("assignee patch completion: bare prefix", function()
	local completion = require("gitflow.completion.assignees")
	local candidates = completion.complete_assignee_patch("a")
	assert_true(contains(candidates, "alice"), "should suggest alice")
end)

test("assignee patch completion: + prefix", function()
	local completion = require("gitflow.completion.assignees")
	local candidates = completion.complete_assignee_patch("+b")
	assert_true(contains(candidates, "+bob"), "should suggest +bob")
end)

test("assignee patch completion: - prefix", function()
	local completion = require("gitflow.completion.assignees")
	local candidates = completion.complete_assignee_patch("-a")
	assert_true(contains(candidates, "-alice"), "should suggest -alice")
end)

test("assignee patch completion: comma-separated", function()
	local completion = require("gitflow.completion.assignees")
	local candidates = completion.complete_assignee_patch("alice,b")
	assert_true(
		contains(candidates, "alice,bob"),
		"should suggest alice,bob"
	)
	local has_alice_again = false
	for _, c in ipairs(candidates) do
		if c == "alice,alice" then
			has_alice_again = true
		end
	end
	assert_true(not has_alice_again, "should not re-suggest alice")
end)

test("assignee token completion: add_assignees=", function()
	local completion = require("gitflow.completion.assignees")
	local candidates = completion.complete_token(
		"add_assignees=a", "add_assignees"
	)
	assert_true(
		contains(candidates, "add_assignees=alice"),
		"should suggest add_assignees=alice"
	)
end)

test("assignee token completion: remove_assignees=", function()
	local completion = require("gitflow.completion.assignees")
	local candidates = completion.complete_token(
		"remove_assignees=b", "remove_assignees"
	)
	assert_true(
		contains(candidates, "remove_assignees=bob"),
		"should suggest remove_assignees=bob"
	)
end)

-- ── 2. Command-line edit completion tests ──

test("issue edit completion includes add_assignees=", function()
	local tokens = commands.complete("", "Gitflow issue edit 10 ", 0)
	assert_true(
		contains(tokens, "add_assignees="),
		"should include add_assignees="
	)
	assert_true(
		contains(tokens, "remove_assignees="),
		"should include remove_assignees="
	)
end)

test("pr edit completion includes add_assignees=", function()
	local tokens = commands.complete("", "Gitflow pr edit 20 ", 0)
	assert_true(
		contains(tokens, "add_assignees="),
		"should include add_assignees="
	)
	assert_true(
		contains(tokens, "remove_assignees="),
		"should include remove_assignees="
	)
end)

test("issue edit add_assignees= tab-completion", function()
	local candidates = commands.complete(
		"add_assignees=a", "Gitflow issue edit 10 add_assignees=a", 0
	)
	assert_true(
		contains(candidates, "add_assignees=alice"),
		"should suggest alice"
	)
end)

test("pr edit add_assignees= tab-completion", function()
	local candidates = commands.complete(
		"add_assignees=c", "Gitflow pr edit 20 add_assignees=c", 0
	)
	assert_true(
		contains(candidates, "add_assignees=charlie"),
		"should suggest charlie"
	)
end)

-- ── 3. Issue panel assign keybind ──

test("issue panel has A keybind", function()
	commands.dispatch({ "issue", "list", "open" }, cfg)
	wait_until(function()
		local bufnr = buffer.get("issues")
		if not bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return find_line(lines, "#10") ~= nil
	end, "issue list should render")

	local issue_buf = buffer.get("issues")
	assert_true(issue_buf ~= nil, "issue panel should open")
	assert_keymaps(issue_buf, { "A", "L" })
end)

test("issue list shows assignees", function()
	local issue_buf = buffer.get("issues")
	assert_true(issue_buf ~= nil, "issue buf exists")
	local lines = vim.api.nvim_buf_get_lines(issue_buf, 0, -1, false)
	assert_true(
		find_line(lines, "assignees: alice") ~= nil,
		"list should show assignees"
	)
end)

test("issue view shows assignees", function()
	commands.dispatch({ "issue", "view", "10" }, cfg)
	wait_until(function()
		local bufnr = buffer.get("issues")
		if not bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return find_line(lines, "Assignees: alice") ~= nil
	end, "issue view should show assignees")
end)

test("issue view footer includes A: assign", function()
	local issue_buf = buffer.get("issues")
	local lines = vim.api.nvim_buf_get_lines(issue_buf, 0, -1, false)
	assert_true(
		find_line(lines, "A: assign") ~= nil,
		"view footer should include A: assign"
	)
end)

-- ── 4. Issue panel assign prompt flow ──

test("issue assign prompt calls gh issue edit with assignees", function()
	local original_fn_input = vim.fn.input
	local original_inputsave = vim.fn.inputsave
	local original_inputrestore = vim.fn.inputrestore

	vim.fn.inputsave = function() return 1 end
	vim.fn.inputrestore = function() return 1 end

	local assignee_prompt_seen = false
	vim.fn.input = function(opts)
		assignee_prompt_seen = true
		local comp = opts.completion
		assert_true(
			type(comp) == "string",
			"assign prompt should configure completion"
		)
		local fn_name = comp:match("^customlist,v:lua%.([%w_]+)$")
		assert_true(fn_name ~= nil, "should use custom completion")
		assert_true(
			type(_G[fn_name]) == "function",
			"completion function should exist"
		)

		local cands = _G[fn_name]("b", "", 0)
		assert_true(
			contains(cands, "bob"),
			"assign completion should suggest bob"
		)
		return "+bob,-alice"
	end

	local gh_lines_before = #read_lines(gh_log)
	issues_panel.edit_assignees_under_cursor()
	wait_until(function()
		local lines = read_lines(gh_log)
		return find_line(
			lines,
			"issue edit 10 --add-assignee bob --remove-assignee alice",
			gh_lines_before + 1
		) ~= nil
	end, "assign should call gh issue edit with --add-assignee/--remove-assignee")

	assert_true(assignee_prompt_seen, "assign prompt should have been shown")

	vim.fn.input = original_fn_input
	vim.fn.inputsave = original_inputsave
	vim.fn.inputrestore = original_inputrestore
end)

test("issue assign empty input warns", function()
	local original_fn_input = vim.fn.input
	local original_inputsave = vim.fn.inputsave
	local original_inputrestore = vim.fn.inputrestore

	vim.fn.inputsave = function() return 1 end
	vim.fn.inputrestore = function() return 1 end
	vim.fn.input = function(_) return "  " end

	issues_panel.edit_assignees_under_cursor()
	assert_true(
		notifications[#notifications].message
			== "No assignee edits provided",
		"blank input should warn"
	)

	vim.fn.input = original_fn_input
	vim.fn.inputsave = original_inputsave
	vim.fn.inputrestore = original_inputrestore
end)

-- ── 5. PR panel assign keybind ──

test("pr panel has A keybind", function()
	commands.dispatch({ "pr", "list", "open" }, cfg)
	wait_until(function()
		local bufnr = buffer.get("prs")
		if not bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return find_line(lines, "#20") ~= nil
	end, "pr list should render")

	local pr_buf = buffer.get("prs")
	assert_true(pr_buf ~= nil, "pr panel should open")
	assert_keymaps(pr_buf, { "A", "L" })
end)

test("pr list shows assignees", function()
	local pr_buf = buffer.get("prs")
	assert_true(pr_buf ~= nil, "pr buf exists")
	local lines = vim.api.nvim_buf_get_lines(pr_buf, 0, -1, false)
	assert_true(
		find_line(lines, "assignees: bob") ~= nil,
		"pr list should show assignees"
	)
end)

test("pr view shows assignees", function()
	commands.dispatch({ "pr", "view", "20" }, cfg)
	wait_until(function()
		local bufnr = buffer.get("prs")
		if not bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return find_line(lines, "Assignees: bob") ~= nil
	end, "pr view should show assignees")
end)

test("pr view footer includes A: assign", function()
	local pr_buf = buffer.get("prs")
	local lines = vim.api.nvim_buf_get_lines(pr_buf, 0, -1, false)
	assert_true(
		find_line(lines, "A: assign") ~= nil,
		"pr view footer should include A: assign"
	)
end)

-- ── 6. PR panel assign prompt flow ──

test("pr assign prompt calls gh pr edit with assignees", function()
	local original_fn_input = vim.fn.input
	local original_inputsave = vim.fn.inputsave
	local original_inputrestore = vim.fn.inputrestore

	vim.fn.inputsave = function() return 1 end
	vim.fn.inputrestore = function() return 1 end
	vim.fn.input = function(_) return "charlie" end

	local gh_lines_before = #read_lines(gh_log)
	pr_panel.edit_assignees_under_cursor()
	wait_until(function()
		local lines = read_lines(gh_log)
		return find_line(
			lines,
			"pr edit 20 --add-assignee charlie",
			gh_lines_before + 1
		) ~= nil
	end, "pr assign should call gh pr edit with --add-assignee")

	vim.fn.input = original_fn_input
	vim.fn.inputsave = original_inputsave
	vim.fn.inputrestore = original_inputrestore
end)

-- ── 7. CLI assign dispatch ──

test("issue edit with add_assignees= dispatches correctly", function()
	local gh_lines_before = #read_lines(gh_log)
	commands.dispatch(
		{ "issue", "edit", "10", "add_assignees=bob,charlie" }, cfg
	)
	wait_until(function()
		local lines = read_lines(gh_log)
		return find_line(
			lines,
			"issue edit 10 --add-assignee bob,charlie",
			gh_lines_before + 1
		) ~= nil
	end, "CLI issue edit add_assignees= should pass to gh")
end)

test("pr edit with add_assignees= dispatches correctly", function()
	local gh_lines_before = #read_lines(gh_log)
	commands.dispatch(
		{ "pr", "edit", "20", "add_assignees=alice" }, cfg
	)
	wait_until(function()
		local lines = read_lines(gh_log)
		return find_line(
			lines,
			"pr edit 20 --add-assignee alice",
			gh_lines_before + 1
		) ~= nil
	end, "CLI pr edit add_assignees= should pass to gh")
end)

test("issue edit with remove_assignees= dispatches correctly", function()
	local gh_lines_before = #read_lines(gh_log)
	commands.dispatch(
		{ "issue", "edit", "10", "remove_assignees=alice" }, cfg
	)
	wait_until(function()
		local lines = read_lines(gh_log)
		return find_line(
			lines,
			"issue edit 10 --remove-assignee alice",
			gh_lines_before + 1
		) ~= nil
	end, "CLI issue edit remove_assignees= should pass to gh")
end)

-- ── Cleanup ──

vim.notify = original_notify
vim.env.PATH = original_path

print(("Assign smoke tests: %d/%d passed"):format(passed, total))
if passed < total then
	vim.cmd("cquit! 1")
end
