-- tests/e2e/actions_spec.lua — GitHub Actions panel E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/actions_spec.lua
--
-- Verifies:
--   1. Actions subcommand is registered and dispatches without crash
--   2. Panel opens/closes correctly
--   3. GH actions data layer parses fixture data
--   4. Status icon rendering produces expected icons
--   5. Buffer-local keymaps are set
--   6. Filters, pagination, rerun/rerun-failed/rerun-job, cancel (confirm
--      gate, single-flight guard), watch (bounded polling, stop conditions),
--      and the log viewer (ANSI stripping, jump-to-first-error)

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local gh = require("gitflow.gh")
local gh_actions = require("gitflow.gh.actions")
local git_branch = require("gitflow.git.branch")
local actions_panel = require("gitflow.panels.actions")
local input = require("gitflow.ui.input")

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

-- Stub ui.input.confirm so a confirmation dialog answers deterministically.
-- Headless nvim's vim.fn.confirm() returns the default choice (no prompt UI),
-- which is "&No" for every mutation here — tests that expect the mutation to
-- proceed must stub this to simulate the user confirming.
---@param answer boolean
---@param fn fun()
local function with_confirm_answer(answer, fn)
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

---@param title string
local function focus_run_by_title(title)
	local winid = actions_panel.state.winid
	local bufnr = actions_panel.state.bufnr
	T.assert_true(
		winid ~= nil and vim.api.nvim_win_is_valid(winid),
		"actions window should be valid"
	)
	T.assert_true(
		bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
		"actions buffer should be valid"
	)
	local line = T.buf_find_line(bufnr, title)
	T.assert_true(
		line ~= nil,
		("actions list should contain run '%s'"):format(title)
	)
	vim.api.nvim_set_current_win(winid)
	vim.api.nvim_win_set_cursor(winid, { line, 0 })
end

---@param footer any
---@return string
local function footer_text(footer)
	if type(footer) == "string" then
		return footer
	end
	if type(footer) ~= "table" then
		return tostring(footer or "")
	end

	local parts = {}
	for _, chunk in ipairs(footer) do
		if type(chunk) == "string" then
			parts[#parts + 1] = chunk
		elseif type(chunk) == "table" then
			parts[#parts + 1] = tostring(chunk[1] or "")
		else
			parts[#parts + 1] = tostring(chunk)
		end
	end
	return table.concat(parts, "")
end

---Stand-in for `git_branch.current` that answers without spawning a job.
local function sync_branch(_, cb)
	cb(nil, "main")
end

---Stub for a `gh_actions` async call that parks its callback for the test to
---fire, so response ordering is deterministic.
---@param sink fun(...)[]
---@return fun(...)
local function capture(sink)
	return function(...)
		-- select("#") not #{...}: the panel passes a nil `opts` argument.
		sink[#sink + 1] = select(select("#", ...), ...)
	end
end

---@param title string
---@return GitflowActionRun
local function stub_run(title)
	return {
		id = 1,
		name = title,
		branch = "main",
		status = "completed",
		conclusion = "success",
		event = "push",
		created_at = "2026-01-01T00:00:00Z",
		updated_at = "2026-01-01T00:00:00Z",
		url = "https://example.test/run/1",
		display_title = title,
	}
end

---@param bufnr integer
---@param keys string[]
local function assert_no_keymaps(bufnr, keys)
	local mapped = {}
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		mapped[map.lhs] = true
	end
	for _, lhs in ipairs(keys) do
		T.assert_false(
			mapped[lhs] == true,
			("'%s' should not be mapped in this view"):format(lhs)
		)
	end
end

---@return string  the actions panel's rendered contents
local function rendered_panel_text()
	local bufnr = actions_panel.state.bufnr
	T.assert_true(
		bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
		"actions buffer should be valid"
	)
	return table.concat(T.buf_lines(bufnr), "\n")
end

T.run_suite("E2E: GitHub Actions Panel", {

	-- ── Subcommand registration ────────────────────────────────────────

	["actions subcommand is registered"] = function()
		T.assert_true(
			commands.subcommands.actions ~= nil,
			"actions subcommand should be registered"
		)
		T.assert_true(
			type(commands.subcommands.actions.description) == "string"
				and commands.subcommands.actions.description ~= "",
			"actions subcommand should have a description"
		)
		T.assert_true(
			type(commands.subcommands.actions.run) == "function",
			"actions subcommand should have a run function"
		)
	end,

	-- ── Dispatch without crash ──────────────────────────────────────────

	["actions dispatch opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "actions" }, cfg)
		end)
		T.assert_true(ok, "actions should not crash: " .. (err or ""))
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("actions")
		T.assert_true(
			bufnr ~= nil,
			"actions should create a buffer"
		)
		T.assert_true(
			actions_panel.is_open(),
			"actions panel should be open after dispatch"
		)
		T.cleanup_panels()
	end,

	-- ── Panel open/close lifecycle ──────────────────────────────────────

	["panel closes cleanly"] = function()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		T.assert_true(
			actions_panel.is_open(),
			"panel should be open after open()"
		)

		actions_panel.close()
		T.assert_false(
			actions_panel.is_open(),
			"panel should be closed after close()"
		)
	end,

	-- ── List data parsing from fixture ──────────────────────────────────

	["list parses fixture run data"] = function()
		local runs_result = nil
		local err_result = nil

		T.wait_async(function(done)
			gh_actions.list({}, nil, function(err, runs)
				err_result = err
				runs_result = runs
				done()
			end)
		end)

		T.assert_true(
			err_result == nil,
			"list should not return error: " .. (err_result or "")
		)
		T.assert_true(
			type(runs_result) == "table",
			"list should return a table"
		)
		T.assert_true(
			#runs_result >= 3,
			("expected >= 3 runs from fixture, got %d"):format(
				#runs_result
			)
		)

		local first = runs_result[1]
		T.assert_equals(
			first.id, 12345,
			"first run id should be 12345"
		)
		T.assert_equals(
			first.name, "CI",
			"first run name should be CI"
		)
		T.assert_equals(
			first.conclusion, "success",
			"first run conclusion should be success"
		)
	end,

	-- ── View data parsing from fixture ──────────────────────────────────

	["view parses fixture run detail with jobs"] = function()
		local run_result = nil
		local err_result = nil

		T.wait_async(function(done)
			gh_actions.view(12345, nil, function(err, run)
				err_result = err
				run_result = run
				done()
			end)
		end)

		T.assert_true(
			err_result == nil,
			"view should not return error: " .. (err_result or "")
		)
		T.assert_true(
			run_result ~= nil,
			"view should return a run"
		)
		T.assert_equals(
			run_result.id, 12345,
			"run id should be 12345"
		)
		T.assert_true(
			type(run_result.jobs) == "table",
			"run should have jobs table"
		)
		T.assert_true(
			#run_result.jobs >= 2,
			("expected >= 2 jobs, got %d"):format(#run_result.jobs)
		)

		local first_job = run_result.jobs[1]
		T.assert_equals(
			first_job.name, "test",
			"first job name should be test"
		)
		T.assert_true(
			type(first_job.steps) == "table" and #first_job.steps >= 2,
			"first job should have >= 2 steps"
		)

		local second_job = run_result.jobs[2]
		T.assert_equals(
			second_job.conclusion, "failure",
			"second job should be marked as failure"
		)
		local failing_step = second_job.steps[2]
		T.assert_equals(
			failing_step.conclusion, "failure",
			"second job second step should be a failure"
		)
		T.assert_true(
			type(failing_step.log_snippet) == "string"
				and failing_step.log_snippet ~= "",
			"failing step should include a log snippet"
		)
	end,

	["view fetches failed logs via gh run view --log-failed"] = function()
		with_temp_gh_log(function(log_path)
			local err_result = nil
			T.wait_async(function(done)
				gh_actions.view(12345, nil, function(err)
					err_result = err
					done()
				end)
			end)
			T.assert_true(
				err_result == nil,
				"view should not return error: " .. (err_result or "")
			)

			local lines = T.read_file(log_path)
			local saw_log_failed = false
			for _, line in ipairs(lines) do
				if line:find("run view 12345 --log-failed", 1, true) then
					saw_log_failed = true
				end
			end
			T.assert_true(
				saw_log_failed,
				"view should call gh run view --log-failed"
			)
		end)
	end,

	-- ── Status icon rendering ───────────────────────────────────────────

	["view keeps snippets job-scoped when step names are duplicated"] = function()
		local run_result = nil
		local err_result = nil
		with_temporary_patches({
			{
				table = gh,
				key = "json",
				value = function(_, _, cb)
					cb(nil, {
						databaseId = 555,
						name = "CI",
						headBranch = "main",
						status = "completed",
						conclusion = "failure",
						event = "pull_request",
						createdAt = "2026-02-17T12:00:00Z",
						updatedAt = "2026-02-17T12:05:00Z",
						url = "https://example.invalid/actions/runs/555",
						displayTitle = "Matrix CI",
						jobs = {
							{
								databaseId = 1,
								name = "linux",
								status = "completed",
								conclusion = "failure",
								steps = {
									{
										name = "Run tests",
										status = "completed",
										conclusion = "failure",
										number = 1,
									},
								},
							},
							{
								databaseId = 2,
								name = "windows",
								status = "completed",
								conclusion = "failure",
								steps = {
									{
										name = "Run tests",
										status = "completed",
										conclusion = "failure",
										number = 1,
									},
								},
							},
						},
					})
				end,
			},
			{
				table = gh,
				key = "run",
				value = function(_, _, cb)
					cb({
						code = 0,
						signal = 0,
						stdout = table.concat({
							"linux\tRun tests\tLinux failure details",
							"windows\tRun tests\tWindows failure details",
						}, "\n"),
						stderr = "",
						cmd = { "gh" },
					})
				end,
			},
		}, function()
			T.wait_async(function(done)
				gh_actions.view(555, nil, function(err, run)
					err_result = err
					run_result = run
					done()
				end)
			end)
		end)

		T.assert_true(
			err_result == nil,
			"view should not return error: " .. (err_result or "")
		)
		T.assert_true(run_result ~= nil, "view should return run data")

		local linux_step = run_result.jobs[1].steps[1]
		local windows_step = run_result.jobs[2].steps[1]
		T.assert_true(
			linux_step.log_snippet:find("Linux failure", 1, true) ~= nil,
			"linux step should keep linux-specific snippet"
		)
		T.assert_true(
			windows_step.log_snippet:find("Windows failure", 1, true) ~= nil,
			"windows step should keep windows-specific snippet"
		)
	end,

	["view records a failing --log-failed instead of reporting clean success"] = function()
		local run_result = nil
		local err_result = nil
		with_temporary_patches({
			{
				table = gh,
				key = "json",
				value = function(_, _, cb)
					cb(nil, {
						databaseId = 777,
						name = "CI",
						headBranch = "main",
						status = "completed",
						conclusion = "failure",
						event = "push",
						url = "https://example.invalid/actions/runs/777",
						displayTitle = "CI",
						jobs = {
							{
								databaseId = 1,
								name = "linux",
								status = "completed",
								conclusion = "failure",
								steps = {
									{
										name = "Run tests",
										status = "completed",
										conclusion = "failure",
										number = 1,
									},
								},
							},
						},
					})
				end,
			},
			{
				table = gh,
				key = "run",
				value = function(_, _, cb)
					cb({
						code = 1,
						signal = 0,
						stdout = "",
						stderr = "failed to fetch logs: HTTP 503",
						cmd = { "gh" },
					})
				end,
			},
		}, function()
			T.wait_async(function(done)
				gh_actions.view(777, nil, function(err, run)
					err_result = err
					run_result = run
					done()
				end)
			end)
		end)

		-- The run itself loaded, so it is still delivered; only the optional
		-- log enrichment failed, and that failure must not vanish.
		T.assert_true(
			err_result == nil,
			"run data loaded, so view should not fail outright: "
				.. tostring(err_result)
		)
		T.assert_true(run_result ~= nil, "view should still return the run")
		T.assert_true(
			type(run_result.log_error) == "string" and run_result.log_error ~= "",
			"a non-zero --log-failed exit must be recorded on the run"
		)
		T.assert_true(
			run_result.log_error:find("503", 1, true) ~= nil,
			"log_error should carry the gh output: "
				.. tostring(run_result.log_error)
		)
		T.assert_true(
			run_result.jobs[1].steps[1].log_snippet == nil,
			"no snippet should be attached when the log fetch failed"
		)
	end,

	["view leaves log_error unset when --log-failed succeeds"] = function()
		local run_result = nil

		T.wait_async(function(done)
			gh_actions.view(12345, nil, function(_, run)
				run_result = run
				done()
			end)
		end)

		T.assert_true(run_result ~= nil, "view should return a run")
		T.assert_true(
			run_result.log_error == nil,
			"a successful log fetch should not record an error: "
				.. tostring(run_result.log_error)
		)
	end,

	["status_icon returns correct icons for each state"] = function()
		T.assert_equals(
			gh_actions.status_icon({ conclusion = "success", status = "" }),
			"✓",
			"success should produce check icon"
		)
		T.assert_equals(
			gh_actions.status_icon({ conclusion = "failure", status = "" }),
			"✗",
			"failure should produce x icon"
		)
		T.assert_equals(
			gh_actions.status_icon({ conclusion = "cancelled", status = "" }),
			"⊘",
			"cancelled should produce circle icon"
		)
		T.assert_equals(
			gh_actions.status_icon({ conclusion = "", status = "in_progress" }),
			"●",
			"in_progress should produce pending icon"
		)
		T.assert_equals(
			gh_actions.status_icon({ conclusion = "", status = "queued" }),
			"●",
			"queued should produce pending icon"
		)
	end,

	-- ── Status highlight mapping ────────────────────────────────────────

	["status_highlight returns correct groups"] = function()
		T.assert_equals(
			gh_actions.status_highlight(
				{ conclusion = "success", status = "" }
			),
			"GitflowActionsPass",
			"success should map to GitflowActionsPass"
		)
		T.assert_equals(
			gh_actions.status_highlight(
				{ conclusion = "failure", status = "" }
			),
			"GitflowActionsFail",
			"failure should map to GitflowActionsFail"
		)
		T.assert_equals(
			gh_actions.status_highlight(
				{ conclusion = "", status = "in_progress" }
			),
			"GitflowActionsPending",
			"in_progress should map to GitflowActionsPending"
		)
		T.assert_equals(
			gh_actions.status_highlight(
				{ conclusion = "cancelled", status = "" }
			),
			"GitflowActionsCancelled",
			"cancelled should map to GitflowActionsCancelled"
		)
	end,

	-- ── Buffer-local keymaps ────────────────────────────────────────────

	["panel sets the list view's buffer-local keymaps"] = function()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = actions_panel.state.bufnr
		T.assert_true(
			bufnr ~= nil,
			"panel should have a buffer"
		)

		T.assert_keymaps(bufnr, {
			"<CR>", "o", "r", "q", "l", "f", "b", "L", "W", "R", "F", "C",
			-- J has no job to target in the list view; mapped to a no-op
			-- rather than left to raise vim's E21 (Join on a RO buffer).
			"J",
		})
		-- Detail/log-only actions must not be mapped over the list.
		assert_no_keymaps(bufnr, { "w", "]e" })

		T.cleanup_panels()
	end,

	["each view maps only its own keys, leaving motions to vim"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		focus_run_by_title("CI: push to main")
		actions_panel.open_detail_under_cursor()
		T.drain_jobs(4000)

		local bufnr = actions_panel.state.bufnr
		T.assert_keymaps(bufnr, { "<BS>", "J", "w", "l", "R", "F", "C" })
		assert_no_keymaps(bufnr, { "f", "b", "L", "W", "]e" })

		actions_panel.view_log_under_cursor()
		T.drain_jobs(4000)
		T.assert_equals(actions_panel.state.view, "log", "should be in the log view")

		T.assert_keymaps(bufnr, {
			"<BS>", "]e", "r", "q",
			-- R/C/J are not motions: mapped to a no-op rather than left to
			-- raise vim's E21 (Replace/Change/Join on a RO buffer).
			"R", "C", "J",
		})
		-- The log view is a text buffer: these are motions, not panel keys.
		assert_no_keymaps(bufnr, { "l", "w", "b", "E", "L", "F", "W", "f" })

		local winid = actions_panel.state.winid
		local content_line = T.buf_find_line(bufnr, "PASS test_one")
		T.assert_true(content_line ~= nil, "log view should show run output")
		vim.api.nvim_set_current_win(winid)
		vim.api.nvim_win_set_cursor(winid, { content_line, 0 })
		T.feedkeys("l")
		T.assert_equals(
			vim.api.nvim_win_get_cursor(winid)[2], 1,
			"l must still move the cursor right in the log view"
		)

		actions_panel.close()
	end,

	["the workflows view maps only its own keys, leaving the rest to vim"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		actions_panel.open_workflows()
		T.drain_jobs(4000)
		T.assert_equals(
			actions_panel.state.view, "workflows", "should be in the workflows view"
		)

		local bufnr = actions_panel.state.bufnr
		T.assert_keymaps(bufnr, {
			"<CR>", "<BS>", "r", "q",
			-- R/C/J/o are not motions: mapped to a no-op rather than left
			-- to raise vim's E21 (Replace/Change/Join/open-line on a RO
			-- buffer) — this view has no run or job to target them at.
			"R", "C", "J", "o",
		})
		assert_no_keymaps(bufnr, { "l", "w", "b", "L", "W", "F", "f", "]e" })

		actions_panel.close()
	end,

	-- ── Rendered buffer contains run data ───────────────────────────────

	["list view renders run entries from fixture"] = function()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = actions_panel.state.bufnr
		T.assert_true(
			bufnr ~= nil,
			"panel should have a buffer"
		)

		local lines = T.buf_lines(bufnr)
		local found_ci = T.find_line(lines, "CI")
		T.assert_true(
			found_ci ~= nil,
			"buffer should contain CI run entry"
		)

		local found_success = T.find_line(lines, "✓")
		T.assert_true(
			found_success ~= nil,
			"buffer should contain success icon"
		)

		T.cleanup_panels()
	end,

	["detail view renders failed-step log snippets"] = function()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		focus_run_by_title("CI: PR #42")
		actions_panel.open_detail_under_cursor()
		T.drain_jobs(4000)

		local bufnr = actions_panel.state.bufnr
		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Lint check") ~= nil,
			"detail view should include failed lint step"
		)
		T.assert_true(
			T.find_line(lines, "log: Error: style violation") ~= nil,
			"detail view should render failed-step log snippet"
		)

		T.cleanup_panels()
	end,

	["actions panel refreshes on GitflowPostOperation while open"] = function()
		local refresh_calls = 0
		local original_refresh = actions_panel.refresh

		with_temporary_patches({
			{
				table = actions_panel,
				key = "refresh",
				value = function(...)
					refresh_calls = refresh_calls + 1
					return original_refresh(...)
				end,
			},
		}, function()
			actions_panel.open(cfg)
			T.drain_jobs(3000)
			local baseline = refresh_calls

			vim.api.nvim_exec_autocmds(
				"User",
				{ pattern = "GitflowPostOperation" }
			)

			T.wait_until(function()
				return refresh_calls > baseline
			end, "actions panel should refresh on GitflowPostOperation")

			actions_panel.close()
			local after_close = refresh_calls
			vim.api.nvim_exec_autocmds(
				"User",
				{ pattern = "GitflowPostOperation" }
			)
			vim.wait(200, function()
				return false
			end, 20)
			T.assert_equals(
				refresh_calls,
				after_close,
				"closed actions panel should not refresh on post-operation events"
			)
		end)
	end,

	["stale delayed detail callback cannot overwrite list view"] = function()
		local original_view = gh_actions.view
		with_temporary_patches({
			{
				table = gh_actions,
				key = "view",
				value = function(run_id, opts, cb)
					return original_view(run_id, opts, function(err, run)
						vim.defer_fn(function()
							cb(err, run)
						end, 250)
					end)
				end,
			},
		}, function()
			actions_panel.open(cfg)
			T.drain_jobs(3000)

			focus_run_by_title("CI: PR #42")
			actions_panel.open_detail_under_cursor()
			actions_panel.back_to_list()
			T.drain_jobs(4500)

			T.assert_equals(
				actions_panel.state.view, "list",
				"view should remain list after delayed detail callback"
			)

			local lines = T.buf_lines(actions_panel.state.bufnr)
			T.assert_true(
				T.find_line(lines, "CI: PR #42") ~= nil,
				"list view should remain rendered after delayed detail callback"
			)
			T.assert_true(
				T.find_line(lines, "Started:") == nil,
				"detail content should not overwrite list view after back navigation"
			)

			actions_panel.close()
		end)
	end,

	-- ── Panel state resets on close ─────────────────────────────────────

	["float footer updates between list and detail views"] = function()
		if vim.fn.has("nvim-0.10") ~= 1 then
			return
		end

		with_temporary_patches({
			{
				table = cfg.ui,
				key = "default_layout",
				value = "float",
			},
			{
				table = cfg.ui.float,
				key = "footer",
				value = true,
			},
		}, function()
			actions_panel.open(cfg)
			T.drain_jobs(3000)

			local winid = actions_panel.state.winid
			T.assert_true(
				winid ~= nil and vim.api.nvim_win_is_valid(winid),
				"actions window should be valid"
			)

			local list_footer = footer_text(vim.api.nvim_win_get_config(winid).footer)
			T.assert_true(
				tostring(list_footer):find("<CR> detail", 1, true) ~= nil,
				"list view footer should advertise <CR> detail"
			)

			focus_run_by_title("CI: PR #42")
			actions_panel.open_detail_under_cursor()
			T.drain_jobs(4000)

			local detail_footer = footer_text(vim.api.nvim_win_get_config(winid).footer)
			T.assert_true(
				tostring(detail_footer):find("<BS> back", 1, true) ~= nil,
				"detail view footer should advertise <BS> back"
			)

			actions_panel.back_to_list()
			T.drain_jobs(3000)

			local back_footer = footer_text(vim.api.nvim_win_get_config(winid).footer)
			T.assert_true(
				tostring(back_footer):find("<CR> detail", 1, true) ~= nil,
				"returning to list should restore list footer hints"
			)

			T.cleanup_panels()
		end)
	end,

	["state resets to list view on close"] = function()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		actions_panel.state.view = "detail"
		actions_panel.close()

		T.assert_equals(
			actions_panel.state.view, "list",
			"view should reset to list on close"
		)
		T.assert_true(
			actions_panel.state.detail_run == nil,
			"detail_run should be nil on close"
		)
	end,

	-- ── Highlight groups defined ────────────────────────────────────────

	["actions highlight groups are defined"] = function()
		T.assert_true(
			T.hl_exists("GitflowActionsPass"),
			"GitflowActionsPass should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowActionsFail"),
			"GitflowActionsFail should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowActionsPending"),
			"GitflowActionsPending should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowActionsCancelled"),
			"GitflowActionsCancelled should be defined"
		)
	end,

	-- ── Keybinding config default ───────────────────────────────────────

	["actions keybinding has a default"] = function()
		T.assert_true(
			cfg.keybindings.actions ~= nil
				and cfg.keybindings.actions ~= "",
			"actions keybinding should have a default value"
		)
	end,

	-- ── Stale async responses ───────────────────────────────────────────

	["a superseded list response does not overwrite newer state"] = function()
		actions_panel.close()

		local list_callbacks = {}
		with_temporary_patches({
			{ table = git_branch, key = "current", value = sync_branch },
			{ table = gh_actions, key = "list", value = capture(list_callbacks) },
		}, function()
			actions_panel.open(cfg)
			T.assert_equals(
				#list_callbacks, 1, "open should issue one list request"
			)

			actions_panel.refresh()
			T.assert_equals(
				#list_callbacks, 2, "refresh should issue a second list request"
			)

			-- Newest response renders first; the superseded one lands late.
			list_callbacks[2](nil, { stub_run("NEWEST RUN") })
			list_callbacks[1](nil, { stub_run("STALE RUN") })
		end)

		local rendered = rendered_panel_text()
		T.assert_contains(
			rendered, "NEWEST RUN", "the newest response should be rendered"
		)
		T.assert_false(
			rendered:find("STALE RUN", 1, true) ~= nil,
			"a superseded list response must not overwrite newer state"
		)

		actions_panel.close()
	end,

	["a list response landing after a detail switch is discarded"] = function()
		actions_panel.close()

		local list_callbacks = {}
		local view_callbacks = {}
		with_temporary_patches({
			{ table = git_branch, key = "current", value = sync_branch },
			{ table = gh_actions, key = "list", value = capture(list_callbacks) },
			{ table = gh_actions, key = "view", value = capture(view_callbacks) },
		}, function()
			actions_panel.open(cfg)
			list_callbacks[1](nil, { stub_run("LIST RUN") })

			-- Refresh in flight, then the user opens a detail view.
			actions_panel.refresh()
			focus_run_by_title("LIST RUN")
			actions_panel.open_detail_under_cursor()
			T.assert_equals(
				#view_callbacks, 1, "detail should issue one view request"
			)

			view_callbacks[1](nil, stub_run("DETAIL RUN"))
			list_callbacks[#list_callbacks](nil, { stub_run("STALE RUN") })
		end)

		local rendered = rendered_panel_text()
		T.assert_contains(
			rendered, "DETAIL RUN", "the detail view should be rendered"
		)
		T.assert_false(
			rendered:find("STALE RUN", 1, true) ~= nil,
			"a list response must not overwrite the newer detail view"
		)

		actions_panel.close()
	end,

	-- ── Palette entry includes actions ──────────────────────────────────

	["palette entries include actions"] = function()
		local entries = commands.palette_entries(cfg)
		local found = false
		for _, entry in ipairs(entries) do
			if entry.name == "actions" then
				found = true
				break
			end
		end
		T.assert_true(
			found,
			"palette entries should include actions"
		)
	end,

	-- ── ANSI stripping / error detection (data layer) ───────────────────

	["strip_ansi removes SGR and OSC-8 escapes"] = function()
		T.assert_equals(
			gh_actions.strip_ansi("\27[32mPASS\27[0m ok"),
			"PASS ok",
			"SGR color codes should be stripped"
		)
		T.assert_equals(
			gh_actions.strip_ansi(
				"\27]8;;https://example.test\7link\27]8;;\7"
			),
			"link",
			"OSC-8 hyperlink wrappers should be stripped"
		)
		T.assert_equals(
			gh_actions.strip_ansi("\27[?25lworking\27[?25h"),
			"working",
			"private-mode CSI (cursor hide/show) should be stripped"
		)
		T.assert_equals(
			gh_actions.strip_ansi("\27[>4;2m tail"),
			" tail",
			"'>'-parameter CSI should be stripped"
		)
		T.assert_equals(
			gh_actions.strip_ansi(
				"\27]8;;https://example.test\27\\link\27]8;;\27\\"
			),
			"link",
			"an ST-terminated OSC-8 hyperlink should be stripped"
		)
		T.assert_equals(
			gh_actions.strip_ansi("\27]0;title\7rest"),
			"rest",
			"a non-OSC-8 OSC (title set) should be stripped, BEL included"
		)
	end,

	["clean_log_message drops gh's BOM and ISO timestamp"] = function()
		T.assert_equals(
			gh_actions.clean_log_message(
				"\239\187\1912026-08-24T04:49:49.1743133Z Current runner version"
			),
			"Current runner version",
			"the first line's BOM and the timestamp column should both go"
		)
		T.assert_equals(
			gh_actions.clean_log_message("2026-08-24T04:49:49Z plain"),
			"plain",
			"a fractionless timestamp should be stripped too"
		)
		T.assert_equals(
			gh_actions.clean_log_message("2026 was a good year"),
			"2026 was a good year",
			"a message that merely starts with digits must survive"
		)
	end,

	["find_first_error_line prefers a ##[error] annotation"] = function()
		local lines = {
			"note: starting build",
			"##[error]Something broke",
			"error: a plain-text error mentioned later",
		}
		T.assert_equals(
			gh_actions.find_first_error_line(lines), 2,
			"the ##[error] annotation should win over a later plain mention"
		)
	end,

	["find_first_error_line falls back to a plain error mention"] = function()
		local lines = { "note: starting build", "Error: build failed" }
		T.assert_equals(
			gh_actions.find_first_error_line(lines), 2,
			"should fall back to a substring match when no annotation exists"
		)
	end,

	["find_first_error_line returns nil for a clean log"] = function()
		T.assert_true(
			gh_actions.find_first_error_line({ "all good", "done" }) == nil,
			"a log with no error mentions should report no match"
		)
	end,

	-- ── Full run log / per-job log (data layer) ──────────────────────────

	["log fetches and formats the full run log"] = function()
		local lines_result, err_result
		T.wait_async(function(done)
			gh_actions.log(12345, nil, function(err, lines)
				err_result, lines_result = err, lines
				done()
			end)
		end)
		T.assert_true(err_result == nil, "log should not error: " .. tostring(err_result))
		T.assert_true(type(lines_result) == "table" and #lines_result > 0, "log should return lines")

		local joined = table.concat(lines_result, "\n")
		T.assert_true(joined:find("\27", 1, true) == nil, "log output must be ANSI-stripped")
		T.assert_true(joined:find("PASS test_one", 1, true) ~= nil, "log should contain step output")
		T.assert_true(
			joined:find("lint / Lint check", 1, true) ~= nil,
			"log should header each job/step change"
		)
		T.assert_true(
			joined:find("Expected indentation to use tabs", 1, true) ~= nil,
			"log should contain the annotated error line"
		)
		for _, line in ipairs(lines_result) do
			T.assert_true(
				line:match("^%d%d%d%d%-%d%d%-%d%dT") == nil,
				"real gh prefixes every message with an ISO timestamp; it must be stripped"
			)
		end
		T.assert_true(
			joined:find("\239\187\191", 1, true) == nil,
			"gh's leading BOM must not reach the buffer"
		)
	end,

	["log's max_lines caps the raw input before formatting runs"] = function()
		-- The fixture's raw log is 6 tab-separated lines; capping to the
		-- last 2 must drop the earlier jobs entirely, not just trim the
		-- already-formatted output — proves the cap bounds format cost too.
		local lines_result, err_result
		T.wait_async(function(done)
			gh_actions.log(12345, { max_lines = 2 }, function(err, lines)
				err_result, lines_result = err, lines
				done()
			end)
		end)
		T.assert_true(err_result == nil, "log should not error: " .. tostring(err_result))
		local joined = table.concat(lines_result, "\n")
		T.assert_true(
			joined:find("Expected indentation to use tabs", 1, true) ~= nil,
			"the capped tail should keep the last raw line"
		)
		T.assert_true(
			joined:find("PASS test_one", 1, true) == nil,
			"a raw line dropped by the cap must never reach formatting"
		)
		T.assert_true(
			joined:find("Cloning into 'repo'", 1, true) == nil,
			"the earlier job's lines must be dropped by the cap, not just trimmed"
		)
	end,

	["job_log fetches a single job's log without a job-name header"] = function()
		local lines_result, err_result
		T.wait_async(function(done)
			gh_actions.job_log(12345, 9002, nil, function(err, lines)
				err_result, lines_result = err, lines
				done()
			end)
		end)
		T.assert_true(err_result == nil, "job_log should not error: " .. tostring(err_result))
		local joined = table.concat(lines_result, "\n")
		T.assert_true(joined:find("\27", 1, true) == nil, "job_log output must be ANSI-stripped")
		T.assert_true(
			joined:find("Lint check", 1, true) ~= nil,
			"job_log should header by step"
		)
		T.assert_true(
			joined:find("lint /", 1, true) == nil,
			"job_log should not repeat the (already-known) job name in headers"
		)
	end,

	["list passes workflow/status/event/actor filters as gh flags"] = function()
		with_temp_gh_log(function(log_path)
			T.wait_async(function(done)
				gh_actions.list({
					workflow = "CI", status = "failure",
					event = "pull_request", actor = "octocat",
				}, nil, function(_, _)
					done()
				end)
			end)
			local saw = false
			for _, line in ipairs(T.read_file(log_path)) do
				if line:find("run list", 1, true)
					and line:find("--workflow CI", 1, true)
					and line:find("--status failure", 1, true)
					and line:find("--event pull_request", 1, true)
					and line:find("--user octocat", 1, true)
				then
					saw = true
				end
			end
			T.assert_true(saw, "list should pass all four filters through to gh")
		end)
	end,

	-- ── Log viewer (panel) ────────────────────────────────────────────

	["l opens the full run log, ANSI-stripped, from the list"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		focus_run_by_title("CI: push to main")
		actions_panel.view_log_under_cursor()
		T.drain_jobs(4000)

		T.assert_equals(actions_panel.state.view, "log", "l should switch to the log view")
		local rendered = rendered_panel_text()
		T.assert_true(rendered:find("\27", 1, true) == nil, "rendered log must be ANSI-stripped")
		T.assert_contains(rendered, "PASS test_one", "log view should show run output")

		actions_panel.close()
	end,

	["l opens a job-scoped log from the detail view's job cursor"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		focus_run_by_title("CI: push to main")
		actions_panel.open_detail_under_cursor()
		T.drain_jobs(4000)

		local bufnr = actions_panel.state.bufnr
		local job_line = T.buf_find_line(bufnr, "lint")
		T.assert_true(job_line ~= nil, "detail view should list the lint job")
		vim.api.nvim_set_current_win(actions_panel.state.winid)
		vim.api.nvim_win_set_cursor(actions_panel.state.winid, { job_line, 0 })

		with_temp_gh_log(function(log_path)
			actions_panel.view_log_under_cursor()
			T.drain_jobs(4000)
			local saw = false
			for _, line in ipairs(T.read_file(log_path)) do
				if line:find("run view 12345 --job 9002 --log", 1, true) then
					saw = true
				end
			end
			T.assert_true(saw, "job-scoped log should call gh with --job 9002 --log")
		end)

		actions_panel.close()
	end,

	["]e jumps the cursor to the first error line in the log view"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		focus_run_by_title("CI: push to main")
		actions_panel.view_log_under_cursor()
		T.drain_jobs(4000)

		local winid = actions_panel.state.winid
		vim.api.nvim_set_current_win(winid)
		T.feedkeys("]e")
		local line = vim.api.nvim_win_get_cursor(winid)[1]
		local text = vim.api.nvim_buf_get_lines(
			actions_panel.state.bufnr, line - 1, line, false
		)[1]
		T.assert_contains(
			text, "Expected indentation to use tabs",
			"]e should land the cursor on the first error line"
		)

		actions_panel.back()
		T.assert_equals(
			actions_panel.state.view, "list",
			"back from a run-level log opened from the list should return to the list"
		)

		actions_panel.close()
	end,

	-- ── Rerun / rerun-failed / rerun-job / cancel (confirm gate) ────────

	["rerun declines without calling gh, confirms with exact argv"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: PR #42")

		with_temp_gh_log(function(log_path)
			with_confirm_answer(false, function()
				actions_panel.rerun_under_cursor()
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "run rerun 12346") == nil,
				"declining confirm must not call gh run rerun"
			)
		end)

		with_temp_gh_log(function(log_path)
			with_confirm_answer(true, function()
				actions_panel.rerun_under_cursor()
				T.drain_jobs(3000)
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "run rerun 12346") ~= nil,
				"accepting confirm should call `gh run rerun 12346`"
			)
		end)

		actions_panel.close()
	end,

	["rerun-failed sends --failed"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: PR #42")

		with_temp_gh_log(function(log_path)
			with_confirm_answer(true, function()
				actions_panel.rerun_failed_under_cursor()
				T.drain_jobs(3000)
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "run rerun 12346 --failed") ~= nil,
				"F should call `gh run rerun 12346 --failed`"
			)
		end)

		actions_panel.close()
	end,

	["rerun-job targets the job under the cursor in detail view"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")
		actions_panel.open_detail_under_cursor()
		T.drain_jobs(4000)

		local bufnr = actions_panel.state.bufnr
		local job_line = T.buf_find_line(bufnr, "test")
		T.assert_true(job_line ~= nil, "detail view should list the test job")
		vim.api.nvim_set_current_win(actions_panel.state.winid)
		vim.api.nvim_win_set_cursor(actions_panel.state.winid, { job_line, 0 })

		with_temp_gh_log(function(log_path)
			with_confirm_answer(true, function()
				actions_panel.rerun_job_under_cursor()
				T.drain_jobs(3000)
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "run rerun 12345 --job 9001") ~= nil,
				"J should call `gh run rerun 12345 --job 9001`"
			)
		end)

		actions_panel.close()
	end,

	["a stale job map on the error page does not resolve to a job for J"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")
		actions_panel.open_detail_under_cursor()
		T.drain_jobs(4000)

		local bufnr = actions_panel.state.bufnr
		local job_line = T.buf_find_line(bufnr, "test")
		T.assert_true(job_line ~= nil, "detail view should list the test job")

		-- A real `gh` error is multi-line stderr, which grows the error
		-- page past where the job row used to be.
		local error_lines = {}
		for index = 1, 30 do
			error_lines[index] = ("service unavailable, line %d"):format(index)
		end
		local multiline_error = table.concat(error_lines, "\n")

		with_temporary_patches({
			{
				table = gh_actions,
				key = "view",
				value = function(_, _, cb)
					cb(multiline_error, nil)
				end,
			},
		}, function()
			actions_panel.refresh()
			T.drain_jobs(3000)
		end)

		local rendered = rendered_panel_text()
		T.assert_contains(
			rendered, "Failed to load run detail",
			"the refresh failure should render the detail error state"
		)

		local line_count = vim.api.nvim_buf_line_count(bufnr)
		T.assert_true(
			line_count >= job_line,
			"the error page should have grown past the old job row"
		)
		vim.api.nvim_set_current_win(actions_panel.state.winid)
		vim.api.nvim_win_set_cursor(actions_panel.state.winid, { job_line, 0 })

		with_temp_gh_log(function(log_path)
			with_confirm_answer(true, function()
				actions_panel.rerun_job_under_cursor()
				T.drain_jobs(3000)
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "run rerun") == nil,
				"J on a stale error page must not resolve to a job and call gh"
			)
		end)

		actions_panel.close()
	end,

	["cancel sends the exact argv once confirmed"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: PR #42")

		with_temp_gh_log(function(log_path)
			with_confirm_answer(true, function()
				actions_panel.cancel_under_cursor()
				T.drain_jobs(3000)
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "run cancel 12346") ~= nil,
				"C should call `gh run cancel 12346`"
			)
		end)

		actions_panel.close()
	end,

	["a mutation cannot be triggered twice while one is in flight"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: PR #42")

		local call_count = 0
		with_temporary_patches({
			{
				table = gh_actions,
				key = "rerun",
				-- Never invokes cb: simulates an in-flight mutation.
				value = function(_, _, _)
					call_count = call_count + 1
				end,
			},
		}, function()
			with_confirm_answer(true, function()
				actions_panel.rerun_under_cursor()
				actions_panel.rerun_under_cursor()
			end)
		end)

		T.assert_equals(
			call_count, 1,
			"a second rerun attempt while one is in flight must not call gh again"
		)

		actions_panel.close()
	end,

	-- ── Watch (bounded polling) ───────────────────────────────────────

	["watch polls on an interval and stops on terminal run state"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")

		-- Patched before opening detail too: the fixture run is already
		-- "completed", and start_watch() refuses to watch a finished run.
		local poll_calls = 0
		local statuses = { "in_progress", "in_progress", "in_progress", "completed" }
		with_temporary_patches({
			{ table = cfg, key = "actions", value = { watch_interval = 15 } },
			{
				table = gh_actions,
				key = "view",
				value = function(run_id, _, cb)
					poll_calls = poll_calls + 1
					local status = statuses[math.min(poll_calls, #statuses)]
					cb(nil, {
						id = run_id, name = "CI", branch = "main", status = status,
						conclusion = status == "completed" and "success" or "",
						event = "push", created_at = "", updated_at = "",
						url = "https://example.test/run/" .. tostring(run_id),
						display_title = "CI: push to main", jobs = {},
					})
				end,
			},
		}, function()
			actions_panel.open_detail_under_cursor()
			T.drain_jobs(3000)
			actions_panel.toggle_watch()

			T.wait_until(function()
				return not actions_panel.state.watch.active
			end, "watch should stop once the run reaches a terminal state", 2000)

			local calls_at_terminal = poll_calls
			vim.wait(120, function() return false end, 20)
			T.assert_equals(
				poll_calls, calls_at_terminal,
				"watch must stop polling once the run has completed"
			)
		end)

		T.assert_false(
			actions_panel.state.watch.active,
			"watch state should be inactive after reaching a terminal status"
		)

		actions_panel.close()
	end,

	["watch stops polling when the panel closes"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")

		local poll_calls = 0
		with_temporary_patches({
			{ table = cfg, key = "actions", value = { watch_interval = 15 } },
			{
				table = gh_actions,
				key = "view",
				-- Always in_progress: this run must never reach a terminal
				-- state on its own, so only close() can stop the polling.
				value = function(run_id, _, cb)
					poll_calls = poll_calls + 1
					cb(nil, {
						id = run_id, name = "CI", branch = "main",
						status = "in_progress", conclusion = "",
						event = "push", created_at = "", updated_at = "",
						url = "", display_title = "CI: push to main", jobs = {},
					})
				end,
			},
		}, function()
			actions_panel.open_detail_under_cursor()
			T.drain_jobs(3000)
			actions_panel.toggle_watch()
			T.wait_until(function()
				return poll_calls >= 2
			end, "watch should poll at least once after the detail open's own fetch", 2000)

			actions_panel.close()
			local calls_at_close = poll_calls
			vim.wait(120, function() return false end, 20)
			T.assert_equals(
				poll_calls, calls_at_close,
				"watch must not keep polling after the panel closes"
			)
		end)
	end,

	["watch stops when the window is closed by anything but q"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")

		local poll_calls = 0
		with_temporary_patches({
			{ table = cfg, key = "actions", value = { watch_interval = 15 } },
			{
				table = gh_actions,
				key = "view",
				value = function(run_id, _, cb)
					poll_calls = poll_calls + 1
					cb(nil, {
						id = run_id, name = "CI", branch = "main",
						status = "in_progress", conclusion = "",
						event = "push", created_at = "", updated_at = "",
						url = "", display_title = "CI: push to main", jobs = {},
					})
				end,
			},
		}, function()
			actions_panel.open_detail_under_cursor()
			T.drain_jobs(3000)
			actions_panel.toggle_watch()
			T.wait_until(function()
				return poll_calls >= 2
			end, "watch should be polling before the window is closed", 2000)

			-- An ordinary window close (:q / :close / <C-w>c all land here),
			-- not the panel's own q.
			vim.api.nvim_win_close(actions_panel.state.winid, true)
			local calls_at_close = poll_calls
			vim.wait(300, function() return false end, 20)

			T.assert_equals(
				poll_calls, calls_at_close,
				"a plain window close must stop the poller, not leak it forever"
			)
			T.assert_false(
				actions_panel.state.watch.active,
				"watch must not claim to be live once its window is gone"
			)
			T.assert_false(
				actions_panel.is_open(),
				"a panel with no window is not open"
			)
		end)

		actions_panel.close()
	end,

	["watch stops when another buffer replaces the panel in its own window"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")

		local poll_calls = 0
		with_temporary_patches({
			{ table = cfg, key = "actions", value = { watch_interval = 15 } },
			{
				table = gh_actions,
				key = "view",
				value = function(run_id, _, cb)
					poll_calls = poll_calls + 1
					cb(nil, {
						id = run_id, name = "CI", branch = "main",
						status = "in_progress", conclusion = "",
						event = "push", created_at = "", updated_at = "",
						url = "", display_title = "CI: push to main", jobs = {},
					})
				end,
			},
		}, function()
			actions_panel.open_detail_under_cursor()
			T.drain_jobs(3000)
			actions_panel.toggle_watch()
			T.wait_until(function()
				return poll_calls >= 2
			end, "watch should be polling before the buffer is swapped", 2000)

			-- :enew in the panel's own window replaces its buffer with no
			-- WinClosed: the window (and its tracked winid) stays valid,
			-- but the panel is nowhere on screen.
			local winid = actions_panel.state.winid
			vim.api.nvim_win_call(winid, function()
				vim.cmd("enew")
			end)

			T.assert_false(
				actions_panel.is_open(),
				"the panel is not open once its window shows another buffer"
			)

			local calls_at_swap = poll_calls
			vim.wait(300, function() return false end, 20)

			T.assert_equals(
				poll_calls, calls_at_swap,
				"a buffer swap in the panel's own window must stop the poller"
			)
			T.assert_false(
				actions_panel.state.watch.active,
				"watch must not claim to be live once the panel is off screen"
			)
		end)

		-- Put the panel's buffer back so close() tears the right thing down.
		vim.api.nvim_win_set_buf(actions_panel.state.winid, actions_panel.state.bufnr)
		actions_panel.close()
	end,

	["watching then pressing l keeps the watch and delivers the log"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")

		local poll_calls, polls_delivered = 0, 0
		local function park_log(_, _, cb)
			-- Left genuinely in flight: the watch tick must not strand it.
			vim.defer_fn(function()
				cb(nil, { "step output", "##[error]boom" })
			end, 250)
		end

		with_temporary_patches({
			{ table = cfg, key = "actions", value = { watch_interval = 120 } },
			{
				table = gh_actions,
				key = "view",
				-- Asynchronous on purpose: a synchronous stub makes every
				-- poll the newest request and hides the collision entirely.
				value = function(run_id, _, cb)
					poll_calls = poll_calls + 1
					vim.defer_fn(function()
						polls_delivered = polls_delivered + 1
						cb(nil, {
							id = run_id, name = "CI", branch = "main",
							status = "in_progress", conclusion = "",
							event = "push", created_at = "", updated_at = "",
							url = "", display_title = "CI: push to main",
							jobs = {},
						})
					end, 20)
				end,
			},
			{ table = gh_actions, key = "log", value = park_log },
			{
				table = gh_actions,
				key = "job_log",
				value = function(_, _, _, cb)
					park_log(nil, nil, cb)
				end,
			},
		}, function()
			actions_panel.open_detail_under_cursor()
			T.wait_until(function()
				return actions_panel.state.detail_run ~= nil
					and actions_panel.state.detail_run.status == "in_progress"
			end, "detail view should load the in-progress run", 3000)

			-- Counted from here: the detail open used the same stub.
			poll_calls, polls_delivered = 0, 0
			actions_panel.toggle_watch()
			-- Press between ticks, with the next one already scheduled: that
			-- is the window in which a shared counter strands the log fetch.
			T.wait_until(function()
				return polls_delivered >= 1
			end, "watch should complete its first poll", 2000)

			vim.api.nvim_set_current_win(actions_panel.state.winid)
			T.feedkeys("l")
			T.assert_equals(
				actions_panel.state.view, "log",
				"l should switch to the log view"
			)
			local polls_at_press = poll_calls

			T.wait_until(function()
				return actions_panel.state.log ~= nil
					and actions_panel.state.log.lines ~= nil
			end, "the in-flight log fetch must not be stranded by a watch tick", 3000)
			T.assert_true(
				rendered_panel_text():find("Loading log", 1, true) == nil,
				"the log view must not sit on 'Loading log…' after delivery"
			)

			T.wait_until(function()
				return poll_calls > polls_at_press + 1
			end, "the watch must survive a view change, not die silently", 3000)
			T.assert_true(
				actions_panel.state.watch.active,
				"watch should still be active after the view change"
			)
		end)

		actions_panel.close()
	end,

	["watch stops itself after repeated poll failures"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")

		local failing = false
		local failed_polls = 0
		with_temporary_patches({
			{ table = cfg, key = "actions", value = { watch_interval = 15 } },
			{
				table = gh_actions,
				key = "view",
				value = function(run_id, _, cb)
					if failing then
						failed_polls = failed_polls + 1
						cb("gh run view failed: network unreachable", nil)
						return
					end
					cb(nil, {
						id = run_id, name = "CI", branch = "main",
						status = "in_progress", conclusion = "",
						event = "push", created_at = "", updated_at = "",
						url = "", display_title = "CI: push to main", jobs = {},
					})
				end,
			},
		}, function()
			actions_panel.open_detail_under_cursor()
			T.drain_jobs(3000)

			failing = true
			actions_panel.toggle_watch()
			T.wait_until(function()
				return not actions_panel.state.watch.active
			end, "a persistently failing watch must give up", 2000)

			T.assert_equals(
				failed_polls, 3,
				"the watch should stop after three consecutive failures"
			)
			local calls_at_stop = failed_polls
			vim.wait(150, function() return false end, 20)
			T.assert_equals(
				failed_polls, calls_at_stop,
				"a stopped watch must not keep erroring once per interval"
			)
		end)

		actions_panel.close()
	end,

	["a failed run-list fetch renders an error, not a stuck loading pane"] = function()
		actions_panel.close()
		with_temporary_patches({
			{ table = git_branch, key = "current", value = sync_branch },
			{
				table = gh_actions,
				key = "list",
				value = function(_, _, cb)
					cb("gh run list failed: bad credentials", nil)
				end,
			},
		}, function()
			actions_panel.open(cfg)
			T.drain_jobs(2000)

			local rendered = rendered_panel_text()
			T.assert_contains(
				rendered, "Failed to load workflow runs",
				"a failed list fetch should render an error state"
			)
			T.assert_contains(
				rendered, "bad credentials",
				"the error state should carry gh's reason"
			)
			T.assert_true(
				rendered:find("Loading workflow runs", 1, true) == nil,
				"a failed fetch must not leave the loading pane behind"
			)
		end)

		actions_panel.close()
	end,

	["a huge log renders its tail under a stated cap"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		focus_run_by_title("CI: push to main")

		local huge = {}
		for index = 1, 20050 do
			huge[index] = ("log line %d"):format(index)
		end

		with_temporary_patches({
			{
				table = gh_actions,
				key = "log",
				value = function(_, _, cb)
					cb(nil, huge)
				end,
			},
		}, function()
			actions_panel.view_log_under_cursor()
			T.drain_jobs(4000)

			T.assert_equals(
				#actions_panel.state.log.lines, 20000,
				"the log render should be capped"
			)
			T.assert_equals(
				actions_panel.state.log.omitted, 50,
				"the panel should count what it dropped"
			)
			local rendered = rendered_panel_text()
			T.assert_contains(
				rendered, "50 earlier lines omitted",
				"the buffer should say the log was capped"
			)
			T.assert_contains(
				rendered, "log line 20050",
				"the tail is what a CI failure lives in, so keep it"
			)
		end)

		actions_panel.close()
	end,

	["the instant paint is scoped to the cached filter set"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		with_temporary_patches({
			{ table = git_branch, key = "current", value = sync_branch },
			{
				table = gh_actions,
				key = "list",
				value = function(_, _, cb)
					cb(nil, { stub_run("Deploy: filtered run") })
				end,
			},
		}, function()
			actions_panel.state.filters.workflow = "Deploy"
			actions_panel.refresh()
			T.drain_jobs(2000)
			T.assert_contains(
				rendered_panel_text(), "Deploy: filtered run",
				"the filtered list should render (and fill the cache)"
			)
		end)

		actions_panel.close()

		with_temporary_patches({
			{ table = git_branch, key = "current", value = sync_branch },
			-- Never resolves: whatever paints now came from the cache.
			{ table = gh_actions, key = "list", value = function(_, _, _) end },
		}, function()
			actions_panel.open(cfg)
			T.assert_true(
				rendered_panel_text():find("Deploy: filtered run", 1, true) == nil,
				"a cache filled under a filter must not paint the unfiltered view"
			)
		end)

		actions_panel.close()
	end,

	-- ── Filters, branch scope, pagination (panel) ───────────────────────

	["the filter menu sets a filter and refetches with it"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		local original_select, original_prompt = vim.ui.select, input.prompt
		vim.ui.select = function(items, _, on_choice)
			for _, item in ipairs(items) do
				if item.key == "workflow" then
					on_choice(item)
					return
				end
			end
		end
		input.prompt = function(_, on_confirm)
			on_confirm("CI")
		end

		local ok, err = T.pcall_message(function()
			with_temp_gh_log(function(log_path)
				actions_panel.open_filter_menu()
				T.drain_jobs(3000)
				local saw = false
				for _, line in ipairs(T.read_file(log_path)) do
					if line:find("run list", 1, true) and line:find("--workflow CI", 1, true) then
						saw = true
					end
				end
				T.assert_true(saw, "choosing the workflow filter should refetch with --workflow CI")
			end)
		end)

		vim.ui.select = original_select
		input.prompt = original_prompt
		T.assert_true(ok, "filter menu test should not error: " .. (err or ""))
		T.assert_equals(
			actions_panel.state.filters.workflow, "CI",
			"filter state should record the chosen workflow"
		)

		actions_panel.close()
	end,

	["toggling branch scope drops --branch from the list request"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		with_temp_gh_log(function(log_path)
			actions_panel.toggle_branch_scope()
			T.drain_jobs(3000)
			local saw_branch_flag = false
			for _, line in ipairs(T.read_file(log_path)) do
				if line:find("run list", 1, true) and line:find("%-%-branch") then
					saw_branch_flag = true
				end
			end
			T.assert_false(saw_branch_flag, "the all-branches scope must not pass --branch")
		end)

		T.assert_true(
			actions_panel.state.filters.all_branches,
			"toggling branch scope should flip all_branches on"
		)

		actions_panel.close()
	end,

	["load more increases the list --limit and refetches"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		T.assert_equals(actions_panel.state.limit, 20, "default limit should start at 20")

		with_temp_gh_log(function(log_path)
			actions_panel.load_more()
			T.drain_jobs(3000)
			local saw_new_limit = false
			for _, line in ipairs(T.read_file(log_path)) do
				if line:find("run list", 1, true) and line:find("--limit 40", 1, true) then
					saw_new_limit = true
				end
			end
			T.assert_true(saw_new_limit, "L should refetch with --limit 40")
		end)

		T.assert_equals(
			actions_panel.state.limit, 40,
			"limit should have increased by one page step"
		)

		actions_panel.close()
	end,

	["reopening the panel paints the cached list before the live fetch lands"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)
		actions_panel.close()

		with_temporary_patches({
			{ table = git_branch, key = "current", value = sync_branch },
			{
				table = gh_actions,
				key = "list",
				-- Never resolves: proves the first paint came from the cache,
				-- not from this (permanently pending) live fetch.
				value = function(_, _, _) end,
			},
		}, function()
			actions_panel.open(cfg)
			local rendered = rendered_panel_text()
			T.assert_contains(
				rendered, "CI: push to main",
				"reopening should paint the cached list before the live fetch resolves"
			)
		end)

		actions_panel.close()
	end,

	-- ── Workflow list + dispatch ─────────────────────────────────────────

	["W lists workflows; dispatch is confirm-gated"] = function()
		actions_panel.close()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		actions_panel.open_workflows()
		T.drain_jobs(3000)
		T.assert_equals(actions_panel.state.view, "workflows", "W should open the workflows view")

		local bufnr = actions_panel.state.bufnr
		T.assert_true(T.buf_find_line(bufnr, "CI") ~= nil, "workflows view should list CI")
		local target_line = T.buf_find_line(bufnr, "CI")
		vim.api.nvim_set_current_win(actions_panel.state.winid)
		vim.api.nvim_win_set_cursor(actions_panel.state.winid, { target_line, 0 })

		-- Pressed, not called: <CR> is what the hint bar, the footer and
		-- KEYBINDINGS.md advertise here, and it was wired to nothing.
		with_temp_gh_log(function(log_path)
			with_confirm_answer(false, function()
				T.feedkeys("<CR>")
				T.drain_jobs(2000)
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "workflow run") == nil,
				"declining confirm must not dispatch the workflow"
			)
		end)

		with_temp_gh_log(function(log_path)
			with_confirm_answer(true, function()
				T.feedkeys("<CR>")
				T.drain_jobs(2000)
			end)
			T.assert_true(
				T.find_line(T.read_file(log_path), "workflow run") ~= nil,
				"accepting confirm should dispatch the workflow"
			)
		end)

		actions_panel.back()
		T.assert_equals(actions_panel.state.view, "list", "back should return to the run list")

		actions_panel.close()
	end,
})

print("E2E actions panel tests passed")
