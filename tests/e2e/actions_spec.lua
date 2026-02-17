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
local gh_actions = require("gitflow.gh.actions")
local actions_panel = require("gitflow.panels.actions")

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
	end,

	-- ── Status icon rendering ───────────────────────────────────────────

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

	-- ── Panel state resets on close ─────────────────────────────────────

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
