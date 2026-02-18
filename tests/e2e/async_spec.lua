-- tests/e2e/async_spec.lua — async determinism E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/async_spec.lua
--
-- Verifies:
--   1. Job completion is properly awaited before UI updates
--   2. No race conditions in concurrent panel operations
--   3. No hanging Neovim processes after test completion
--   4. All timers terminate
--   5. vim.schedule callbacks execute in correct order
--   6. GitflowPostOperation event fires after successful operations

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local git = require("gitflow.git")
local utils = require("gitflow.utils")
local status_panel = require("gitflow.panels.status")
local diff_panel = require("gitflow.panels.diff")
local log_panel = require("gitflow.panels.log")
local stash_panel = require("gitflow.panels.stash")
local branch_panel = require("gitflow.panels.branch")
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

--- Count active timers via libuv handle walk.
---@return integer
local function active_timer_count()
	local count = 0
	local uv = vim.uv or vim.loop
	if uv and uv.walk then
		uv.walk(function(handle)
			local handle_type = uv.handle_get_type
				and uv.handle_get_type(handle)
				or nil
			if handle_type == "timer" then
				local ok_active, active = pcall(function()
					return handle:is_active()
				end)
				local ok_closing, closing = pcall(function()
					return handle:is_closing()
				end)
				if ok_active and active and (not ok_closing or not closing) then
					count = count + 1
				end
			end
		end)
	end
	return count
end

T.run_suite("E2E: Async Determinism", {

	-- ── Job completion awaited before UI ──────────────────────────────

	["status panel waits for git completion before rendering"] = function()
		status_panel.open(cfg, {})
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("status")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"status buffer should exist after drain"
		)

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			#lines > 0,
			"status panel should have content after async completion"
		)

		T.cleanup_panels()
	end,

	["diff panel waits for git completion before rendering"] = function()
		diff_panel.open(cfg, {})
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("diff")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"diff buffer should exist after drain"
		)

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			#lines > 0,
			"diff panel should have content after async completion"
		)

		T.cleanup_panels()
	end,

	["log panel waits for git completion before rendering"] = function()
		log_panel.open(cfg, {})
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("log")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"log buffer should exist after drain"
		)

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			#lines > 0,
			"log panel should have content after async completion"
		)

		T.cleanup_panels()
	end,

	-- ── No race conditions in concurrent panel operations ─────────────

	["concurrent panel opens do not race"] = function()
		-- Queue multiple panel opens before draining to force overlap.
		status_panel.open(cfg, {})
		diff_panel.open(cfg, {})
		log_panel.open(cfg, {})
		T.drain_jobs(5000)

		-- All should have valid buffers
		local status_buf = ui.buffer.get("status")
		local diff_buf = ui.buffer.get("diff")
		local log_buf = ui.buffer.get("log")

		T.assert_true(
			status_buf ~= nil and vim.api.nvim_buf_is_valid(status_buf),
			"status buffer should be valid after concurrent opens"
		)
		T.assert_true(
			diff_buf ~= nil and vim.api.nvim_buf_is_valid(diff_buf),
			"diff buffer should be valid after concurrent opens"
		)
		T.assert_true(
			log_buf ~= nil and vim.api.nvim_buf_is_valid(log_buf),
			"log buffer should be valid after concurrent opens"
		)
		T.assert_true(
			#T.buf_lines(status_buf) > 0
				and #T.buf_lines(diff_buf) > 0
				and #T.buf_lines(log_buf) > 0,
			"concurrent opens should render content for all panels"
		)

		T.cleanup_panels()
	end,

	["rapid open/close does not leave orphaned state"] = function()
		-- Open and immediately close several times
		for _ = 1, 3 do
			status_panel.open(cfg, {})
			T.drain_jobs(3000)
			status_panel.close()
		end

		-- Should be cleanly closed
		T.assert_false(
			status_panel.is_open(),
			"status panel should be closed after rapid open/close cycles"
		)

		T.cleanup_panels()
	end,

	-- ── No hanging processes ──────────────────────────────────────────

	["no active async jobs remain after drain"] = function()
		-- Dispatch a command that runs an async git operation
		commands.dispatch({ "fetch" }, cfg)
		T.drain_jobs(3000)

		-- Verify no lingering job channels
		local active = 0
		for _, chan in ipairs(vim.api.nvim_list_chans()) do
			if chan.stream == "job" then
				active = active + 1
			end
		end

		T.assert_equals(
			active,
			0,
			"no job channels should remain after drain"
		)
	end,

	["no active libuv process handles remain after drain"] = function()
		commands.dispatch({ "pull" }, cfg)
		T.drain_jobs(3000)

		local uv = vim.uv or vim.loop
		local process_count = 0
		if uv and uv.walk then
			uv.walk(function(handle)
				local handle_type = uv.handle_get_type
					and uv.handle_get_type(handle)
					or nil
				if handle_type == "process" then
					local ok_active, active = pcall(function()
						return handle:is_active()
					end)
					local ok_closing, closing = pcall(function()
						return handle:is_closing()
					end)
					if ok_active and active and (not ok_closing or not closing) then
						process_count = process_count + 1
					end
				end
			end)
		end

		T.assert_equals(
			process_count,
			0,
			"no active process handles after drain"
		)
	end,

	["active timers return to baseline after async operations"] = function()
		local baseline_timers = active_timer_count()

		status_panel.open(cfg, {})
		diff_panel.open(cfg, {})
		log_panel.open(cfg, {})
		commands.dispatch({ "fetch" }, cfg)
		T.drain_jobs(5000)
		T.cleanup_panels()

		T.wait_until(function()
			return active_timer_count() <= baseline_timers
		end, "active timers should return to baseline after drain", 1500)

		local remaining_timers = active_timer_count()
		T.assert_true(
			remaining_timers <= baseline_timers,
			("active timers should return to baseline (baseline=%d, remaining=%d)")
				:format(baseline_timers, remaining_timers)
		)
	end,

	-- ── vim.schedule callback ordering ────────────────────────────────

	["vim.schedule callbacks execute in correct order"] = function()
		local order = {}

		vim.schedule(function()
			order[#order + 1] = "first"
		end)
		vim.schedule(function()
			order[#order + 1] = "second"
		end)
		vim.schedule(function()
			order[#order + 1] = "third"
		end)

		-- Process pending callbacks
		vim.wait(200, function()
			return #order >= 3
		end, 10)

		T.assert_equals(#order, 3, "all 3 scheduled callbacks should run")
		T.assert_equals(order[1], "first", "first callback runs first")
		T.assert_equals(order[2], "second", "second callback runs second")
		T.assert_equals(order[3], "third", "third callback runs third")
	end,

	-- ── GitflowPostOperation event ────────────────────────────────────

	["GitflowPostOperation fires after successful push"] = function()
		local event_fired = false
		local augroup = vim.api.nvim_create_augroup(
			"TestPostOp", { clear = true }
		)
		vim.api.nvim_create_autocmd("User", {
			group = augroup,
			pattern = "GitflowPostOperation",
			callback = function()
				event_fired = true
			end,
		})

		commands.dispatch({ "push" }, cfg)
		T.drain_jobs(3000)

		T.wait_until(function()
			return event_fired
		end,
			"GitflowPostOperation should fire after successful push"
		)

		pcall(vim.api.nvim_del_augroup_by_id, augroup)
	end,

	["GitflowPostOperation fires after successful fetch"] = function()
		local event_fired = false
		local augroup = vim.api.nvim_create_augroup(
			"TestPostOpFetch", { clear = true }
		)
		vim.api.nvim_create_autocmd("User", {
			group = augroup,
			pattern = "GitflowPostOperation",
			callback = function()
				event_fired = true
			end,
		})

		commands.dispatch({ "fetch" }, cfg)
		T.drain_jobs(3000)

		T.assert_true(
			event_fired,
			"GitflowPostOperation should fire after successful fetch"
		)

		pcall(vim.api.nvim_del_augroup_by_id, augroup)
	end,

	["GitflowPostOperation triggers statusline refresh"] = function()
		-- Record whether statusline refresh was called
		local refreshed = false
		local orig_refresh = statusline.refresh

		statusline.refresh = function(...)
			refreshed = true
			return orig_refresh(...)
		end

		-- Fire the event manually
		vim.api.nvim_exec_autocmds(
			"User", { pattern = "GitflowPostOperation" }
		)
		T.drain_jobs(3000)

		statusline.refresh = orig_refresh

		T.assert_true(
			refreshed,
			"statusline.refresh should be called on GitflowPostOperation"
		)
	end,

	-- ── Statusline concurrent update dedup ────────────────────────────

	["statusline deduplicates concurrent refresh calls"] = function()
		-- Reset statusline state for clean test
		statusline.state.updating = false
		statusline.state.pending = false

		-- Issue two rapid refresh calls
		statusline.refresh()
		statusline.refresh()

		-- The second should set pending=true instead of running in parallel
		-- After draining, both should have completed
		T.drain_jobs(3000)

		T.assert_false(
			statusline.state.updating,
			"statusline should not be updating after drain"
		)
	end,

	-- ── wait_async helper correctness ─────────────────────────────────

	["wait_async returns value from async callback"] = function()
		local result = T.wait_async(function(done)
			vim.defer_fn(function()
				done("hello")
			end, 50)
		end, 2000)

		T.assert_equals(
			result, "hello",
			"wait_async should return value from done callback"
		)
	end,

	["wait_async times out for never-resolving callback"] = function()
		local ok = pcall(function()
			T.wait_async(function(_done)
				-- never calls done
			end, 200)
		end)

		T.assert_false(
			ok,
			"wait_async should raise on timeout"
		)
	end,

	-- ── drain_jobs determinism ────────────────────────────────────────

	["drain_jobs waits for vim.system process to complete"] = function()
		local completed = false

		vim.system(
			{ "echo", "drain-test" },
			{ text = true },
			function(_result)
				vim.schedule(function()
					completed = true
				end)
			end
		)

		T.drain_jobs(3000)

		T.assert_true(
			completed,
			"drain_jobs should wait for vim.system callback"
		)
	end,

	-- ── Multiple dispatch stability ───────────────────────────────────

	["multiple dispatches in sequence remain stable"] = function()
		-- Run several commands in sequence to ensure no state leaks
		commands.dispatch({ "diff" }, cfg)
		T.drain_jobs(3000)
		T.cleanup_panels()

		commands.dispatch({ "log" }, cfg)
		T.drain_jobs(3000)
		T.cleanup_panels()

		commands.dispatch({ "status" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("status")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"status buffer should be valid after multiple dispatches"
		)

		T.cleanup_panels()
	end,
})
