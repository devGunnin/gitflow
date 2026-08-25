-- scripts/test_status_optimistic.lua — the status panel's optimistic
-- stage/unstage contract: a guess is never allowed to become the resting
-- state, and a destructive verb never resolves against one.
--
-- Driven with `git status`, `git add` and `git reset` stubbed so a call can
-- be held in flight and answered on demand.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, failed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " — " .. tostring(err))
	end
end

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

local gitflow = require("gitflow")
local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_status = require("gitflow.git.status")
local git_branch = require("gitflow.git.branch")
local status_panel = require("gitflow.panels.status")

gitflow.setup({})
local cfg = gitflow.get_config()

-- ── the fake repository ────────────────────────────────────────────────

---@param path string
---@param kind "staged"|"unstaged"|"untracked"|"added"
---@return table
local function file(path, kind)
	local index, worktree = " ", " "
	if kind == "staged" then
		index = "M"
	elseif kind == "unstaged" then
		worktree = "M"
	elseif kind == "added" then
		index = "A"
	elseif kind == "untracked" then
		index, worktree = "?", "?"
	end
	return {
		raw = index .. worktree .. " " .. path,
		path = path,
		original_path = nil,
		index_status = index,
		worktree_status = worktree,
		staged = kind == "staged" or kind == "added",
		unstaged = kind == "unstaged",
		untracked = kind == "untracked",
		ignored = false,
	}
end

---@param groups table
---@return table
local function grouped(groups)
	return {
		staged = groups.staged or {},
		unstaged = groups.unstaged or {},
		untracked = groups.untracked or {},
	}
end

--- What the stubbed `git status` will report next, plus everything a call
--- into git recorded.
local world = {}

local real = {
	fetch = git_status.fetch,
	stage_file = git_status.stage_file,
	unstage_file = git_status.unstage_file,
	revert_file = git_status.revert_file,
	current = git_branch.current,
	git = git.git,
	confirm = ui.input.confirm,
	notify = utils.notify,
}

local function install_stubs()
	world = {
		truth = grouped({}),
		pending = {},   -- held stage/unstage callbacks, in call order
		calls = {},     -- "add <path>" / "reset <path>"
		reverted = {},  -- paths X actually discarded
		confirmed = 0,
		notices = {},
		-- `git status` can be held too, so a test can look at the panel in
		-- the window between the optimistic undo and the reconcile.
		hold_fetch = false,
		held_fetches = {},
		fetches = 0,
	}

	git_status.fetch = function(_, cb)
		world.fetches = world.fetches + 1
		local function answer_fetch()
			cb(nil, nil, world.truth, { code = 0, stdout = "", stderr = "" })
		end
		if world.hold_fetch then
			world.held_fetches[#world.held_fetches + 1] = answer_fetch
			return
		end
		answer_fetch()
	end
	git_status.stage_file = function(path, _, cb)
		world.calls[#world.calls + 1] = "add " .. path
		world.pending[#world.pending + 1] = cb
	end
	git_status.unstage_file = function(path, _, cb)
		world.calls[#world.calls + 1] = "reset " .. path
		world.pending[#world.pending + 1] = cb
	end
	git_status.revert_file = function(path, opts, cb)
		world.reverted[#world.reverted + 1] = path
		world.revert_opts = opts
		cb(nil, { code = 0, stdout = "", stderr = "" })
	end
	git_branch.current = function(_, cb)
		cb(nil, "main")
	end
	-- The only `git` the panel spawns directly is the upstream probe.
	git.git = function(_, _, cb)
		cb({ code = 1, stdout = "", stderr = "fatal: no upstream configured" })
	end
	ui.input.confirm = function()
		world.confirmed = world.confirmed + 1
		return true
	end
	utils.notify = function(message)
		world.notices[#world.notices + 1] = tostring(message)
	end
end

local function restore_stubs()
	git_status.fetch = real.fetch
	git_status.stage_file = real.stage_file
	git_status.unstage_file = real.unstage_file
	git_status.revert_file = real.revert_file
	git_branch.current = real.current
	git.git = real.git
	ui.input.confirm = real.confirm
	utils.notify = real.notify
end

---Answer the `n`th still-unanswered stage/unstage call.
---@param index integer
---@param err string|nil
local function answer(index, err)
	local cb = world.pending[index]
	assert_true(cb ~= nil, ("no git call #%d to answer"):format(index))
	world.pending[index] = false
	cb(err)
end

---Let every held `git status` answer.
local function flush_fetches()
	local held = world.held_fetches
	world.held_fetches = {}
	world.hold_fetch = false
	for _, answer_fetch in ipairs(held) do
		answer_fetch()
	end
end

---@return string
local function notices()
	return table.concat(world.notices, "\n")
end

--- The panel's current picture, read back off the rendered rows rather than
--- off its internals: `{ staged = {...}, unstaged = {...}, untracked = {...} }`.
---@return table<string, string[]>
local function painted()
	local sections = { staged = {}, unstaged = {}, untracked = {} }
	for _, entry in pairs(status_panel.state.line_entries) do
		if entry.kind == "file" then
			local name = "unstaged"
			if entry.diff_staged then
				name = "staged"
			elseif entry.entry.untracked then
				name = "untracked"
			end
			sections[name][#sections[name] + 1] = entry.entry.path
		end
	end
	for _, list in pairs(sections) do
		table.sort(list)
	end
	return sections
end

---@param section string
---@return string
local function shown(section)
	return table.concat(painted()[section], ",")
end

---Put the cursor on the row for `path` in `section`.
---@param section "staged"|"unstaged"|"untracked"
---@param path string
local function cursor_to(section, path)
	for line, entry in pairs(status_panel.state.line_entries) do
		if entry.kind == "file" and entry.entry.path == path then
			local is_staged = entry.diff_staged
			if (section == "staged") == is_staged then
				vim.api.nvim_set_current_win(status_panel.state.winid)
				vim.api.nvim_win_set_cursor(status_panel.state.winid, { line, 0 })
				return
			end
		end
	end
	error(("no %s row for %s"):format(section, path))
end

---Open the panel on `truth` and wait for the first real render.
---@param truth table
local function open_on(truth)
	world.truth = truth
	status_panel.open(cfg, {})
	assert_true(
		vim.wait(2000, function()
			return next(status_panel.state.line_entries) ~= nil
		end, 5),
		"status panel should render its first frame"
	)
end

---@param fn fun()
local function with_panel(fn)
	install_stubs()
	local ok, err = pcall(fn)
	status_panel.close()
	-- A test that leaves a call unanswered would otherwise hand the next one
	-- a panel that refuses every mutation.
	status_panel.state.last = nil
	status_panel.state.busy = nil
	restore_stubs()
	assert_true(ok, tostring(err))
end

-- ── F1 sequence A: two stages, both fail ───────────────────────────────

test("a second stage while one is in flight is refused, not queued", function()
	with_panel(function()
		open_on(grouped({
			unstaged = { file("tracked.txt", "unstaged") },
			untracked = { file("new.txt", "untracked") },
		}))

		cursor_to("unstaged", "tracked.txt")
		status_panel.stage_under_cursor()
		assert_equals(shown("staged"), "tracked.txt", "the guess should paint immediately")

		cursor_to("untracked", "new.txt")
		status_panel.stage_under_cursor()

		assert_equals(#world.calls, 1, "only one git add may be in flight")
		assert_true(
			notices():find("Already busy", 1, true) ~= nil,
			"the second press should say what it is waiting on"
		)
	end)
end)

test("a failed stage ends on git's truth, never on the guess", function()
	with_panel(function()
		open_on(grouped({
			unstaged = { file("tracked.txt", "unstaged") },
			untracked = { file("new.txt", "untracked") },
		}))

		cursor_to("unstaged", "tracked.txt")
		status_panel.stage_under_cursor()
		assert_equals(shown("staged"), "tracked.txt", "guess painted")

		-- The `git add` failed AND the file went away while it was out — a
		-- state no undo can reconstruct, only a fresh `git status`.
		world.truth = grouped({ untracked = { file("new.txt", "untracked") } })
		world.hold_fetch = true
		local before = world.fetches
		answer(1, "git add failed: permission denied")
		assert_true(
			world.fetches > before,
			"the failure path must ask git what is actually true"
		)
		flush_fetches()

		assert_equals(shown("staged"), "", "nothing is staged")
		assert_equals(shown("unstaged"), "", "the vanished file must be gone")
		assert_equals(shown("untracked"), "new.txt", "and the rest is git's truth")
		assert_true(
			notices():find("permission denied", 1, true) ~= nil,
			"the failure must be reported"
		)
	end)
end)

-- ── F1 sequence B: a refresh lands mid-flight ──────────────────────────

test("a refresh that lands mid-flight survives the failing operation's undo", function()
	with_panel(function()
		open_on(grouped({ unstaged = { file("tracked.txt", "unstaged") } }))

		cursor_to("unstaged", "tracked.txt")
		status_panel.stage_under_cursor()
		assert_equals(shown("staged"), "tracked.txt", "guess painted")

		-- While `git add` is still out, a real refresh paints the truth: the
		-- add has not landed, and a second file has been modified since.
		world.truth = grouped({
			unstaged = { file("brand_new.txt", "unstaged"), file("tracked.txt", "unstaged") },
		})
		status_panel.refresh({ files_only = true })
		assert_equals(shown("unstaged"), "brand_new.txt,tracked.txt", "the refresh should paint both")

		-- Hold the reconcile so what the undo itself painted is visible.
		world.hold_fetch = true
		answer(1, "git add failed: index.lock exists")
		assert_equals(
			shown("unstaged"), "brand_new.txt,tracked.txt",
			"the undo rolled the panel back past a newer, true render"
		)
		flush_fetches()
		assert_equals(shown("unstaged"), "brand_new.txt,tracked.txt", "and it stays true")
	end)
end)

-- ── F1: per-row undo across a batch ────────────────────────────────────

test("a partly failed batch puts back only the rows that failed", function()
	with_panel(function()
		open_on(grouped({
			unstaged = { file("a.txt", "unstaged"), file("b.txt", "unstaged") },
		}))

		vim.api.nvim_set_current_win(status_panel.state.winid)
		local first, last
		for line, entry in pairs(status_panel.state.line_entries) do
			if entry.kind == "file" then
				first = (not first or line < first) and line or first
				last = (not last or line > last) and line or last
			end
		end
		vim.api.nvim_win_set_cursor(status_panel.state.winid, { first, 0 })
		vim.cmd("normal! V")
		vim.api.nvim_win_set_cursor(status_panel.state.winid, { last, 0 })
		status_panel.stage_visual()

		assert_equals(#world.calls, 2, "both files should be staged")
		-- a.txt lands, b.txt does not.
		world.truth = grouped({
			staged = { file("a.txt", "staged") },
			unstaged = { file("b.txt", "unstaged") },
		})
		world.hold_fetch = true
		answer(1, nil)
		answer(2, "git add failed: permission denied")

		assert_equals(shown("staged"), "a.txt", "the row that landed must stay staged")
		assert_equals(shown("unstaged"), "b.txt", "only the failed row goes back")
		flush_fetches()
		assert_equals(shown("staged"), "a.txt", "git agrees")
	end)
end)

-- ── F2: a destructive verb never resolves against a guess ──────────────

test("X refuses on a row git has not confirmed, and fires no discard", function()
	with_panel(function()
		open_on(grouped({ staged = { file("brand.txt", "added") } }))

		cursor_to("staged", "brand.txt")
		status_panel.unstage_under_cursor()
		-- `git reset` on an index-added path guesses it back to untracked —
		-- and `untracked` alone would authorise `git clean -f`.
		assert_equals(shown("untracked"), "brand.txt", "the guess should paint as untracked")

		-- The reset lands, but `git status` has not answered yet: the row on
		-- screen is still the guess, and nothing on it is confirmed.
		world.truth = grouped({ untracked = { file("brand.txt", "untracked") } })
		world.hold_fetch = true
		answer(1, nil)
		assert_equals(status_panel.state.busy, nil, "the operation itself is over")
		assert_equals(shown("untracked"), "brand.txt", "the guess is still what is on screen")

		cursor_to("untracked", "brand.txt")
		status_panel.revert_under_cursor()
		assert_equals(#world.reverted, 0, "X must not discard an unconfirmed row")
		assert_equals(world.confirmed, 0, "X must not even offer to discard it")

		-- Confirmed: X behaves exactly as before.
		flush_fetches()
		cursor_to("untracked", "brand.txt")
		status_panel.revert_under_cursor()
		assert_equals(#world.reverted, 1, "X on a confirmed row still discards")
		assert_equals(world.reverted[1], "brand.txt", "the right path")
		assert_equals(
			world.revert_opts.untracked, true,
			"and it carries git's own answer, not a guess"
		)
	end)
end)

-- ── F6: a guess must not seed the next open ───────────────────────────

test("reopening after a close mid-mutation does not paint the guess", function()
	with_panel(function()
		open_on(grouped({ unstaged = { file("tracked.txt", "unstaged") } }))

		cursor_to("unstaged", "tracked.txt")
		status_panel.stage_under_cursor()
		assert_equals(shown("staged"), "tracked.txt", "guess painted")

		-- Closed before `git add` answers: the cached frame still holds the
		-- guess, and it is the first thing a reopen would paint.
		status_panel.close()
		world.hold_fetch = true
		status_panel.open(cfg, {})
		assert_equals(
			shown("staged"), "",
			"the first frame must not paint a row git never confirmed"
		)
		flush_fetches()
		assert_equals(shown("unstaged"), "tracked.txt", "and the refresh paints the truth")
	end)
end)

-- ── F3: the cursor stays in the section the user was in ────────────────

test("the cursor does not cross a section boundary on a partly staged path", function()
	with_panel(function()
		local partly = file("a.lua", "staged")
		partly.worktree_status = "M"
		partly.unstaged = true
		open_on(grouped({
			staged = { partly },
			unstaged = { file("a.lua", "unstaged") },
		}))

		cursor_to("unstaged", "a.lua")
		local before = status_panel.state.line_entries[
			vim.api.nvim_win_get_cursor(status_panel.state.winid)[1]
		]
		assert_equals(before.diff_staged, false, "cursor should start on the unstaged row")

		-- A staged row sorting above a.lua shifts every line below it down.
		world.truth = grouped({
			staged = { file("aaa.lua", "staged"), partly },
			unstaged = { file("a.lua", "unstaged") },
		})
		status_panel.refresh({ files_only = true })

		local after = status_panel.state.line_entries[
			vim.api.nvim_win_get_cursor(status_panel.state.winid)[1]
		]
		assert_true(after ~= nil and after.kind == "file", "cursor should still be on a file row")
		assert_equals(after.entry.path, "a.lua", "still on a.lua")
		assert_equals(after.diff_staged, false, "cursor teleported into the Staged section")
	end)
end)

-- ── F2: the destructive gate at the git layer ─────────────────────────

test("only a confirmed untracked flag authorises `git clean -f`", function()
	local real_git = git.git
	local ok, err = pcall(function()
		---@param untracked any
		---@return string[]  the git subcommands that ran
		local function revert_with(untracked)
			local ran = {}
			git.git = function(argv, _, cb)
				ran[#ran + 1] = argv[1]
				-- Everything up to `clean` fails, so `should_clean` is what
				-- decides whether the file gets deleted.
				local code = (argv[1] == "reset" or argv[1] == "clean") and 0 or 1
				cb({ code = code, stdout = "", stderr = "error: could not restore" })
			end
			real.revert_file("f.txt", { untracked = untracked }, function() end)
			return ran
		end

		assert_true(
			vim.tbl_contains(revert_with(true), "clean"),
			"a confirmed untracked file still gets cleaned"
		)
		assert_true(
			not vim.tbl_contains(revert_with("guess"), "clean"),
			"a non-boolean untracked flag must never reach `git clean -f`"
		)
		assert_true(
			not vim.tbl_contains(revert_with(nil), "clean"),
			"an unknown untracked state must never reach `git clean -f`"
		)
	end)
	git.git = real_git
	assert_true(ok, tostring(err))
end)

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
