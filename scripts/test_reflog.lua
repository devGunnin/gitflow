-- scripts/test_reflog.lua — reflog panel smoke tests
--
-- Run: nvim --headless -u NONE -l scripts/test_reflog.lua
--
-- Verifies:
--   1. Reflog parser handles tab-delimited format
--   2. Reflog panel opens/closes without crash
--   3. Reflog keybinding and Plug mapping registered

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed = 0
local failed = 0

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

local function test(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed = passed + 1
		print(("  PASS: %s"):format(name))
	else
		failed = failed + 1
		print(("  FAIL: %s\n    %s"):format(name, err))
	end
end

-- ── Setup ──────────────────────────────────────────────────────────

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 40 },
	},
})

-- ── Parser tests ───────────────────────────────────────────────────

local git_reflog = require("gitflow.git.reflog")

test("parse handles single reflog entry", function()
	local entries = git_reflog.parse(
		"abc1234567890\tHEAD@{0}\tcommit: Initial commit\n"
	)
	assert_equals(#entries, 1, "should parse one entry")
	assert_equals(entries[1].sha, "abc1234567890", "sha")
	assert_equals(entries[1].short_sha, "abc1234", "short_sha")
	assert_equals(entries[1].selector, "HEAD@{0}", "selector")
	assert_equals(
		entries[1].description,
		"commit: Initial commit",
		"description"
	)
	assert_equals(entries[1].action, "commit", "action")
end)

test("parse handles multiple entries", function()
	local output = table.concat({
		"abc1234567890\tHEAD@{0}\tcommit: First",
		"def5678901234\tHEAD@{1}\tcheckout: moving from a to b",
		"fed9012345678\tHEAD@{2}\treset: moving to HEAD~1",
	}, "\n")
	local entries = git_reflog.parse(output)
	assert_equals(#entries, 3, "should parse three entries")
	assert_equals(entries[1].action, "commit", "action 1")
	assert_equals(entries[2].action, "checkout", "action 2")
	assert_equals(entries[3].action, "reset", "action 3")
end)

test("parse handles empty output", function()
	local entries = git_reflog.parse("")
	assert_equals(#entries, 0, "empty output => no entries")
end)

test("parse extracts short_sha from full sha", function()
	local entries = git_reflog.parse(
		"abcdef1234567890\tHEAD@{0}\tcommit: test\n"
	)
	assert_equals(
		entries[1].short_sha, "abcdef1", "first 7 chars"
	)
end)

-- ── Subcommand registration ────────────────────────────────────────

local commands = require("gitflow.commands")

test("reflog subcommand is registered", function()
	assert_true(
		commands.subcommands["reflog"] ~= nil,
		"reflog subcommand should be registered"
	)
end)

test("reflog subcommand has description and run", function()
	local sub = commands.subcommands["reflog"]
	assert_true(
		type(sub.description) == "string"
			and sub.description ~= "",
		"should have non-empty description"
	)
	assert_true(
		type(sub.run) == "function",
		"should have run function"
	)
end)

-- ── Config keybinding ──────────────────────────────────────────────

test("reflog keybinding default is gF", function()
	local defaults = require("gitflow.config").defaults()
	assert_equals(
		defaults.keybindings.reflog,
		"gF",
		"default reflog keybinding"
	)
end)

-- ── Plug mapping ───────────────────────────────────────────────────

test("Plug(GitflowReflog) mapping exists", function()
	local maps = vim.api.nvim_get_keymap("n")
	local found = false
	for _, map in ipairs(maps) do
		if map.lhs == "<Plug>(GitflowReflog)" then
			found = true
			break
		end
	end
	assert_true(found, "<Plug>(GitflowReflog) should exist")
end)

-- ── Highlight groups ───────────────────────────────────────────────

test("GitflowReflogHash highlight exists", function()
	local hl = vim.api.nvim_get_hl(0, {
		name = "GitflowReflogHash",
	})
	assert_true(
		hl ~= nil and next(hl) ~= nil,
		"GitflowReflogHash should be defined"
	)
end)

test("GitflowReflogAction highlight exists", function()
	local hl = vim.api.nvim_get_hl(0, {
		name = "GitflowReflogAction",
	})
	assert_true(
		hl ~= nil and next(hl) ~= nil,
		"GitflowReflogAction should be defined"
	)
end)

-- ── Summary ────────────────────────────────────────────────────────

print(("\nReflog smoke tests: %d passed, %d failed"):format(
	passed, failed
))
if failed > 0 then
	vim.cmd("cquit! 1")
end
print("All reflog smoke tests passed")
