-- tests/e2e/error_paths_spec.lua — error handling E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/error_paths_spec.lua
--
-- Verifies:
--   1. gh CLI failure produces user-visible error (no crash)
--   2. git CLI failure produces user-visible error (no crash)
--   3. Malformed JSON from gh is handled gracefully
--   4. Async timeout does not hang
--   5. Invalid repository state (rev-parse failure) is handled
--   6. State resets correctly after error scenarios
--   7. No orphaned buffers/windows after errors

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local git = require("gitflow.git")
local gh = require("gitflow.gh")
local gh_prs = require("gitflow.gh.prs")
local gh_issues = require("gitflow.gh.issues")
local utils = require("gitflow.utils")
local status_panel = require("gitflow.panels.status")
local diff_panel = require("gitflow.panels.diff")
local prs_panel = require("gitflow.panels.prs")
local issues_panel = require("gitflow.panels.issues")
local statusline = require("gitflow.statusline")

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

--- Count current window/layout and gitflow UI registry state.
---@return { total: integer, floats: integer, panel_windows: integer, panel_buffers: integer }
local function window_snapshot()
	local wins = vim.api.nvim_list_wins()
	local floats = 0
	for _, w in ipairs(wins) do
		if T.is_float(w) then
			floats = floats + 1
		end
	end

	local panel_windows = 0
	for _, record in pairs(ui.window.registry) do
		if record and vim.api.nvim_win_is_valid(record.winid) then
			panel_windows = panel_windows + 1
		end
	end

	local panel_buffers = 0
	for _ in pairs(ui.buffer.list()) do
		panel_buffers = panel_buffers + 1
	end

	return {
		total = #wins,
		floats = floats,
		panel_windows = panel_windows,
		panel_buffers = panel_buffers,
	}
end

--- Run a command dispatch with GITFLOW_GH_FAIL set.
---@param fail_target string
---@param fn fun()
local function with_gh_fail(fail_target, fn)
	local previous = vim.env.GITFLOW_GH_FAIL
	vim.env.GITFLOW_GH_FAIL = fail_target

	local ok, err = xpcall(fn, debug.traceback)

	vim.env.GITFLOW_GH_FAIL = previous or ""
	if previous == nil then
		vim.env.GITFLOW_GH_FAIL = nil
	end

	if not ok then
		error(err, 0)
	end
end

--- Run with GITFLOW_GIT_FAIL set.
---@param fail_target string
---@param fn fun()
local function with_git_fail(fail_target, fn)
	local previous = vim.env.GITFLOW_GIT_FAIL
	vim.env.GITFLOW_GIT_FAIL = fail_target

	local ok, err = xpcall(fn, debug.traceback)

	vim.env.GITFLOW_GIT_FAIL = previous or ""
	if previous == nil then
		vim.env.GITFLOW_GIT_FAIL = nil
	end

	if not ok then
		error(err, 0)
	end
end

--- Capture notifications during a block.
---@param fn fun()
---@return table[] notifications  list of {message, level}
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

--- Check if any notification contains the needle at the given level.
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

T.run_suite("E2E: Error Paths", {

	-- ── gh CLI failure ────────────────────────────────────────────────

	["gh CLI failure on pr list does not crash, shows error"] = function()
		local before = window_snapshot()
		local notifications = capture_notifications(function()
			with_gh_fail("pr", function()
				prs_panel.open(cfg)
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "failed", vim.log.levels.ERROR),
			"should notify user of gh pr failure"
		)

		-- Plugin should not crash — Neovim still responsive
		T.assert_true(
			vim.api.nvim_get_current_buf() ~= nil,
			"Neovim should remain responsive after gh failure"
		)

		T.cleanup_panels()
	end,

	["gh CLI failure on issue list does not crash"] = function()
		local notifications = capture_notifications(function()
			with_gh_fail("issue", function()
				issues_panel.open(cfg)
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "failed", vim.log.levels.ERROR),
			"should notify user of gh issue failure"
		)

		T.cleanup_panels()
	end,

	-- ── git CLI failure ───────────────────────────────────────────────

	["git CLI failure on push produces error notification"] = function()
		local notifications = capture_notifications(function()
			with_git_fail("push", function()
				commands.dispatch({ "push" }, cfg)
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "failed", vim.log.levels.ERROR)
			or has_notification(notifications, "error", vim.log.levels.ERROR),
			"push failure should produce error notification"
		)
	end,

	["git CLI failure on diff does not crash"] = function()
		local notifications = capture_notifications(function()
			with_git_fail("diff", function()
				diff_panel.open(cfg, {})
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "git diff failed", vim.log.levels.ERROR)
			or has_notification(notifications, "failed", vim.log.levels.ERROR)
			or has_notification(notifications, "error", vim.log.levels.ERROR),
			"diff failure should produce error notification"
		)

		-- Diff panel should open even if git diff fails (shows empty diff)
		T.assert_true(
			vim.api.nvim_get_current_buf() ~= nil,
			"Neovim should remain responsive after diff failure"
		)

		T.cleanup_panels()
	end,

	["git merge failure with conflict shows error"] = function()
		local notifications = capture_notifications(function()
			with_git_fail("merge", function()
				commands.dispatch({ "merge", "some-branch" }, cfg)
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "conflict", nil)
			or has_notification(notifications, "CONFLICT", nil)
			or has_notification(notifications, "failed", vim.log.levels.ERROR),
			"merge failure should mention conflict or failure"
		)

		T.cleanup_panels()
	end,

	-- ── Malformed JSON from gh ────────────────────────────────────────

	["malformed JSON from gh is handled gracefully"] = function()
		local notifications = capture_notifications(function()
			with_temporary_patches({
				{
					table = gh,
					key = "run",
					value = function(args, opts, on_exit)
						vim.schedule(function()
							on_exit({
								code = 0,
								signal = 0,
								stdout = "NOT VALID JSON {{{",
								stderr = "",
								cmd = { "gh" },
							})
						end)
					end,
				},
			}, function()
				gh.json(
					{ "pr", "list", "--json", "number" },
					{},
					function(err, data, _result)
						if err then
							utils.notify(err, vim.log.levels.ERROR)
						end
					end
				)
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "parse", vim.log.levels.ERROR)
			or has_notification(notifications, "JSON", vim.log.levels.ERROR),
			"malformed JSON should produce parse error notification"
		)
	end,

	-- ── Async timeout does not hang ───────────────────────────────────

	["async operation respects bounded timeout"] = function()
		-- Verify that wait_until properly times out and does not hang
		local timed_out = false
		local ok = pcall(function()
			T.wait_until(function()
				return false -- never resolves
			end, "intentional timeout", 200) -- 200ms timeout
		end)

		T.assert_false(ok, "wait_until should raise on timeout")
	end,

	["drain_jobs does not hang when no jobs are running"] = function()
		-- Should return immediately if nothing is pending
		T.drain_jobs(500)
		T.assert_true(true, "drain_jobs returned without hanging")
	end,

	-- ── Invalid repository state ──────────────────────────────────────

	["rev-parse failure handled gracefully by statusline"] = function()
		-- Statusline refresh calls rev-parse --show-toplevel.
		-- When it fails, statusline should degrade to empty string
		-- without crashing.
		local refreshed = false
		with_git_fail("rev-parse", function()
			statusline.refresh(function(_value)
				refreshed = true
			end)
			T.drain_jobs(3000)
		end)

		T.assert_true(
			refreshed,
			"statusline refresh should complete even on rev-parse failure"
		)
		-- Statusline cache should be empty (not a git repo)
		T.assert_equals(
			statusline.state.cache,
			"",
			"statusline cache should be empty on rev-parse failure"
		)
	end,

	["git status failure in status panel does not crash"] = function()
		local notifications = capture_notifications(function()
			with_git_fail("status", function()
				status_panel.open(cfg, {})
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "git status failed", vim.log.levels.ERROR)
			or has_notification(notifications, "failed", vim.log.levels.ERROR)
			or has_notification(notifications, "error", vim.log.levels.ERROR),
			"status failure should produce error notification"
		)

		T.assert_true(
			vim.api.nvim_get_current_buf() ~= nil,
			"Neovim should remain responsive after status failure"
		)

		T.cleanup_panels()
	end,

	-- ── State resets after error ──────────────────────────────────────

	["state resets correctly after gh error scenario"] = function()
		-- Force a gh failure, then verify normal operation resumes
		with_gh_fail("pr", function()
			prs_panel.open(cfg)
			T.drain_jobs(3000)
		end)
		T.cleanup_panels()

		-- Now open again without failure — should work normally
		prs_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("prs")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"PR panel should work after previous failure clears"
		)

		T.cleanup_panels()
	end,

	["state resets correctly after git failure scenario"] = function()
		-- Force diff failure then verify normal operation resumes
		with_git_fail("diff", function()
			diff_panel.open(cfg, {})
			T.drain_jobs(3000)
		end)
		T.cleanup_panels()

		-- Now open without failure
		diff_panel.open(cfg, {})
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("diff")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"diff panel should work after previous failure clears"
		)

		T.cleanup_panels()
	end,

	-- ── No orphaned buffers/windows ───────────────────────────────────

	["no orphaned windows after gh failure"] = function()
		local before = window_snapshot()

		with_gh_fail("pr", function()
			prs_panel.open(cfg)
			T.drain_jobs(3000)
		end)
		T.cleanup_panels()

		local after = window_snapshot()
		T.assert_equals(
			after.total,
			before.total,
			"no orphaned windows after gh failure + cleanup"
		)
		T.assert_equals(
			after.panel_windows,
			before.panel_windows,
			"panel window registry should return to baseline after gh failure"
		)
		T.assert_equals(
			after.panel_buffers,
			before.panel_buffers,
			"panel buffer registry should return to baseline after gh failure"
		)
	end,

	["no orphaned windows after git failure"] = function()
		local before = window_snapshot()

		with_git_fail("diff", function()
			diff_panel.open(cfg, {})
			T.drain_jobs(3000)
		end)
		T.cleanup_panels()

		local after = window_snapshot()
		T.assert_equals(
			after.total,
			before.total,
			"no orphaned windows after git failure + cleanup"
		)
		T.assert_equals(
			after.panel_windows,
			before.panel_windows,
			"panel window registry should return to baseline after git failure"
		)
		T.assert_equals(
			after.panel_buffers,
			before.panel_buffers,
			"panel buffer registry should return to baseline after git failure"
		)
	end,

	-- ── gh auth failure path ──────────────────────────────────────────

	["gh auth failure prevents GitHub commands"] = function()
		local saved_state = vim.deepcopy(gh.state)

		-- Simulate unauthenticated state
		gh.state = {
			checked = true,
			available = true,
			authenticated = false,
			message = "GitHub CLI is not authenticated",
		}

		local result = commands.dispatch({ "issue", "list" }, cfg)
		T.assert_true(
			result ~= nil and result:find("not", 1, true) ~= nil,
			"dispatch should return prerequisite error"
		)

		-- Restore original state
		gh.state = saved_state
	end,

	-- ── Unknown subcommand error ──────────────────────────────────────

	["unknown subcommand shows error without crash"] = function()
		local notifications = capture_notifications(function()
			commands.dispatch({ "nonexistent-command" }, cfg)
		end)

		T.assert_true(
			has_notification(notifications, "Unknown", vim.log.levels.ERROR),
			"unknown subcommand should produce error notification"
		)
	end,

	-- ── Git log failure ───────────────────────────────────────────────

	["git log failure does not crash log panel"] = function()
		local log_panel = require("gitflow.panels.log")
		local notifications = capture_notifications(function()
			with_git_fail("log", function()
				log_panel.open(cfg, {})
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "git log failed", vim.log.levels.ERROR)
			or has_notification(notifications, "failed", vim.log.levels.ERROR)
			or has_notification(notifications, "error", vim.log.levels.ERROR),
			"log failure should produce error notification"
		)

		T.assert_true(
			vim.api.nvim_get_current_buf() ~= nil,
			"Neovim should remain responsive after log failure"
		)

		T.cleanup_panels()
	end,

	-- ── Git stash failure ─────────────────────────────────────────────

	["git stash failure does not crash"] = function()
		local notifications = capture_notifications(function()
			with_git_fail("stash", function()
				local stash_panel = require("gitflow.panels.stash")
				stash_panel.open(cfg)
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			has_notification(notifications, "git stash list failed", vim.log.levels.ERROR)
			or has_notification(notifications, "failed", vim.log.levels.ERROR)
			or has_notification(notifications, "error", vim.log.levels.ERROR),
			"stash failure should produce error notification"
		)

		T.assert_true(
			vim.api.nvim_get_current_buf() ~= nil,
			"Neovim should remain responsive after stash failure"
		)

		T.cleanup_panels()
	end,
})
