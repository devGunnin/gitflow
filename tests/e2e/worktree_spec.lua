-- tests/e2e/worktree_spec.lua — worktree panel E2E tests
--
-- Run:
--   nvim --headless -u tests/minimal_init.lua \
--     -l tests/e2e/worktree_spec.lua

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local worktree_panel = require("gitflow.panels.worktree")
local git_worktree = require("gitflow.git.worktree")
local highlights = require("gitflow.highlights")

T.run_suite("E2E: Worktree Panel", {

	-- ── Module loading ──────────────────────────────────────────────

	["git/worktree module exports expected functions"] =
		function()
			T.assert_true(
				type(git_worktree.list) == "function",
				"list should be a function"
			)
			T.assert_true(
				type(git_worktree.add) == "function",
				"add should be a function"
			)
			T.assert_true(
				type(git_worktree.remove) == "function",
				"remove should be a function"
			)
			T.assert_true(
				type(git_worktree.parse) == "function",
				"parse should be a function"
			)
		end,

	["panels/worktree module exports lifecycle"] =
		function()
			T.assert_true(
				type(worktree_panel.open) == "function",
				"open"
			)
			T.assert_true(
				type(worktree_panel.close) == "function",
				"close"
			)
			T.assert_true(
				type(worktree_panel.refresh) == "function",
				"refresh"
			)
			T.assert_true(
				type(worktree_panel.is_open) == "function",
				"is_open"
			)
		end,

	-- ── Subcommand registration ──────────────────────────────────

	["worktree subcommand is registered"] = function()
		T.assert_true(
			commands.subcommands.worktree ~= nil,
			"worktree subcommand should exist"
		)
		T.assert_true(
			type(commands.subcommands.worktree.run)
				== "function",
			"run should be a function"
		)
	end,

	["worktree appears in tab completion"] = function()
		local candidates = commands.complete("")
		local found = false
		for _, c in ipairs(candidates) do
			if c == "worktree" then
				found = true
				break
			end
		end
		T.assert_true(
			found,
			"worktree should appear in completions"
		)
	end,

	-- ── Keybinding wiring ─────────────────────────────────────────

	["GitflowWorktree plug mapping registered"] =
		function()
			local m = vim.fn.maparg(
				"<Plug>(GitflowWorktree)", "n",
				false, true
			)
			T.assert_true(
				type(m) == "table"
					and m.rhs == "<Cmd>Gitflow worktree<CR>",
				"plug mapping should point to"
					.. " :Gitflow worktree"
			)
		end,

	["global keybinding maps to plug"] = function()
		local key = cfg.keybindings.worktree
		T.assert_true(
			key ~= nil and key ~= "",
			"worktree keybinding should be set"
		)
		local m = vim.fn.maparg(key, "n", false, true)
		T.assert_true(
			type(m) == "table"
				and m.rhs == "<Plug>(GitflowWorktree)",
			"keybinding should map to plug"
		)
	end,

	-- ── Highlight groups ──────────────────────────────────────────

	["GitflowWorktreeActive highlight defined"] =
		function()
			T.assert_true(
				highlights.DEFAULT_GROUPS
					.GitflowWorktreeActive ~= nil,
				"GitflowWorktreeActive should exist"
			)
		end,

	["GitflowWorktreePath highlight defined"] =
		function()
			T.assert_true(
				highlights.DEFAULT_GROUPS
					.GitflowWorktreePath ~= nil,
				"GitflowWorktreePath should exist"
			)
		end,

	-- ── Parser ────────────────────────────────────────────────────

	["parse extracts worktree entries"] = function()
		local output = table.concat({
			"worktree /home/user/project",
			"HEAD abc1234567890" .. string.rep("a", 24),
			"branch refs/heads/main",
			"",
			"worktree /home/user/wt",
			"HEAD def5678901234" .. string.rep("b", 24),
			"branch refs/heads/feature",
			"",
		}, "\n")

		local entries = git_worktree.parse(output)
		T.assert_equals(
			#entries, 2, "should parse 2 entries"
		)
		T.assert_equals(
			entries[1].branch, "main",
			"branch refs/heads/ stripped"
		)
		T.assert_true(
			entries[1].is_main,
			"first is main worktree"
		)
		T.assert_true(
			not entries[2].is_main,
			"second is not main"
		)
	end,

	["parse handles bare worktree"] = function()
		local output = table.concat({
			"worktree /bare/repo.git",
			"HEAD abc" .. string.rep("0", 37),
			"bare",
			"",
		}, "\n")

		local entries = git_worktree.parse(output)
		T.assert_equals(#entries, 1, "one entry")
		T.assert_true(entries[1].is_bare, "is_bare")
	end,

	["parse handles empty output"] = function()
		local entries = git_worktree.parse("")
		T.assert_equals(
			#entries, 0, "no entries from empty"
		)
	end,

	-- ── Panel lifecycle ───────────────────────────────────────────

	["panel opens via dispatch"] = function()
		commands.dispatch({ "worktree" }, cfg)

		T.wait_until(function()
			return worktree_panel.state.bufnr ~= nil
		end, "panel should have bufnr", 3000)

		T.assert_true(
			worktree_panel.is_open(),
			"panel should be open"
		)
		T.cleanup_panels()
	end,

	["panel renders worktree entries"] = function()
		worktree_panel.open(cfg)
		T.drain_jobs(3000)

		T.wait_until(function()
			if not worktree_panel.state.bufnr then
				return false
			end
			local lines = vim.api.nvim_buf_get_lines(
				worktree_panel.state.bufnr,
				0, -1, false
			)
			return #lines > 1
				and not lines[1]:find(
					"Loading", 1, true
				)
		end, "panel should render content", 3000)

		local count = 0
		for _ in pairs(
			worktree_panel.state.line_entries
		) do
			count = count + 1
		end
		T.assert_true(
			count >= 1,
			"should have at least 1 line entry"
		)

		T.cleanup_panels()
	end,

	["panel keymaps are set"] = function()
		worktree_panel.open(cfg)

		T.wait_until(function()
			return worktree_panel.state.bufnr ~= nil
				and vim.api.nvim_buf_is_valid(
					worktree_panel.state.bufnr
				)
		end, "bufnr should exist", 2000)

		local keymaps = vim.api.nvim_buf_get_keymap(
			worktree_panel.state.bufnr, "n"
		)
		local found = {}
		for _, km in ipairs(keymaps) do
			found[km.lhs] = true
		end

		T.assert_true(
			found["<CR>"] ~= nil, "CR keymap"
		)
		T.assert_true(found["a"] ~= nil, "a keymap")
		T.assert_true(found["d"] ~= nil, "d keymap")
		T.assert_true(found["r"] ~= nil, "r keymap")
		T.assert_true(found["q"] ~= nil, "q keymap")

		T.cleanup_panels()
	end,

	["panel close resets state"] = function()
		worktree_panel.open(cfg)

		T.wait_until(function()
			return worktree_panel.state.bufnr ~= nil
		end, "bufnr should exist", 2000)

		worktree_panel.close()

		T.assert_true(
			worktree_panel.state.bufnr == nil,
			"bufnr should be nil"
		)
		T.assert_true(
			worktree_panel.state.winid == nil,
			"winid should be nil"
		)
		T.assert_true(
			not worktree_panel.is_open(),
			"is_open should be false"
		)
	end,

	["cleanup_panels includes worktree"] = function()
		worktree_panel.open(cfg)

		T.wait_until(function()
			return worktree_panel.state.bufnr ~= nil
		end, "bufnr should exist", 2000)

		T.cleanup_panels()

		T.assert_true(
			not worktree_panel.is_open(),
			"worktree should be closed by cleanup"
		)
	end,
})
