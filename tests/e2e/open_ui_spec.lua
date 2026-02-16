-- tests/e2e/open_ui_spec.lua — UI initialization, panel open/close, buffer naming
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/open_ui_spec.lua

local T = _G.T
local cfg = _G.TestConfig

local ui = require("gitflow.ui")
local commands = require("gitflow.commands")

---@param dimension number
---@param max_value integer
---@return integer
local function resolve_expected_dimension(dimension, max_value)
	if dimension > 0 and dimension <= 1 then
		return math.max(1, math.floor(max_value * dimension))
	end
	return math.max(1, math.floor(dimension))
end

T.run_suite("E2E: UI Initialization & Panel Open/Close", {

	-- ── Main panel via :Gitflow open ────────────────────────────────────

	["open main panel via :Gitflow open"] = function()
		local before = T.window_layout()
		T.exec_command("Gitflow open")

		-- split layout: one new split window
		local after = T.window_layout()
		T.assert_true(
			after.total > before.total,
			"opening main panel should create a new window"
		)

		-- buffer name follows gitflow:// convention
		local winid = commands.state.panel_window
		T.assert_true(
			winid ~= nil and vim.api.nvim_win_is_valid(winid),
			"panel window should be valid after open"
		)
		T.assert_buf_name(winid, "gitflow://", "main panel buffer name")

		-- clean up
		T.exec_command("Gitflow close")
	end,

	["main panel buffer uses gitflow:// naming convention"] = function()
		T.exec_command("Gitflow open")
		local winid = commands.state.panel_window
		local bufnr = vim.api.nvim_win_get_buf(winid)
		local name = vim.api.nvim_buf_get_name(bufnr)
		T.assert_contains(
			name,
			"gitflow://main",
			"main panel buffer should be named gitflow://main"
		)
		T.exec_command("Gitflow close")
	end,

	["main panel split has correct size"] = function()
		T.exec_command("Gitflow open")
		local winid = commands.state.panel_window
		T.assert_true(
			winid ~= nil and vim.api.nvim_win_is_valid(winid),
			"panel window should exist"
		)

		-- test config sets split orientation=vertical, size=40
		local width = vim.api.nvim_win_get_width(winid)
		T.assert_equals(
			width,
			40,
			"vertical split panel should have width 40 from test config"
		)

		T.exec_command("Gitflow close")
	end,

	["close main panel via :Gitflow close"] = function()
		T.exec_command("Gitflow open")
		T.assert_true(
			commands.state.panel_window ~= nil,
			"panel window should exist before close"
		)

		T.exec_command("Gitflow close")
		-- after close the state should be cleared
		T.assert_true(
			commands.state.panel_window == nil
				or not vim.api.nvim_win_is_valid(commands.state.panel_window),
			"panel window should be gone after close"
		)
	end,

	["main panel renders without errors"] = function()
		local ok, err = T.pcall_message(function()
			T.exec_command("Gitflow open")
		end)
		T.assert_true(ok, "opening main panel should not error: " .. (err or ""))

		-- verify buffer has content
		local winid = commands.state.panel_window
		local bufnr = vim.api.nvim_win_get_buf(winid)
		local lines = T.buf_lines(bufnr)
		T.assert_true(#lines > 0, "main panel should have content")
		T.assert_true(
			T.find_line(lines, "Gitflow") ~= nil,
			"main panel should contain 'Gitflow' text"
		)

		T.exec_command("Gitflow close")
	end,

	-- ── Float layout ────────────────────────────────────────────────────

	["open main panel as float when configured"] = function()
		-- temporarily reconfigure to float layout
		local gitflow = require("gitflow")
		local float_cfg = gitflow.setup({
			ui = {
				default_layout = "float",
				split = { orientation = "vertical", size = 40 },
			},
		})

		T.exec_command("Gitflow open")

		local winid = commands.state.panel_window
		T.assert_true(
			winid ~= nil and vim.api.nvim_win_is_valid(winid),
			"float panel window should be valid"
		)
		T.assert_true(
			T.is_float(winid),
			"panel should be a floating window in float layout"
		)

		-- verify float dimensions match configured values
		local width = vim.api.nvim_win_get_width(winid)
		local height = vim.api.nvim_win_get_height(winid)
		local expected_width = resolve_expected_dimension(
			float_cfg.ui.float.width,
			vim.o.columns
		)
		local expected_height = resolve_expected_dimension(
			float_cfg.ui.float.height,
			vim.o.lines - vim.o.cmdheight
		)

		T.assert_equals(
			width,
			expected_width,
			"float width should match configured width"
		)
		T.assert_equals(
			height,
			expected_height,
			"float height should match configured height"
		)

		T.exec_command("Gitflow close")

		-- restore split config
		gitflow.setup({
			ui = {
				default_layout = "split",
				split = { orientation = "vertical", size = 40 },
			},
		})
	end,

	-- ── Status panel open/close ─────────────────────────────────────────

	["status panel opens and creates buffer"] = function()
		local status = require("gitflow.panels.status")
		local ok, err = T.pcall_message(function()
			T.exec_command("Gitflow status")
		end)
		T.assert_true(
			ok,
			"opening status panel should not error: " .. (err or "")
		)
		T.drain_jobs(3000)

		-- buffer should exist with gitflow:// prefix
		local bufnr = ui.buffer.get("status")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"status buffer should exist after :Gitflow status"
		)
		local name = vim.api.nvim_buf_get_name(bufnr)
		T.assert_contains(
			name,
			"gitflow://status",
			"status buffer should be named gitflow://status"
		)

		-- close and verify
		status.close()
	end,

	["status panel has q keymap for close"] = function()
		local status = require("gitflow.panels.status")
		T.exec_command("Gitflow status")
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("status")
		T.assert_true(bufnr ~= nil, "status buffer should exist")
		T.assert_keymaps(bufnr, { "q" })

		status.close()
	end,

	-- ── Diff panel open/close ───────────────────────────────────────────

	["diff panel opens and creates buffer"] = function()
		local diff_panel = require("gitflow.panels.diff")
		local ok, err = T.pcall_message(function()
			T.exec_command("Gitflow diff")
		end)
		T.assert_true(
			ok,
			"opening diff panel should not error: " .. (err or "")
		)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("diff")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"diff buffer should exist after :Gitflow diff"
		)

		local ft = vim.api.nvim_get_option_value(
			"filetype", { buf = bufnr }
		)
		T.assert_equals(
			ft,
			"gitflow-diff",
			"diff buffer should use gitflow-diff filetype"
		)

		local has_ts = pcall(
			vim.treesitter.get_parser, bufnr
		)
		T.assert_false(
			has_ts,
			"treesitter should not attach to diff buffer"
		)

		diff_panel.close()
	end,

	-- ── Log panel open/close ────────────────────────────────────────────

	["log panel opens and creates buffer"] = function()
		local log_panel = require("gitflow.panels.log")
		local ok, err = T.pcall_message(function()
			T.exec_command("Gitflow log")
		end)
		T.assert_true(
			ok,
			"opening log panel should not error: " .. (err or "")
		)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("log")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"log buffer should exist after :Gitflow log"
		)

		log_panel.close()
	end,

	-- ── Stash panel open/close ──────────────────────────────────────────

	["stash panel opens and creates buffer"] = function()
		local stash_panel = require("gitflow.panels.stash")
		local ok, err = T.pcall_message(function()
			T.exec_command("Gitflow stash list")
		end)
		T.assert_true(
			ok,
			"opening stash panel should not error: " .. (err or "")
		)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("stash")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"stash buffer should exist after :Gitflow stash list"
		)

		stash_panel.close()
	end,

	-- ── Branch panel open/close ─────────────────────────────────────────

	["branch panel opens and creates buffer"] = function()
		local branch_panel = require("gitflow.panels.branch")
		local ok, err = T.pcall_message(function()
			T.exec_command("Gitflow branch")
		end)
		T.assert_true(
			ok,
			"opening branch panel should not error: " .. (err or "")
		)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"branch buffer should exist after :Gitflow branch"
		)

		branch_panel.close()
	end,

	-- ── Conflict panel ──────────────────────────────────────────────────

	["conflict panel opens and creates buffer"] = function()
		local conflict = require("gitflow.panels.conflict")
		local ok, err = T.pcall_message(function()
			T.exec_command("Gitflow conflicts")
		end)
		T.assert_true(
			ok,
			"opening conflict panel should not error: " .. (err or "")
		)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("conflict")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"conflict buffer should exist after :Gitflow conflicts"
		)

		conflict.close()
	end,

	-- ── Title rendering ─────────────────────────────────────────────────

	["panel buffers contain title content"] = function()
		T.exec_command("Gitflow open")
		T.drain_jobs(3000)
		local winid = commands.state.panel_window
		local bufnr = vim.api.nvim_win_get_buf(winid)
		local lines = T.buf_lines(bufnr)

		T.assert_true(
			T.find_line(lines, "Gitflow") ~= nil,
			"main panel should render a title with 'Gitflow'"
		)

		T.exec_command("Gitflow close")
	end,

	-- ── Window cleanup after close ──────────────────────────────────────

	["closing panel cleans up window registry"] = function()
		T.exec_command("Gitflow open")
		local winid = commands.state.panel_window
		T.assert_true(
			winid ~= nil,
			"panel should have a window id"
		)
		T.assert_true(
			ui.window.get("main") ~= nil,
			"main window should be in registry"
		)

		T.exec_command("Gitflow close")
		T.assert_true(
			ui.window.get("main") == nil,
			"main window should be removed from registry after close"
		)
	end,
})

print("E2E UI initialization tests passed")
