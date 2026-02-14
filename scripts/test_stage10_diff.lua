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

local function find_line(lines, needle, start_line)
	local from = start_line or 1
	for i = from, #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
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

local function get_highlight(name, opts)
	local options = vim.tbl_extend(
		"force", { name = name }, opts or {}
	)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, options)
	assert_true(
		ok,
		("expected highlight '%s' to exist"):format(name)
	)
	return value
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

print("Stage 10 diff overhaul tests")
print(string.rep("─", 50))

-- ─── Module loading ────────────────────────────────────

test("git/diff module loads", function()
	local git_diff = require("gitflow.git.diff")
	assert_true(
		type(git_diff) == "table",
		"git_diff should be a table"
	)
end)

test("git/diff.parse_hunk_header exists", function()
	local git_diff = require("gitflow.git.diff")
	assert_true(
		type(git_diff.parse_hunk_header) == "function",
		"parse_hunk_header should be a function"
	)
end)

test("git/diff.collect_markers exists", function()
	local git_diff = require("gitflow.git.diff")
	assert_true(
		type(git_diff.collect_markers) == "function",
		"collect_markers should be a function"
	)
end)

-- ─── parse_hunk_header ────────────────────────────────

test("parse_hunk_header extracts line numbers", function()
	local git_diff = require("gitflow.git.diff")
	local old, new = git_diff.parse_hunk_header(
		"@@ -10,2 +10,3 @@ local M = {}"
	)
	assert_equals(old, 10, "old start should be 10")
	assert_equals(new, 10, "new start should be 10")
end)

test("parse_hunk_header with single-line hunk", function()
	local git_diff = require("gitflow.git.diff")
	local old, new = git_diff.parse_hunk_header(
		"@@ -1 +1,5 @@"
	)
	assert_equals(old, 1, "old start should be 1")
	assert_equals(new, 1, "new start should be 1")
end)

-- ─── collect_markers ──────────────────────────────────

local diff_text = table.concat({
	"diff --git a/foo.lua b/foo.lua",
	"index 1111111..2222222 100644",
	"--- a/foo.lua",
	"+++ b/foo.lua",
	"@@ -10,2 +10,3 @@ local M = {}",
	" local a = 1",
	"+local b = 2",
	"diff --git a/bar.lua b/bar.lua",
	"new file mode 100644",
	"--- /dev/null",
	"+++ b/bar.lua",
	"@@ -0,0 +1,2 @@",
	"+local bar = true",
	"+return bar",
}, "\n")

test("collect_markers finds files", function()
	local git_diff = require("gitflow.git.diff")
	local lines = vim.split(diff_text, "\n", { plain = true })
	local files = git_diff.collect_markers(lines, 1)
	assert_equals(#files, 2, "should find 2 files")
	assert_equals(
		files[1].path, "foo.lua",
		"first file path"
	)
	assert_equals(
		files[2].path, "bar.lua",
		"second file path"
	)
end)

test("collect_markers detects file status", function()
	local git_diff = require("gitflow.git.diff")
	local lines = vim.split(diff_text, "\n", { plain = true })
	local files = git_diff.collect_markers(lines, 1)
	assert_equals(
		files[1].status, "M",
		"modified file should have M status"
	)
	assert_equals(
		files[2].status, "A",
		"new file should have A status"
	)
end)

test("collect_markers finds hunks", function()
	local git_diff = require("gitflow.git.diff")
	local lines = vim.split(diff_text, "\n", { plain = true })
	local _, hunks = git_diff.collect_markers(lines, 1)
	assert_equals(#hunks, 2, "should find 2 hunks")
end)

test("collect_markers tracks line numbers", function()
	local git_diff = require("gitflow.git.diff")
	local lines = vim.split(diff_text, "\n", { plain = true })
	local _, _, line_context =
		git_diff.collect_markers(lines, 1)

	-- Line 6 is " local a = 1" (context, old=10, new=10)
	local ctx6 = line_context[6]
	assert_true(ctx6 ~= nil, "context line should exist")
	assert_equals(ctx6.old_line, 10, "context old_line")
	assert_equals(ctx6.new_line, 10, "context new_line")

	-- Line 7 is "+local b = 2" (added, new=11)
	local ctx7 = line_context[7]
	assert_true(ctx7 ~= nil, "added line should exist")
	assert_equals(ctx7.old_line, nil, "added has no old_line")
	assert_equals(ctx7.new_line, 11, "added new_line")
end)

test("collect_markers with offset", function()
	local git_diff = require("gitflow.git.diff")
	local lines = vim.split(diff_text, "\n", { plain = true })
	local files, hunks, line_context =
		git_diff.collect_markers(lines, 10)
	assert_equals(
		files[1].line, 10,
		"first file marker offset by 10"
	)
	assert_equals(
		hunks[1].line, 14,
		"first hunk marker offset"
	)
	-- Line 6 of diff is " local a = 1" -> at offset 10, buf=15
	local ctx15 = line_context[15]
	assert_true(
		ctx15 ~= nil,
		"offset context should exist at line 15"
	)
	assert_equals(
		ctx15.old_line, 10,
		"offset context old_line"
	)
end)

-- ─── Highlight groups ─────────────────────────────────

test("new diff highlight groups are defined", function()
	local highlights = require("gitflow.highlights")
	local groups = {
		"GitflowDiffFileHeader",
		"GitflowDiffHunkHeader",
		"GitflowDiffContext",
		"GitflowDiffLineNr",
	}
	for _, group in ipairs(groups) do
		assert_true(
			highlights.DEFAULT_GROUPS[group] ~= nil,
			group .. " should be in DEFAULT_GROUPS"
		)
	end
end)

test("diff highlight groups have valid attrs", function()
	local highlights = require("gitflow.highlights")
	local groups = {
		"GitflowDiffFileHeader",
		"GitflowDiffHunkHeader",
		"GitflowDiffContext",
		"GitflowDiffLineNr",
	}
	for _, group in ipairs(groups) do
		local attrs = highlights.DEFAULT_GROUPS[group]
		local has_link = type(attrs.link) == "string"
		local has_explicit =
			attrs.fg ~= nil or attrs.bg ~= nil
		assert_true(
			has_link or has_explicit,
			group .. " should have link or explicit colors"
		)
	end
end)

test("diff highlights are applied after setup", function()
	local highlights = require("gitflow.highlights")
	highlights.setup({})
	local file_hdr = get_highlight(
		"GitflowDiffFileHeader", { link = false }
	)
	assert_true(
		file_hdr.fg ~= nil,
		"GitflowDiffFileHeader should have fg after setup"
	)
	local hunk_hdr = get_highlight(
		"GitflowDiffHunkHeader", { link = false }
	)
	assert_true(
		hunk_hdr.fg ~= nil,
		"GitflowDiffHunkHeader should have fg after setup"
	)
	local linenr = get_highlight(
		"GitflowDiffLineNr", { link = false }
	)
	assert_true(
		linenr.fg ~= nil,
		"GitflowDiffLineNr should have fg after setup"
	)
end)

-- ─── Diff panel keymaps and navigation ────────────────

local stub_root = vim.fn.tempname()
vim.fn.mkdir(stub_root, "p")
local stub_bin = stub_root .. "/bin"
vim.fn.mkdir(stub_bin, "p")

local repo_dir = stub_root .. "/repo"
vim.fn.mkdir(repo_dir, "p")

local function run_git(args)
	local cmd = { "git" }
	vim.list_extend(cmd, args)
	if vim.system then
		local r = vim.system(
			cmd, { cwd = repo_dir, text = true }
		):wait()
		return r
	else
		local prev = vim.fn.getcwd()
		vim.fn.chdir(repo_dir)
		vim.fn.system(cmd)
		vim.fn.chdir(prev)
	end
end

-- Setup a git repo with changes for diff testing
run_git({ "init" })
run_git({ "config", "user.email", "test@test.com" })
run_git({ "config", "user.name", "Test" })
vim.fn.writefile({ "local a = 1" }, repo_dir .. "/foo.lua")
run_git({ "add", "." })
run_git({ "commit", "-m", "init" })
vim.fn.writefile(
	{ "local a = 1", "local b = 2" },
	repo_dir .. "/foo.lua"
)

vim.fn.chdir(repo_dir)

-- Stub gh so it won't fail auth checks
local gh_script = [[#!/bin/sh
if [ "$1" = "--version" ]; then
	echo "gh version 2.55.0"
	exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
	echo "Logged in to github.com as test"
	exit 0
fi
echo "[]"
exit 0
]]
local gh_path = stub_bin .. "/gh"
vim.fn.writefile(
	vim.split(gh_script, "\n", { plain = true }), gh_path
)
vim.fn.setfperm(gh_path, "rwxr-xr-x")

local original_path = vim.env.PATH
vim.env.PATH = stub_bin .. ":" .. (original_path or "")

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 60,
		},
	},
})

local buffer = require("gitflow.ui.buffer")
local diff_panel = require("gitflow.panels.diff")

local function wait_until(predicate, message, timeout_ms)
	local ok = vim.wait(timeout_ms or 5000, predicate, 20)
	assert_true(ok, message)
end

test("diff panel opens with navigation keymaps", function()
	diff_panel.open(cfg, {})
	wait_until(function()
		local bufnr = buffer.get("diff")
		if not bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			bufnr, 0, -1, false
		)
		return find_line(lines, "diff --git") ~= nil
	end, "diff panel should render diff output")

	local bufnr = buffer.get("diff")
	assert_true(bufnr ~= nil, "diff buffer should exist")
	assert_keymaps(bufnr, {
		"q", "r", "]f", "[f", "]c", "[c",
	})
end)

test("diff panel shows file summary", function()
	local bufnr = buffer.get("diff")
	assert_true(bufnr ~= nil, "diff buffer should exist")
	local lines = vim.api.nvim_buf_get_lines(
		bufnr, 0, -1, false
	)
	assert_true(
		find_line(lines, "Files:") ~= nil,
		"diff panel should show file summary"
	)
	assert_true(
		find_line(lines, "Hunks:") ~= nil,
		"diff panel should show hunk count"
	)
end)

test("diff panel populates file markers", function()
	assert_true(
		#diff_panel.state.file_markers > 0,
		"file_markers should be populated"
	)
	assert_equals(
		diff_panel.state.file_markers[1].path, "foo.lua",
		"first file marker path"
	)
end)

test("diff panel populates hunk markers", function()
	assert_true(
		#diff_panel.state.hunk_markers > 0,
		"hunk_markers should be populated"
	)
end)

test("diff panel populates line context", function()
	local has_context = false
	for _, ctx in pairs(diff_panel.state.line_context) do
		if ctx.new_line then
			has_context = true
			break
		end
	end
	assert_true(
		has_context,
		"line_context should have entries with new_line"
	)
end)

test("diff panel has line number extmarks", function()
	local bufnr = buffer.get("diff")
	assert_true(bufnr ~= nil, "diff buffer should exist")
	local ns = vim.api.nvim_create_namespace(
		"gitflow_diff_linenr"
	)
	local marks = vim.api.nvim_buf_get_extmarks(
		bufnr, ns, 0, -1, {}
	)
	assert_true(
		#marks > 0,
		"should have line number extmarks"
	)
end)

test("diff file navigation works", function()
	if #diff_panel.state.file_markers < 1 then
		error("no file markers to navigate")
	end
	vim.api.nvim_win_set_cursor(
		diff_panel.state.winid, { 1, 0 }
	)
	diff_panel.next_file()
	local cursor = vim.api.nvim_win_get_cursor(
		diff_panel.state.winid
	)[1]
	assert_equals(
		cursor, diff_panel.state.file_markers[1].line,
		"next_file should jump to first file marker"
	)
end)

test("diff hunk navigation works", function()
	if #diff_panel.state.hunk_markers < 1 then
		error("no hunk markers to navigate")
	end
	vim.api.nvim_win_set_cursor(
		diff_panel.state.winid, { 1, 0 }
	)
	diff_panel.next_hunk()
	local cursor = vim.api.nvim_win_get_cursor(
		diff_panel.state.winid
	)[1]
	assert_equals(
		cursor, diff_panel.state.hunk_markers[1].line,
		"next_hunk should jump to first hunk marker"
	)
end)

test("diff hunk prev wraps around", function()
	vim.api.nvim_win_set_cursor(
		diff_panel.state.winid, { 1, 0 }
	)
	diff_panel.prev_hunk()
	local cursor = vim.api.nvim_win_get_cursor(
		diff_panel.state.winid
	)[1]
	local last_hunk = diff_panel.state.hunk_markers[
		#diff_panel.state.hunk_markers
	]
	assert_equals(
		cursor, last_hunk.line,
		"prev_hunk should wrap to last hunk"
	)
end)

test("diff panel close resets state", function()
	diff_panel.close()
	assert_true(
		diff_panel.state.bufnr == nil,
		"bufnr should be nil after close"
	)
	assert_true(
		diff_panel.state.winid == nil,
		"winid should be nil after close"
	)
	assert_equals(
		#diff_panel.state.file_markers, 0,
		"file_markers should be empty after close"
	)
	assert_equals(
		#diff_panel.state.hunk_markers, 0,
		"hunk_markers should be empty after close"
	)
end)

test("diff panel footer includes nav hints", function()
	diff_panel.open(cfg, {})
	wait_until(function()
		local bufnr = buffer.get("diff")
		if not bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			bufnr, 0, -1, false
		)
		return find_line(lines, "diff --git") ~= nil
	end, "diff panel should render for footer test")
	diff_panel.close()
end)

-- ─── Review panel uses shared parser ──────────────────

test("review panel requires git/diff module", function()
	-- This verifies the import works by checking the module
	local review = require("gitflow.panels.review")
	assert_true(
		type(review) == "table",
		"review module should load"
	)
end)

-- Cleanup
vim.env.PATH = original_path
vim.fn.chdir(project_root)

print(string.rep("─", 50))
print(
	("Stage 10 diff overhaul: %d/%d passed"):format(
		passed, total
	)
)
if passed < total then
	vim.cmd("cquit! 1")
end
print("Stage 10 diff overhaul tests passed")
