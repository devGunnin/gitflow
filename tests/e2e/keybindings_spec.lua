-- tests/e2e/keybindings_spec.lua — keybinding wiring & panel-local keymap tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/keybindings_spec.lua
--
-- Verifies:
--   1. All global keybindings are mapped correctly via <Plug> mappings
--   2. Panel-local keybindings are active in appropriate buffers

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")

--- Resolve a key notation to its internal form for comparison.
---@param lhs string
---@return string
local function normalize_key(lhs)
	return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

--- Find a global normal-mode mapping by lhs string.
---@param lhs string  the key combo to search for
---@return table|nil   the keymap entry, or nil
local function find_global_map(lhs)
	local maps = vim.api.nvim_get_keymap("n")
	local target = normalize_key(lhs)
	for _, m in ipairs(maps) do
		if normalize_key(m.lhs) == target then
			return m
		end
	end
	return nil
end

--- Find a buffer-local normal-mode mapping by lhs string.
---@param bufnr integer
---@param lhs string
---@return table|nil
local function find_buf_map(bufnr, lhs)
	local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local target = normalize_key(lhs)
	for _, m in ipairs(maps) do
		if normalize_key(m.lhs) == target then
			return m
		end
	end
	return nil
end

-- Expected global keybinding -> <Plug> mapping wiring.
-- These come from config.defaults().keybindings + commands.lua key_to_plug.
local EXPECTED_GLOBAL_KEYBINDINGS = {
	{ action = "help", plug = "<Plug>(GitflowHelp)" },
	{ action = "refresh", plug = "<Plug>(GitflowRefresh)" },
	{ action = "close", plug = "<Plug>(GitflowClose)" },
	{ action = "status", plug = "<Plug>(GitflowStatus)" },
	{ action = "commit", plug = "<Plug>(GitflowCommit)" },
	{ action = "push", plug = "<Plug>(GitflowPush)" },
	{ action = "pull", plug = "<Plug>(GitflowPull)" },
	{ action = "fetch", plug = "<Plug>(GitflowFetch)" },
	{ action = "diff", plug = "<Plug>(GitflowDiff)" },
	{ action = "log", plug = "<Plug>(GitflowLog)" },
	{ action = "stash", plug = "<Plug>(GitflowStash)" },
	{ action = "stash_push", plug = "<Plug>(GitflowStashPush)" },
	{ action = "branch", plug = "<Plug>(GitflowBranch)" },
	{ action = "issue", plug = "<Plug>(GitflowIssue)" },
	{ action = "pr", plug = "<Plug>(GitflowPr)" },
	{ action = "palette", plug = "<Plug>(GitflowPalette)" },
	{ action = "conflict", plug = "<Plug>(GitflowConflicts)" },
}

-- Expected <Plug> mappings (these should exist as global maps).
local EXPECTED_PLUG_MAPPINGS = {
	"<Plug>(GitflowHelp)",
	"<Plug>(GitflowOpen)",
	"<Plug>(GitflowRefresh)",
	"<Plug>(GitflowClose)",
	"<Plug>(GitflowStatus)",
	"<Plug>(GitflowBranch)",
	"<Plug>(GitflowCommit)",
	"<Plug>(GitflowPush)",
	"<Plug>(GitflowPull)",
	"<Plug>(GitflowFetch)",
	"<Plug>(GitflowDiff)",
	"<Plug>(GitflowLog)",
	"<Plug>(GitflowStash)",
	"<Plug>(GitflowStashPush)",
	"<Plug>(GitflowIssue)",
	"<Plug>(GitflowPr)",
	"<Plug>(GitflowLabel)",
	"<Plug>(GitflowPalette)",
	"<Plug>(GitflowConflict)",
	"<Plug>(GitflowConflicts)",
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

T.run_suite("E2E: Keybinding Verification", {

	-- ── <Plug> mappings ─────────────────────────────────────────────────

	["all <Plug> mappings are registered"] = function()
		for _, plug in ipairs(EXPECTED_PLUG_MAPPINGS) do
			local m = find_global_map(plug)
			T.assert_true(
				m ~= nil,
				("Plug mapping '%s' should be registered"):format(plug)
			)
		end
	end,

	-- ── Global keybindings wired to <Plug> ──────────────────────────────

	["all global keybindings map to correct <Plug>"] = function()
		for _, binding in ipairs(EXPECTED_GLOBAL_KEYBINDINGS) do
			local key = cfg.keybindings[binding.action]
			T.assert_true(
				key ~= nil,
				("keybinding for '%s' should exist in config"):format(
					binding.action
				)
			)

			local m = find_global_map(key)
			T.assert_true(
				m ~= nil,
				("global map '%s' for action '%s' should exist"):format(
					key, binding.action
				)
			)

			-- the rhs should resolve to the expected <Plug>
			local expected_rhs = normalize_key(binding.plug)
			local actual_rhs = normalize_key(m.rhs or "")
			T.assert_equals(
				actual_rhs,
				expected_rhs,
				("'%s' should map to %s"):format(key, binding.plug)
			)
		end
	end,

	-- ── Keybinding count ────────────────────────────────────────────────

	["at least 17 global keybindings are configured"] = function()
		local count = 0
		for _ in pairs(cfg.keybindings) do
			count = count + 1
		end
		T.assert_true(
			count >= 17,
			("expected >= 17 keybindings, got %d"):format(count)
		)
	end,

	-- ── Status panel local keybindings ──────────────────────────────────

	["status panel has expected buffer-local keymaps"] = function()
		commands.dispatch({ "status" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("status")
		T.assert_true(bufnr ~= nil, "status buffer should exist")

		local expected_keys = { "s", "u", "a", "A", "r", "q" }
		for _, key in ipairs(expected_keys) do
			local m = find_buf_map(bufnr, key)
			T.assert_true(
				m ~= nil,
				("status panel should have '%s' keymap"):format(key)
			)
		end

		cleanup_panels()
	end,

	-- ── Diff panel local keybindings ────────────────────────────────────

	["diff panel has expected buffer-local keymaps"] = function()
		commands.dispatch({ "diff" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("diff")
		T.assert_true(bufnr ~= nil, "diff buffer should exist")

		T.assert_keymaps(bufnr, { "q", "r" })

		cleanup_panels()
	end,

	-- ── Log panel local keybindings ─────────────────────────────────────

	["log panel has expected buffer-local keymaps"] = function()
		commands.dispatch({ "log" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("log")
		T.assert_true(bufnr ~= nil, "log buffer should exist")

		T.assert_keymaps(bufnr, { "q", "r" })

		cleanup_panels()
	end,

	-- ── Stash panel local keybindings ───────────────────────────────────

	["stash panel has expected buffer-local keymaps"] = function()
		commands.dispatch({ "stash", "list" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("stash")
		T.assert_true(bufnr ~= nil, "stash buffer should exist")

		T.assert_keymaps(bufnr, { "q", "r", "S" })

		cleanup_panels()
	end,

	-- ── Branch panel local keybindings ──────────────────────────────────

	["branch panel has expected buffer-local keymaps"] = function()
		commands.dispatch({ "branch" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		T.assert_true(bufnr ~= nil, "branch buffer should exist")

		T.assert_keymaps(bufnr, { "q", "r" })

		cleanup_panels()
	end,

	-- ── Conflict panel local keybindings ────────────────────────────────

	["conflict panel has expected buffer-local keymaps"] = function()
		commands.dispatch({ "conflicts" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("conflict")
		T.assert_true(bufnr ~= nil, "conflict buffer should exist")

		T.assert_keymaps(bufnr, { "q", "r" })

		cleanup_panels()
	end,

	-- ── <Plug> mapping rhs points to :Gitflow command ───────────────────

	["<Plug>(GitflowStatus) maps to :Gitflow status"] = function()
		local m = find_global_map("<Plug>(GitflowStatus)")
		T.assert_true(m ~= nil, "Plug(GitflowStatus) should exist")
		-- rhs is typically "<Cmd>Gitflow status<CR>"
		-- normalize and check contains
		local rhs = m.rhs or ""
		T.assert_contains(
			rhs,
			"Gitflow status",
			"GitflowStatus plug should run :Gitflow status"
		)
	end,

	["<Plug>(GitflowDiff) maps to :Gitflow diff"] = function()
		local m = find_global_map("<Plug>(GitflowDiff)")
		T.assert_true(m ~= nil, "Plug(GitflowDiff) should exist")
		local rhs = m.rhs or ""
		T.assert_contains(
			rhs,
			"Gitflow diff",
			"GitflowDiff plug should run :Gitflow diff"
		)
	end,

	["<Plug>(GitflowLog) maps to :Gitflow log"] = function()
		local m = find_global_map("<Plug>(GitflowLog)")
		T.assert_true(m ~= nil, "Plug(GitflowLog) should exist")
		local rhs = m.rhs or ""
		T.assert_contains(
			rhs,
			"Gitflow log",
			"GitflowLog plug should run :Gitflow log"
		)
	end,

	["<Plug>(GitflowStash) maps to :Gitflow stash list"] = function()
		local m = find_global_map("<Plug>(GitflowStash)")
		T.assert_true(m ~= nil, "Plug(GitflowStash) should exist")
		local rhs = m.rhs or ""
		T.assert_contains(
			rhs,
			"Gitflow stash",
			"GitflowStash plug should run :Gitflow stash"
		)
	end,

	["<Plug>(GitflowConflicts) maps to :Gitflow conflicts"] = function()
		local m = find_global_map("<Plug>(GitflowConflicts)")
		T.assert_true(m ~= nil, "Plug(GitflowConflicts) should exist")
		local rhs = m.rhs or ""
		T.assert_contains(
			rhs,
			"Gitflow conflicts",
			"GitflowConflicts plug should run :Gitflow conflicts"
		)
	end,
})

print("E2E keybinding verification tests passed")
