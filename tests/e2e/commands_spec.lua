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

-- All subcommands that should be registered after setup
local EXPECTED_SUBCOMMANDS = {
	"help",
	"open",
	"refresh",
	"close",
	"palette",
	"status",
	"branch",
	"commit",
	"push",
	"pull",
	"sync",
	"fetch",
	"diff",
	"log",
	"stash",
	"issue",
	"pr",
	"label",
	"conflicts",
	"conflict",
	"merge",
	"rebase",
	"cherry-pick",
	"quick-commit",
	"quick-push",
}

--- Close any panel windows left open between tests.
local function cleanup_panels()
	for _, panel_name in ipairs({
		"status", "diff", "log", "stash", "branch",
		"conflict", "issues", "prs", "labels", "review",
	}) do
		local mod_ok, mod = pcall(require, "gitflow.panels." .. panel_name)
		if mod_ok and mod.close then
			pcall(mod.close)
		end
	end
	pcall(function()
		commands.state.panel_window = nil
	end)
	pcall(ui.window.close, "main")
end

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
		cleanup_panels()
	end,

	-- ── branch subcommand ───────────────────────────────────────────────

	["branch opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "branch" }, cfg)
		end)
		T.assert_true(ok, "branch should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
	end,

	-- ── diff subcommand ─────────────────────────────────────────────────

	["diff opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "diff" }, cfg)
		end)
		T.assert_true(ok, "diff should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
	end,

	-- ── log subcommand ──────────────────────────────────────────────────

	["log opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "log" }, cfg)
		end)
		T.assert_true(ok, "log should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
	end,

	-- ── stash subcommand ────────────────────────────────────────────────

	["stash list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "stash", "list" }, cfg)
		end)
		T.assert_true(ok, "stash list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
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
		cleanup_panels()
	end,

	-- ── conflict alias ──────────────────────────────────────────────────

	["conflict alias opens same panel"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "conflict" }, cfg)
		end)
		T.assert_true(ok, "conflict should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
	end,

	-- ── issue subcommand ────────────────────────────────────────────────

	["issue list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "issue", "list" }, cfg)
		end)
		T.assert_true(ok, "issue list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
	end,

	-- ── pr subcommand ───────────────────────────────────────────────────

	["pr list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "pr", "list" }, cfg)
		end)
		T.assert_true(ok, "pr list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
	end,

	-- ── label subcommand ────────────────────────────────────────────────

	["label list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "label", "list" }, cfg)
		end)
		T.assert_true(ok, "label list should not crash: " .. (err or ""))
		T.drain_jobs(3000)
		cleanup_panels()
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
		cleanup_panels()
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
})

print("E2E command exposure tests passed")
