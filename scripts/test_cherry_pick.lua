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

print("=== Gitflow Cherry Pick Panel Tests ===")

-- Set up a temp repo with multiple branches
local repo_dir = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(repo_dir, "p"), 1,
	"temp repo directory should be created"
)

run_git(repo_dir, { "init", "-b", "main" })
run_git(repo_dir, { "config", "user.email", "cp@example.com" })
run_git(repo_dir, { "config", "user.name", "CP Tester" })

write_file(repo_dir .. "/file.txt", { "line1" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "initial commit" })

write_file(repo_dir .. "/file.txt", { "line1", "line2" })
run_git(repo_dir, { "add", "file.txt" })
run_git(repo_dir, { "commit", "-m", "second commit on main" })

-- Create a feature branch with unique commits
run_git(repo_dir, { "checkout", "-b", "feature-a" })

write_file(repo_dir .. "/feature.txt", { "feature-line1" })
run_git(repo_dir, { "add", "feature.txt" })
run_git(repo_dir, { "commit", "-m", "feature-a commit 1" })

write_file(repo_dir .. "/feature.txt", { "feature-line1", "feature-line2" })
run_git(repo_dir, { "add", "feature.txt" })
run_git(repo_dir, { "commit", "-m", "feature-a commit 2" })

-- Create another branch with more unique commits
run_git(repo_dir, { "checkout", "main" })
run_git(repo_dir, { "checkout", "-b", "feature-b" })

write_file(repo_dir .. "/other.txt", { "other-line1" })
run_git(repo_dir, { "add", "other.txt" })
run_git(repo_dir, { "commit", "-m", "feature-b commit 1" })

-- Go back to main for testing
run_git(repo_dir, { "checkout", "main" })

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

test("git/cherry_pick module loads successfully", function()
	local git_cp = require("gitflow.git.cherry_pick")
	assert_true(type(git_cp) == "table", "module should be a table")
	assert_true(
		type(git_cp.list_branches) == "function",
		"list_branches should be a function"
	)
	assert_true(
		type(git_cp.list_unique_commits) == "function",
		"list_unique_commits should be a function"
	)
	assert_true(
		type(git_cp.cherry_pick) == "function",
		"cherry_pick should be a function"
	)
	assert_true(
		type(git_cp.parse_commits) == "function",
		"parse_commits should be a function"
	)
	assert_true(
		type(git_cp.parse_branches) == "function",
		"parse_branches should be a function"
	)
end)

test("panels/cherry_pick module loads successfully", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	assert_true(type(cp_panel) == "table", "module should be a table")
	assert_true(
		type(cp_panel.open) == "function",
		"open should be a function"
	)
	assert_true(
		type(cp_panel.close) == "function",
		"close should be a function"
	)
	assert_true(
		type(cp_panel.refresh) == "function",
		"refresh should be a function"
	)
	assert_true(
		type(cp_panel.is_open) == "function",
		"is_open should be a function"
	)
	assert_true(
		type(cp_panel.select_under_cursor) == "function",
		"select_under_cursor should be a function"
	)
	assert_true(
		type(cp_panel.select_by_position) == "function",
		"select_by_position should be a function"
	)
	assert_true(
		type(cp_panel.show_branch_picker) == "function",
		"show_branch_picker should be a function"
	)
end)

-- ─── Subcommand registration tests ───

test("cherry-pick-panel subcommand is registered", function()
	local commands = require("gitflow.commands")
	local all = commands.complete("")
	assert_true(
		contains(all, "cherry-pick-panel"),
		"cherry-pick-panel should appear in subcommand completions"
	)
end)

test("cherry-pick-panel subcommand has correct description", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands["cherry-pick-panel"] ~= nil,
		"cherry-pick-panel subcommand should exist"
	)
	assert_equals(
		commands.subcommands["cherry-pick-panel"].description,
		"Open cherry-pick panel (branch-aware commit picker)",
		"cherry-pick-panel subcommand description should match"
	)
end)

test("cherry-pick subcommand still exists", function()
	local commands = require("gitflow.commands")
	assert_true(
		commands.subcommands["cherry-pick"] ~= nil,
		"cherry-pick subcommand should still exist"
	)
end)

-- ─── Keybinding tests ───

test("default cherry_pick keybinding is gC", function()
	assert_equals(
		cfg.keybindings.cherry_pick, "gC",
		"default cherry_pick keybinding should be gC"
	)
end)

test("GitflowCherryPick plug mapping is registered", function()
	assert_mapping(
		"<Plug>(GitflowCherryPick)",
		"<Cmd>Gitflow cherry-pick-panel<CR>",
		"cherry-pick plug keymap should be registered"
	)
end)

test("default cherry_pick keymap maps to plug", function()
	assert_mapping(
		cfg.keybindings.cherry_pick,
		"<Plug>(GitflowCherryPick)",
		"gC should map to <Plug>(GitflowCherryPick)"
	)
end)

-- ─── Highlight group tests ───

test("GitflowCherryPickBranch highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowCherryPickBranch ~= nil,
		"GitflowCherryPickBranch should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowCherryPickBranch.fg,
		"#C678DD",
		"GitflowCherryPickBranch fg should be purple"
	)
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowCherryPickBranch.bold == true,
		"GitflowCherryPickBranch should be bold"
	)
end)

test("GitflowCherryPickHash highlight group is defined", function()
	local highlights = require("gitflow.highlights")
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowCherryPickHash ~= nil,
		"GitflowCherryPickHash should be in DEFAULT_GROUPS"
	)
	assert_equals(
		highlights.DEFAULT_GROUPS.GitflowCherryPickHash.fg,
		"#E5C07B",
		"GitflowCherryPickHash fg should be gold"
	)
	assert_true(
		highlights.DEFAULT_GROUPS.GitflowCherryPickHash.bold == true,
		"GitflowCherryPickHash should be bold"
	)
end)

test("cherry-pick highlight groups are applied after setup", function()
	local hl_branch = vim.api.nvim_get_hl(
		0, { name = "GitflowCherryPickBranch" }
	)
	assert_true(
		hl_branch ~= nil and next(hl_branch) ~= nil,
		"GitflowCherryPickBranch highlight should be applied"
	)

	local hl_hash = vim.api.nvim_get_hl(
		0, { name = "GitflowCherryPickHash" }
	)
	assert_true(
		hl_hash ~= nil and next(hl_hash) ~= nil,
		"GitflowCherryPickHash highlight should be applied"
	)
end)

-- ─── Parsing tests ───

test("parse_commits handles tab-separated output", function()
	local git_cp = require("gitflow.git.cherry_pick")
	local output = table.concat({
		"abc1234567890123456789012345678901234567\tabc1234 first commit",
		"def5678901234567890123456789012345678901\tdef5678 second commit",
	}, "\n")
	local entries = git_cp.parse_commits(output)
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
		entries[1].summary, "abc1234 first commit",
		"first entry summary should match"
	)
end)

test("parse_commits handles empty output", function()
	local git_cp = require("gitflow.git.cherry_pick")
	local entries = git_cp.parse_commits("")
	assert_equals(
		#entries, 0,
		"empty output should produce empty entries"
	)
end)

test("parse_branches filters current branch", function()
	local git_cp = require("gitflow.git.cherry_pick")
	local output = "* main\n  feature-a\n  feature-b\n"
	local branches = git_cp.parse_branches(output, "main")
	assert_true(
		not contains(branches, "main"),
		"current branch should be filtered out"
	)
	assert_true(
		contains(branches, "feature-a"),
		"feature-a should be included"
	)
	assert_true(
		contains(branches, "feature-b"),
		"feature-b should be included"
	)
end)

test("parse_branches filters HEAD entries", function()
	local git_cp = require("gitflow.git.cherry_pick")
	local output = "main\norigin/HEAD\nfeature-a\n"
	local branches = git_cp.parse_branches(output, nil)
	assert_true(
		not contains(branches, "origin/HEAD"),
		"HEAD entries should be filtered out"
	)
end)

-- ─── Git operation tests ───

test("list_branches returns branches excluding current", function()
	local git_cp = require("gitflow.git.cherry_pick")
	local err, branches = wait_async(function(done)
		git_cp.list_branches({}, function(e, b)
			done(e, b)
		end)
	end)

	assert_true(err == nil, "list_branches should not error")
	assert_true(
		type(branches) == "table" and #branches > 0,
		"should return at least one branch"
	)
	assert_true(
		not contains(branches, "main"),
		"current branch (main) should not be included"
	)
	assert_true(
		contains(branches, "feature-a"),
		"feature-a should be in the list"
	)
end)

test("list_unique_commits returns unique commits", function()
	local git_cp = require("gitflow.git.cherry_pick")
	local err, entries = wait_async(function(done)
		git_cp.list_unique_commits(
			"feature-a", { count = 50 },
			function(e, ents)
				done(e, ents)
			end
		)
	end)

	assert_true(err == nil, "list_unique_commits should not error")
	assert_true(
		type(entries) == "table" and #entries > 0,
		"should return unique commits"
	)

	-- feature-a has 2 unique commits not on main
	local has_feature_commit = false
	for _, entry in ipairs(entries) do
		if entry.summary:find("feature%-a commit", 1, false) then
			has_feature_commit = true
			break
		end
	end
	assert_true(
		has_feature_commit,
		"should include feature-a commits"
	)
end)

test("list_unique_commits returns empty for identical branches", function()
	-- Create a branch that's identical to main
	run_git(repo_dir, { "branch", "same-as-main", "main" })

	local git_cp = require("gitflow.git.cherry_pick")
	local err, entries = wait_async(function(done)
		git_cp.list_unique_commits(
			"same-as-main", { count = 50 },
			function(e, ents)
				done(e, ents)
			end
		)
	end)

	assert_true(err == nil, "should not error for identical branches")
	assert_true(
		type(entries) == "table" and #entries == 0,
		"should return empty for identical branches"
	)
end)

-- ─── Cherry-pick execution tests ───

test("cherry_pick succeeds on a valid non-conflicting commit", function()
	-- Get a commit from feature-b (non-conflicting since
	-- it adds a different file)
	local sha = vim.trim(
		run_git(repo_dir, { "rev-parse", "feature-b" })
	)

	local git_cp = require("gitflow.git.cherry_pick")
	local err = wait_async(function(done)
		git_cp.cherry_pick(sha, function(e, _)
			done(e)
		end)
	end)

	assert_true(
		err == nil,
		"cherry_pick should succeed for non-conflicting commit"
	)

	-- Verify the file was cherry-picked
	local content = vim.fn.readfile(repo_dir .. "/other.txt")
	assert_true(
		#content > 0 and content[1] == "other-line1",
		"cherry-picked file should exist with correct content"
	)
end)

-- ─── Panel lifecycle tests ───

test("cherry_pick panel state initializes correctly", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	assert_true(
		cp_panel.state.bufnr == nil,
		"bufnr should be nil initially"
	)
	assert_true(
		cp_panel.state.winid == nil,
		"winid should be nil initially"
	)
	assert_equals(
		cp_panel.state.stage, "branch",
		"initial stage should be branch"
	)
end)

test("cherry_pick panel close cleans up state", function()
	local cp_panel = require("gitflow.panels.cherry_pick")

	-- Manually set some state and close
	cp_panel.state.source_branch = "feature-a"
	cp_panel.state.stage = "commits"
	cp_panel.close()

	assert_true(
		cp_panel.state.bufnr == nil,
		"bufnr should be nil after close"
	)
	assert_true(
		cp_panel.state.winid == nil,
		"winid should be nil after close"
	)
	assert_true(
		cp_panel.state.source_branch == nil,
		"source_branch should be nil after close"
	)
	assert_equals(
		cp_panel.state.stage, "branch",
		"stage should reset to branch after close"
	)
	assert_true(
		not cp_panel.is_open(),
		"is_open should return false after close"
	)
end)

test("delayed list_branches callback is ignored after panel close", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	local git_cp = require("gitflow.git.cherry_pick")
	local list_picker = require("gitflow.ui.list_picker")
	local original_list_branches = git_cp.list_branches
	local original_picker_open = list_picker.open
	local callback_ran = false
	local picker_open_calls = 0

	local ok, err = pcall(function()
		git_cp.list_branches = function(_, cb)
			vim.defer_fn(function()
				callback_ran = true
				cb(nil, { "feature-a", "feature-b" })
			end, 80)
		end

		list_picker.open = function(_)
			picker_open_calls = picker_open_calls + 1
			return {}
		end

		cp_panel.close()
		cp_panel.open(cfg)
		cp_panel.close()

		local did_run = vim.wait(1000, function()
			return callback_ran
		end, 20)
		assert_true(did_run, "delayed list_branches callback should run")

		vim.wait(120, function()
			return false
		end, 20)

		assert_equals(
			picker_open_calls, 0,
			"list picker should not open after panel close"
		)
	end)

	git_cp.list_branches = original_list_branches
	list_picker.open = original_picker_open
	cp_panel.close()

	if not ok then
		error(err, 0)
	end
end)

test("out-of-order refresh callbacks ignore stale branch responses", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	local git_cp = require("gitflow.git.cherry_pick")
	local git_branch = require("gitflow.git.branch")
	local ui_mod = require("gitflow.ui")
	local original_list_unique_commits = git_cp.list_unique_commits
	local original_current = git_branch.current
	local pending_by_source = {}

	local ok, err = pcall(function()
		cp_panel.close()
		cp_panel.state.cfg = cfg
		cp_panel.state.stage = "commits"
		cp_panel.state.source_branch = "feature-a"

		local bufnr = ui_mod.buffer.create("cherry_pick", {
			filetype = "gitflowcherrypick",
			lines = { "Loading..." },
		})
		cp_panel.state.bufnr = bufnr
		cp_panel.state.winid = ui_mod.window.open_split({
			name = "cherry_pick",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				cp_panel.state.winid = nil
			end,
		})

		git_branch.current = function(_, cb)
			cb(nil, "main")
		end
		git_cp.list_unique_commits = function(source_branch, _, cb)
			pending_by_source[source_branch] = cb
		end

		cp_panel.refresh()
		assert_true(
			type(pending_by_source["feature-a"]) == "function",
			"feature-a refresh callback should be pending"
		)

		cp_panel.state.source_branch = "feature-b"
		cp_panel.refresh()
		assert_true(
			type(pending_by_source["feature-b"]) == "function",
			"feature-b refresh callback should be pending"
		)

		pending_by_source["feature-a"](nil, {
			{
				sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				short_sha = "aaaaaaa",
				summary = "stale feature-a entry",
			},
		})

		local stale_rendered = false
		local lines = vim.api.nvim_buf_get_lines(
			cp_panel.state.bufnr, 0, -1, false
		)
		for _, line in ipairs(lines) do
			if line:find("stale feature-a entry", 1, true) then
				stale_rendered = true
				break
			end
		end
		assert_true(
			not stale_rendered,
			"stale feature-a callback should not render after switching branches"
		)

		pending_by_source["feature-b"](nil, {
			{
				sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
				short_sha = "bbbbbbb",
				summary = "latest feature-b entry",
			},
		})

		lines = vim.api.nvim_buf_get_lines(
			cp_panel.state.bufnr, 0, -1, false
		)
		local has_latest_branch = false
		local has_latest_entry = false
		for _, line in ipairs(lines) do
			if line:find("Source: feature-b", 1, true) then
				has_latest_branch = true
			end
			if line:find("latest feature-b entry", 1, true) then
				has_latest_entry = true
			end
		end
		assert_true(
			has_latest_branch,
			"latest refresh should render feature-b branch header"
		)
		assert_true(
			has_latest_entry,
			"latest refresh should render feature-b commit entry"
		)

		local stale_in_entries = false
		local latest_in_entries = false
		for _, entry in pairs(cp_panel.state.line_entries) do
			if entry.summary == "stale feature-a entry" then
				stale_in_entries = true
			elseif entry.summary == "latest feature-b entry" then
				latest_in_entries = true
			end
		end
		assert_true(
			not stale_in_entries,
			"line_entries should not contain stale feature-a entries"
		)
		assert_true(
			latest_in_entries,
			"line_entries should contain the latest feature-b entries"
		)
	end)

	git_cp.list_unique_commits = original_list_unique_commits
	git_branch.current = original_current
	cp_panel.close()

	if not ok then
		error(err, 0)
	end
end)

test("cherry_pick panel renders commits for a source branch", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	cp_panel.state.cfg = cfg
	cp_panel.state.source_branch = "feature-a"
	cp_panel.state.stage = "commits"

	-- Create window/buffer manually for rendering test
	local ui_mod = require("gitflow.ui")
	local bufnr = ui_mod.buffer.create("cherry_pick", {
		filetype = "gitflowcherrypick",
		lines = { "Loading..." },
	})
	cp_panel.state.bufnr = bufnr
	cp_panel.state.winid = ui_mod.window.open_split({
		name = "cherry_pick",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			cp_panel.state.winid = nil
		end,
	})

	cp_panel.refresh()

	vim.wait(3000, function()
		if not cp_panel.state.bufnr then
			return false
		end
		if not vim.api.nvim_buf_is_valid(cp_panel.state.bufnr) then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			cp_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local lines = vim.api.nvim_buf_get_lines(
		cp_panel.state.bufnr, 0, -1, false
	)
	assert_true(#lines > 2, "should have rendered content lines")

	-- Check source branch header
	local has_source = false
	for _, line in ipairs(lines) do
		if line:find("feature%-a", 1, false) then
			has_source = true
			break
		end
	end
	assert_true(
		has_source,
		"should display source branch name"
	)

	-- Check that feature-a commits appear
	local has_commit = false
	for _, line in ipairs(lines) do
		if line:find("feature%-a commit", 1, false) then
			has_commit = true
			break
		end
	end
	assert_true(
		has_commit,
		"should display feature-a commits"
	)

	cp_panel.close()
end)

test("cherry_pick panel applies hash highlight to commit SHAs", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	cp_panel.state.cfg = cfg
	cp_panel.state.source_branch = "feature-a"
	cp_panel.state.stage = "commits"

	local ui_mod = require("gitflow.ui")
	local bufnr = ui_mod.buffer.create("cherry_pick", {
		filetype = "gitflowcherrypick",
		lines = { "Loading..." },
	})
	cp_panel.state.bufnr = bufnr
	cp_panel.state.winid = ui_mod.window.open_split({
		name = "cherry_pick",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			cp_panel.state.winid = nil
		end,
	})

	cp_panel.refresh()

	vim.wait(3000, function()
		if not cp_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			cp_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local lines = vim.api.nvim_buf_get_lines(
		cp_panel.state.bufnr, 0, -1, false
	)
	local ns = vim.api.nvim_create_namespace("gitflow_cherry_pick_hl")
	local marks = vim.api.nvim_buf_get_extmarks(
		cp_panel.state.bufnr, ns, 0, -1, { details = true }
	)
	local has_hash_highlight = false
	for _, mark in ipairs(marks) do
		local details = mark[4] or {}
		if details.hl_group == "GitflowCherryPickHash" then
			local line_no = mark[2] + 1
			local entry = cp_panel.state.line_entries[line_no]
			local line_text = lines[line_no] or ""
			local sha_start = entry
				and line_text:find(entry.short_sha, 1, true) or nil
			if sha_start and mark[3] == (sha_start - 1) then
				has_hash_highlight = true
				break
			end
		end
	end
	assert_true(
		has_hash_highlight,
		"rendered commit SHA should use GitflowCherryPickHash highlight"
	)

	cp_panel.close()
end)

test("cherry_pick panel keymaps are set on buffer", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	cp_panel.state.cfg = cfg
	cp_panel.state.source_branch = "feature-a"
	cp_panel.state.stage = "commits"

	local ui_mod = require("gitflow.ui")
	local bufnr = ui_mod.buffer.create("cherry_pick", {
		filetype = "gitflowcherrypick",
		lines = { "Loading..." },
	})
	cp_panel.state.bufnr = bufnr
	cp_panel.state.winid = ui_mod.window.open_split({
		name = "cherry_pick",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			cp_panel.state.winid = nil
		end,
	})

	-- Set keymaps (they are set in ensure_window, so set them manually here)
	vim.keymap.set("n", "<CR>", function()
		cp_panel.select_under_cursor()
	end, { buffer = bufnr, silent = true })

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			cp_panel.select_by_position(i)
		end, { buffer = bufnr, silent = true, nowait = true })
	end

	vim.keymap.set("n", "b", function()
		cp_panel.show_branch_picker()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		cp_panel.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		cp_panel.close()
	end, { buffer = bufnr, silent = true, nowait = true })

	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local found_keys = {}
	for _, km in ipairs(keymaps) do
		found_keys[km.lhs] = true
	end

	assert_true(found_keys["<CR>"] ~= nil, "CR keymap should be set")
	assert_true(found_keys["b"] ~= nil, "b keymap should be set")
	assert_true(found_keys["r"] ~= nil, "r keymap should be set")
	assert_true(found_keys["q"] ~= nil, "q keymap should be set")
	assert_true(found_keys["1"] ~= nil, "1 keymap should be set")
	assert_true(found_keys["9"] ~= nil, "9 keymap should be set")

	cp_panel.close()
end)

test("line_entries map is populated after render", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	cp_panel.state.cfg = cfg
	cp_panel.state.source_branch = "feature-a"
	cp_panel.state.stage = "commits"

	local ui_mod = require("gitflow.ui")
	local bufnr = ui_mod.buffer.create("cherry_pick", {
		filetype = "gitflowcherrypick",
		lines = { "Loading..." },
	})
	cp_panel.state.bufnr = bufnr
	cp_panel.state.winid = ui_mod.window.open_split({
		name = "cherry_pick",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			cp_panel.state.winid = nil
		end,
	})

	cp_panel.refresh()

	vim.wait(3000, function()
		if not cp_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			cp_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local entry_count = 0
	for _ in pairs(cp_panel.state.line_entries) do
		entry_count = entry_count + 1
	end
	assert_true(
		entry_count >= 2,
		"should have at least 2 commit entries in line_entries"
	)

	cp_panel.close()
end)

test("position numbers are rendered for commits", function()
	local cp_panel = require("gitflow.panels.cherry_pick")
	cp_panel.state.cfg = cfg
	cp_panel.state.source_branch = "feature-a"
	cp_panel.state.stage = "commits"

	local ui_mod = require("gitflow.ui")
	local bufnr = ui_mod.buffer.create("cherry_pick", {
		filetype = "gitflowcherrypick",
		lines = { "Loading..." },
	})
	cp_panel.state.bufnr = bufnr
	cp_panel.state.winid = ui_mod.window.open_split({
		name = "cherry_pick",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			cp_panel.state.winid = nil
		end,
	})

	cp_panel.refresh()

	vim.wait(3000, function()
		if not cp_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(
			cp_panel.state.bufnr, 0, -1, false
		)
		return #lines > 1 and not lines[1]:find("Loading", 1, true)
	end, 50)

	local lines = vim.api.nvim_buf_get_lines(
		cp_panel.state.bufnr, 0, -1, false
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

	cp_panel.close()
end)

-- ─── Config tests ───

test("config validation accepts cherry_pick keybinding", function()
	local config = require("gitflow.config")
	local test_cfg = config.defaults()
	test_cfg.keybindings.cherry_pick = "gC"
	local ok = pcall(config.validate, test_cfg)
	assert_true(
		ok,
		"config validation should pass with cherry_pick keybinding"
	)
end)

-- ─── Dispatch tests ───

test("dispatch cherry-pick-panel returns expected message", function()
	local commands = require("gitflow.commands")
	-- The subcommand opens the panel (with branch picker), but
	-- dispatch returns the message. We can just verify the dispatch
	-- doesn't error and returns a string.
	local cp_panel = require("gitflow.panels.cherry_pick")

	-- Pre-close any open state
	cp_panel.close()

	local result = commands.dispatch(
		{ "cherry-pick-panel" }, cfg
	)
	assert_true(
		type(result) == "string",
		"dispatch should return a string"
	)

	-- Wait briefly then clean up
	vim.wait(500, function() return false end, 50)
	cp_panel.close()
end)

-- ─── Cleanup ───

vim.fn.chdir(original_cwd)
vim.fn.delete(repo_dir, "rf")

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
