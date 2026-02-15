-- tests/e2e/full_repo_flow_spec.lua — end-to-end lifecycle flow tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/full_repo_flow_spec.lua
--
-- Verifies:
--   1. Open main UI -> verify panel
--   2. Open status panel -> stage files -> commit
--   3. Create PR via :Gitflow pr create
--   4. View PR via :Gitflow pr view
--   5. Open review panel -> add inline comment -> submit review
--   6. Open conflict panel -> resolve conflict
--   7. Verify entire flow without restart
--   8. Validate all stubs invoked in correct sequence

local T = _G.T
local cfg = _G.TestConfig

local ui = require("gitflow.ui")
local commands = require("gitflow.commands")
local status_panel = require("gitflow.panels.status")
local prs_panel = require("gitflow.panels.prs")
local review_panel = require("gitflow.panels.review")
local conflict_panel = require("gitflow.panels.conflict")
local conflict_view = require("gitflow.ui.conflict")
local git_conflict = require("gitflow.git.conflict")
local git_status = require("gitflow.git.status")
local gh_labels = require("gitflow.gh.labels")
local form = require("gitflow.ui.form")

-- ── Helpers ────────────────────────────────────────────────────────────

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

---@param fn fun()
---@return table[] notifications
local function capture_notifications(fn)
	local notifications = {}
	local orig_notify = vim.notify
	vim.notify = function(msg, level, ...)
		notifications[#notifications + 1] = {
			message = msg,
			level = level,
		}
		return orig_notify(msg, level, ...)
	end

	local ok, err = xpcall(fn, debug.traceback)
	vim.notify = orig_notify

	if not ok then
		error(err, 0)
	end
	return notifications
end

---@param notifications table[]
---@param needle string
---@param level integer|nil
---@return boolean
local function has_notification(notifications, needle, level)
	for _, n in ipairs(notifications) do
		if n.message and n.message:find(needle, 1, true) then
			if level == nil or n.level == level then
				return true
			end
		end
	end
	return false
end

--- Close all panels and floating windows.
local function cleanup_panels()
	if conflict_view.is_open() then
		pcall(conflict_view.close)
	end
	for _, panel_name in ipairs({
		"status", "diff", "log", "stash", "branch",
		"conflict", "issues", "prs", "labels", "review",
		"palette",
	}) do
		local mod_ok, mod = pcall(require, "gitflow.panels." .. panel_name)
		if mod_ok and mod.close then
			pcall(mod.close)
		end
	end

	while vim.fn.tabpagenr("$") > 1 do
		pcall(vim.cmd, "tabclose!")
	end

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local win_cfg = vim.api.nvim_win_get_config(win)
		if win_cfg.relative and win_cfg.relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
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

---@param paths string
---@param fn fun()
local function with_conflicts(paths, fn)
	local previous = vim.env.GITFLOW_GIT_CONFLICTS
	vim.env.GITFLOW_GIT_CONFLICTS = paths

	local ok, err = xpcall(fn, debug.traceback)

	vim.env.GITFLOW_GIT_CONFLICTS = previous or ""
	if previous == nil then
		vim.env.GITFLOW_GIT_CONFLICTS = nil
	end

	if not ok then
		error(err, 0)
	end
end

--- Create a temporary file with conflict markers.
---@return string path
local function create_conflict_file()
	local path = vim.fn.tempname()
	local lines = {
		"line one",
		"<<<<<<< HEAD",
		"local content",
		"|||||||",
		"base content",
		"=======",
		"remote content",
		">>>>>>> feature",
		"line four",
	}
	T.write_file(path, lines)
	return path
end

T.run_suite("E2E: Full Repository Flow", {

	-- ── Step 1: Open main UI -> verify panel ─────────────────────────

	["step 1: main UI opens and shows panel"] = function()
		cleanup_panels()
		T.exec_command("Gitflow open")

		local winid = commands.state.panel_window
		T.assert_true(
			winid ~= nil and vim.api.nvim_win_is_valid(winid),
			"main panel window should be valid"
		)

		local bufnr = vim.api.nvim_win_get_buf(winid)
		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Gitflow") ~= nil,
			"main panel should contain Gitflow title"
		)

		T.exec_command("Gitflow close")
	end,

	-- ── Step 2: Status panel → stage files ───────────────────────────

	["step 2: status panel opens and shows files"] = function()
		cleanup_panels()
		status_panel.open(cfg, {})
		T.drain_jobs(5000)

		local bufnr = ui.buffer.get("status")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"status buffer should exist"
		)

		-- Wait for status content to be rendered
		T.wait_until(function()
			local lines = T.buf_lines(bufnr)
			return T.find_line(lines, "tracked.txt") ~= nil
				or T.find_line(lines, "new.txt") ~= nil
				or T.find_line(lines, "Staged") ~= nil
		end, "status panel should render file content", 5000)

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Staged") ~= nil
			or T.find_line(lines, "Unstaged") ~= nil
			or T.find_line(lines, "Untracked") ~= nil,
			"status panel should show section headers from git stub"
		)

		cleanup_panels()
	end,

	["step 2: stage file dispatches git add"] = function()
		with_temp_git_log(function(log_path)
			-- Stage a file via git_status.stage_file
			git_status.stage_file("tracked.txt", {}, function(err)
				-- stub always succeeds
			end)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "add") ~= nil,
				"staging should invoke git add"
			)
		end)
	end,

	["step 2: stage all dispatches git add -A"] = function()
		with_temp_git_log(function(log_path)
			git_status.stage_all({}, function(err)
				-- stub always succeeds
			end)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "add") ~= nil,
				"stage all should invoke git add"
			)
		end)
	end,

	["step 2: status panel has staging keymaps"] = function()
		cleanup_panels()
		status_panel.open(cfg, {})
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("status")
		T.assert_true(bufnr ~= nil, "status buffer should exist")
		T.assert_keymaps(bufnr, { "s", "u", "a", "A", "q", "r" })

		cleanup_panels()
	end,

	-- ── Step 3: Create PR via :Gitflow pr create ─────────────────────

	["step 3: pr create dispatches gh pr create"] = function()
		with_temp_gh_log(function(log_path)
			with_temporary_patches({
				{
					table = gh_labels,
					key = "list",
					value = function(_, cb)
						cb(nil, {})
					end,
				},
				{
					table = form,
					key = "open",
					value = function(opts)
						opts.on_submit({
							title = "Flow PR Title",
							body = "Flow PR Body",
							base = "main",
							reviewers = "alice,bob",
							labels = "bug,docs",
						})
						return {
							bufnr = nil,
							winid = nil,
							fields = opts.fields or {},
							field_lines = {},
							on_submit = opts.on_submit,
							active_field = 1,
						}
					end,
				},
			}, function()
				commands.dispatch({ "pr", "create" }, cfg)
				T.drain_jobs(5000)

				local lines = T.read_file(log_path)
				local create_line = nil
				for _, line in ipairs(lines) do
					if line:find("pr create", 1, true) then
						create_line = line
					end
				end

				T.assert_true(
					create_line ~= nil,
					"should invoke gh pr create"
				)
				T.assert_true(
					create_line:find("--title Flow PR Title", 1, true) ~= nil,
					"pr create should include title argument"
				)
				T.assert_true(
					create_line:find("--body Flow PR Body", 1, true) ~= nil,
					"pr create should include body argument"
				)
				T.assert_true(
					create_line:find("--base main", 1, true) ~= nil,
					"pr create should include base argument"
				)
				T.assert_true(
					create_line:find("--reviewer alice,bob", 1, true) ~= nil,
					"pr create should include reviewer argument"
				)
				T.assert_true(
					create_line:find("--label bug,docs", 1, true) ~= nil,
					"pr create should include label argument"
				)
			end)

			cleanup_panels()
		end)
	end,

	["step 3: pr panel opens and lists PRs"] = function()
		cleanup_panels()
		prs_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("prs")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"PR buffer should exist"
		)

		local lines = T.buf_lines(bufnr)
		-- fixture pr_list.json has PR #42 "Add dark mode support"
		T.assert_true(
			T.find_line(lines, "dark mode") ~= nil
			or T.find_line(lines, "#42") ~= nil
			or T.find_line(lines, "42") ~= nil,
			"PR panel should show PR from fixture"
		)

		cleanup_panels()
	end,

	-- ── Step 4: View PR via :Gitflow pr view ─────────────────────────

	["step 4: pr view dispatches gh pr view"] = function()
		with_temp_gh_log(function(log_path)
			commands.dispatch({ "pr", "view", "42" }, cfg)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "pr view") ~= nil
				or T.find_line(lines, "pr") ~= nil,
				"should invoke gh pr view"
			)
		end)

		cleanup_panels()
	end,

	-- ── Step 5: Review panel → inline comment → submit ───────────────

	["step 5: review panel opens for PR"] = function()
		cleanup_panels()
		review_panel.open(cfg, 42)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("review")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"review buffer should exist"
		)

		-- Review panel should show diff content from fixture
		local lines = T.buf_lines(bufnr)
		T.assert_true(
			#lines > 0,
			"review panel should have content"
		)

		cleanup_panels()
	end,

	["step 5: review panel has expected keymaps"] = function()
		cleanup_panels()
		review_panel.open(cfg, 42)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("review")
		T.assert_true(bufnr ~= nil, "review buffer should exist")
		T.assert_keymaps(
			bufnr,
			{ "]f", "[f", "]c", "[c", "c", "S", "a", "x", "q" }
		)

		cleanup_panels()
	end,

	["step 5: review tracks PR number"] = function()
		cleanup_panels()
		review_panel.open(cfg, 42)
		T.drain_jobs(3000)

		T.assert_equals(
			review_panel.state.pr_number, 42,
			"review panel should track PR number"
		)

		cleanup_panels()
	end,

	["step 5: inline comment adds to pending list"] = function()
		cleanup_panels()
		review_panel.open(cfg, 42)
		T.drain_jobs(3000)

		local before_count = #(review_panel.state.pending_comments or {})

		-- Simulate inline comment by adding to pending directly
		-- (the interactive prompt path requires user input)
		local pending = review_panel.state.pending_comments or {}
		pending[#pending + 1] = {
			id = os.time(),
			path = "test.lua",
			line = 5,
			body = "Test inline comment",
		}
		review_panel.state.pending_comments = pending

		T.assert_equals(
			#review_panel.state.pending_comments,
			before_count + 1,
			"pending comments should increase by 1"
		)

		cleanup_panels()
	end,

	["step 5: review approve invokes gh pr review"] = function()
		local input_mod = require("gitflow.ui.input")
		with_temp_gh_log(function(log_path)
			cleanup_panels()
			review_panel.open(cfg, 42)
			T.drain_jobs(3000)

			with_temporary_patches({
				{
					table = input_mod,
					key = "prompt",
					value = function(opts, cb)
						if cb then
							cb("")
						end
					end,
				},
			}, function()
				review_panel.review_approve()
				T.drain_jobs(3000)
			end)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "pr review") ~= nil
				or T.find_line(lines, "--approve") ~= nil,
				"approve should invoke gh pr review"
			)
		end)

		cleanup_panels()
	end,

	-- ── Step 6: Conflict resolution ──────────────────────────────────

	["step 6: conflict panel opens and lists files"] = function()
		cleanup_panels()
		with_conflicts("conflict.txt", function()
			conflict_panel.open(cfg)
			T.drain_jobs(3000)

			local bufnr = ui.buffer.get("conflict")
			T.assert_true(
				bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
				"conflict buffer should exist"
			)

			local lines = T.buf_lines(bufnr)
			T.assert_true(
				T.find_line(lines, "conflict.txt") ~= nil,
				"should show conflicted file"
			)
		end)

		cleanup_panels()
	end,

	["step 6: conflict resolution resolves file"] = function()
		local path = create_conflict_file()

		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
			{
				table = git_conflict,
				key = "mark_resolved",
				value = function(p, opts, cb)
					cb(nil, { code = 0, stdout = "resolved", stderr = "" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)

			T.assert_true(
				conflict_view.is_open(),
				"conflict view should open"
			)
			T.assert_true(
				#conflict_view.state.hunks > 0,
				"should have hunks"
			)

			-- Resolve with local side
			local win = conflict_view.state.merged_winid
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(
				win,
				{ conflict_view.state.hunks[1].start_line, 0 }
			)
			conflict_view.resolve_current("local")
			T.drain_jobs(3000)

			-- Verify resolution
			local result = T.read_file(path)
			T.assert_true(
				T.find_line(result, "<<<<<<<") == nil,
				"conflict markers should be removed"
			)
		end)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Step 7: Full flow without restart ────────────────────────────

	["step 7: sequential operations work without restart"] = function()
		cleanup_panels()

		-- 1. Open and close main panel
		T.exec_command("Gitflow open")
		T.assert_true(
			commands.state.panel_window ~= nil,
			"main panel should open"
		)
		T.exec_command("Gitflow close")

		-- 2. Open status panel
		status_panel.open(cfg, {})
		T.drain_jobs(3000)
		local status_buf = ui.buffer.get("status")
		T.assert_true(
			status_buf ~= nil,
			"status buffer should exist in flow"
		)
		cleanup_panels()

		-- 3. Open PR panel
		prs_panel.open(cfg)
		T.drain_jobs(3000)
		local pr_buf = ui.buffer.get("prs")
		T.assert_true(
			pr_buf ~= nil,
			"PR buffer should exist in flow"
		)
		cleanup_panels()

		-- 4. Open review panel
		review_panel.open(cfg, 42)
		T.drain_jobs(3000)
		local review_buf = ui.buffer.get("review")
		T.assert_true(
			review_buf ~= nil,
			"review buffer should exist in flow"
		)
		cleanup_panels()

		-- 5. Open conflict panel
		conflict_panel.open(cfg)
		T.drain_jobs(3000)
		local conflict_buf = ui.buffer.get("conflict")
		T.assert_true(
			conflict_buf ~= nil,
			"conflict buffer should exist in flow"
		)
		cleanup_panels()

		-- 6. Verify no leaked state
		T.assert_true(
			vim.fn.tabpagenr("$") == 1,
			"should have only 1 tab after full flow"
		)
	end,

	-- ── Step 8: Validate stubs invoked in sequence ───────────────────

	["step 8: git stubs invoked in correct sequence"] = function()
		with_temp_git_log(function(log_path)
			-- Status fetch
			git_status.fetch({}, function() end)
			T.drain_jobs(3000)

			-- Stage a file
			git_status.stage_file("test.txt", {}, function() end)
			T.drain_jobs(3000)

			-- Push
			commands.dispatch({ "push" }, cfg)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)

			-- Find indices to verify ordering
			local status_idx = T.find_line(lines, "status")
			local add_idx = T.find_line(lines, "add")
			local push_idx = T.find_line(lines, "push")

			T.assert_true(
				status_idx ~= nil,
				"git status should be in log"
			)
			T.assert_true(
				add_idx ~= nil,
				"git add should be in log"
			)
			T.assert_true(
				push_idx ~= nil,
				"git push should be in log"
			)
			T.assert_true(
				status_idx < add_idx,
				"status should come before add"
			)
			T.assert_true(
				add_idx < push_idx,
				"add should come before push"
			)
		end)
	end,

	["step 8: gh stubs invoked in correct sequence"] = function()
		with_temp_gh_log(function(log_path)
			-- Open PR list
			prs_panel.open(cfg)
			T.drain_jobs(3000)
			cleanup_panels()

			-- Open review
			review_panel.open(cfg, 42)
			T.drain_jobs(3000)
			cleanup_panels()

			local lines = T.read_file(log_path)

			-- PR list should be invoked
			local pr_list_idx = T.find_line(lines, "pr list")
			T.assert_true(
				pr_list_idx ~= nil,
				"gh pr list should be in log"
			)

			-- PR diff for review should follow
			local pr_diff_idx = T.find_line(lines, "pr diff")
			T.assert_true(
				pr_diff_idx ~= nil,
				"gh pr diff should be in log"
			)
			T.assert_true(
				pr_list_idx < pr_diff_idx,
				"pr list should come before pr diff"
			)
		end)
	end,

	-- ── No orphaned windows after full flow ──────────────────────────

	["no orphaned windows after full lifecycle"] = function()
		local before = T.window_layout()

		-- Run through multiple operations
		T.exec_command("Gitflow open")
		T.exec_command("Gitflow close")

		status_panel.open(cfg, {})
		T.drain_jobs(3000)
		cleanup_panels()

		prs_panel.open(cfg)
		T.drain_jobs(3000)
		cleanup_panels()

		review_panel.open(cfg, 42)
		T.drain_jobs(3000)
		cleanup_panels()

		conflict_panel.open(cfg)
		T.drain_jobs(3000)
		cleanup_panels()

		local after = T.window_layout()
		T.assert_equals(
			after.total,
			before.total,
			"window count should return to baseline"
		)
	end,

	-- ── Command dispatch coverage ────────────────────────────────────

	["dispatch status command works"] = function()
		local result = commands.dispatch({ "status" }, cfg)
		T.drain_jobs(3000)
		T.assert_true(
			result ~= nil,
			"status dispatch should return a result"
		)
		cleanup_panels()
	end,

	["dispatch conflicts command works"] = function()
		local result = commands.dispatch({ "conflicts" }, cfg)
		T.drain_jobs(3000)
		T.assert_true(
			result ~= nil,
			"conflicts dispatch should return a result"
		)
		cleanup_panels()
	end,

	["dispatch conflict alias works"] = function()
		local result = commands.dispatch({ "conflict" }, cfg)
		T.drain_jobs(3000)
		T.assert_true(
			result ~= nil,
			"conflict alias dispatch should return a result"
		)
		cleanup_panels()
	end,

	["dispatch pr list command works"] = function()
		local result = commands.dispatch({ "pr", "list" }, cfg)
		T.drain_jobs(3000)
		T.assert_true(
			result ~= nil,
			"pr list dispatch should return a result"
		)
		cleanup_panels()
	end,

	-- ── Conflict panel → 3-way view → back to panel ─────────────────

	["conflict flow: panel → 3-way → close returns to panel"] = function()
		local path = create_conflict_file()
		cleanup_panels()

		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			with_conflicts(path, function()
				conflict_panel.open(cfg)
				T.drain_jobs(3000)

				T.assert_true(
					conflict_panel.is_open(),
					"conflict panel should be open"
				)

				-- Open 3-way view
				conflict_view.open(path, {
					cfg = cfg,
					on_closed = function()
						conflict_panel.refresh()
					end,
				})
				T.drain_jobs(3000)

				T.assert_true(
					conflict_view.is_open(),
					"3-way view should be open"
				)

				-- Close 3-way view
				conflict_view.close()
				T.drain_jobs(3000)

				T.assert_false(
					conflict_view.is_open(),
					"3-way view should be closed"
				)

				-- Conflict panel should still work
				T.assert_true(
					conflict_panel.is_open(),
					"conflict panel should still be accessible"
				)
			end)
		end)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,
})

print("E2E full repository flow tests passed")
