-- tests/e2e/commands_spec.lua — command exposure & dispatch tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/commands_spec.lua
--
-- Verifies:
--   1. All expected subcommands are registered
--   2. Commands execute without crashing
--   3. Invalid subcommands produce meaningful error messages

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")

---@param patches table[]
---@param fn fun()
local function with_temporary_patches(patches, fn)
	local originals = {}
	for index, patch in ipairs(patches) do
		originals[index] = patch.table[patch.key]
		patch.table[patch.key] = patch.value
	end

	local ok, err = xpcall(fn, debug.traceback)

	for index = #patches, 1, -1 do
		local patch = patches[index]
		patch.table[patch.key] = originals[index]
	end

	if not ok then
		error(err, 0)
	end
end

---@param fn fun(log_path: string)
local function with_temp_git_log(fn)
	local log_path = vim.fn.tempname()
	local previous = vim.env.GITFLOW_GIT_LOG
	vim.env.GITFLOW_GIT_LOG = log_path

	local ok, err = xpcall(function()
		fn(log_path)
	end, debug.traceback)

	vim.env.GITFLOW_GIT_LOG = previous
	pcall(vim.fn.delete, log_path)

	if not ok then
		error(err, 0)
	end
end

---@param fn fun(log_path: string)
local function with_temp_gh_log(fn)
	local log_path = vim.fn.tempname()
	local previous = vim.env.GITFLOW_GH_LOG
	vim.env.GITFLOW_GH_LOG = log_path

	local ok, err = xpcall(function()
		fn(log_path)
	end, debug.traceback)

	vim.env.GITFLOW_GH_LOG = previous
	pcall(vim.fn.delete, log_path)

	if not ok then
		error(err, 0)
	end
end

-- Generate EXPECTED_SUBCOMMANDS from the live registered set so
-- new subcommands are automatically covered without manual updates.
local EXPECTED_SUBCOMMANDS = vim.tbl_keys(commands.subcommands)
table.sort(EXPECTED_SUBCOMMANDS)

T.run_suite("E2E: Command Exposure & Dispatch", {

	-- ── Subcommand registration ─────────────────────────────────────────

	["all expected subcommands are registered"] = function()
		for _, name in ipairs(EXPECTED_SUBCOMMANDS) do
			T.assert_true(
				commands.subcommands[name] ~= nil,
				("subcommand '%s' should be registered"):format(name)
			)
		end
	end,

	["at least 25 subcommands registered"] = function()
		local count = 0
		for _ in pairs(commands.subcommands) do
			count = count + 1
		end
		T.assert_true(
			count >= 25,
			("expected >= 25 subcommands, got %d"):format(count)
		)
	end,

	["each subcommand has description and run function"] = function()
		for name, sub in pairs(commands.subcommands) do
			T.assert_true(
				type(sub.description) == "string" and sub.description ~= "",
				("subcommand '%s' should have a non-empty description"):format(name)
			)
			T.assert_true(
				type(sub.run) == "function",
				("subcommand '%s' should have a run function"):format(name)
			)
		end
	end,

	-- ── :Gitflow command registration ───────────────────────────────────

	[":Gitflow command exists with completion"] = function()
		local cmds = vim.api.nvim_get_commands({})
		T.assert_true(
			cmds.Gitflow ~= nil,
			":Gitflow command should be registered"
		)
	end,

	-- ── help subcommand ─────────────────────────────────────────────────

	["help executes without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "help" }, cfg)
		end)
		T.assert_true(ok, "help should not crash: " .. (err or ""))
	end,

	-- ── palette subcommand ────────────────────────────────────────────────

	["palette executes without crash"] = function()
		local palette_panel = require("gitflow.panels.palette")
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "palette" }, cfg)
		end)
		T.assert_true(ok, "palette should not crash: " .. (err or ""))
		T.assert_true(
			palette_panel.is_open(),
			"palette should open after dispatch"
		)
		T.cleanup_panels()
	end,

	-- ── commit + quick actions ────────────────────────────────────────────

	["commit executes prompt-driven flow without crash"] = function()
		local git_status = require("gitflow.git.status")
		local input = require("gitflow.ui.input")

		with_temp_git_log(function(log_path)
			with_temporary_patches({
				{
					table = git_status,
					key = "fetch",
					value = function(_, cb)
						cb(nil, {}, {
							staged = { { path = "tracked.txt" } },
							unstaged = {},
							untracked = {},
						}, { code = 0, stdout = "", stderr = "" })
					end,
				},
				{
					table = input,
					key = "prompt",
					value = function(opts, on_confirm)
						T.assert_true(opts.multiline, "commit should use the multiline composer")
						T.assert_equals(opts.draft_key, "commit:create:message", "commit should retain a draft")
						on_confirm("Test commit from E2E")
					end,
				},
				{
					table = input,
					key = "confirm",
					value = function()
						return true, 1
					end,
				},
			}, function()
				local result
				local ok, err = T.pcall_message(function()
					result = commands.dispatch({ "commit" }, cfg)
				end)
				T.assert_true(ok, "commit should not crash: " .. (err or ""))
				T.assert_contains(
					result,
					"Commit prompt opened",
					"commit should report opening prompt"
				)

				T.drain_jobs(3000)
				local lines = T.read_file(log_path)
				T.assert_true(
					T.find_line(lines, "commit -m Test commit from E2E") ~= nil,
					"commit flow should invoke git commit with prompted message"
				)
			end)
		end)
	end,

	["quick-commit executes prompt-driven flow without crash"] = function()
		local git_status = require("gitflow.git.status")
		local input = require("gitflow.ui.input")

		with_temp_git_log(function(log_path)
			with_temporary_patches({
				{
					table = git_status,
					key = "fetch",
					value = function(_, cb)
						cb(nil, {}, {
							staged = { { path = "tracked.txt" } },
							unstaged = {},
							untracked = {},
						}, { code = 0, stdout = "", stderr = "" })
					end,
				},
				{
					table = input,
					key = "prompt",
					value = function(opts, on_confirm)
						T.assert_true(opts.multiline, "quick commit should use the multiline composer")
						T.assert_equals(opts.draft_key, "commit:quick:message", "quick commit should retain a draft")
						on_confirm("Quick commit from E2E")
					end,
				},
			}, function()
				local result
				local ok, err = T.pcall_message(function()
					result = commands.dispatch({ "quick-commit" }, cfg)
				end)
				T.assert_true(ok, "quick-commit should not crash: " .. (err or ""))
				T.assert_contains(
					result,
					"Running quick commit",
					"quick-commit should return execution message"
				)

				T.drain_jobs(3000)
				local lines = T.read_file(log_path)
				T.assert_true(
					T.find_line(lines, "add -A") ~= nil,
					"quick-commit should stage all changes"
				)
				T.assert_true(
					T.find_line(lines, "commit -m Quick commit from E2E") ~= nil,
					"quick-commit should invoke git commit"
				)
			end)
		end)
	end,

	["quick-push executes prompt-driven flow without crash"] = function()
		local git_status = require("gitflow.git.status")
		local input = require("gitflow.ui.input")

		with_temp_git_log(function(log_path)
			with_temporary_patches({
				{
					table = git_status,
					key = "fetch",
					value = function(_, cb)
						cb(nil, {}, {
							staged = { { path = "tracked.txt" } },
							unstaged = {},
							untracked = {},
						}, { code = 0, stdout = "", stderr = "" })
					end,
				},
				{
					table = input,
					key = "prompt",
					value = function(_, on_confirm)
						on_confirm("Quick push from E2E")
					end,
				},
			}, function()
				local result
				local ok, err = T.pcall_message(function()
					result = commands.dispatch({ "quick-push" }, cfg)
				end)
				T.assert_true(ok, "quick-push should not crash: " .. (err or ""))
				T.assert_contains(
					result,
					"Running quick push",
					"quick-push should return execution message"
				)

				T.drain_jobs(3000)
				local lines = T.read_file(log_path)
				T.assert_true(
					T.find_line(lines, "commit -m Quick push from E2E") ~= nil,
					"quick-push should invoke git commit"
				)
				T.assert_true(
					T.find_line(lines, "push") ~= nil,
					"quick-push should invoke git push"
				)
			end)
		end)
	end,

	-- ── open / close subcommands ────────────────────────────────────────

	["open creates a window and close removes it"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "open" }, cfg)
		end)
		T.assert_true(ok, "open should not crash: " .. (err or ""))
		T.assert_true(
			commands.state.panel_window ~= nil,
			"open should set panel_window"
		)

		commands.dispatch({ "close" }, cfg)
		T.assert_true(
			commands.state.panel_window == nil
				or not vim.api.nvim_win_is_valid(commands.state.panel_window),
			"close should clear panel window"
		)
	end,

	-- ── status subcommand ───────────────────────────────────────────────

	["status opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "status" }, cfg)
		end)
		T.assert_true(ok, "status should not crash: " .. (err or ""))
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("status")
		T.assert_true(
			bufnr ~= nil,
			"status should create a buffer"
		)
		T.cleanup_panels()
	end,

	-- ── branch subcommand ───────────────────────────────────────────────

	["branch opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "branch" }, cfg)
		end)
		T.assert_true(ok, "branch should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── diff subcommand ─────────────────────────────────────────────────

	["diff opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "diff" }, cfg)
		end)
		T.assert_true(ok, "diff should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── log subcommand ──────────────────────────────────────────────────

	["log opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "log" }, cfg)
		end)
		T.assert_true(ok, "log should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── stash subcommand ────────────────────────────────────────────────

	["stash list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "stash", "list" }, cfg)
		end)
		T.assert_true(ok, "stash list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── fetch subcommand ────────────────────────────────────────────────

	["fetch executes without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "fetch" }, cfg)
		end)
		T.assert_true(ok, "fetch should not crash: " .. (err or ""))
		T.drain_jobs(3000)
	end,

	-- ── pull subcommand ─────────────────────────────────────────────────

	["pull executes without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "pull" }, cfg)
		end)
		T.assert_true(ok, "pull should not crash: " .. (err or ""))
		T.drain_jobs(3000)
	end,

	-- ── push subcommand ─────────────────────────────────────────────────

	["push executes without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "push" }, cfg)
		end)
		T.assert_true(ok, "push should not crash: " .. (err or ""))
		T.drain_jobs(3000)
	end,

	-- ── sync subcommand ─────────────────────────────────────────────────

	["sync executes without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "sync" }, cfg)
		end)
		T.assert_true(ok, "sync should not crash: " .. (err or ""))
		T.drain_jobs(3000)
	end,

	-- ── conflicts subcommand ────────────────────────────────────────────

	["conflicts opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "conflicts" }, cfg)
		end)
		T.assert_true(ok, "conflicts should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── conflict alias ──────────────────────────────────────────────────

	["conflict alias opens same panel"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "conflict" }, cfg)
		end)
		T.assert_true(ok, "conflict should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── issue subcommand ────────────────────────────────────────────────

	["issue list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "issue", "list" }, cfg)
		end)
		T.assert_true(ok, "issue list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── pr subcommand ───────────────────────────────────────────────────

	["pr list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "pr", "list" }, cfg)
		end)
		T.assert_true(ok, "pr list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── label subcommand ────────────────────────────────────────────────

	["label list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "label", "list" }, cfg)
		end)
		T.assert_true(ok, "label list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── refresh subcommand ──────────────────────────────────────────────

	["refresh executes without crash"] = function()
		-- open a panel first so refresh has something to refresh
		commands.dispatch({ "open" }, cfg)
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "refresh" }, cfg)
		end)
		T.assert_true(ok, "refresh should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── merge subcommand (no args gives usage) ──────────────────────────

	["merge without args returns usage without crash"] = function()
		local result
		local ok, err = T.pcall_message(function()
			result = commands.dispatch({ "merge" }, cfg)
		end)
		T.assert_true(ok, "merge should not crash: " .. (err or ""))
		T.assert_contains(
			result,
			"Usage",
			"merge without args should show usage"
		)
	end,

	-- ── rebase subcommand (no args gives usage) ─────────────────────────

	["rebase without args returns usage without crash"] = function()
		local result
		local ok, err = T.pcall_message(function()
			result = commands.dispatch({ "rebase" }, cfg)
		end)
		T.assert_true(ok, "rebase should not crash: " .. (err or ""))
		T.assert_contains(
			result,
			"Usage",
			"rebase without args should show usage"
		)
	end,

	-- ── cherry-pick subcommand (no args gives usage) ────────────────────

	["cherry-pick without args returns usage without crash"] = function()
		local result
		local ok, err = T.pcall_message(function()
			result = commands.dispatch({ "cherry-pick" }, cfg)
		end)
		T.assert_true(ok, "cherry-pick should not crash: " .. (err or ""))
		T.assert_contains(
			result,
			"Usage",
			"cherry-pick without args should show usage"
		)
	end,

	-- ── Invalid subcommand produces error ───────────────────────────────

	["invalid subcommand returns error message"] = function()
		local result = commands.dispatch({ "nonexistent-cmd" }, cfg)
		T.assert_contains(
			result,
			"Unknown",
			"invalid subcommand should mention 'Unknown'"
		)
		T.assert_contains(
			result,
			"nonexistent-cmd",
			"error should include the invalid command name"
		)
	end,

	-- ── dispatch with no args shows usage ───────────────────────────────

	["dispatch with no args shows usage"] = function()
		local result = commands.dispatch({}, cfg)
		T.assert_contains(
			result,
			"Gitflow usage",
			"no-args dispatch should show usage"
		)
	end,

	-- ── tab completion returns subcommand names ─────────────────────────

	["tab completion returns subcommand names"] = function()
		local candidates = commands.complete("", "Gitflow ", 9)
		T.assert_true(
			type(candidates) == "table",
			"complete should return a table"
		)
		T.assert_true(
			#candidates >= 20,
			("expected >= 20 completion candidates, got %d"):format(
				#candidates
			)
		)
		T.assert_true(
			T.contains(candidates, "status"),
			"completion should include 'status'"
		)
		T.assert_true(
			T.contains(candidates, "branch"),
			"completion should include 'branch'"
		)
	end,

	-- ── palette entries cover all commands ───────────────────────────────

	["palette_entries returns entries for all subcommands"] = function()
		local entries = commands.palette_entries(cfg)
		T.assert_true(
			type(entries) == "table",
			"palette_entries should return a table"
		)
		T.assert_true(
			#entries >= 25,
			("expected >= 25 palette entries, got %d"):format(#entries)
		)

		-- check that each entry has required fields
		for _, entry in ipairs(entries) do
			T.assert_true(
				type(entry.name) == "string" and entry.name ~= "",
				"palette entry should have a name"
			)
			T.assert_true(
				type(entry.description) == "string",
				"palette entry should have a description"
			)
		end
	end,

	-- ── Silent failures must surface, never report success ───────────────

	["issue edit with an unrecognized key refuses and calls no gh"] = function()
		with_temp_gh_log(function(log_path)
			local result = commands.dispatch(
				{ "issue", "edit", "7", "mislabel=x" }, cfg
			)
			T.drain_jobs(2000)

			T.assert_contains(result, "mislabel=x", "should name the bad option")
			T.assert_true(
				result:find("Updating issue", 1, true) == nil,
				"should not report an update in progress"
			)
			T.assert_true(
				T.find_line(T.read_file(log_path), "issue edit") == nil,
				"no gh issue edit should be invoked"
			)
		end)
	end,

	["issue edit with no options refuses instead of reporting success"] = function()
		with_temp_gh_log(function(log_path)
			local result = commands.dispatch({ "issue", "edit", "7" }, cfg)
			T.drain_jobs(2000)

			T.assert_contains(result, "No edits requested", "should refuse an empty edit")
			T.assert_true(
				T.find_line(T.read_file(log_path), "issue edit") == nil,
				"no gh issue edit should be invoked"
			)
		end)
	end,

	["issue edit with a recognized key still dispatches"] = function()
		with_temp_gh_log(function(log_path)
			local result = commands.dispatch(
				{ "issue", "edit", "7", "title=Renamed" }, cfg
			)
			T.drain_jobs(2000)

			T.assert_contains(result, "Updating issue", "valid edit should proceed")
			T.assert_true(
				T.find_line(T.read_file(log_path), "issue edit 7 --title Renamed") ~= nil,
				"gh issue edit should carry the new title"
			)
		end)
	end,

	["pr edit with an unrecognized key refuses and calls no gh"] = function()
		with_temp_gh_log(function(log_path)
			local result = commands.dispatch(
				{ "pr", "edit", "12", "reviewer=alice" }, cfg
			)
			T.drain_jobs(2000)

			T.assert_contains(result, "reviewer=alice", "should name the bad option")
			T.assert_true(
				result:find("Updating PR", 1, true) == nil,
				"should not report an update in progress"
			)
			T.assert_true(
				T.find_line(T.read_file(log_path), "pr edit") == nil,
				"no gh pr edit should be invoked"
			)
		end)
	end,

	["a throwing subcommand yields a clean error keeping the cause"] = function()
		commands.register_subcommand("e2e-throwing", {
			description = "test-only handler that always throws",
			run = function()
				error("boom from the handler")
			end,
		})

		local notifications = {}
		local orig_notify = vim.notify
		vim.notify = function(msg, level, ...)
			notifications[#notifications + 1] = { message = msg, level = level }
			return orig_notify(msg, level, ...)
		end

		local ok, result = pcall(commands.dispatch, { "e2e-throwing" }, cfg)

		vim.notify = orig_notify
		commands.subcommands["e2e-throwing"] = nil

		T.assert_true(ok, "dispatch should not propagate a raw handler error")
		T.assert_contains(result, "e2e-throwing", "error should name the subcommand")
		T.assert_contains(result, "boom from the handler", "error should keep the cause")
		T.assert_contains(result, "stack traceback", "error should keep the traceback")

		local notified = false
		for _, n in ipairs(notifications) do
			if n.message
				and n.message:find("boom from the handler", 1, true)
				and n.level == vim.log.levels.ERROR
			then
				notified = true
			end
		end
		T.assert_true(notified, "handler failure should notify at ERROR level")
	end,

	["stash pop with a non-numeric index refuses instead of popping"] = function()
		with_temp_git_log(function(log_path)
			local result = commands.dispatch({ "stash", "pop", "3x" }, cfg)
			T.drain_jobs(2000)

			T.assert_contains(result, "Invalid stash index", "should refuse the bad index")
			T.assert_contains(result, "3x", "should name the bad index")
			T.assert_true(
				T.find_line(T.read_file(log_path), "stash pop") == nil,
				"no git stash pop should be invoked for an invalid index"
			)
		end)
	end,

	["stash apply with a non-numeric index refuses instead of applying"] = function()
		with_temp_git_log(function(log_path)
			local result = commands.dispatch({ "stash", "apply", "oops" }, cfg)
			T.drain_jobs(2000)

			T.assert_contains(result, "Invalid stash index", "should refuse the bad index")
			T.assert_true(
				T.find_line(T.read_file(log_path), "stash apply") == nil,
				"no git stash apply should be invoked for an invalid index"
			)
		end)
	end,

	["stash pop with a valid index still dispatches"] = function()
		with_temp_git_log(function(log_path)
			commands.dispatch({ "stash", "pop", "2" }, cfg)
			T.drain_jobs(2000)

			T.assert_true(
				T.find_line(T.read_file(log_path), "stash pop") ~= nil,
				"a valid index should still pop"
			)
		end)
	end,

	["worktree add -b without a branch name errors and runs no git"] = function()
		with_temp_git_log(function(log_path)
			local result = commands.dispatch(
				{ "worktree", "add", "/tmp/gitflow-wt-nob", "-b" }, cfg
			)
			T.drain_jobs(2000)

			T.assert_contains(result, "requires a branch name", "should reject the bare -b")
			T.assert_true(
				T.find_line(T.read_file(log_path), "worktree add") == nil,
				"no git worktree add should be invoked"
			)
		end)
	end,

	-- ── per-area registration seam ───────────────────────────────────────

	["register_subcommand refuses a non-function complete"] = function()
		local ok, err = pcall(commands.register_subcommand, "e2e-bad-complete", {
			description = "test-only handler with a broken completer",
			run = function() end,
			complete = "not-a-function",
		})
		commands.subcommands["e2e-bad-complete"] = nil

		T.assert_true(not ok, "a non-function complete should be refused")
		T.assert_contains(
			tostring(err),
			"complete must be a function",
			"refusal should name the offending field"
		)
		T.assert_true(
			commands.subcommands["e2e-bad-complete"] == nil,
			"a refused subcommand should not be registered"
		)
	end,

	["a registered complete function drives :Gitflow completion"] = function()
		local seen
		commands.register_subcommand("e2e-completing", {
			description = "test-only handler with a completer",
			run = function()
				return "ok"
			end,
			complete = function(arglead, cmdline, args)
				seen = { arglead = arglead, cmdline = cmdline, args = args }
				return { "alpha", "beta" }
			end,
		})

		local candidates = commands.complete("al", "Gitflow e2e-completing al", 25)
		commands.subcommands["e2e-completing"] = nil

		T.assert_deep_equals(
			candidates,
			{ "alpha", "beta" },
			"completion should come from the subcommand's own completer"
		)
		T.assert_true(seen ~= nil, "the completer should have been called")
		T.assert_equals(seen.arglead, "al", "completer should receive the arglead")
		T.assert_equals(seen.args[2], "e2e-completing", "completer should receive the split cmdline")
	end,

	["a subcommand without a completer completes to nothing"] = function()
		T.assert_deep_equals(
			commands.complete("", "Gitflow status ", 16),
			{},
			"a subcommand that registers no completer should offer no candidates"
		)
	end,

	["close closes panels owned by every area"] = function()
		local status_panel = require("gitflow.panels.status")
		local conflict_panel = require("gitflow.panels.conflict")
		local palette_panel = require("gitflow.panels.palette")

		commands.dispatch({ "status" }, cfg)
		commands.dispatch({ "conflicts" }, cfg)
		commands.dispatch({ "palette" }, cfg)
		T.drain_jobs(3000)

		T.assert_true(status_panel.is_open(), "status panel should be open before close")
		T.assert_true(conflict_panel.is_open(), "conflict panel should be open before close")
		T.assert_true(palette_panel.is_open(), "palette panel should be open before close")

		commands.dispatch({ "close" }, cfg)

		-- One panel per area proves close walks every registered area, not a
		-- hand-maintained list inside the dispatcher.
		T.assert_true(not status_panel.is_open(), "close should close the workspace area's panels")
		T.assert_true(not conflict_panel.is_open(), "close should close the history area's panels")
		T.assert_true(not palette_panel.is_open(), "close should close the shell area's panels")
		T.cleanup_panels()
	end,

	["worktree add -b followed by a flag errors"] = function()
		with_temp_git_log(function(log_path)
			local result = commands.dispatch(
				{ "worktree", "add", "/tmp/gitflow-wt-nob2", "-b", "--force" }, cfg
			)
			T.drain_jobs(2000)

			T.assert_contains(result, "requires a branch name", "should reject a flag as branch")
			T.assert_true(
				T.find_line(T.read_file(log_path), "worktree add") == nil,
				"no git worktree add should be invoked"
			)
		end)
	end,
})

print("E2E command exposure tests passed")
