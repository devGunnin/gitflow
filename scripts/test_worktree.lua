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
		local result = vim.system(
			cmd, { cwd = repo_dir, text = true }
		):wait()
		output = (result.stdout or "")
			.. (result.stderr or "")
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
		type(mapping) == "table"
			and mapping.rhs == expected_rhs,
		message
	)
end

local passed = 0
local failed = 0

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print(("  PASS: %s"):format(name))
	else
		failed = failed + 1
		print(
			("  FAIL: %s\n        %s"):format(
				name, tostring(err)
			)
		)
	end
end

print("=== Gitflow Worktree Panel Tests ===")

-- Set up a temp repo with a main branch and a feature branch
local repo_dir = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(repo_dir, "p"), 1,
	"temp repo directory should be created"
)

run_git(repo_dir, { "init", "-b", "main" })
run_git(
	repo_dir,
	{ "config", "user.email", "worktree@example.com" }
)
run_git(
	repo_dir,
	{ "config", "user.name", "Worktree Tester" }
)

write_file(repo_dir .. "/file.txt", { "line1" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "initial commit" })

-- Create a feature branch (for worktree add)
run_git(repo_dir, { "branch", "feature" })

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
})

-- ─── Module loading tests ───

test("git/worktree module loads", function()
	local git_wt = require("gitflow.git.worktree")
	assert_true(
		type(git_wt) == "table",
		"module should be a table"
	)
	assert_true(
		type(git_wt.list) == "function",
		"list should be a function"
	)
	assert_true(
		type(git_wt.add) == "function",
		"add should be a function"
	)
	assert_true(
		type(git_wt.remove) == "function",
		"remove should be a function"
	)
	assert_true(
		type(git_wt.parse) == "function",
		"parse should be a function"
	)
end)

test("panels/worktree module loads", function()
	local wt_panel = require("gitflow.panels.worktree")
	assert_true(
		type(wt_panel) == "table",
		"module should be a table"
	)
	assert_true(
		type(wt_panel.open) == "function",
		"open should be a function"
	)
	assert_true(
		type(wt_panel.close) == "function",
		"close should be a function"
	)
	assert_true(
		type(wt_panel.refresh) == "function",
		"refresh should be a function"
	)
	assert_true(
		type(wt_panel.is_open) == "function",
		"is_open should be a function"
	)
end)

-- ─── Parser tests ───

test("parse handles porcelain output", function()
	local git_wt = require("gitflow.git.worktree")
	local output = table.concat({
		"worktree /home/user/project",
		"HEAD abc1234567890abcdef1234567890abcdef1234",
		"branch refs/heads/main",
		"",
		"worktree /home/user/project-wt",
		"HEAD def5678901234abcdef1234567890abcdef5678",
		"branch refs/heads/feature",
		"",
	}, "\n")

	local entries = git_wt.parse(output)
	assert_equals(
		#entries, 2,
		"should parse 2 worktree entries"
	)
	assert_equals(
		entries[1].path, "/home/user/project",
		"first entry path"
	)
	assert_equals(
		entries[1].branch, "main",
		"first entry branch (refs/heads/ stripped)"
	)
	assert_equals(
		entries[1].short_sha, "abc1234",
		"first entry short_sha"
	)
	assert_true(
		entries[1].is_main,
		"first entry should be main worktree"
	)
	assert_equals(
		entries[2].path, "/home/user/project-wt",
		"second entry path"
	)
	assert_equals(
		entries[2].branch, "feature",
		"second entry branch"
	)
	assert_true(
		not entries[2].is_main,
		"second entry should not be main"
	)
end)

test("parse handles bare worktree", function()
	local git_wt = require("gitflow.git.worktree")
	local output = table.concat({
		"worktree /home/user/project.git",
		"HEAD abc1234567890abcdef1234567890abcdef1234",
		"bare",
		"",
	}, "\n")

	local entries = git_wt.parse(output)
	assert_equals(#entries, 1, "should parse 1 entry")
	assert_true(
		entries[1].is_bare, "entry should be bare"
	)
	assert_true(
		entries[1].branch == nil,
		"bare entry should have no branch"
	)
end)

test("parse handles detached HEAD", function()
	local git_wt = require("gitflow.git.worktree")
	local output = table.concat({
		"worktree /home/user/project-detached",
		"HEAD abc1234567890abcdef1234567890abcdef1234",
		"detached",
		"",
	}, "\n")

	local entries = git_wt.parse(output)
	assert_equals(#entries, 1, "should parse 1 entry")
	assert_true(
		entries[1].branch == nil,
		"detached entry should have no branch"
	)
end)

test("parse handles empty output", function()
	local git_wt = require("gitflow.git.worktree")
	local entries = git_wt.parse("")
	assert_equals(
		#entries, 0, "should parse 0 entries"
	)
end)

-- ─── Async git operation tests ───

test("list returns worktree entries", function()
	local git_wt = require("gitflow.git.worktree")
	local err, entries = wait_async(function(done)
		git_wt.list({}, function(e, ents)
			done(e, ents)
		end)
	end)

	assert_true(err == nil, "list should not error")
	assert_true(
		type(entries) == "table" and #entries >= 1,
		"should return at least the main worktree"
	)
	assert_true(
		entries[1].path ~= nil and entries[1].path ~= "",
		"first entry should have a path"
	)
	assert_true(
		entries[1].is_main,
		"first entry should be the main worktree"
	)
end)

test("add creates a new worktree", function()
	local git_wt = require("gitflow.git.worktree")
	local wt_path = repo_dir .. "/wt-test"

	local err = wait_async(function(done)
		git_wt.add(wt_path, "feature", function(e, _)
			done(e)
		end)
	end)

	assert_true(
		err == nil,
		"add should not error: " .. tostring(err)
	)

	-- Verify the worktree was created
	local _, list_entries = wait_async(function(done)
		git_wt.list({}, function(e, ents)
			done(e, ents)
		end)
	end)

	local found = false
	for _, entry in ipairs(list_entries or {}) do
		if entry.path:find("wt%-test", 1, false) then
			found = true
			break
		end
	end
	assert_true(
		found, "newly added worktree should appear"
	)
end)

test("remove deletes a worktree", function()
	local git_wt = require("gitflow.git.worktree")
	local wt_path = repo_dir .. "/wt-test"

	local err = wait_async(function(done)
		git_wt.remove(wt_path, function(e, _)
			done(e)
		end)
	end)

	assert_true(
		err == nil,
		"remove should not error: " .. tostring(err)
	)

	-- Verify the worktree was removed
	local _, list_entries = wait_async(function(done)
		git_wt.list({}, function(e, ents)
			done(e, ents)
		end)
	end)

	local found = false
	for _, entry in ipairs(list_entries or {}) do
		if entry.path:find("wt%-test", 1, false) then
			found = true
			break
		end
	end
	assert_true(
		not found,
		"removed worktree should not appear"
	)
end)

-- ─── Subcommand registration tests ───

test("worktree subcommand is registered", function()
	local commands = require("gitflow.commands")
	local all = commands.complete("")
	assert_true(
		contains(all, "worktree"),
		"worktree should appear in completions"
	)
end)

test("worktree subcommand has description", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands.worktree ~= nil,
		"worktree subcommand should exist"
	)
	assert_equals(
		commands.subcommands.worktree.description,
		"Open git worktree panel",
		"worktree description should match"
	)
end)

-- ─── Keybinding tests ───

test("default worktree keybinding is gW", function()
	assert_equals(
		cfg.keybindings.worktree, "gW",
		"default worktree keybinding should be gW"
	)
end)

test("GitflowWorktree plug mapping exists", function()
	assert_mapping(
		"<Plug>(GitflowWorktree)",
		"<Cmd>Gitflow worktree<CR>",
		"worktree plug keymap should exist"
	)
end)

test("gW maps to plug", function()
	assert_mapping(
		cfg.keybindings.worktree,
		"<Plug>(GitflowWorktree)",
		"gW should map to <Plug>(GitflowWorktree)"
	)
end)

-- ─── Highlight group tests ───

test("GitflowWorktreeActive highlight defined", function()
	local hl = require("gitflow.highlights")
	assert_true(
		hl.DEFAULT_GROUPS.GitflowWorktreeActive ~= nil,
		"GitflowWorktreeActive should exist"
	)
end)

test("GitflowWorktreePath highlight defined", function()
	local hl = require("gitflow.highlights")
	assert_true(
		hl.DEFAULT_GROUPS.GitflowWorktreePath ~= nil,
		"GitflowWorktreePath should exist"
	)
end)

test("worktree highlights applied after setup", function()
	local active_hl = vim.api.nvim_get_hl(
		0, { name = "GitflowWorktreeActive" }
	)
	assert_true(
		active_hl ~= nil and next(active_hl) ~= nil,
		"GitflowWorktreeActive should be applied"
	)
	local path_hl = vim.api.nvim_get_hl(
		0, { name = "GitflowWorktreePath" }
	)
	assert_true(
		path_hl ~= nil and next(path_hl) ~= nil,
		"GitflowWorktreePath should be applied"
	)
end)

-- ─── Panel lifecycle tests ───

test("worktree panel opens and shows entries", function()
	local wt_panel = require("gitflow.panels.worktree")
	wt_panel.open(cfg)

	vim.wait(2000, function()
		if not wt_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(
			wt_panel.state.bufnr
		) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			wt_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1
			and not lines[1]:find("Loading", 1, true)
	end, 50)

	assert_true(
		wt_panel.is_open(),
		"worktree panel should be open"
	)
	assert_true(
		wt_panel.state.bufnr ~= nil,
		"bufnr should be set"
	)
	assert_true(
		wt_panel.state.winid ~= nil,
		"winid should be set"
	)

	local lines = vim.api.nvim_buf_get_lines(
		wt_panel.state.bufnr, 0, -1, false
	)
	assert_true(
		#lines > 2,
		"should have rendered worktree lines"
	)

	-- Check that at least one line mentions the repo dir
	local has_path = false
	for _, line in ipairs(lines) do
		if line:find(repo_dir, 1, true) then
			has_path = true
			break
		end
	end
	assert_true(
		has_path,
		"should contain worktree path in output"
	)

	wt_panel.close()
end)

test("worktree panel keymaps are set", function()
	local wt_panel = require("gitflow.panels.worktree")
	wt_panel.open(cfg)

	vim.wait(1000, function()
		return wt_panel.state.bufnr ~= nil
			and vim.api.nvim_buf_is_valid(
				wt_panel.state.bufnr
			)
	end, 50)

	local bufnr = wt_panel.state.bufnr
	assert_true(bufnr ~= nil, "bufnr should exist")

	local keymaps = vim.api.nvim_buf_get_keymap(
		bufnr, "n"
	)
	local found = {}
	for _, km in ipairs(keymaps) do
		found[km.lhs] = true
	end

	assert_true(
		found["<CR>"] ~= nil, "CR keymap should be set"
	)
	assert_true(
		found["a"] ~= nil, "a keymap should be set"
	)
	assert_true(
		found["d"] ~= nil, "d keymap should be set"
	)
	assert_true(
		found["r"] ~= nil, "r keymap should be set"
	)
	assert_true(
		found["q"] ~= nil, "q keymap should be set"
	)

	wt_panel.close()
end)

test("worktree panel close cleans up state", function()
	local wt_panel = require("gitflow.panels.worktree")
	wt_panel.open(cfg)

	vim.wait(500, function()
		return wt_panel.state.bufnr ~= nil
	end, 50)

	wt_panel.close()

	assert_true(
		wt_panel.state.bufnr == nil,
		"bufnr should be nil after close"
	)
	assert_true(
		wt_panel.state.winid == nil,
		"winid should be nil after close"
	)
	assert_true(
		not wt_panel.is_open(),
		"is_open should return false"
	)
end)

test("line_entries populated after render", function()
	local wt_panel = require("gitflow.panels.worktree")
	wt_panel.open(cfg)

	vim.wait(2000, function()
		if not wt_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			wt_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1
			and not lines[1]:find("Loading", 1, true)
	end, 50)

	local count = 0
	for _ in pairs(wt_panel.state.line_entries) do
		count = count + 1
	end
	assert_true(
		count >= 1,
		"should have at least 1 worktree entry"
	)

	wt_panel.close()
end)

test("dispatch worktree returns message", function()
	local commands = require("gitflow.commands")
	local result = commands.dispatch({ "worktree" }, cfg)
	assert_true(
		type(result) == "string",
		"dispatch should return a string"
	)

	local wt_panel = require("gitflow.panels.worktree")
	vim.wait(500, function()
		return wt_panel.state.bufnr ~= nil
	end, 50)
	wt_panel.close()
end)

test("config validation accepts worktree key", function()
	local config = require("gitflow.config")
	local test_cfg = config.defaults()
	test_cfg.keybindings.worktree = "gW"
	local ok = pcall(config.validate, test_cfg)
	assert_true(
		ok,
		"config validation should pass with worktree"
	)
end)

-- ─── Cleanup ───

vim.fn.chdir(original_cwd)
vim.fn.delete(repo_dir, "rf")

print(
	("=== Results: %d passed, %d failed ==="):format(
		passed, failed
	)
)
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
