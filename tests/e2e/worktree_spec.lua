-- tests/e2e/worktree_spec.lua — worktree panel E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/worktree_spec.lua
--
-- Verifies:
--   1. worktree subcommand registration and dispatch
--   2. Panel open/close, buffer creation, keymaps
--   3. --porcelain parsing (branch / detached / locked / prunable / bare)
--   4. add / remove / prune command dispatch through the git stub

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local git_worktree = require("gitflow.git.worktree")

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

-- Stub ui.input.prompt so a sequence of prompts is answered from a queue.
-- A `nil` answer simulates <Esc> (on_confirm is not called); an empty string
-- simulates an empty-but-confirmed entry.
---@param answers (string|nil)[]
---@param fn fun()
local function with_prompt_answers(answers, fn)
	local input = require("gitflow.ui.input")
	local original = input.prompt
	local i = 0
	input.prompt = function(_, on_confirm)
		i = i + 1
		local answer = answers[i]
		if answer == nil then
			return
		end
		on_confirm(answer)
	end

	local ok, err = xpcall(fn, debug.traceback)
	input.prompt = original
	if not ok then
		error(err, 0)
	end
end

-- Stub ui.input.confirm so a confirmation dialog answers deterministically.
-- Headless nvim's vim.fn.confirm() returns the default choice (no prompt UI),
-- which is "&Cancel" for remove/move — tests that expect the mutation to
-- proceed must stub this to simulate the user confirming.
---@param answer boolean
---@param fn fun()
local function with_confirm_answer(answer, fn)
	local input = require("gitflow.ui.input")
	local original = input.confirm
	input.confirm = function()
		return answer
	end

	local ok, err = xpcall(fn, debug.traceback)
	input.confirm = original
	if not ok then
		error(err, 0)
	end
end

-- Stub the branch picker so the base ref is chosen deterministically.
---@param ref string
---@param fn fun()
local function with_picker_choice(ref, fn)
	local list_picker = require("gitflow.ui.list_picker")
	local original = list_picker.open
	list_picker.open = function(opts)
		opts.on_submit({ ref })
	end

	local ok, err = xpcall(fn, debug.traceback)
	list_picker.open = original
	if not ok then
		error(err, 0)
	end
end

T.run_suite("E2E: Worktree Panel", {

	-- ── Subcommand registration ─────────────────────────────────────

	["worktree subcommand is registered"] = function()
		T.assert_true(
			commands.subcommands["worktree"] ~= nil,
			"worktree subcommand should be registered"
		)
	end,

	["worktree subcommand has description and run"] = function()
		local sub = commands.subcommands["worktree"]
		T.assert_true(
			type(sub.description) == "string" and sub.description ~= "",
			"worktree should have a non-empty description"
		)
		T.assert_true(
			type(sub.run) == "function",
			"worktree should have a run function"
		)
	end,

	-- ── Panel open / default action ─────────────────────────────────

	["worktree list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "worktree", "list" }, cfg)
		end)
		T.assert_true(ok, "worktree list should not crash: " .. (err or ""))
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("worktree")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"worktree buffer should exist after :Gitflow worktree list"
		)
		T.cleanup_panels()
	end,

	["worktree default action is list"] = function()
		local result
		local ok, err = T.pcall_message(function()
			result = commands.dispatch({ "worktree" }, cfg)
		end)
		T.assert_true(ok, "worktree default should not crash: " .. (err or ""))
		T.assert_contains(
			result, "Worktree panel opened",
			"default worktree action should open panel"
		)
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── Panel keymaps ───────────────────────────────────────────────

	["worktree panel has expected keymaps"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("worktree")
		T.assert_true(bufnr ~= nil, "worktree buffer should exist")
		T.assert_keymaps(bufnr,
			{ "q", "r", "a", "d", "D", "m", "L", "p", "<CR>" })

		worktree_panel.close()
	end,

	-- ── Panel content from stub ─────────────────────────────────────

	["worktree panel renders entries from stub"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("worktree")
		T.assert_true(bufnr ~= nil, "worktree buffer should exist")

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "main") ~= nil,
			"should render the main worktree branch"
		)
		T.assert_true(
			T.find_line(lines, "feature/test") ~= nil,
			"should render the feature worktree branch"
		)
		T.assert_true(
			T.find_line(lines, "[locked]") ~= nil,
			"should mark the locked worktree"
		)
		T.assert_true(
			T.find_line(lines, "detached") ~= nil,
			"should render the detached worktree"
		)
		T.assert_true(
			T.find_line(lines, "[current]") ~= nil,
			"the cwd worktree should be marked current"
		)

		worktree_panel.close()
	end,

	-- ── Parser ──────────────────────────────────────────────────────

	["parse handles branch / detached / locked / prunable"] = function()
		local out = table.concat({
			"worktree /repo",
			"HEAD abc1234",
			"branch refs/heads/main",
			"",
			"worktree /repo-feat",
			"HEAD def5678",
			"branch refs/heads/feature/x",
			"locked needs review",
			"",
			"worktree /repo-old",
			"HEAD 0001111",
			"detached",
			"prunable gitdir file points to non-existent location",
			"",
		}, "\n")

		local entries = git_worktree.parse(out)
		T.assert_equals(#entries, 3, "should parse three worktrees")

		T.assert_equals(entries[1].branch, "main", "entry 1 branch")
		T.assert_false(entries[1].is_detached, "entry 1 not detached")

		T.assert_equals(entries[2].branch, "feature/x", "entry 2 branch")
		T.assert_true(entries[2].is_locked, "entry 2 locked")
		T.assert_equals(
			entries[2].lock_reason, "needs review", "entry 2 lock reason"
		)

		T.assert_true(entries[3].is_detached, "entry 3 detached")
		T.assert_equals(entries[3].branch, nil, "entry 3 has no branch")
		T.assert_true(entries[3].is_prunable, "entry 3 prunable")
	end,

	["parse handles a bare worktree"] = function()
		local out = table.concat({
			"worktree /repo.git",
			"bare",
			"",
		}, "\n")
		local entries = git_worktree.parse(out)
		T.assert_equals(#entries, 1, "should parse one entry")
		T.assert_true(entries[1].is_bare, "should be bare")
		T.assert_equals(entries[1].branch, nil, "bare has no branch")
	end,

	["parse handles empty output"] = function()
		T.assert_equals(#git_worktree.parse(""), 0, "empty => no entries")
	end,

	-- ── Command dispatch hits the git stub ──────────────────────────

	["worktree add dispatches git worktree add"] = function()
		with_temp_git_log(function(log_path)
			commands.dispatch(
				{ "worktree", "add", "/tmp/gitflow-wt-new", "main" }, cfg
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			local found = false
			for _, line in ipairs(lines) do
				if line:find("worktree add", 1, true)
					and line:find("/tmp/gitflow-wt-new", 1, true) then
					found = true
				end
			end
			T.assert_true(found, "should invoke `git worktree add <path>`")
		end)
		T.cleanup_panels()
	end,

	["worktree add -b passes a new branch flag"] = function()
		with_temp_git_log(function(log_path)
			commands.dispatch(
				{ "worktree", "add", "/tmp/gitflow-wt-b", "-b", "feat/new" }, cfg
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			local found = false
			for _, line in ipairs(lines) do
				if line:find("worktree add", 1, true)
					and line:find("-b feat/new", 1, true) then
					found = true
				end
			end
			T.assert_true(found, "should pass `-b feat/new`")
		end)
		T.cleanup_panels()
	end,

	["worktree prune dispatches git worktree prune"] = function()
		with_temp_git_log(function(log_path)
			commands.dispatch({ "worktree", "prune" }, cfg)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			local found = false
			for _, line in ipairs(lines) do
				if line:find("worktree prune", 1, true) then
					found = true
				end
			end
			T.assert_true(found, "should invoke `git worktree prune`")
		end)
		T.cleanup_panels()
	end,

	-- ── Panel add flow (sequential prompts) ─────────────────────────

	["panel add: pick base + new branch runs `add -b <branch> <path> <base>`"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(2000)

		with_temp_git_log(function(log_path)
			-- path prompt, then picker chooses "main", then branch name
			with_picker_choice("main", function()
				with_prompt_answers(
					{ "/tmp/gitflow-wt-flow", "feat/from-main" },
					function()
						worktree_panel.add_worktree()
						T.drain_jobs(2000)
					end
				)
			end)

			local lines = T.read_file(log_path)
			local found = false
			for _, line in ipairs(lines) do
				if line:find("worktree add", 1, true)
					and line:find("-b feat/from-main", 1, true)
					and line:find("/tmp/gitflow-wt-flow", 1, true)
					and line:match("%smain%s*$") then
					found = true
				end
			end
			T.assert_true(
				found,
				"new-branch flow should base the branch on the picked ref"
			)
		end)

		worktree_panel.close()
	end,

	["panel add: pick base + empty branch checks out the ref (no -b)"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(2000)

		with_temp_git_log(function(log_path)
			-- picker chooses "develop"; empty branch name => plain checkout
			with_picker_choice("develop", function()
				with_prompt_answers(
					{ "/tmp/gitflow-wt-existing", "" },
					function()
						worktree_panel.add_worktree()
						T.drain_jobs(2000)
					end
				)
			end)

			local lines = T.read_file(log_path)
			local found_checkout, found_b = false, false
			for _, line in ipairs(lines) do
				if line:find("worktree add", 1, true)
					and line:find("/tmp/gitflow-wt-existing", 1, true)
					and line:find("develop", 1, true) then
					found_checkout = true
				end
				if line:find("worktree add", 1, true)
					and line:find("-b ", 1, true) then
					found_b = true
				end
			end
			T.assert_true(
				found_checkout, "should check out the picked ref"
			)
			T.assert_false(
				found_b, "existing-checkout flow should not pass -b"
			)
		end)

		worktree_panel.close()
	end,

	["unknown worktree action returns usage"] = function()
		local result = commands.dispatch({ "worktree", "bogus" }, cfg)
		T.assert_contains(
			result, "Unknown worktree action",
			"unknown action should report an error"
		)
		T.cleanup_panels()
	end,

	-- ── lock / unlock / move ────────────────────────────────────────

	["worktree move/lock/unlock dispatch the matching git command"] = function()
		with_temp_git_log(function(log_path)
			commands.dispatch(
				{ "worktree", "move", "/tmp/a", "/tmp/b" }, cfg)
			commands.dispatch(
				{ "worktree", "lock", "/tmp/a", "in", "use" }, cfg)
			commands.dispatch({ "worktree", "unlock", "/tmp/a" }, cfg)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			local move_, lock_, unlock_ = false, false, false
			for _, line in ipairs(lines) do
				if line:find("worktree move /tmp/a /tmp/b", 1, true) then
					move_ = true
				end
				if line:find("worktree lock", 1, true)
					and line:find("/tmp/a", 1, true) then
					lock_ = true
				end
				if line:find("worktree unlock /tmp/a", 1, true) then
					unlock_ = true
				end
			end
			T.assert_true(move_, "move should run `git worktree move <a> <b>`")
			T.assert_true(lock_, "lock should run `git worktree lock <a>`")
			T.assert_true(unlock_, "unlock should run `git worktree unlock <a>`")
		end)
		T.cleanup_panels()
	end,

	["toggle_lock on a locked worktree unlocks it"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(3000)

		-- The stub fixture marks /tmp/gitflow-feature as locked.
		local locked_line
		for line, entry in pairs(worktree_panel.state.line_entries) do
			if entry.is_locked then
				locked_line = line
			end
		end
		T.assert_true(locked_line ~= nil, "fixture should have a locked worktree")

		with_temp_git_log(function(log_path)
			vim.api.nvim_set_current_win(worktree_panel.state.winid)
			vim.api.nvim_win_set_cursor(
				worktree_panel.state.winid, { locked_line, 0 })
			worktree_panel.toggle_lock_under_cursor()
			T.drain_jobs(2000)

			local lines = T.read_file(log_path)
			local found = false
			for _, line in ipairs(lines) do
				if line:find("worktree unlock", 1, true)
					and line:find("/tmp/gitflow-feature", 1, true) then
					found = true
				end
			end
			T.assert_true(found, "a locked worktree should be unlocked")
		end)

		worktree_panel.close()
	end,

	["removing a locked worktree without force is blocked"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(3000)

		local locked_line
		for line, entry in pairs(worktree_panel.state.line_entries) do
			if entry.is_locked then
				locked_line = line
			end
		end
		T.assert_true(locked_line ~= nil, "fixture should have a locked worktree")

		with_temp_git_log(function(log_path)
			vim.api.nvim_set_current_win(worktree_panel.state.winid)
			vim.api.nvim_win_set_cursor(
				worktree_panel.state.winid, { locked_line, 0 })
			worktree_panel.remove_under_cursor(false)
			T.drain_jobs(1000)

			local lines = T.read_file(log_path)
			local removed = false
			for _, line in ipairs(lines) do
				if line:find("worktree remove", 1, true) then
					removed = true
				end
			end
			T.assert_false(removed,
				"a non-force remove of a locked worktree must not run")
		end)

		worktree_panel.close()
	end,

	-- ── Refresh-exactly-once (GitflowPostOperation double-refresh) ───

	["prune refreshes the open panel exactly once"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(3000)

		with_temp_git_log(function(log_path)
			worktree_panel.prune()
			T.drain_jobs(2000)

			local lines = T.read_file(log_path)
			local list_calls = 0
			for _, line in ipairs(lines) do
				if line:find("worktree list", 1, true) then
					list_calls = list_calls + 1
				end
			end
			T.assert_equals(
				list_calls, 1,
				"prune should refresh the worktree list exactly once"
			)
		end)

		worktree_panel.close()
	end,

	["removing a worktree refreshes the open panel exactly once"] = function()
		local worktree_panel = require("gitflow.panels.worktree")
		commands.dispatch({ "worktree", "list" }, cfg)
		T.drain_jobs(3000)

		-- The detached entry is neither the cwd nor locked, so remove proceeds.
		local target_line
		for line, entry in pairs(worktree_panel.state.line_entries) do
			if entry.is_detached then
				target_line = line
			end
		end
		T.assert_true(target_line ~= nil, "fixture should have a detached worktree")

		with_temp_git_log(function(log_path)
			with_confirm_answer(true, function()
				vim.api.nvim_set_current_win(worktree_panel.state.winid)
				vim.api.nvim_win_set_cursor(
					worktree_panel.state.winid, { target_line, 0 })
				worktree_panel.remove_under_cursor(false)
				T.drain_jobs(2000)
			end)

			local lines = T.read_file(log_path)
			local remove_ran, list_calls = false, 0
			for _, line in ipairs(lines) do
				if line:find("worktree remove", 1, true) then
					remove_ran = true
				end
				if line:find("worktree list", 1, true) then
					list_calls = list_calls + 1
				end
			end
			T.assert_true(remove_ran, "remove should have run `git worktree remove`")
			T.assert_equals(
				list_calls, 1,
				"remove should refresh the worktree list exactly once"
			)
		end)

		worktree_panel.close()
	end,
})

print("E2E worktree panel tests passed")
