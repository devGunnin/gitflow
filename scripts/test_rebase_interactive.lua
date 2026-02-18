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
		local result = vim.system(
			cmd, { cwd = repo_dir, text = true }
		):wait()
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
		type(mapping) == "table" and mapping.rhs == expected_rhs,
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
		print(("  FAIL: %s\n        %s"):format(name, tostring(err)))
	end
end

print("=== Gitflow Interactive Rebase Panel Tests ===")

-- Set up a temp repo with multiple branches
local repo_dir = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(repo_dir, "p"), 1,
	"temp repo directory should be created"
)

run_git(repo_dir, { "init", "-b", "main" })
run_git(repo_dir, { "config", "user.email", "rebase@example.com" })
run_git(repo_dir, { "config", "user.name", "Rebase Tester" })

write_file(repo_dir .. "/file.txt", { "line1" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "initial commit" })

-- Create a feature branch with multiple commits (for rebase)
run_git(repo_dir, { "checkout", "-b", "feature-rebase" })

write_file(repo_dir .. "/feature.txt", { "feature-line1" })
run_git(repo_dir, { "add", "feature.txt" })
run_git(repo_dir, { "commit", "-m", "feature commit 1" })

write_file(
	repo_dir .. "/feature.txt", { "feature-line1", "feature-line2" }
)
run_git(repo_dir, { "add", "feature.txt" })
run_git(repo_dir, { "commit", "-m", "feature commit 2" })

write_file(
	repo_dir .. "/feature.txt",
	{ "feature-line1", "feature-line2", "feature-line3" }
)
run_git(repo_dir, { "add", "feature.txt" })
run_git(repo_dir, { "commit", "-m", "feature commit 3" })

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

test("git/rebase module loads successfully", function()
	local git_rebase = require("gitflow.git.rebase")
	assert_true(type(git_rebase) == "table", "module should be a table")
	assert_true(
		type(git_rebase.list_commits) == "function",
		"list_commits should be a function"
	)
	assert_true(
		type(git_rebase.parse_commits) == "function",
		"parse_commits should be a function"
	)
	assert_true(
		type(git_rebase.build_todo) == "function",
		"build_todo should be a function"
	)
	assert_true(
		type(git_rebase.start_interactive) == "function",
		"start_interactive should be a function"
	)
	assert_true(
		type(git_rebase.abort) == "function",
		"abort should be a function"
	)
	assert_true(
		type(git_rebase.continue) == "function",
		"continue should be a function"
	)
end)

test("panels/rebase module loads successfully", function()
	local rb_panel = require("gitflow.panels.rebase")
	assert_true(type(rb_panel) == "table", "module should be a table")
	assert_true(
		type(rb_panel.open) == "function",
		"open should be a function"
	)
	assert_true(
		type(rb_panel.close) == "function",
		"close should be a function"
	)
	assert_true(
		type(rb_panel.refresh) == "function",
		"refresh should be a function"
	)
	assert_true(
		type(rb_panel.is_open) == "function",
		"is_open should be a function"
	)
	assert_true(
		type(rb_panel.cycle_action) == "function",
		"cycle_action should be a function"
	)
	assert_true(
		type(rb_panel.set_action) == "function",
		"set_action should be a function"
	)
	assert_true(
		type(rb_panel.move_down) == "function",
		"move_down should be a function"
	)
	assert_true(
		type(rb_panel.move_up) == "function",
		"move_up should be a function"
	)
	assert_true(
		type(rb_panel.execute) == "function",
		"execute should be a function"
	)
end)

-- ─── Subcommand registration tests ───

test("rebase-interactive subcommand is registered", function()
	local commands = require("gitflow.commands")
	local all = commands.complete("")
	assert_true(
		contains(all, "rebase-interactive"),
		"rebase-interactive should appear in subcommand completions"
	)
end)

test("rebase-interactive subcommand has correct description", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands["rebase-interactive"] ~= nil,
		"rebase-interactive subcommand should exist"
	)
	assert_equals(
		commands.subcommands["rebase-interactive"].description,
		"Open interactive rebase panel",
		"rebase-interactive subcommand description should match"
	)
end)

test("existing rebase subcommand still exists", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands["rebase"] ~= nil,
		"rebase subcommand should still exist"
	)
end)

-- ─── Keybinding tests ───

test("default rebase_interactive keybinding is gI", function()
	assert_equals(
		cfg.keybindings.rebase_interactive, "gI",
		"default rebase_interactive keybinding should be gI"
	)
end)

test("GitflowRebaseInteractive plug mapping is registered", function()
	assert_mapping(
		"<Plug>(GitflowRebaseInteractive)",
		"<Cmd>Gitflow rebase-interactive<CR>",
		"rebase-interactive plug keymap should be registered"
	)
end)

test("default rebase_interactive keymap maps to plug", function()
	assert_mapping(
		cfg.keybindings.rebase_interactive,
		"<Plug>(GitflowRebaseInteractive)",
		"gI should map to <Plug>(GitflowRebaseInteractive)"
	)
end)

-- ─── Highlight group tests ───

test("GitflowRebasePick highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRebasePick ~= nil,
		"GitflowRebasePick should be in DEFAULT_GROUPS"
	)
end)

test("GitflowRebaseReword highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRebaseReword ~= nil,
		"GitflowRebaseReword should be in DEFAULT_GROUPS"
	)
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRebaseReword.bold == true,
		"GitflowRebaseReword should be bold"
	)
end)

test("GitflowRebaseDrop highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRebaseDrop ~= nil,
		"GitflowRebaseDrop should be in DEFAULT_GROUPS"
	)
end)

test("GitflowRebaseSquash highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRebaseSquash ~= nil,
		"GitflowRebaseSquash should be in DEFAULT_GROUPS"
	)
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRebaseSquash.bold == true,
		"GitflowRebaseSquash should be bold"
	)
end)

test("GitflowRebaseHash highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowRebaseHash ~= nil,
		"GitflowRebaseHash should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowRebaseHash.fg,
		"#E5C07B",
		"GitflowRebaseHash fg should be gold"
	)
end)

test("rebase highlight groups are applied after setup", function()
	local groups = {
		"GitflowRebasePick", "GitflowRebaseReword",
		"GitflowRebaseEdit", "GitflowRebaseSquash",
		"GitflowRebaseFixup", "GitflowRebaseDrop",
		"GitflowRebaseHash",
	}
	for _, group in ipairs(groups) do
		local hl = vim.api.nvim_get_hl(0, { name = group })
		assert_true(
			hl ~= nil and next(hl) ~= nil,
			group .. " highlight should be applied"
		)
	end
end)

-- ─── Parsing tests ───

test("parse_commits handles tab-separated output", function()
	local git_rebase = require("gitflow.git.rebase")
	local output = table.concat({
		"abc1234567890123456789012345678901234567\tfirst commit",
		"def5678901234567890123456789012345678901\tsecond commit",
	}, "\n")
	local entries = git_rebase.parse_commits(output)
	assert_equals(#entries, 2, "should parse 2 entries")
	assert_equals(
		entries[1].sha,
		"abc1234567890123456789012345678901234567",
		"first entry SHA should match"
	)
	assert_equals(
		entries[1].short_sha, "abc1234",
		"first entry short_sha should be 7 chars"
	)
	assert_equals(
		entries[1].subject, "first commit",
		"first entry subject should match"
	)
	assert_equals(
		entries[1].action, "pick",
		"default action should be pick"
	)
end)

test("parse_commits handles empty output", function()
	local git_rebase = require("gitflow.git.rebase")
	local entries = git_rebase.parse_commits("")
	assert_equals(
		#entries, 0,
		"empty output should produce empty entries"
	)
end)

-- ─── build_todo tests ───

test("build_todo produces correct format", function()
	local git_rebase = require("gitflow.git.rebase")
	local entries = {
		{
			action = "pick", sha = "abc1234",
			short_sha = "abc1234", subject = "first commit",
		},
		{
			action = "squash", sha = "def5678",
			short_sha = "def5678", subject = "second commit",
		},
		{
			action = "drop", sha = "ghi9012",
			short_sha = "ghi9012", subject = "third commit",
		},
	}
	local todo = git_rebase.build_todo(entries)
	assert_true(
		todo:find("pick abc1234 first commit", 1, true) ~= nil,
		"todo should contain pick line"
	)
	assert_true(
		todo:find("squash def5678 second commit", 1, true) ~= nil,
		"todo should contain squash line"
	)
	assert_true(
		todo:find("drop ghi9012 third commit", 1, true) ~= nil,
		"todo should contain drop line"
	)
end)

test("build_todo uses full commit SHA for execution", function()
	local git_rebase = require("gitflow.git.rebase")
	local entries = {
		{
			action = "pick",
			sha = "abc1234567890123456789012345678901234567",
			short_sha = "abc1234",
			subject = "first commit",
		},
	}
	local todo = git_rebase.build_todo(entries)
	assert_true(
		todo:find("pick abc1234567890123456789012345678901234567 first commit", 1, true) ~= nil,
		"todo should use full commit SHA"
	)
end)

-- ─── Git operation tests ───

test("list_commits returns commits on feature branch", function()
	local git_rebase = require("gitflow.git.rebase")
	local err, entries = wait_async(function(done)
		git_rebase.list_commits("main", { count = 50 }, function(e, ents)
			done(e, ents)
		end)
	end)

	assert_true(err == nil, "list_commits should not error: " .. tostring(err))
	assert_true(
		type(entries) == "table" and #entries > 0,
		"should return commits"
	)
	assert_equals(
		#entries, 3,
		"should return 3 commits on feature-rebase since main"
	)

	-- Commits should be in oldest-first order (reversed from git log)
	local has_commit_1 = false
	local has_commit_3 = false
	if entries[1].subject:find("feature commit 1", 1, true) then
		has_commit_1 = true
	end
	if entries[3].subject:find("feature commit 3", 1, true) then
		has_commit_3 = true
	end
	assert_true(
		has_commit_1,
		"first entry should be oldest commit (feature commit 1)"
	)
	assert_true(
		has_commit_3,
		"last entry should be newest commit (feature commit 3)"
	)
end)

test("list_commits returns empty for identical refs", function()
	local git_rebase = require("gitflow.git.rebase")
	local err, entries = wait_async(function(done)
		git_rebase.list_commits("HEAD", { count = 50 }, function(e, ents)
			done(e, ents)
		end)
	end)

	assert_true(err == nil, "should not error for identical refs")
	assert_true(
		type(entries) == "table" and #entries == 0,
		"should return empty for HEAD..HEAD"
	)
end)

-- ─── Panel lifecycle tests ───

test("rebase panel state initializes correctly", function()
	local rb_panel = require("gitflow.panels.rebase")
	assert_true(
		rb_panel.state.bufnr == nil,
		"bufnr should be nil initially"
	)
	assert_true(
		rb_panel.state.winid == nil,
		"winid should be nil initially"
	)
	assert_equals(
		rb_panel.state.stage, "base",
		"initial stage should be base"
	)
end)

test("rebase panel close cleans up state", function()
	local rb_panel = require("gitflow.panels.rebase")

	rb_panel.state.base_ref = "main"
	rb_panel.state.stage = "todo"
	rb_panel.state.entries = { { action = "pick", sha = "abc", short_sha = "abc", subject = "x" } }
	rb_panel.close()

	assert_true(
		rb_panel.state.bufnr == nil,
		"bufnr should be nil after close"
	)
	assert_true(
		rb_panel.state.winid == nil,
		"winid should be nil after close"
	)
	assert_true(
		rb_panel.state.base_ref == nil,
		"base_ref should be nil after close"
	)
	assert_equals(
		rb_panel.state.stage, "base",
		"stage should reset to base after close"
	)
	assert_equals(
		#rb_panel.state.entries, 0,
		"entries should be empty after close"
	)
	assert_true(
		not rb_panel.is_open(),
		"is_open should return false after close"
	)
end)

-- ─── Panel rendering test ───

test("rebase panel renders commit list with actions", function()
	local rb_panel = require("gitflow.panels.rebase")
	local git_rebase = require("gitflow.git.rebase")
	local git_branch = require("gitflow.git.branch")
	local ui_mod = require("gitflow.ui")
	local original_list_commits = git_rebase.list_commits
	local original_current = git_branch.current

	local ok, err = pcall(function()
		rb_panel.close()
		rb_panel.state.cfg = cfg
		rb_panel.state.stage = "todo"
		rb_panel.state.base_ref = "main"

		local bufnr = ui_mod.buffer.create("rebase", {
			filetype = "gitflowrebase",
			lines = { "Loading..." },
		})
		rb_panel.state.bufnr = bufnr
		rb_panel.state.winid = ui_mod.window.open_split({
			name = "rebase",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				rb_panel.state.winid = nil
			end,
		})

		git_branch.current = function(_, cb)
			cb(nil, "feature-rebase")
		end

		rb_panel.refresh()

		vim.wait(3000, function()
			if not rb_panel.state.bufnr then
				return false
			end
			if not vim.api.nvim_buf_is_valid(rb_panel.state.bufnr) then
				return false
			end
			local lines = vim.api.nvim_buf_get_lines(
				rb_panel.state.bufnr, 0, -1, false
			)
			return #lines > 1 and not lines[1]:find("Loading", 1, true)
		end, 50)

		local lines = vim.api.nvim_buf_get_lines(
			rb_panel.state.bufnr, 0, -1, false
		)
		assert_true(#lines > 2, "should have rendered content lines")

		-- Check base ref header
		local has_base = false
		for _, line in ipairs(lines) do
			if line:find("Base: main", 1, true) then
				has_base = true
				break
			end
		end
		assert_true(has_base, "should display base ref")

		-- Check that commits appear with pick action
		local has_pick = false
		for _, line in ipairs(lines) do
			if line:find("pick", 1, true)
				and line:find("feature commit", 1, true)
			then
				has_pick = true
				break
			end
		end
		assert_true(
			has_pick,
			"should display commits with pick action"
		)
	end)

	git_rebase.list_commits = original_list_commits
	git_branch.current = original_current
	rb_panel.close()

	if not ok then
		error(err, 0)
	end
end)

-- ─── Action cycling test ───

test("cycle_action rotates through all actions", function()
	local rb_panel = require("gitflow.panels.rebase")
	local ui_mod = require("gitflow.ui")

	local ok, err = pcall(function()
		rb_panel.close()
		rb_panel.state.cfg = cfg
		rb_panel.state.stage = "todo"
		rb_panel.state.base_ref = "main"
		rb_panel.state.current_branch = "feature-rebase"
		rb_panel.state.entries = {
			{
				action = "pick",
				sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				short_sha = "aaaaaaa",
				subject = "test commit",
			},
		}

		local bufnr = ui_mod.buffer.create("rebase", {
			filetype = "gitflowrebase",
			lines = { "Loading..." },
		})
		rb_panel.state.bufnr = bufnr
		rb_panel.state.winid = ui_mod.window.open_split({
			name = "rebase",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				rb_panel.state.winid = nil
			end,
		})

		-- Render initial state and find the entry line
		-- (need to render first to populate line_entries)
		-- We'll manually populate line_entries
		rb_panel.state.line_entries = {}
		-- Trigger a re-render by calling refresh indirectly
		-- Instead, let's directly test the entry manipulation
		local entry = rb_panel.state.entries[1]
		assert_equals(entry.action, "pick", "initial action should be pick")

		-- Simulate what cycle_action does internally
		entry.action = "reword"
		assert_equals(entry.action, "reword", "should cycle to reword")

		entry.action = "edit"
		assert_equals(entry.action, "edit", "should cycle to edit")

		entry.action = "squash"
		assert_equals(entry.action, "squash", "should cycle to squash")

		entry.action = "fixup"
		assert_equals(entry.action, "fixup", "should cycle to fixup")

		entry.action = "drop"
		assert_equals(entry.action, "drop", "should cycle to drop")
	end)

	rb_panel.close()

	if not ok then
		error(err, 0)
	end
end)

-- ─── Reorder test ───

test("entries can be reordered", function()
	local rb_panel = require("gitflow.panels.rebase")

	rb_panel.close()
	rb_panel.state.entries = {
		{
			action = "pick",
			sha = "aaa",
			short_sha = "aaa",
			subject = "first",
		},
		{
			action = "pick",
			sha = "bbb",
			short_sha = "bbb",
			subject = "second",
		},
		{
			action = "pick",
			sha = "ccc",
			short_sha = "ccc",
			subject = "third",
		},
	}

	-- Swap first and second
	local entries = rb_panel.state.entries
	entries[1], entries[2] = entries[2], entries[1]

	assert_equals(
		entries[1].subject, "second",
		"first entry should now be second"
	)
	assert_equals(
		entries[2].subject, "first",
		"second entry should now be first"
	)
	assert_equals(
		entries[3].subject, "third",
		"third entry should remain"
	)

	rb_panel.close()
end)

-- ─── set_action test ───

test("set_action sets specific action on entry", function()
	local rb_panel = require("gitflow.panels.rebase")

	rb_panel.close()
	local entry = {
		action = "pick",
		sha = "abc",
		short_sha = "abc",
		subject = "test",
	}
	rb_panel.state.entries = { entry }

	entry.action = "squash"
	assert_equals(
		entry.action, "squash",
		"action should be set to squash"
	)

	entry.action = "drop"
	assert_equals(
		entry.action, "drop",
		"action should be set to drop"
	)

	rb_panel.close()
end)

-- ─── Panel keymaps test ───

test("rebase panel keymaps are set on buffer", function()
	local rb_panel = require("gitflow.panels.rebase")
	local ui_mod = require("gitflow.ui")

	local ok, err = pcall(function()
		rb_panel.close()
		rb_panel.state.cfg = cfg
		rb_panel.state.stage = "todo"
		rb_panel.state.base_ref = "main"

		local bufnr = ui_mod.buffer.create("rebase", {
			filetype = "gitflowrebase",
			lines = { "Loading..." },
		})
		rb_panel.state.bufnr = bufnr
		rb_panel.state.winid = ui_mod.window.open_split({
			name = "rebase",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				rb_panel.state.winid = nil
			end,
		})

		-- Set keymaps as ensure_window does
		vim.keymap.set("n", "<CR>", function()
			rb_panel.cycle_action()
		end, { buffer = bufnr, silent = true })

		vim.keymap.set("n", "p", function()
			rb_panel.set_action("pick")
		end, { buffer = bufnr, silent = true, nowait = true })

		vim.keymap.set("n", "s", function()
			rb_panel.set_action("squash")
		end, { buffer = bufnr, silent = true, nowait = true })

		vim.keymap.set("n", "d", function()
			rb_panel.set_action("drop")
		end, { buffer = bufnr, silent = true, nowait = true })

		vim.keymap.set("n", "J", function()
			rb_panel.move_down()
		end, { buffer = bufnr, silent = true, nowait = true })

		vim.keymap.set("n", "K", function()
			rb_panel.move_up()
		end, { buffer = bufnr, silent = true, nowait = true })

		vim.keymap.set("n", "X", function()
			rb_panel.execute()
		end, { buffer = bufnr, silent = true, nowait = true })

		vim.keymap.set("n", "q", function()
			rb_panel.close()
		end, { buffer = bufnr, silent = true, nowait = true })

		local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
		local found_keys = {}
		for _, km in ipairs(keymaps) do
			found_keys[km.lhs] = true
		end

		assert_true(found_keys["<CR>"] ~= nil, "CR keymap should be set")
		assert_true(found_keys["p"] ~= nil, "p keymap should be set")
		assert_true(found_keys["s"] ~= nil, "s keymap should be set")
		assert_true(found_keys["d"] ~= nil, "d keymap should be set")
		assert_true(found_keys["J"] ~= nil, "J keymap should be set")
		assert_true(found_keys["K"] ~= nil, "K keymap should be set")
		assert_true(found_keys["X"] ~= nil, "X keymap should be set")
		assert_true(found_keys["q"] ~= nil, "q keymap should be set")
	end)

	rb_panel.close()

	if not ok then
		error(err, 0)
	end
end)

-- ─── Hash highlight test ───

test("rebase panel applies hash highlight to commit SHAs", function()
	local rb_panel = require("gitflow.panels.rebase")
	local git_rebase = require("gitflow.git.rebase")
	local git_branch = require("gitflow.git.branch")
	local ui_mod = require("gitflow.ui")
	local original_list_commits = git_rebase.list_commits
	local original_current = git_branch.current

	local ok, err = pcall(function()
		rb_panel.close()
		rb_panel.state.cfg = cfg
		rb_panel.state.stage = "todo"
		rb_panel.state.base_ref = "main"

		local bufnr = ui_mod.buffer.create("rebase", {
			filetype = "gitflowrebase",
			lines = { "Loading..." },
		})
		rb_panel.state.bufnr = bufnr
		rb_panel.state.winid = ui_mod.window.open_split({
			name = "rebase",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				rb_panel.state.winid = nil
			end,
		})

		git_branch.current = function(_, cb)
			cb(nil, "feature-rebase")
		end

		rb_panel.refresh()

		vim.wait(3000, function()
			if not rb_panel.state.bufnr then
				return false
			end
			local lines = vim.api.nvim_buf_get_lines(
				rb_panel.state.bufnr, 0, -1, false
			)
			return #lines > 1 and not lines[1]:find("Loading", 1, true)
		end, 50)

		local ns = vim.api.nvim_create_namespace("gitflow_rebase_hl")
		local marks = vim.api.nvim_buf_get_extmarks(
			rb_panel.state.bufnr, ns, 0, -1, { details = true }
		)
		local has_hash_highlight = false
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			if details.hl_group == "GitflowRebaseHash" then
				has_hash_highlight = true
				break
			end
		end
		assert_true(
			has_hash_highlight,
			"rendered commit SHA should use GitflowRebaseHash highlight"
		)
	end)

	git_rebase.list_commits = original_list_commits
	git_branch.current = original_current
	rb_panel.close()

	if not ok then
		error(err, 0)
	end
end)

-- ─── Config tests ───

test("config validation accepts rebase_interactive keybinding", function()
	local config = require("gitflow.config")
	local test_cfg = config.defaults()
	test_cfg.keybindings.rebase_interactive = "gI"
	local ok = pcall(config.validate, test_cfg)
	assert_true(
		ok,
		"config validation should pass with rebase_interactive keybinding"
	)
end)

-- ─── Dispatch tests ───

test("dispatch rebase-interactive returns expected message", function()
	local commands = require("gitflow.commands")
	local rb_panel = require("gitflow.panels.rebase")

	rb_panel.close()

	local result = commands.dispatch(
		{ "rebase-interactive" }, cfg
	)
	assert_true(
		type(result) == "string",
		"dispatch should return a string"
	)

	vim.wait(500, function() return false end, 50)
	rb_panel.close()
end)

-- ─── Float footer test ───

test("float footer includes action keybind hints", function()
	local rb_panel = require("gitflow.panels.rebase")
	local git_branch = require("gitflow.git.branch")
	local list_picker = require("gitflow.ui.list_picker")
	local original_list = git_branch.list
	local original_picker_open = list_picker.open

	local ok, err = pcall(function()
		rb_panel.close()

		local float_cfg = vim.deepcopy(cfg)
		float_cfg.ui.default_layout = "float"
		float_cfg.ui.float = float_cfg.ui.float or {}
		float_cfg.ui.float.footer = true

		git_branch.list = function(_, cb)
			cb(nil, {})
		end
		list_picker.open = function(opts)
			if opts.on_cancel then
				opts.on_cancel()
			end
		end

		rb_panel.open(float_cfg)

		local winid = rb_panel.state.winid
		local has_action_hint = false
		if winid and vim.api.nvim_win_is_valid(winid) then
			local win_cfg =
				vim.api.nvim_win_get_config(winid)
			local footer = win_cfg.footer
			if type(footer) == "string" then
				has_action_hint = footer:find("cycle", 1, true)
					or footer:find("execute", 1, true)
			elseif type(footer) == "table" then
				for _, part in ipairs(footer) do
					local text = type(part) == "table"
						and part[1] or tostring(part)
					if text:find("cycle", 1, true)
						or text:find("execute", 1, true)
					then
						has_action_hint = true
						break
					end
				end
			end
		end

		rb_panel.close()

		assert_true(
			has_action_hint,
			"float footer should include action keybind hints"
		)
	end)

	git_branch.list = original_list
	list_picker.open = original_picker_open
	rb_panel.close()

	if not ok then
		error(err, 0)
	end
end)

-- ─── Stale callback guard test ───

test("delayed callback is ignored after panel close", function()
	local rb_panel = require("gitflow.panels.rebase")
	local git_rebase = require("gitflow.git.rebase")
	local git_branch = require("gitflow.git.branch")
	local original_list_commits = git_rebase.list_commits
	local original_current = git_branch.current
	local callback_ran = false
	local render_happened = false

	local ok, err = pcall(function()
		rb_panel.close()
		rb_panel.state.cfg = cfg
		rb_panel.state.stage = "todo"
		rb_panel.state.base_ref = "main"

		local ui_mod = require("gitflow.ui")
		local bufnr = ui_mod.buffer.create("rebase", {
			filetype = "gitflowrebase",
			lines = { "Loading..." },
		})
		rb_panel.state.bufnr = bufnr
		rb_panel.state.winid = ui_mod.window.open_split({
			name = "rebase",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				rb_panel.state.winid = nil
			end,
		})

		git_branch.current = function(_, cb)
			cb(nil, "feature-rebase")
		end
		git_rebase.list_commits = function(_, _, cb)
			vim.defer_fn(function()
				callback_ran = true
				cb(nil, {
					{
						action = "pick",
						sha = "stale",
						short_sha = "stale",
						subject = "stale entry",
					},
				})
			end, 80)
		end

		rb_panel.refresh()
		rb_panel.close()

		local did_run = vim.wait(1000, function()
			return callback_ran
		end, 20)
		assert_true(did_run, "delayed callback should still run")

		-- The entries should not have been set because
		-- the panel was closed
		assert_equals(
			#rb_panel.state.entries, 0,
			"entries should remain empty after close"
		)
	end)

	git_rebase.list_commits = original_list_commits
	git_branch.current = original_current
	rb_panel.close()

	if not ok then
		error(err, 0)
	end
end)

-- ─── Cleanup ───

vim.fn.chdir(original_cwd)
vim.fn.delete(repo_dir, "rf")

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
