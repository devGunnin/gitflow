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

local unpack_fn = table.unpack or unpack

local function wait_async(start, timeout_ms)
	local done = false
	local result = nil

	start(function(...)
		result = { ... }
		done = true
	end)

	local ok = vim.wait(timeout_ms or 5000, function()
		return done
	end, 10)
	assert_true(ok, "async callback timed out")
	return unpack_fn(result)
end

local function run_git(repo_dir, args, should_succeed)
	local cmd = { "git" }
	vim.list_extend(cmd, args)
	local output = ""
	local code = 1

	if vim.system then
		local result = vim.system(cmd, { cwd = repo_dir, text = true }):wait()
		output = (result.stdout or "") .. (result.stderr or "")
		code = result.code or 1
	else
		local previous = vim.fn.getcwd()
		vim.fn.chdir(repo_dir)
		output = vim.fn.system(cmd)
		code = vim.v.shell_error
		vim.fn.chdir(previous)
	end
	if should_succeed == nil then
		should_succeed = true
	end
	if should_succeed and code ~= 0 then
		error(
			("git command failed (%s): %s"):format(
				table.concat(cmd, " "), output
			),
			2
		)
	end
	return output, code
end

local function write_file(path, lines)
	vim.fn.writefile(lines, path)
end

local function assert_mapping(lhs, expected_rhs, message)
	local mapping = vim.fn.maparg(lhs, "n", false, true)
	assert_true(
		type(mapping) == "table" and mapping.rhs == expected_rhs, message
	)
end

local passed = 0
local failed = 0
local test_name = ""

local function test(name, fn)
	test_name = name
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print(("  PASS: %s"):format(name))
	else
		failed = failed + 1
		print(("  FAIL: %s\n        %s"):format(name, tostring(err)))
	end
end

print("=== Gitflow Reset Panel Tests ===")

-- Set up a temp repo with multiple commits and a main branch
local repo_dir = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(repo_dir, "p"), 1,
	"temp repo directory should be created"
)

run_git(repo_dir, { "init", "-b", "main" })
run_git(repo_dir, { "config", "user.email", "reset@example.com" })
run_git(repo_dir, { "config", "user.name", "Reset Tester" })

write_file(repo_dir .. "/file.txt", { "line1" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "initial commit" })

write_file(repo_dir .. "/file.txt", { "line1", "line2" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "second commit" })

-- Create a feature branch with additional commits
run_git(repo_dir, { "checkout", "-b", "feature" })

write_file(repo_dir .. "/file.txt", { "line1", "line2", "line3" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "feature commit 1" })

write_file(repo_dir .. "/file.txt", { "line1", "line2", "line3", "line4" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "feature commit 2" })

local original_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 45,
		},
	},
	git = {
		log = {
			count = 25,
			format = "%h %s",
		},
	},
})

-- ─── Module loading tests ───

test("git/reset module loads successfully", function()
	local git_reset = require("gitflow.git.reset")
	assert_true(type(git_reset) == "table", "module should be a table")
	assert_true(
		type(git_reset.list_commits) == "function",
		"list_commits should be a function"
	)
	assert_true(
		type(git_reset.find_merge_base) == "function",
		"find_merge_base should be a function"
	)
	assert_true(
		type(git_reset.reset) == "function",
		"reset should be a function"
	)
end)

test("panels/reset module loads successfully", function()
	local reset_panel = require("gitflow.panels.reset")
	assert_true(type(reset_panel) == "table", "module should be a table")
	assert_true(
		type(reset_panel.open) == "function",
		"open should be a function"
	)
	assert_true(
		type(reset_panel.close) == "function",
		"close should be a function"
	)
	assert_true(
		type(reset_panel.refresh) == "function",
		"refresh should be a function"
	)
	assert_true(
		type(reset_panel.is_open) == "function",
		"is_open should be a function"
	)
	assert_true(
		type(reset_panel.select_under_cursor) == "function",
		"select_under_cursor should be a function"
	)
	assert_true(
		type(reset_panel.select_by_position) == "function",
		"select_by_position should be a function"
	)
	assert_true(
		type(reset_panel.reset_under_cursor) == "function",
		"reset_under_cursor should be a function"
	)
end)

-- ─── Subcommand registration tests ───

test("reset subcommand is registered", function()
	local commands = require("gitflow.commands")
	local all = commands.complete("")
	assert_true(
		contains(all, "reset"),
		"reset should appear in subcommand completions"
	)
end)

test("reset subcommand has correct description", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands.reset ~= nil,
		"reset subcommand should exist"
	)
	assert_equals(
		commands.subcommands.reset.description,
		"Open git reset panel",
		"reset subcommand description should match"
	)
end)

-- ─── Keybinding tests ───

test("default reset keybinding is gR", function()
	assert_equals(
		cfg.keybindings.reset, "gR",
		"default reset keybinding should be gR"
	)
end)

test("GitflowReset plug mapping is registered", function()
	assert_mapping(
		"<Plug>(GitflowReset)",
		"<Cmd>Gitflow reset<CR>",
		"reset plug keymap should be registered"
	)
end)

test("default reset keymap maps to plug", function()
	assert_mapping(
		cfg.keybindings.reset,
		"<Plug>(GitflowReset)",
		"gR should map to <Plug>(GitflowReset)"
	)
end)

-- ─── Highlight group tests ───

test("GitflowResetMergeBase highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowResetMergeBase ~= nil,
		"GitflowResetMergeBase should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowResetMergeBase.link,
		"WarningMsg",
		"GitflowResetMergeBase should link to WarningMsg"
	)
end)

test("GitflowResetMergeBase highlight is applied after setup", function()
	local hl = vim.api.nvim_get_hl(0, { name = "GitflowResetMergeBase" })
	assert_true(
		hl ~= nil and (hl.link ~= nil or next(hl) ~= nil),
		"GitflowResetMergeBase highlight should be applied"
	)
end)

-- ─── Icon tests ───

test("reset icon is registered in palette category", function()
	local icons_mod = require("gitflow.icons")
	local icon = icons_mod.get("palette", "reset")
	assert_true(
		icon ~= nil and icon ~= "",
		"reset icon should be available in palette category"
	)
end)

-- ─── Git operation tests ───

test("list_commits returns commit entries", function()
	local git_reset = require("gitflow.git.reset")
	local err, entries = wait_async(function(done)
		git_reset.list_commits({ count = 10 }, function(e, ents)
			done(e, ents)
		end)
	end)

	assert_true(err == nil, "list_commits should not error")
	assert_true(
		type(entries) == "table" and #entries > 0,
		"should return at least one entry"
	)
	assert_true(
		entries[1].sha ~= nil and entries[1].sha ~= "",
		"entry should have a sha"
	)
	assert_true(
		entries[1].short_sha ~= nil and entries[1].short_sha ~= "",
		"entry should have a short_sha"
	)
	assert_true(
		entries[1].summary ~= nil and entries[1].summary ~= "",
		"entry should have a summary"
	)
end)

test("find_merge_base returns SHA on diverged branch", function()
	local git_reset = require("gitflow.git.reset")
	local err, sha = wait_async(function(done)
		git_reset.find_merge_base({}, function(e, s)
			done(e, s)
		end)
	end)

	assert_true(err == nil, "find_merge_base should not error")
	assert_true(
		type(sha) == "string" and #sha > 0,
		"merge-base SHA should be a non-empty string"
	)
end)

-- ─── Panel lifecycle tests ───

test("reset panel opens and shows commits", function()
	local reset_panel = require("gitflow.panels.reset")
	reset_panel.open(cfg)

	vim.wait(2000, function()
		if not reset_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(reset_panel.state.bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			reset_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	assert_true(reset_panel.is_open(), "reset panel should be open")
	assert_true(
		reset_panel.state.bufnr ~= nil,
		"bufnr should be set"
	)
	assert_true(
		reset_panel.state.winid ~= nil,
		"winid should be set"
	)

	local lines = vim.api.nvim_buf_get_lines(
		reset_panel.state.bufnr, 0, -1, false
	)
	assert_true(#lines > 2, "should have rendered commit lines")

	-- Check that at least one line has a commit entry marker
	local has_entry = false
	for _, line in ipairs(lines) do
		if line:find("feature commit", 1, true) then
			has_entry = true
			break
		end
	end
	assert_true(has_entry, "should contain a commit summary line")

	reset_panel.close()
end)

test("reset panel keymaps are set on buffer", function()
	local reset_panel = require("gitflow.panels.reset")
	reset_panel.open(cfg)

	vim.wait(1000, function()
		return reset_panel.state.bufnr ~= nil
			and vim.api.nvim_buf_is_valid(reset_panel.state.bufnr)
	end, 50)

	local bufnr = reset_panel.state.bufnr
	assert_true(bufnr ~= nil, "bufnr should exist")

	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local found_keys = {}
	for _, km in ipairs(keymaps) do
		found_keys[km.lhs] = true
	end

	assert_true(found_keys["<CR>"] ~= nil, "CR keymap should be set")
	assert_true(found_keys["r"] ~= nil, "r keymap should be set")
	assert_true(found_keys["q"] ~= nil, "q keymap should be set")
	assert_true(found_keys["S"] ~= nil, "S keymap should be set")
	assert_true(found_keys["H"] ~= nil, "H keymap should be set")
	assert_true(found_keys["1"] ~= nil, "1 keymap should be set")
	assert_true(found_keys["9"] ~= nil, "9 keymap should be set")

	reset_panel.close()
end)

test("reset panel close cleans up state", function()
	local reset_panel = require("gitflow.panels.reset")
	reset_panel.open(cfg)

	vim.wait(500, function()
		return reset_panel.state.bufnr ~= nil
	end, 50)

	reset_panel.close()

	assert_true(
		reset_panel.state.bufnr == nil,
		"bufnr should be nil after close"
	)
	assert_true(
		reset_panel.state.winid == nil,
		"winid should be nil after close"
	)
	assert_true(
		not reset_panel.is_open(),
		"is_open should return false after close"
	)
end)

test("merge-base commit is highlighted", function()
	local reset_panel = require("gitflow.panels.reset")
	reset_panel.open(cfg)

	vim.wait(2000, function()
		if not reset_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(reset_panel.state.bufnr) then
			return false
		end
		return reset_panel.state.merge_base_sha ~= nil
	end, 50)

	assert_true(
		reset_panel.state.merge_base_sha ~= nil,
		"merge_base_sha should be set after render"
	)

	-- Check that highlight extmarks were applied
	local bufnr = reset_panel.state.bufnr
	local ns = vim.api.nvim_create_namespace("gitflow_reset_hl")
	local extmarks = vim.api.nvim_buf_get_extmarks(
		bufnr, ns, 0, -1, { details = true }
	)
	assert_true(
		#extmarks > 0,
		"should have highlight extmarks applied"
	)

	-- Look for the merge-base highlight specifically
	local has_merge_base_hl = false
	for _, mark in ipairs(extmarks) do
		local details = mark[4]
		if details and details.hl_group == "GitflowResetMergeBase" then
			has_merge_base_hl = true
			break
		end
	end
	assert_true(
		has_merge_base_hl,
		"GitflowResetMergeBase highlight should be applied to"
			.. " the merge-base line"
	)

	reset_panel.close()
end)

test("HEAD has no position number, [1] is on HEAD~1", function()
	local reset_panel = require("gitflow.panels.reset")
	reset_panel.open(cfg)

	vim.wait(2000, function()
		if not reset_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(reset_panel.state.bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			reset_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local lines = vim.api.nvim_buf_get_lines(
		reset_panel.state.bufnr, 0, -1, false
	)

	-- Find the first commit line (HEAD) and the second commit line (HEAD~1)
	local commit_lines = {}
	for _, line in ipairs(lines) do
		if line:find("feature commit", 1, true)
			or line:find("second commit", 1, true)
			or line:find("initial commit", 1, true)
		then
			commit_lines[#commit_lines + 1] = line
		end
	end

	assert_true(
		#commit_lines >= 2,
		"should have at least 2 commit lines"
	)

	-- HEAD (first commit line) should NOT have a [N] marker
	assert_true(
		not commit_lines[1]:find("%[%d%]"),
		"HEAD commit should not have a position number"
	)

	-- HEAD~1 (second commit line) should have [1]
	assert_true(
		commit_lines[2]:find("%[1%]", 1, false) ~= nil,
		"HEAD~1 commit should have [1] position marker"
	)

	reset_panel.close()
end)

test("line_entries map is populated after render", function()
	local reset_panel = require("gitflow.panels.reset")
	reset_panel.open(cfg)

	vim.wait(2000, function()
		if not reset_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			reset_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local entry_count = 0
	for _ in pairs(reset_panel.state.line_entries) do
		entry_count = entry_count + 1
	end
	assert_true(
		entry_count >= 4,
		"should have at least 4 commit entries in line_entries"
	)

	reset_panel.close()
end)

test("git reset --soft executes successfully", function()
	-- Get current HEAD
	local head_sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD" })
	)
	local parent_sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD~1" })
	)

	local git_reset = require("gitflow.git.reset")
	local err = wait_async(function(done)
		git_reset.reset(parent_sha, "soft", function(e, _)
			done(e)
		end)
	end)

	assert_true(err == nil, "soft reset should not error")

	-- Verify HEAD moved
	local new_head = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD" })
	)
	assert_equals(
		new_head, parent_sha,
		"HEAD should point to the parent commit after soft reset"
	)

	-- Restore original HEAD for subsequent tests
	run_git(repo_dir, { "reset", "--hard", head_sha })
end)

test("git reset --hard executes successfully", function()
	local head_sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD" })
	)
	local parent_sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD~1" })
	)

	local git_reset = require("gitflow.git.reset")
	local err = wait_async(function(done)
		git_reset.reset(parent_sha, "hard", function(e, _)
			done(e)
		end)
	end)

	assert_true(err == nil, "hard reset should not error")

	local new_head = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD" })
	)
	assert_equals(
		new_head, parent_sha,
		"HEAD should point to the parent commit after hard reset"
	)

	-- Restore
	run_git(repo_dir, { "reset", "--hard", head_sha })
end)

test("config validation accepts reset keybinding", function()
	local config = require("gitflow.config")
	local test_cfg = config.defaults()
	test_cfg.keybindings.reset = "gR"
	local ok = pcall(config.validate, test_cfg)
	assert_true(ok, "config validation should pass with reset keybinding")
end)

test("dispatch reset subcommand returns expected message", function()
	local commands = require("gitflow.commands")
	local result = commands.dispatch({ "reset" }, cfg)
	-- The panel opens asynchronously, but dispatch returns a message
	assert_true(
		type(result) == "string",
		"dispatch should return a string"
	)

	-- Clean up the panel
	local reset_panel = require("gitflow.panels.reset")
	vim.wait(500, function()
		return reset_panel.state.bufnr ~= nil
	end, 50)
	reset_panel.close()
end)

-- ─── Cleanup ───

vim.fn.chdir(original_cwd)
vim.fn.delete(repo_dir, "rf")

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
