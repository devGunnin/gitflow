-- tests/e2e/notifications_spec.lua — notification center smoke tests
--
-- Run: nvim --headless -u tests/minimal_init.lua \
--        -l tests/e2e/notifications_spec.lua
--
-- Verifies:
--   1. Ring buffer push / entries / clear / overflow
--   2. Notification capture via utils.notify()
--   3. Panel open / close / keymaps
--   4. Severity filter rendering
--   5. Global keybinding and <Plug> mapping

local T = _G.T
local cfg = _G.TestConfig

local notifications = require("gitflow.notifications")
local notifications_panel = require("gitflow.panels.notifications")
local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local utils = require("gitflow.utils")

T.run_suite("E2E: Notification Center", {

	-- ── Ring buffer basics ────────────────────────────────────────────

	["push and entries return stored notifications"] = function()
		notifications.clear()
		notifications.push("test message", vim.log.levels.INFO)
		local entries = notifications.entries()
		T.assert_equals(#entries, 1, "should have 1 entry")
		T.assert_equals(
			entries[1].message,
			"test message",
			"message should match"
		)
		T.assert_equals(
			entries[1].level,
			vim.log.levels.INFO,
			"level should be INFO"
		)
		T.assert_true(
			type(entries[1].timestamp) == "number",
			"timestamp should be a number"
		)
		notifications.clear()
	end,

	["clear empties the buffer"] = function()
		notifications.clear()
		notifications.push("a", vim.log.levels.INFO)
		notifications.push("b", vim.log.levels.WARN)
		T.assert_equals(
			notifications.count(), 2,
			"should have 2 entries before clear"
		)
		notifications.clear()
		T.assert_equals(
			notifications.count(), 0,
			"should have 0 entries after clear"
		)
	end,

	["overflow drops oldest entries"] = function()
		notifications.clear()
		notifications.setup(5)
		for i = 1, 8 do
			notifications.push(
				("msg%d"):format(i), vim.log.levels.INFO
			)
		end
		T.assert_equals(
			notifications.count(), 5,
			"buffer should cap at max_entries"
		)
		local entries = notifications.entries()
		T.assert_equals(
			entries[1].message, "msg4",
			"oldest surviving entry should be msg4"
		)
		T.assert_equals(
			entries[5].message, "msg8",
			"newest entry should be msg8"
		)
		-- restore default capacity
		notifications.setup(200)
		notifications.clear()
	end,

	["entries returns a copy, not a reference"] = function()
		notifications.clear()
		notifications.push("original", vim.log.levels.INFO)
		local entries = notifications.entries()
		entries[1].message = "modified"
		local fresh = notifications.entries()
		T.assert_equals(
			fresh[1].message, "original",
			"modifying returned entries should not affect buffer"
		)
		notifications.clear()
	end,

	-- ── Capture via utils.notify ──────────────────────────────────────

	["utils.notify captures into ring buffer"] = function()
		notifications.clear()
		utils.notify("hello from utils", vim.log.levels.WARN)
		local entries = notifications.entries()
		T.assert_equals(#entries, 1, "should capture 1 entry")
		T.assert_equals(
			entries[1].message, "hello from utils",
			"captured message should match"
		)
		T.assert_equals(
			entries[1].level, vim.log.levels.WARN,
			"captured level should be WARN"
		)
		notifications.clear()
	end,

	-- ── Panel open / close ────────────────────────────────────────────

	["panel opens and closes correctly"] = function()
		notifications.clear()
		notifications.push("test entry", vim.log.levels.INFO)

		notifications_panel.open(cfg)
		T.assert_true(
			notifications_panel.is_open(),
			"panel should be open"
		)

		local bufnr = ui.buffer.get("notifications")
		T.assert_true(
			bufnr ~= nil,
			"notifications buffer should exist"
		)

		local lines = T.buf_lines(bufnr)
		local found = false
		for _, line in ipairs(lines) do
			if line:find("test entry", 1, true) then
				found = true
				break
			end
		end
		T.assert_true(found, "panel should show the notification")

		notifications_panel.close()
		T.assert_false(
			notifications_panel.is_open(),
			"panel should be closed"
		)
		notifications.clear()
	end,

	["panel shows empty state"] = function()
		notifications.clear()
		notifications_panel.open(cfg)

		local bufnr = ui.buffer.get("notifications")
		T.assert_true(bufnr ~= nil, "buffer should exist")

		local lines = T.buf_lines(bufnr)
		local found = false
		for _, line in ipairs(lines) do
			if line:find("no notifications", 1, true) then
				found = true
				break
			end
		end
		T.assert_true(
			found, "panel should show empty state message"
		)

		T.cleanup_panels()
	end,

	-- ── Panel keymaps ─────────────────────────────────────────────────

	["panel has expected buffer-local keymaps"] = function()
		notifications.clear()
		notifications_panel.open(cfg)

		local bufnr = ui.buffer.get("notifications")
		T.assert_true(
			bufnr ~= nil,
			"notifications buffer should exist"
		)

		T.assert_keymaps(
			bufnr,
			{ "r", "c", "q", "0", "1", "2", "3" }
		)

		T.cleanup_panels()
	end,

	-- ── Severity filter rendering ─────────────────────────────────────

	["severity filter shows only matching entries"] = function()
		notifications.clear()
		notifications.push("error msg", vim.log.levels.ERROR)
		notifications.push("warn msg", vim.log.levels.WARN)
		notifications.push("info msg", vim.log.levels.INFO)

		notifications_panel.open(cfg)
		notifications_panel.state.filter_level =
			vim.log.levels.ERROR
		notifications_panel.refresh()

		local bufnr = ui.buffer.get("notifications")
		T.assert_true(bufnr ~= nil, "buffer should exist")

		local lines = T.buf_lines(bufnr)
		local found_error = false
		local found_warn = false
		local found_info = false
		for _, line in ipairs(lines) do
			if line:find("error msg", 1, true) then
				found_error = true
			end
			if line:find("warn msg", 1, true) then
				found_warn = true
			end
			if line:find("info msg", 1, true) then
				found_info = true
			end
		end

		T.assert_true(
			found_error,
			"error filter should show error entries"
		)
		T.assert_false(
			found_warn,
			"error filter should hide warn entries"
		)
		T.assert_false(
			found_info,
			"error filter should hide info entries"
		)

		T.cleanup_panels()
		notifications.clear()
	end,

	-- ── Severity grouping in content ──────────────────────────────────

	["entries show severity labels"] = function()
		notifications.clear()
		notifications.push("e1", vim.log.levels.ERROR)
		notifications.push("w1", vim.log.levels.WARN)
		notifications.push("i1", vim.log.levels.INFO)

		notifications_panel.open(cfg)

		local bufnr = ui.buffer.get("notifications")
		local lines = T.buf_lines(bufnr)

		local has_error_label = false
		local has_warn_label = false
		local has_info_label = false
		for _, line in ipairs(lines) do
			if line:find("[ERROR]", 1, true) then
				has_error_label = true
			end
			if line:find("[WARN]", 1, true) then
				has_warn_label = true
			end
			if line:find("[INFO]", 1, true) then
				has_info_label = true
			end
		end

		T.assert_true(
			has_error_label,
			"should show [ERROR] severity label"
		)
		T.assert_true(
			has_warn_label,
			"should show [WARN] severity label"
		)
		T.assert_true(
			has_info_label,
			"should show [INFO] severity label"
		)

		T.cleanup_panels()
		notifications.clear()
	end,

	-- ── Subcommand dispatch ──────────────────────────────────────────

	["Gitflow notifications subcommand opens panel"] = function()
		notifications.clear()
		commands.dispatch({ "notifications" }, cfg)

		T.assert_true(
			notifications_panel.is_open(),
			"dispatch should open notifications panel"
		)

		T.cleanup_panels()
	end,

	-- ── Global <Plug> mapping ─────────────────────────────────────────

	["<Plug>(GitflowNotifications) mapping exists"] = function()
		local maps = vim.api.nvim_get_keymap("n")
		local found = false
		for _, m in ipairs(maps) do
			if m.lhs
				and m.lhs:find(
					"<Plug>(GitflowNotifications)", 1, true
				)
			then
				found = true
				break
			end
		end
		T.assert_true(
			found,
			"<Plug>(GitflowNotifications) should be registered"
		)
	end,

	["notifications keybinding has a global map"] = function()
		local key = cfg.keybindings.notifications
		T.assert_true(
			key ~= nil,
			"notifications keybinding should exist in config"
		)

		local target = vim.api.nvim_replace_termcodes(
			key, true, true, true
		)
		local maps = vim.api.nvim_get_keymap("n")
		local found = false
		for _, m in ipairs(maps) do
			local lhs = vim.api.nvim_replace_termcodes(
				m.lhs, true, true, true
			)
			if lhs == target then
				found = true
				break
			end
		end
		T.assert_true(
			found,
			("global map '%s' for notifications should exist"
			):format(key)
		)
	end,

	-- ── Config validation ─────────────────────────────────────────────

	["config rejects invalid max_entries"] = function()
		local config_mod = require("gitflow.config")
		local ok, _ = pcall(function()
			config_mod.validate(
				vim.tbl_deep_extend(
					"force",
					config_mod.defaults(),
					{ notifications = { max_entries = 0 } }
				)
			)
		end)
		T.assert_false(
			ok,
			"max_entries = 0 should fail validation"
		)

		local ok2, _ = pcall(function()
			config_mod.validate(
				vim.tbl_deep_extend(
					"force",
					config_mod.defaults(),
					{ notifications = { max_entries = "bad" } }
				)
			)
		end)
		T.assert_false(
			ok2,
			"max_entries = 'bad' should fail validation"
		)
	end,

	-- ── Highlight groups exist ────────────────────────────────────────

	["notification highlight groups are defined"] = function()
		T.assert_true(
			T.hl_exists("GitflowNotificationError"),
			"GitflowNotificationError should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowNotificationWarn"),
			"GitflowNotificationWarn should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowNotificationInfo"),
			"GitflowNotificationInfo should be defined"
		)
	end,
})

print("E2E notification center tests passed")
