-- tests/e2e/reflog_spec.lua — reflog panel E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/reflog_spec.lua
--
-- Verifies:
--   1. Reflog subcommand registration and dispatch
--   2. Reflog panel open/close, buffer creation, keymaps
--   3. Reflog list parsing for tab-delimited entries
--   4. Checkout and reset command dispatch via git stub
--   5. Plug mapping and keybinding wiring

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local git_reflog = require("gitflow.git.reflog")

---@param fn fun(log_path: string)
local function with_temp_git_log(fn)
	local log_path = vim.fn.tempname()
	local previous = vim.env.GITFLOW_GIT_LOG
	vim.env.GITFLOW_GIT_LOG = log_path

	local ok, err = xpcall(function()
		fn(log_path)
	end, debug.traceback)

	vim.env.GITFLOW_GIT_LOG = previous
	pcall(vim.fn.delete, log_path)

	if not ok then
		error(err, 0)
	end
end

T.run_suite("E2E: Reflog Panel", {

	-- ── Subcommand registration ─────────────────────────────────────

	["reflog subcommand is registered"] = function()
		T.assert_true(
			commands.subcommands["reflog"] ~= nil,
			"reflog subcommand should be registered"
		)
	end,

	["reflog subcommand has description and run"] = function()
		local sub = commands.subcommands["reflog"]
		T.assert_true(
			type(sub.description) == "string"
				and sub.description ~= "",
			"reflog should have a non-empty description"
		)
		T.assert_true(
			type(sub.run) == "function",
			"reflog should have a run function"
		)
	end,

	-- ── Reflog dispatch ─────────────────────────────────────────────

	["reflog opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "reflog" }, cfg)
		end)
		T.assert_true(
			ok, "reflog should not crash: " .. (err or "")
		)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("reflog")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"reflog buffer should exist after :Gitflow reflog"
		)
		T.cleanup_panels()
	end,

	["reflog dispatch returns message"] = function()
		local result
		local ok, err = T.pcall_message(function()
			result = commands.dispatch({ "reflog" }, cfg)
		end)
		T.assert_true(
			ok, "reflog should not crash: " .. (err or "")
		)
		T.assert_contains(
			result, "Reflog panel opened",
			"should return opened message"
		)
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── Panel keymaps ───────────────────────────────────────────────

	["reflog panel has expected keymaps"] = function()
		local reflog_panel = require("gitflow.panels.reflog")
		commands.dispatch({ "reflog" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("reflog")
		T.assert_true(bufnr ~= nil, "reflog buffer should exist")
		T.assert_keymaps(bufnr, { "q", "r", "R", "<CR>" })

		reflog_panel.close()
	end,

	-- ── Panel content ───────────────────────────────────────────────

	["reflog panel renders entries from stub"] = function()
		local reflog_panel = require("gitflow.panels.reflog")
		commands.dispatch({ "reflog" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("reflog")
		T.assert_true(bufnr ~= nil, "reflog buffer should exist")

		local lines = T.buf_lines(bufnr)
		local found_commit = T.find_line(lines, "commit:")
		local found_checkout = T.find_line(
			lines, "checkout:"
		)
		local found_reset = T.find_line(lines, "reset:")
		T.assert_true(
			found_commit ~= nil,
			"should render commit entry"
		)
		T.assert_true(
			found_checkout ~= nil,
			"should render checkout entry"
		)
		T.assert_true(
			found_reset ~= nil,
			"should render reset entry"
		)

		reflog_panel.close()
	end,

	["reflog panel shows short SHA"] = function()
		local reflog_panel = require("gitflow.panels.reflog")
		commands.dispatch({ "reflog" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("reflog")
		T.assert_true(bufnr ~= nil, "reflog buffer should exist")

		local lines = T.buf_lines(bufnr)
		local found_sha = T.find_line(lines, "abc1234")
		T.assert_true(
			found_sha ~= nil,
			"should render short SHA abc1234"
		)

		reflog_panel.close()
	end,

	["reflog panel shows HEAD selectors"] = function()
		local reflog_panel = require("gitflow.panels.reflog")
		commands.dispatch({ "reflog" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("reflog")
		T.assert_true(bufnr ~= nil, "reflog buffer should exist")

		local lines = T.buf_lines(bufnr)
		local found_head0 = T.find_line(lines, "HEAD@{0}")
		local found_head1 = T.find_line(lines, "HEAD@{1}")
		T.assert_true(
			found_head0 ~= nil,
			"should render HEAD@{0} selector"
		)
		T.assert_true(
			found_head1 ~= nil,
			"should render HEAD@{1} selector"
		)

		reflog_panel.close()
	end,

	-- ── Reflog list parser ──────────────────────────────────────────

	["parse handles single entry"] = function()
		local entries = git_reflog.parse(
			"abc1234567890\tHEAD@{0}\tcommit: Initial\n"
		)
		T.assert_equals(#entries, 1, "should parse one entry")
		T.assert_equals(
			entries[1].sha, "abc1234567890", "sha"
		)
		T.assert_equals(
			entries[1].short_sha, "abc1234", "short_sha"
		)
		T.assert_equals(
			entries[1].selector, "HEAD@{0}", "selector"
		)
		T.assert_equals(
			entries[1].action, "commit", "action"
		)
	end,

	["parse handles empty output"] = function()
		local entries = git_reflog.parse("")
		T.assert_equals(
			#entries, 0, "empty output => no entries"
		)
	end,

	["parse handles multi-line output"] = function()
		local output =
			"abc123\tHEAD@{0}\tcommit: First\n"
			.. "def456\tHEAD@{1}\tcheckout: move\n"
			.. "fed789\tHEAD@{2}\treset: back\n"
		local entries = git_reflog.parse(output)
		T.assert_equals(
			#entries, 3, "should parse three entries"
		)
	end,

	["list invokes git reflog show with format"] = function()
		with_temp_git_log(function(log_path)
			local done = false
			local call_err = nil
			git_reflog.list({}, function(err)
				call_err = err
				done = true
			end)

			T.wait_until(
				function()
					return done
				end,
				"git_reflog.list callback should run",
				3000
			)
			T.assert_true(
				call_err == nil,
				"git_reflog.list should succeed with stub"
			)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "reflog show") ~= nil,
				"list should invoke git reflog show"
			)
		end)
	end,

	-- ── Checkout dispatch ───────────────────────────────────────────

	["checkout invokes git checkout with sha"] = function()
		with_temp_git_log(function(log_path)
			local done = false
			local call_err = nil
			git_reflog.checkout(
				"abc1234567890", {}, function(err)
					call_err = err
					done = true
				end
			)

			T.wait_until(
				function()
					return done
				end,
				"checkout callback should run",
				3000
			)
			T.assert_true(
				call_err == nil,
				"checkout should succeed with stub"
			)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(
					lines, "checkout abc1234567890"
				) ~= nil,
				"should invoke git checkout <sha>"
			)
		end)
	end,

	-- ── Reset dispatch ──────────────────────────────────────────────

	["reset invokes git reset with mode and sha"] = function()
		with_temp_git_log(function(log_path)
			local done = false
			local call_err = nil
			git_reflog.reset(
				"abc1234567890", "soft", {},
				function(err)
					call_err = err
					done = true
				end
			)

			T.wait_until(
				function()
					return done
				end,
				"reset callback should run",
				3000
			)
			T.assert_true(
				call_err == nil,
				"reset should succeed with stub"
			)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(
					lines, "reset --soft abc1234567890"
				) ~= nil,
				"should invoke git reset --soft <sha>"
			)
		end)
	end,

	-- ── Keybinding / Plug wiring ────────────────────────────────────

	["Plug(GitflowReflog) mapping exists"] = function()
		local maps = vim.api.nvim_get_keymap("n")
		local found = false
		for _, map in ipairs(maps) do
			if map.lhs == "<Plug>(GitflowReflog)" then
				found = true
				break
			end
		end
		T.assert_true(
			found,
			"<Plug>(GitflowReflog) should be registered"
		)
	end,

	["gF keybinding wired to Plug(GitflowReflog)"] = function()
		local maps = vim.api.nvim_get_keymap("n")
		local found = false
		for _, map in ipairs(maps) do
			if map.lhs == cfg.keybindings.reflog then
				T.assert_contains(
					map.rhs or "",
					"GitflowReflog",
					"gF should map to GitflowReflog plug"
				)
				found = true
				break
			end
		end
		T.assert_true(
			found,
			("keybinding '%s' should be registered"):format(
				cfg.keybindings.reflog
			)
		)
	end,

	-- ── Tab completion ──────────────────────────────────────────────

	["tab completion includes reflog"] = function()
		local candidates = commands.complete(
			"", "Gitflow ", 9
		)
		T.assert_true(
			T.contains(candidates, "reflog"),
			"completion should include 'reflog'"
		)
	end,

	-- ── Palette entry ───────────────────────────────────────────────

	["palette entries include reflog"] = function()
		local entries = commands.palette_entries(cfg)
		local found = false
		for _, entry in ipairs(entries) do
			if entry.name == "reflog" then
				found = true
				T.assert_true(
					entry.description ~= nil
						and entry.description ~= "",
					"reflog palette entry needs description"
				)
				break
			end
		end
		T.assert_true(
			found, "palette entries should include reflog"
		)
	end,

	-- ── Highlight groups ────────────────────────────────────────────

	["GitflowReflogHash highlight group exists"] = function()
		T.assert_true(
			T.hl_exists("GitflowReflogHash"),
			"GitflowReflogHash highlight should be defined"
		)
	end,

	["GitflowReflogAction highlight group exists"] = function()
		T.assert_true(
			T.hl_exists("GitflowReflogAction"),
			"GitflowReflogAction highlight should be defined"
		)
	end,

	-- ── Panel close and cleanup ─────────────────────────────────────

	["reflog panel close resets state"] = function()
		local reflog_panel = require("gitflow.panels.reflog")
		commands.dispatch({ "reflog" }, cfg)
		T.drain_jobs(3000)

		T.assert_true(
			reflog_panel.is_open(),
			"panel should be open"
		)

		reflog_panel.close()

		T.assert_false(
			reflog_panel.is_open(),
			"panel should be closed after close()"
		)
		T.assert_true(
			reflog_panel.state.bufnr == nil,
			"bufnr should be nil after close"
		)
		T.assert_true(
			reflog_panel.state.winid == nil,
			"winid should be nil after close"
		)
	end,
})

print("E2E reflog panel tests passed")
