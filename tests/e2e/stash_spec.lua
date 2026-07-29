-- tests/e2e/stash_spec.lua — stash panel E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/stash_spec.lua
--
-- Verifies:
--   1. pop_under_cursor refreshes an open status panel (mirrors the sibling
--      apply_under_cursor behavior)

local T = _G.T
local cfg = _G.TestConfig

local status_panel = require("gitflow.panels.status")
local stash_panel = require("gitflow.panels.stash")

T.run_suite("E2E: Stash Panel", {

	["pop_under_cursor refreshes an open status panel"] = function()
		status_panel.open(cfg, {})
		stash_panel.open(cfg)
		T.drain_jobs(3000)

		local entry_line
		for line, entry in pairs(stash_panel.state.line_entries) do
			if entry.index == 0 then
				entry_line = line
			end
		end
		T.assert_true(entry_line ~= nil, "fixture should have a stash@{0} entry")

		local count = 0
		local original = status_panel.refresh
		status_panel.refresh = function(...)
			count = count + 1
			return original(...)
		end

		local ok, err = xpcall(function()
			vim.api.nvim_set_current_win(stash_panel.state.winid)
			vim.api.nvim_win_set_cursor(
				stash_panel.state.winid, { entry_line, 0 })
			stash_panel.pop_under_cursor()
			T.drain_jobs(2000)
		end, debug.traceback)
		status_panel.refresh = original
		if not ok then
			error(err, 0)
		end

		T.assert_true(
			count > 0,
			"stash pop should refresh the open status panel"
		)

		stash_panel.close()
		status_panel.close()
	end,
})

print("E2E stash panel tests passed")
