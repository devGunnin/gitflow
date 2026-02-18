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

print("=== Gitflow Bisect Panel Tests ===")

-- Set up a temp repo with multiple commits for bisect testing
local repo_dir = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(repo_dir, "p"), 1,
	"temp repo directory should be created"
)

run_git(repo_dir, { "init", "-b", "main" })
run_git(repo_dir, { "config", "user.email", "bisect@example.com" })
run_git(repo_dir, { "config", "user.name", "Bisect Tester" })

-- Create a series of commits so bisect has something to work with
write_file(repo_dir .. "/file.txt", { "version 1" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "initial commit (good)" })

write_file(repo_dir .. "/file.txt", { "version 2" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "second commit" })

write_file(repo_dir .. "/file.txt", { "version 3 - bug introduced" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "third commit (bug)" })

write_file(repo_dir .. "/file.txt", { "version 4 - still broken" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "fourth commit" })

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

test("git/bisect module loads successfully", function()
	local git_bisect = require("gitflow.git.bisect")
	assert_true(type(git_bisect) == "table", "module should be a table")
	assert_true(
		type(git_bisect.list_commits) == "function",
		"list_commits should be a function"
	)
	assert_true(
		type(git_bisect.start) == "function",
		"start should be a function"
	)
	assert_true(
		type(git_bisect.good) == "function",
		"good should be a function"
	)
	assert_true(
		type(git_bisect.bad) == "function",
		"bad should be a function"
	)
	assert_true(
		type(git_bisect.reset_bisect) == "function",
		"reset_bisect should be a function"
	)
	assert_true(
		type(git_bisect.run) == "function",
		"run should be a function"
	)
	assert_true(
		type(git_bisect.is_bisecting) == "function",
		"is_bisecting should be a function"
	)
	assert_true(
		type(git_bisect.parse_first_bad) == "function",
		"parse_first_bad should be a function"
	)
end)

test("panels/bisect module loads successfully", function()
	local bisect_panel = require("gitflow.panels.bisect")
	assert_true(type(bisect_panel) == "table", "module should be a table")
	assert_true(
		type(bisect_panel.open) == "function",
		"open should be a function"
	)
	assert_true(
		type(bisect_panel.close) == "function",
		"close should be a function"
	)
	assert_true(
		type(bisect_panel.refresh) == "function",
		"refresh should be a function"
	)
	assert_true(
		type(bisect_panel.is_open) == "function",
		"is_open should be a function"
	)
	assert_true(
		type(bisect_panel.select_under_cursor) == "function",
		"select_under_cursor should be a function"
	)
	assert_true(
		type(bisect_panel.select_by_position) == "function",
		"select_by_position should be a function"
	)
	assert_true(
		type(bisect_panel.mark_good) == "function",
		"mark_good should be a function"
	)
	assert_true(
		type(bisect_panel.mark_bad) == "function",
		"mark_bad should be a function"
	)
	assert_true(
		type(bisect_panel.reset_bisect) == "function",
		"reset_bisect should be a function"
	)
end)

-- ─── Subcommand registration tests ───

test("bisect subcommand is registered", function()
	local commands = require("gitflow.commands")
	local all = commands.complete("")
	assert_true(
		contains(all, "bisect"),
		"bisect should appear in subcommand completions"
	)
end)

test("bisect subcommand has correct description", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands.bisect ~= nil,
		"bisect subcommand should exist"
	)
	assert_equals(
		commands.subcommands.bisect.description,
		"Open git bisect panel",
		"bisect subcommand description should match"
	)
end)

-- ─── Keybinding tests ───

test("default bisect keybinding is gI", function()
	assert_equals(
		cfg.keybindings.bisect, "gI",
		"default bisect keybinding should be gI"
	)
end)

test("GitflowBisect plug mapping is registered", function()
	assert_mapping(
		"<Plug>(GitflowBisect)",
		"<Cmd>Gitflow bisect<CR>",
		"bisect plug keymap should be registered"
	)
end)

test("default bisect keymap maps to plug", function()
	assert_mapping(
		cfg.keybindings.bisect,
		"<Plug>(GitflowBisect)",
		"gI should map to <Plug>(GitflowBisect)"
	)
end)

-- ─── Highlight group tests ───

test("GitflowBisectBad highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowBisectBad ~= nil,
		"GitflowBisectBad should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowBisectBad.link,
		"DiagnosticError",
		"GitflowBisectBad should link to DiagnosticError"
	)
end)

test("GitflowBisectGood highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowBisectGood ~= nil,
		"GitflowBisectGood should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowBisectGood.link,
		"DiagnosticOk",
		"GitflowBisectGood should link to DiagnosticOk"
	)
end)

test("GitflowBisectCurrent highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowBisectCurrent ~= nil,
		"GitflowBisectCurrent should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowBisectCurrent.link,
		"WarningMsg",
		"GitflowBisectCurrent should link to WarningMsg"
	)
end)

test("GitflowBisectBad highlight is applied after setup", function()
	local hl = vim.api.nvim_get_hl(0, { name = "GitflowBisectBad" })
	assert_true(
		hl ~= nil and (hl.link ~= nil or next(hl) ~= nil),
		"GitflowBisectBad highlight should be applied"
	)
end)

-- ─── Icon tests ───

test("bisect icon is registered in palette category", function()
	local icons_mod = require("gitflow.icons")
	local icon = icons_mod.get("palette", "bisect")
	assert_true(
		icon ~= nil and icon ~= "",
		"bisect icon should be available in palette category"
	)
end)

-- ─── Git operation tests ───

test("list_commits returns commit entries", function()
	local git_bisect = require("gitflow.git.bisect")
	local err, entries = wait_async(function(done)
		git_bisect.list_commits({ count = 10 }, function(e, ents)
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

test("parse_first_bad extracts SHA from bisect output", function()
	local git_bisect = require("gitflow.git.bisect")
	local sha = git_bisect.parse_first_bad(
		"abc1234def5678 is the first bad commit"
	)
	assert_equals(
		sha, "abc1234def5678",
		"should extract the SHA from bisect output"
	)
end)

test("parse_first_bad returns nil for non-matching output", function()
	local git_bisect = require("gitflow.git.bisect")
	local sha = git_bisect.parse_first_bad("Bisecting: 2 revisions left")
	assert_true(sha == nil, "should return nil for non-matching output")
end)

test("is_bisecting returns false when no session active", function()
	local git_bisect = require("gitflow.git.bisect")
	local is_active = wait_async(function(done)
		git_bisect.is_bisecting(function(active)
			done(active)
		end)
	end)

	assert_true(
		is_active == false,
		"should not be bisecting initially"
	)
end)

-- ─── Bisect start / good / bad / reset ───

test("bisect start, good, bad, and reset work", function()
	local git_bisect = require("gitflow.git.bisect")

	-- Get SHAs for the first (good) and last (bad) commits
	local good_sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD~3" })
	)
	local bad_sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "HEAD" })
	)

	-- Start bisect
	local start_err = wait_async(function(done)
		git_bisect.start(bad_sha, good_sha, function(e, _)
			done(e)
		end)
	end)

	assert_true(
		start_err == nil,
		"bisect start should not error: " .. tostring(start_err)
	)

	-- Verify bisect is active
	local is_active = wait_async(function(done)
		git_bisect.is_bisecting(function(active)
			done(active)
		end)
	end)

	assert_true(is_active, "bisect should be active after start")

	-- Reset bisect
	local reset_err = wait_async(function(done)
		git_bisect.reset_bisect(function(e, _)
			done(e)
		end)
	end)

	assert_true(
		reset_err == nil,
		"bisect reset should not error: " .. tostring(reset_err)
	)
end)

-- ─── Panel lifecycle tests ───

test("bisect panel opens and shows commits", function()
	local bisect_panel = require("gitflow.panels.bisect")
	bisect_panel.open(cfg)

	vim.wait(2000, function()
		if not bisect_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(bisect_panel.state.bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			bisect_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	assert_true(bisect_panel.is_open(), "bisect panel should be open")
	assert_true(
		bisect_panel.state.bufnr ~= nil,
		"bufnr should be set"
	)
	assert_true(
		bisect_panel.state.winid ~= nil,
		"winid should be set"
	)

	local lines = vim.api.nvim_buf_get_lines(
		bisect_panel.state.bufnr, 0, -1, false
	)
	assert_true(#lines > 2, "should have rendered commit lines")

	-- Check that at least one line has a commit entry marker
	local has_entry = false
	for _, line in ipairs(lines) do
		if line:find("commit", 1, true) then
			has_entry = true
			break
		end
	end
	assert_true(has_entry, "should contain a commit summary line")

	bisect_panel.close()
end)

test("bisect panel keymaps are set on buffer", function()
	local bisect_panel = require("gitflow.panels.bisect")
	bisect_panel.open(cfg)

	vim.wait(1000, function()
		return bisect_panel.state.bufnr ~= nil
			and vim.api.nvim_buf_is_valid(bisect_panel.state.bufnr)
	end, 50)

	local bufnr = bisect_panel.state.bufnr
	assert_true(bufnr ~= nil, "bufnr should exist")

	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local found_keys = {}
	for _, km in ipairs(keymaps) do
		found_keys[km.lhs] = true
	end

	assert_true(found_keys["<CR>"] ~= nil, "CR keymap should be set")
	assert_true(found_keys["r"] ~= nil, "r keymap should be set")
	assert_true(found_keys["q"] ~= nil, "q keymap should be set")
	assert_true(found_keys["b"] ~= nil, "b keymap should be set")
	assert_true(found_keys["g"] ~= nil, "g keymap should be set")
	assert_true(found_keys["t"] ~= nil, "t keymap should be set")
	assert_true(found_keys["R"] ~= nil, "R keymap should be set")
	assert_true(found_keys["1"] ~= nil, "1 keymap should be set")
	assert_true(found_keys["9"] ~= nil, "9 keymap should be set")

	bisect_panel.close()
end)

test("bisect panel close cleans up state", function()
	local bisect_panel = require("gitflow.panels.bisect")
	bisect_panel.open(cfg)

	vim.wait(500, function()
		return bisect_panel.state.bufnr ~= nil
	end, 50)

	bisect_panel.close()

	assert_true(
		bisect_panel.state.bufnr == nil,
		"bufnr should be nil after close"
	)
	assert_true(
		bisect_panel.state.winid == nil,
		"winid should be nil after close"
	)
	assert_true(
		not bisect_panel.is_open(),
		"is_open should return false after close"
	)
end)

test("bisect panel starts in select_bad phase", function()
	local bisect_panel = require("gitflow.panels.bisect")
	bisect_panel.open(cfg)

	vim.wait(2000, function()
		if not bisect_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(bisect_panel.state.bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			bisect_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	assert_equals(
		bisect_panel.state.phase, "select_bad",
		"initial phase should be select_bad"
	)

	local lines = vim.api.nvim_buf_get_lines(
		bisect_panel.state.bufnr, 0, -1, false
	)
	local has_bad_prompt = false
	for _, line in ipairs(lines) do
		if line:find("BAD", 1, true) then
			has_bad_prompt = true
			break
		end
	end
	assert_true(
		has_bad_prompt,
		"should show BAD commit selection prompt"
	)

	bisect_panel.close()
end)

test("line_entries map is populated after render", function()
	local bisect_panel = require("gitflow.panels.bisect")
	bisect_panel.open(cfg)

	vim.wait(2000, function()
		if not bisect_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			bisect_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local entry_count = 0
	for _ in pairs(bisect_panel.state.line_entries) do
		entry_count = entry_count + 1
	end
	assert_true(
		entry_count >= 4,
		"should have at least 4 commit entries in line_entries"
	)

	bisect_panel.close()
end)

test("config validation accepts bisect keybinding", function()
	local config = require("gitflow.config")
	local test_cfg = config.defaults()
	test_cfg.keybindings.bisect = "gI"
	local ok = pcall(config.validate, test_cfg)
	assert_true(ok, "config validation should pass with bisect keybinding")
end)

test("dispatch bisect subcommand returns expected message", function()
	local commands = require("gitflow.commands")
	local result = commands.dispatch({ "bisect" }, cfg)
	assert_true(
		type(result) == "string",
		"dispatch should return a string"
	)

	local bisect_panel = require("gitflow.panels.bisect")
	vim.wait(500, function()
		return bisect_panel.state.bufnr ~= nil
	end, 50)
	bisect_panel.close()
end)

-- ─── Cleanup ───

vim.fn.chdir(original_cwd)
vim.fn.delete(repo_dir, "rf")

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
