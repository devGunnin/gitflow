-- tests/e2e/pr_issue_lifecycle_spec.lua — T6 lifecycle verbs against the real
-- `gh` stub process.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/pr_issue_lifecycle_spec.lua
--
-- The unit-level spec (scripts/test_t6_lifecycle_verbs.lua) pins the argv the
-- panel builds. This one pins the other half: that argv actually reaches a gh
-- process, and that the PR views read `statusCheckRollup` off its output.

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local prs_panel = require("gitflow.panels.prs")

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

---Dispatch a :Gitflow subcommand and return everything the gh stub was
---invoked with while it ran.
---@param args string[]
---@return string
local function gh_log_for(args)
	local text
	with_temp_gh_log(function(log_path)
		commands.dispatch(args, cfg)
		T.drain_jobs(3000)
		text = table.concat(T.read_file(log_path), "\n")
	end)
	return text
end

T.run_suite("E2E: PR and issue lifecycle verbs", {

	["pr reopen reaches gh"] = function()
		T.assert_contains(
			gh_log_for({ "pr", "reopen", "42" }),
			"pr reopen 42",
			"`:Gitflow pr reopen` should invoke `gh pr reopen`"
		)
	end,

	["pr ready marks a PR ready for review"] = function()
		local log = gh_log_for({ "pr", "ready", "42" })
		T.assert_contains(log, "pr ready 42", "should invoke `gh pr ready`")
		T.assert_true(
			log:find("--undo", 1, true) == nil,
			"without --undo the PR is marked ready, not turned back into a draft"
		)
	end,

	["pr ready --undo converts a PR back to a draft"] = function()
		T.assert_contains(
			gh_log_for({ "pr", "ready", "42", "--undo" }),
			"pr ready 42 --undo",
			"--undo should reach gh verbatim"
		)
	end,

	["pr merge carries the strategy and --delete-branch"] = function()
		T.assert_contains(
			gh_log_for({ "pr", "merge", "42", "squash", "--delete-branch" }),
			"pr merge 42 --squash --delete-branch",
			"both merge options should reach gh"
		)
	end,

	["pr merge --auto queues rather than merging now"] = function()
		T.assert_contains(
			gh_log_for({ "pr", "merge", "42", "rebase", "--auto" }),
			"pr merge 42 --rebase --auto",
			"--auto should reach gh"
		)
	end,

	["an unknown pr merge option is refused, not silently dropped"] = function()
		local text
		with_temp_gh_log(function(log_path)
			local message = commands.dispatch({ "pr", "merge", "42", "--oops" }, cfg)
			T.assert_contains(
				tostring(message), "Usage:", "an unknown option should return usage"
			)
			T.drain_jobs(1000)
			text = table.concat(T.read_file(log_path), "\n")
		end)
		T.assert_true(
			text:find("pr merge", 1, true) == nil,
			"a rejected merge must not reach gh at all"
		)
	end,

	["issue close carries its reason"] = function()
		T.assert_contains(
			gh_log_for({ "issue", "close", "7", "not_planned" }),
			"issue close 7 --reason not_planned",
			"the close reason should reach gh"
		)
	end,

	["issue close without a reason stays a plain close"] = function()
		local log = gh_log_for({ "issue", "close", "7" })
		T.assert_contains(log, "issue close 7", "should still close")
		T.assert_true(
			log:find("--reason", 1, true) == nil,
			"no reason means no --reason flag"
		)
	end,

	["an invalid close reason is refused"] = function()
		local message = commands.dispatch({ "issue", "close", "7", "maybe" }, cfg)
		T.assert_contains(
			tostring(message), "Usage:", "an unknown reason should return usage"
		)
	end,

	-- ── statusCheckRollup is read, not just requested (#423) ──────────

	["the PR list requests and renders check state"] = function()
		local requested
		with_temp_gh_log(function(log_path)
			prs_panel.close()
			prs_panel.state.cache = nil
			prs_panel.open(cfg)
			T.drain_jobs(3000)
			requested = table.concat(T.read_file(log_path), "\n")
		end)

		T.assert_contains(
			requested, "statusCheckRollup", "the list query should ask for the rollup"
		)
		T.assert_contains(
			table.concat(T.buf_lines(prs_panel.state.bufnr), "\n"),
			"checks",
			"the list card should show a checks chip"
		)
		prs_panel.close()
		prs_panel.state.cache = nil
	end,

	["the PR detail view names every check and its state"] = function()
		prs_panel.close()
		prs_panel.state.cache = nil
		prs_panel.open_view(42, cfg)
		T.drain_jobs(3000)

		local text = table.concat(T.buf_lines(prs_panel.state.bufnr), "\n")
		T.assert_contains(text, "Checks (3)", "all three checks should be counted")
		T.assert_contains(text, "build", "a passing check should be named")
		T.assert_contains(text, "lint", "a failing check should be named")
		T.assert_contains(text, "legacy/ci", "a commit status should be named")
		T.assert_contains(text, "failure", "per-check state should be rendered")

		prs_panel.close()
		prs_panel.state.cache = nil
	end,
})
