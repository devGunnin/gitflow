local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
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

local function read_lines(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.fn.readfile(path)
end

-- ── gh stub setup ──

local stub_root = vim.fn.tempname()
assert_true(vim.fn.mkdir(stub_root, "p") == 1, "stub root")
local stub_bin = stub_root .. "/bin"
assert_true(vim.fn.mkdir(stub_bin, "p") == 1, "stub bin")
local gh_log = stub_root .. "/gh.log"

local gh_script = [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GITFLOW_GH_LOG"

if [ "$#" -ge 1 ] && [ "$1" = "--version" ]; then
  echo "gh version 2.55.0"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com as labels-test"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "list" ]; then
  printf '[{"name":"bug"},{"name":"docs"},{"name":"enhancement"}]'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  echo '[]'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo '[]'
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
gitflow.setup({})

-- gh is probed on the first GitHub command, never at setup (startup must not
-- pay `gh auth status`), so drive the probe explicitly here.
local gh = require("gitflow.gh")
assert_true(not gh.state.checked, "setup should not probe gh")
assert_true(gh.ensure_prerequisites(), "gh stub should satisfy prerequisites")
assert_true(gh.state.authenticated, "gh should be authenticated")

local commands = require("gitflow.commands")
local completion = require("gitflow.completion.labels")

vim.notify = function() end

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

-- ── 1. Fetch + cache ──

test("label completion fetches repo labels", function()
	local candidates = completion.list_repo_label_candidates()
	assert_true(#candidates == 3, "should fetch 3 labels")
	assert_true(contains(candidates, "bug"), "should include bug")
	assert_true(contains(candidates, "docs"), "should include docs")
	assert_true(contains(candidates, "enhancement"), "should include enhancement")
end)

test("candidates are returned sorted", function()
	local candidates = completion.list_repo_label_candidates()
	assert_true(
		candidates[1] == "bug"
			and candidates[2] == "docs"
			and candidates[3] == "enhancement",
		"should be alphabetically sorted"
	)
end)

test("repeat call within TTL is served from cache, not gh", function()
	local before = #read_lines(gh_log)
	completion.list_repo_label_candidates()
	local after = #read_lines(gh_log)
	assert_true(after == before, "cached call should not invoke gh again")
end)

test("fetch_repo_label_candidates bypasses the cache", function()
	local before = #read_lines(gh_log)
	local candidates = completion.fetch_repo_label_candidates()
	local after = #read_lines(gh_log)
	assert_true(after > before, "uncached fetch should invoke gh")
	assert_true(#candidates == 3, "should fetch 3 labels")
end)

-- ── 2. complete_token (add=/remove= on issue|pr edit) ──

test("label token completion: add=", function()
	local candidates = completion.complete_token("add=b", "add")
	assert_true(contains(candidates, "add=bug"), "should suggest add=bug")
end)

test("label token completion: remove=", function()
	local candidates = completion.complete_token("remove=d", "remove")
	assert_true(contains(candidates, "remove=docs"), "should suggest remove=docs")
end)

test("label token completion: comma-separated excludes selected", function()
	local candidates = completion.complete_token("add=bug,", "add")
	assert_true(contains(candidates, "add=bug,docs"), "should suggest docs next")
	assert_true(
		not contains(candidates, "add=bug,bug"),
		"should not re-suggest bug"
	)
end)

test("label token completion: wrong prefix returns nothing", function()
	local candidates = completion.complete_token("remove=b", "add")
	assert_true(#candidates == 0, "add key should not match remove= arglead")
end)

test("issue edit completion includes add=/remove=", function()
	local tokens = commands.complete("", "Gitflow issue edit 1 ", 0)
	assert_true(contains(tokens, "add="), "should include add=")
	assert_true(contains(tokens, "remove="), "should include remove=")
end)

test("issue edit add= tab-completion routes to label completion", function()
	local candidates = commands.complete(
		"add=e", "Gitflow issue edit 1 add=e", 0
	)
	assert_true(
		contains(candidates, "add=enhancement"),
		"should suggest enhancement"
	)
end)

test("pr edit remove= tab-completion routes to label completion", function()
	local candidates = commands.complete(
		"remove=b", "Gitflow pr edit 1 remove=b", 0
	)
	assert_true(contains(candidates, "remove=bug"), "should suggest bug")
end)

-- ── 3. complete_issue_patch (+/-/bare, used by panel label-edit prompts) ──

test("issue patch completion: bare prefix", function()
	local candidates = completion.complete_issue_patch("b")
	assert_true(contains(candidates, "bug"), "should suggest bug")
end)

test("issue patch completion: + prefix", function()
	local candidates = completion.complete_issue_patch("+d")
	assert_true(contains(candidates, "+docs"), "should suggest +docs")
end)

test("issue patch completion: - prefix", function()
	local candidates = completion.complete_issue_patch("-b")
	assert_true(contains(candidates, "-bug"), "should suggest -bug")
end)

test("issue patch completion: comma-separated excludes selected", function()
	local candidates = completion.complete_issue_patch("+bug,+d")
	assert_true(
		contains(candidates, "+bug,+docs"),
		"should suggest +bug,+docs"
	)
	assert_true(
		not contains(candidates, "+bug,+bug"),
		"should not re-suggest bug"
	)
end)

-- ── 4. complete_create_labels (comma-separated, no sign) ──

test("create-labels completion: bare prefix", function()
	local candidates = completion.complete_create_labels("e")
	assert_true(
		contains(candidates, "enhancement"),
		"should suggest enhancement"
	)
end)

test("create-labels completion: comma-separated excludes selected", function()
	local candidates = completion.complete_create_labels("bug,d")
	assert_true(contains(candidates, "bug,docs"), "should suggest bug,docs")
	assert_true(
		not contains(candidates, "bug,bug"),
		"should not re-suggest bug"
	)
end)

test("create-labels completion: nil arglead is treated as empty", function()
	local candidates = completion.complete_create_labels(nil)
	assert_true(#candidates == 3, "should suggest all 3 labels")
end)

-- ── Cleanup ──

vim.notify = original_notify
vim.env.PATH = original_path

print(("Label completion smoke tests: %d/%d passed"):format(passed, total))
if passed < total then
	vim.cmd("cquit! 1")
end
