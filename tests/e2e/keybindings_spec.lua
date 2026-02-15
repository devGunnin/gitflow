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
local branch_panel = require("gitflow.panels.branch")

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

---@param bufnr integer
---@param lines string[]
local function set_branch_buffer_lines(bufnr, lines)
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

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
	local original_notify = vim.notify
	vim.notify = function(msg, level, ...)
		notifications[#notifications + 1] = {
			message = msg,
			level = level,
		}
		return original_notify(msg, level, ...)
	end

	local ok, err = xpcall(fn, debug.traceback)
	vim.notify = original_notify
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

		T.assert_keymaps(bufnr, { "q", "r", "m" })

		cleanup_panels()
	end,

	["branch merge action forwards branch name via structured args"] = function()
		commands.dispatch({ "branch" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		local winid = branch_panel.state.winid
		T.assert_true(bufnr ~= nil, "branch buffer should exist")
		T.assert_true(winid ~= nil, "branch window should exist")

		vim.api.nvim_set_current_win(winid)

		local special_branch = "feature|unsafe'branch"
		set_branch_buffer_lines(bufnr, {
			"Gitflow Branches",
			"  " .. special_branch,
		})
		branch_panel.state.line_entries = {
			[2] = {
				name = special_branch,
				is_current = false,
				is_remote = false,
			},
		}
		vim.api.nvim_win_set_cursor(winid, { 2, 0 })

		local observed_cmd = nil
		local refresh_calls = 0
		with_temporary_patches({
			{
				table = require("gitflow.ui.input"),
				key = "confirm",
				value = function()
					return true
				end,
			},
			{
				table = branch_panel,
				key = "refresh",
				value = function()
					refresh_calls = refresh_calls + 1
				end,
			},
			{
				table = vim,
				key = "cmd",
				value = function(cmd_args)
					observed_cmd = cmd_args
				end,
			},
		}, function()
			branch_panel.merge_under_cursor()
			T.wait_until(function()
				return refresh_calls > 0
			end, "branch merge should schedule a refresh", 1000)
		end)

		T.assert_true(
			type(observed_cmd) == "table",
			"branch merge should call vim.cmd with structured args"
		)
		T.assert_equals(observed_cmd.cmd, "Gitflow", "branch merge should invoke :Gitflow")
		T.assert_deep_equals(
			observed_cmd.args,
			{ "merge", special_branch },
			"branch merge should pass branch name as a literal arg"
		)

		cleanup_panels()
	end,

	["branch merge warns when no branch entry is selected"] = function()
		commands.dispatch({ "branch" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		local winid = branch_panel.state.winid
		T.assert_true(bufnr ~= nil, "branch buffer should exist")
		T.assert_true(winid ~= nil, "branch window should exist")

		set_branch_buffer_lines(bufnr, {
			"Gitflow Branches",
			"  feature/test",
		})
		branch_panel.state.line_entries = {
			[2] = { name = "feature/test", is_current = false, is_remote = false },
		}

		vim.api.nvim_set_current_win(winid)
		vim.api.nvim_win_set_cursor(winid, { 1, 0 })
		T.assert_true(
			branch_panel.state.line_entries[1] == nil,
			"line 1 should not be a selectable branch entry"
		)

		local confirm_calls = 0
		local cmd_calls = 0
		local notifications = capture_notifications(function()
			with_temporary_patches({
				{
					table = require("gitflow.ui.input"),
					key = "confirm",
					value = function()
						confirm_calls = confirm_calls + 1
						return true
					end,
				},
				{
					table = vim,
					key = "cmd",
					value = function()
						cmd_calls = cmd_calls + 1
					end,
				},
			}, function()
				branch_panel.merge_under_cursor()
			end)
		end)

		T.assert_true(
			has_notification(notifications, "No branch selected", vim.log.levels.WARN),
			"branch merge should warn when cursor is not on a branch"
		)
		T.assert_equals(confirm_calls, 0, "no-selection merge should not show confirm prompt")
		T.assert_equals(cmd_calls, 0, "no-selection merge should not invoke command")

		cleanup_panels()
	end,

	["branch merge blocks merging the current branch"] = function()
		commands.dispatch({ "branch" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		local winid = branch_panel.state.winid
		T.assert_true(bufnr ~= nil, "branch buffer should exist")
		T.assert_true(winid ~= nil, "branch window should exist")
		vim.api.nvim_set_current_win(winid)

		set_branch_buffer_lines(bufnr, {
			"Gitflow Branches",
			"  main (current)",
		})
		branch_panel.state.line_entries = {
			[2] = { name = "main", is_current = true, is_remote = false },
		}
		vim.api.nvim_win_set_cursor(winid, { 2, 0 })

		local confirm_calls = 0
		local cmd_calls = 0
		local notifications = capture_notifications(function()
			with_temporary_patches({
				{
					table = require("gitflow.ui.input"),
					key = "confirm",
					value = function()
						confirm_calls = confirm_calls + 1
						return true
					end,
				},
				{
					table = vim,
					key = "cmd",
					value = function()
						cmd_calls = cmd_calls + 1
					end,
				},
			}, function()
				branch_panel.merge_under_cursor()
			end)
		end)

		T.assert_true(
			has_notification(
				notifications,
				"Cannot merge branch into itself",
				vim.log.levels.WARN
			),
			"current-branch merge should warn"
		)
		T.assert_equals(confirm_calls, 0, "self-merge should not show confirm prompt")
		T.assert_equals(cmd_calls, 0, "self-merge should not invoke command")

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
