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

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local gh = require("gitflow.gh")
local gh_actions = require("gitflow.gh.actions")
local actions_panel = require("gitflow.panels.actions")

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

	["panel sets expected buffer-local keymaps"] = function()
		actions_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = actions_panel.state.bufnr
		T.assert_true(
			bufnr ~= nil,
			"panel should have a buffer"
		)

		T.assert_keymaps(bufnr, { "<CR>", "o", "<BS>", "r", "q" })

		T.cleanup_panels()
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
})

print("E2E actions panel tests passed")
