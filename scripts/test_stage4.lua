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

local stub_root = vim.fn.tempname()
assert_equals(vim.fn.mkdir(stub_root, "p"), 1, "stub root should be created")
local stub_bin = stub_root .. "/bin"
assert_equals(vim.fn.mkdir(stub_bin, "p"), 1, "stub bin should be created")
local gh_log = stub_root .. "/gh.log"

local gh_script = [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GITFLOW_GH_LOG"

if [ "$#" -ge 1 ] && [ "$1" = "--version" ]; then
  echo "gh version 2.55.0"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com as stage4-test"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  sleep 0.15
  echo '[{"number":1,"title":"Stage4 issue","state":"OPEN","labels":[{"name":"bug"}],"assignees":[],"author":{"login":"octocat"},"updatedAt":"2026-02-08T00:00:00Z"}]'
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "issue" ] && [ "$2" = "view" ] && [ "$3" = "1" ]; then
  sleep 0.15
  echo '{"number":1,"title":"Stage4 issue","body":"Issue body","state":"OPEN","labels":[{"name":"bug"}],"author":{"login":"octocat"},"comments":[{"body":"First comment","author":{"login":"hubot"}}]}'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://example.com/devGunnin/Gitflow/issues/2"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  echo "issue comment ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "close" ]; then
  echo "issue close ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "reopen" ]; then
  echo "issue reopen ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  echo "issue edit ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  sleep 0.15
  echo '[{"number":7,"title":"Stage4 PR","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"headRefName":"feature/stage4","baseRefName":"main","updatedAt":"2026-02-08T00:00:00Z","mergedAt":null}]'
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "7" ]; then
  sleep 0.15
  echo '{"number":7,"title":"Stage4 PR","body":"PR body","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"headRefName":"feature/stage4","baseRefName":"main","reviewRequests":[],"reviews":[],"comments":[],"files":[{"path":"lua/gitflow/commands.lua"}]}'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://example.com/devGunnin/Gitflow/pull/8"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  echo "pr comment ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  echo "pr merge ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "checkout" ]; then
  echo "pr checkout ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "close" ]; then
  echo "pr close ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  echo "pr edit ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "list" ]; then
  sleep 0.15
  echo '[{"name":"bug","color":"ff0000","description":"Bug label","isDefault":false},{"name":"docs","color":"00ff00","description":"Docs","isDefault":false}]'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "create" ]; then
  echo "label create ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "delete" ]; then
  echo "label delete ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo '{"name":"Gitflow","nameWithOwner":"devGunnin/Gitflow","url":"https://github.com/devGunnin/Gitflow","description":"repo","isPrivate":false,"defaultBranchRef":{"name":"main"}}'
  exit 0
fi

echo "unsupported gh args: $*" >&2
exit 1
]]

local gh_path = stub_bin .. "/gh"
vim.fn.writefile(vim.split(gh_script, "\n", { plain = true }), gh_path)
vim.fn.setfperm(gh_path, "rwxr-xr-x")

local original_path = vim.env.PATH
vim.env.PATH = stub_bin .. ":" .. (original_path or "")
vim.env.GITFLOW_GH_LOG = gh_log

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 44,
		},
	},
})

local gh = require("gitflow.gh")
assert_true(gh.state.checked, "gh prerequisites should be checked on setup")
assert_true(gh.state.available, "gh should be available with stub")
assert_true(gh.state.authenticated, "gh auth should pass with stub")

local gh_log_lines = read_lines(gh_log)
assert_true(#gh_log_lines >= 2, "setup should invoke gh prerequisite commands")
assert_true(find_line(gh_log_lines, "--version") ~= nil, "setup should call gh --version")
assert_true(find_line(gh_log_lines, "auth status") ~= nil, "setup should call gh auth status")

local commands = require("gitflow.commands")
local subcommands = commands.complete("")
for _, expected in ipairs({ "issue", "pr", "label" }) do
	assert_true(contains(subcommands, expected), ("missing subcommand '%s'"):format(expected))
end

local issue_actions = commands.complete("", "Gitflow issue ", 0)
for _, expected in ipairs({ "list", "view", "create", "comment", "close", "reopen", "edit" }) do
	assert_true(contains(issue_actions, expected), ("missing issue action '%s'"):format(expected))
end

commands.dispatch({ "issue", "list", "open" }, cfg)
local buffer = require("gitflow.ui.buffer")
wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading issues...") ~= nil
end, "issue list should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "#1 [open] Stage4 issue") ~= nil
end, "issue list should render issue entries")

local issue_buf = buffer.get("issues")
assert_true(issue_buf ~= nil, "issue panel should open")
assert_keymaps(issue_buf, { "<CR>", "c", "C", "x", "l", "q" })

commands.dispatch({ "issue", "view", "1" }, cfg)
wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading issue #1") ~= nil
end, "issue view should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Issue #1: Stage4 issue") ~= nil
end, "issue view should render issue details")

commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading pull requests...") ~= nil
end, "pr list should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "#7 [open] Stage4 PR") ~= nil
end, "pr list should render pr entries")

local pr_buf = buffer.get("prs")
assert_true(pr_buf ~= nil, "pr panel should open")
assert_keymaps(pr_buf, { "<CR>", "c", "C", "m", "o", "q" })

commands.dispatch({ "pr", "view", "7" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading PR #7") ~= nil
end, "pr view should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "PR #7: Stage4 PR") ~= nil
end, "pr view should render details")

commands.dispatch({ "label", "list" }, cfg)
wait_until(function()
	local bufnr = buffer.get("labels")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading labels...") ~= nil
end, "label list should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("labels")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "bug (#ff0000)") ~= nil
end, "label list should render labels")

commands.dispatch({ "label", "create", "stage4", "00ff00", "Green", "label" }, cfg)
commands.dispatch({ "pr", "merge", "7", "squash" }, cfg)
commands.dispatch({ "pr", "checkout", "7" }, cfg)
commands.dispatch({ "issue", "close", "1" }, cfg)

wait_until(function()
	local lines = read_lines(gh_log)
	return find_line(lines, "label create stage4 --color 00ff00 --description Green label") ~= nil
		and find_line(lines, "pr merge 7 --squash") ~= nil
		and find_line(lines, "pr checkout 7") ~= nil
		and find_line(lines, "issue close 1") ~= nil
end, "stage4 command actions should invoke gh")

vim.env.PATH = original_path
print("Stage 4 smoke tests passed")
