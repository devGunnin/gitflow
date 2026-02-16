-- tests/e2e/focus_restore_spec.lua — Focus restore after issue/PR creation
--
-- Run:
--   nvim --headless -u tests/minimal_init.lua \
--     -l tests/e2e/focus_restore_spec.lua
--
-- Verifies:
--   1. After issue creation, cursor focus returns to the issues panel
--   2. After PR creation, cursor focus returns to the PRs panel
--   3. Focus restore is skipped when the panel window is closed

local T = _G.T
local cfg = _G.TestConfig

local ui = require("gitflow.ui")
local gh_issues = require("gitflow.gh.issues")
local gh_prs = require("gitflow.gh.prs")
local gh_labels = require("gitflow.gh.labels")
local form = require("gitflow.ui.form")
local utils = require("gitflow.utils")
local issues_panel = require("gitflow.panels.issues")
local prs_panel = require("gitflow.panels.prs")

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

--- Close any panel windows left open between tests.
local function cleanup_panels()
	for _, panel_name in ipairs({
		"status", "diff", "log", "stash", "branch",
		"conflict", "issues", "prs", "labels", "review",
		"palette",
	}) do
		local mod_ok, mod = pcall(
			require, "gitflow.panels." .. panel_name
		)
		if mod_ok and mod.close then
			pcall(mod.close)
		end
	end

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local win_cfg = vim.api.nvim_win_get_config(win)
		if win_cfg.relative and win_cfg.relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
end

T.run_suite("E2E: Focus Restore After Creation", {

	-- ── Issue creation restores focus to panel ──────────────

	["issue create restores focus to panel window"] = function()
		-- Open the issues panel so M.state.winid is set
		issues_panel.open(cfg)
		T.drain_jobs(3000)

		local panel_winid = issues_panel.state.winid
		T.assert_true(
			panel_winid ~= nil
				and vim.api.nvim_win_is_valid(panel_winid),
			"issues panel window should be open"
		)

		-- Move focus away from the panel to simulate the
		-- background-window focus drift during async execution
		local other_win = vim.api.nvim_open_win(
			vim.api.nvim_create_buf(false, true),
			true,
			{ relative = "editor", width = 10, height = 5,
				row = 1, col = 1 }
		)
		T.assert_true(
			vim.api.nvim_get_current_win() == other_win,
			"focus should be on the other window"
		)

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_issues,
				key = "create",
				value = function(_, _, cb)
					cb(nil, {
						url = "https://github.com/t/r/issues/99",
					})
				end,
			},
			{
				table = gh_issues,
				key = "list",
				value = function(_, _, cb)
					cb(nil, {})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					opts.on_submit({
						title = "Focus test issue",
						body = "",
						labels = "",
						assignees = "",
					})
					return {
						bufnr = nil, winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			issues_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_equals(
				vim.api.nvim_get_current_win(),
				panel_winid,
				"focus should return to issues panel window"
			)
		end)

		pcall(vim.api.nvim_win_close, other_win, true)
		cleanup_panels()
	end,

	-- ── PR creation restores focus to panel ─────────────────

	["pr create restores focus to panel window"] = function()
		prs_panel.open(cfg)
		T.drain_jobs(3000)

		local panel_winid = prs_panel.state.winid
		T.assert_true(
			panel_winid ~= nil
				and vim.api.nvim_win_is_valid(panel_winid),
			"prs panel window should be open"
		)

		-- Move focus away from the panel
		local other_win = vim.api.nvim_open_win(
			vim.api.nvim_create_buf(false, true),
			true,
			{ relative = "editor", width = 10, height = 5,
				row = 1, col = 1 }
		)
		T.assert_true(
			vim.api.nvim_get_current_win() == other_win,
			"focus should be on the other window"
		)

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_prs,
				key = "create",
				value = function(_, _, cb)
					cb(nil, {
						url = "https://github.com/t/r/pull/99",
					})
				end,
			},
			{
				table = gh_prs,
				key = "list",
				value = function(_, _, cb)
					cb(nil, {})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					opts.on_submit({
						title = "Focus test PR",
						body = "",
						base = "",
						reviewers = "",
						labels = "",
					})
					return {
						bufnr = nil, winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_equals(
				vim.api.nvim_get_current_win(),
				panel_winid,
				"focus should return to prs panel window"
			)
		end)

		pcall(vim.api.nvim_win_close, other_win, true)
		cleanup_panels()
	end,

	-- ── Focus restore skipped when panel closed ─────────────

	["focus restore skipped when panel window is gone"] = function()
		local notify_messages = {}

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_issues,
				key = "create",
				value = function(_, _, cb)
					-- Close panel before callback fires
					issues_panel.close()
					cb(nil, {
						url = "https://github.com/t/r/issues/50",
					})
				end,
			},
			{
				table = gh_issues,
				key = "list",
				value = function(_, _, cb)
					cb(nil, {})
				end,
			},
			{
				table = utils,
				key = "notify",
				value = function(msg, level)
					notify_messages[#notify_messages + 1] = {
						msg = msg, level = level,
					}
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					opts.on_submit({
						title = "Closed panel test",
						body = "",
						labels = "",
						assignees = "",
					})
					return {
						bufnr = nil, winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			issues_panel.open(cfg)
			T.drain_jobs(3000)

			local ok = T.pcall_message(function()
				issues_panel.create_interactive()
				T.drain_jobs(3000)
			end)

			T.assert_true(
				ok,
				"no crash when panel closed during create"
			)
		end)

		cleanup_panels()
	end,
})

print("E2E focus restore tests passed")
