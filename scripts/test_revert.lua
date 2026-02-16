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

print("=== Gitflow Revert Panel Tests ===")

-- Set up a temp repo with multiple commits and a main branch
local repo_dir = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(repo_dir, "p"), 1,
	"temp repo directory should be created"
)

run_git(repo_dir, { "init", "-b", "main" })
run_git(repo_dir, { "config", "user.email", "revert@example.com" })
run_git(repo_dir, { "config", "user.name", "Revert Tester" })

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

test("git/revert module loads successfully", function()
	local git_revert = require("gitflow.git.revert")
	assert_true(type(git_revert) == "table", "module should be a table")
	assert_true(
		type(git_revert.list_commits) == "function",
		"list_commits should be a function"
	)
	assert_true(
		type(git_revert.find_merge_base) == "function",
		"find_merge_base should be a function"
	)
	assert_true(
		type(git_revert.revert) == "function",
		"revert should be a function"
	)
end)

test("panels/revert module loads successfully", function()
	local revert_panel = require("gitflow.panels.revert")
	assert_true(type(revert_panel) == "table", "module should be a table")
	assert_true(
		type(revert_panel.open) == "function",
		"open should be a function"
	)
	assert_true(
		type(revert_panel.close) == "function",
		"close should be a function"
	)
	assert_true(
		type(revert_panel.refresh) == "function",
		"refresh should be a function"
	)
	assert_true(
		type(revert_panel.is_open) == "function",
		"is_open should be a function"
	)
	assert_true(
		type(revert_panel.select_under_cursor) == "function",
		"select_under_cursor should be a function"
	)
	assert_true(
		type(revert_panel.select_by_position) == "function",
		"select_by_position should be a function"
	)
end)

-- ─── Subcommand registration tests ───

test("revert subcommand is registered", function()
	local commands = require("gitflow.commands")
	local all = commands.complete("")
	assert_true(
		contains(all, "revert"),
		"revert should appear in subcommand completions"
	)
end)

test("revert subcommand has correct description", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands.revert ~= nil,
		"revert subcommand should exist"
	)
	assert_equals(
		commands.subcommands.revert.description,
		"Open git revert panel",
		"revert subcommand description should match"
	)
end)

-- ─── Keybinding tests ───

test("default revert keybinding is gV", function()
	assert_equals(
		cfg.keybindings.revert, "gV",
		"default revert keybinding should be gV"
	)
end)

test("GitflowRevert plug mapping is registered", function()
	assert_mapping(
		"<Plug>(GitflowRevert)",
		"<Cmd>Gitflow revert<CR>",
		"revert plug keymap should be registered"
	)
end)

test("default revert keymap maps to plug", function()
	assert_mapping(
		cfg.keybindings.revert,
		"<Plug>(GitflowRevert)",
		"gV should map to <Plug>(GitflowRevert)"
	)
end)

-- ─── Highlight group tests ───

test("GitflowRevertMergeBase highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRevertMergeBase ~= nil,
		"GitflowRevertMergeBase should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowRevertMergeBase.link,
		"WarningMsg",
		"GitflowRevertMergeBase should link to WarningMsg"
	)
end)

test("GitflowRevertMergeBase highlight is applied after setup", function()
	local hl = vim.api.nvim_get_hl(0, { name = "GitflowRevertMergeBase" })
	assert_true(
		hl ~= nil and (hl.link ~= nil or next(hl) ~= nil),
		"GitflowRevertMergeBase highlight should be applied"
	)
end)

-- ─── Icon tests ───

test("revert icon is registered in palette category", function()
	local icons_mod = require("gitflow.icons")
	local icon = icons_mod.get("palette", "revert")
	assert_true(
		icon ~= nil and icon ~= "",
		"revert icon should be available in palette category"
	)
end)

-- ─── Git operation tests ───

test("list_commits returns commit entries", function()
	local git_revert = require("gitflow.git.revert")
	local err, entries = wait_async(function(done)
		git_revert.list_commits({ count = 10 }, function(e, ents)
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
	local git_revert = require("gitflow.git.revert")
	local err, sha = wait_async(function(done)
		git_revert.find_merge_base({}, function(e, s)
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

test("revert panel opens and shows commits", function()
	local revert_panel = require("gitflow.panels.revert")
	revert_panel.open(cfg)

	vim.wait(2000, function()
		if not revert_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(revert_panel.state.bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			revert_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	assert_true(revert_panel.is_open(), "revert panel should be open")
	assert_true(
		revert_panel.state.bufnr ~= nil,
		"bufnr should be set"
	)
	assert_true(
		revert_panel.state.winid ~= nil,
		"winid should be set"
	)

	local lines = vim.api.nvim_buf_get_lines(
		revert_panel.state.bufnr, 0, -1, false
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

	revert_panel.close()
end)

test("revert panel keymaps are set on buffer", function()
	local revert_panel = require("gitflow.panels.revert")
	revert_panel.open(cfg)

	vim.wait(1000, function()
		return revert_panel.state.bufnr ~= nil
			and vim.api.nvim_buf_is_valid(revert_panel.state.bufnr)
	end, 50)

	local bufnr = revert_panel.state.bufnr
	assert_true(bufnr ~= nil, "bufnr should exist")

	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local found_keys = {}
	for _, km in ipairs(keymaps) do
		found_keys[km.lhs] = true
	end

	assert_true(found_keys["<CR>"] ~= nil, "CR keymap should be set")
	assert_true(found_keys["r"] ~= nil, "r keymap should be set")
	assert_true(found_keys["q"] ~= nil, "q keymap should be set")
	assert_true(found_keys["1"] ~= nil, "1 keymap should be set")
	assert_true(found_keys["9"] ~= nil, "9 keymap should be set")

	revert_panel.close()
end)

test("revert panel close cleans up state", function()
	local revert_panel = require("gitflow.panels.revert")
	revert_panel.open(cfg)

	vim.wait(500, function()
		return revert_panel.state.bufnr ~= nil
	end, 50)

	revert_panel.close()

	assert_true(
		revert_panel.state.bufnr == nil,
		"bufnr should be nil after close"
	)
	assert_true(
		revert_panel.state.winid == nil,
		"winid should be nil after close"
	)
	assert_true(
		not revert_panel.is_open(),
		"is_open should return false after close"
	)
end)

test("merge-base commit is highlighted", function()
	local revert_panel = require("gitflow.panels.revert")
	revert_panel.open(cfg)

	vim.wait(2000, function()
		if not revert_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(revert_panel.state.bufnr) then
			return false
		end
		return revert_panel.state.merge_base_sha ~= nil
	end, 50)

	assert_true(
		revert_panel.state.merge_base_sha ~= nil,
		"merge_base_sha should be set after render"
	)

	-- Check that highlight extmarks were applied
	local bufnr = revert_panel.state.bufnr
	local ns = vim.api.nvim_create_namespace("gitflow_revert_hl")
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
		if details and details.hl_group == "GitflowRevertMergeBase" then
			has_merge_base_hl = true
			break
		end
	end
	assert_true(
		has_merge_base_hl,
		"GitflowRevertMergeBase highlight should be applied to"
			.. " the merge-base line"
	)

	revert_panel.close()
end)

test("position numbers are rendered for first 9 commits", function()
	local revert_panel = require("gitflow.panels.revert")
	revert_panel.open(cfg)

	vim.wait(2000, function()
		if not revert_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(revert_panel.state.bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			revert_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local lines = vim.api.nvim_buf_get_lines(
		revert_panel.state.bufnr, 0, -1, false
	)

	local has_numbered = false
	for _, line in ipairs(lines) do
		if line:find("%[1%]", 1, false) then
			has_numbered = true
			break
		end
	end
	assert_true(
		has_numbered,
		"first commit should have [1] position marker"
	)

	revert_panel.close()
end)

test("line_entries map is populated after render", function()
	local revert_panel = require("gitflow.panels.revert")
	revert_panel.open(cfg)

	vim.wait(2000, function()
		if not revert_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			revert_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local entry_count = 0
	for _ in pairs(revert_panel.state.line_entries) do
		entry_count = entry_count + 1
	end
	assert_true(
		entry_count >= 4,
		"should have at least 4 commit entries in line_entries"
	)

	revert_panel.close()
end)

test("git revert executes successfully", function()
	-- Get current HEAD
	local head_sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD" })
	)

	local git_revert = require("gitflow.git.revert")
	local err = wait_async(function(done)
		git_revert.revert(head_sha, function(e, _)
			done(e)
		end)
	end)

	assert_true(err == nil, "revert should not error")

	-- Verify a new commit was created (HEAD moved forward)
	local new_head = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD" })
	)
	assert_true(
		new_head ~= head_sha,
		"HEAD should have moved to a new revert commit"
	)

	-- Verify the revert commit message
	local log_msg = vim.trim(
		run_git(repo_dir, { "log", "-1", "--format=%s" })
	)
	assert_true(
		log_msg:find("Revert", 1, true) ~= nil,
		"revert commit message should contain 'Revert'"
	)

	-- Restore original HEAD for subsequent tests
	run_git(repo_dir, { "reset", "--hard", head_sha })
end)

test("config validation accepts revert keybinding", function()
	local config = require("gitflow.config")
	local test_cfg = config.defaults()
	test_cfg.keybindings.revert = "gV"
	local ok = pcall(config.validate, test_cfg)
	assert_true(ok, "config validation should pass with revert keybinding")
end)

test("dispatch revert subcommand returns expected message", function()
	local commands = require("gitflow.commands")
	local result = commands.dispatch({ "revert" }, cfg)
	-- The panel opens asynchronously, but dispatch returns a message
	assert_true(
		type(result) == "string",
		"dispatch should return a string"
	)

	-- Clean up the panel
	local revert_panel = require("gitflow.panels.revert")
	vim.wait(500, function()
		return revert_panel.state.bufnr ~= nil
	end, 50)
	revert_panel.close()
end)

-- ─── Cleanup ───

vim.fn.chdir(original_cwd)
vim.fn.delete(repo_dir, "rf")

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
