-- tests/e2e/branch_graph_spec.lua — branch flowchart visualization tests
--
-- Usage:
--   nvim --headless -u tests/minimal_init.lua -l tests/e2e/branch_graph_spec.lua

local ui = require("gitflow.ui")
local branch_panel = require("gitflow.panels.branch")
local git_branch = require("gitflow.git.branch")
local cfg = _G.TestConfig

local function close_panel()
	pcall(function()
		branch_panel.close()
	end)
end

T.run_suite("Branch Graph Visualization", {

	-- ── Module loading ──────────────────────────────────────────────────

	["git/branch exports graph function"] = function()
		T.assert_true(
			type(git_branch.graph) == "function",
			"git_branch.graph should be a function"
		)
	end,

	["git/branch exports parse_graph function"] = function()
		T.assert_true(
			type(git_branch.parse_graph) == "function",
			"git_branch.parse_graph should be a function"
		)
	end,

	-- ── Graph parsing ───────────────────────────────────────────────────

	["parse_graph extracts hash from graph line"] = function()
		local output =
			"* abc1234 (HEAD -> main) Initial commit\n"
			.. "| * def5678 (feature/test) Add feature\n"
		local entries = git_branch.parse_graph(output, "main")

		T.assert_true(#entries >= 2, "should parse at least 2 entries")
		T.assert_equals(
			entries[1].hash, "abc1234",
			"first entry hash"
		)
		T.assert_equals(
			entries[2].hash, "def5678",
			"second entry hash"
		)
	end,

	["parse_graph extracts decorations"] = function()
		local output =
			"* abc1234 (HEAD -> main, origin/main) Initial commit\n"
		local entries = git_branch.parse_graph(output, "main")

		T.assert_true(#entries >= 1, "should parse at least 1 entry")
		T.assert_true(
			entries[1].decoration ~= nil
				and entries[1].decoration:find("main", 1, true) ~= nil,
			"decoration should contain branch name"
		)
	end,

	["parse_graph extracts subject"] = function()
		local output = "* abc1234 Initial commit\n"
		local entries = git_branch.parse_graph(output, nil)

		T.assert_true(#entries >= 1, "should parse entry")
		T.assert_equals(
			entries[1].subject, "Initial commit",
			"subject should be extracted"
		)
	end,

	["parse_graph handles graph-only lines"] = function()
		local output = "|/\n"
		local entries = git_branch.parse_graph(output, nil)

		T.assert_true(#entries == 1, "should parse graph-only line")
		T.assert_true(
			entries[1].hash == nil,
			"graph-only line should have no hash"
		)
		T.assert_true(
			entries[1].graph ~= "",
			"graph-only line should have graph content"
		)
	end,

	["parse_graph preserves raw line"] = function()
		local raw = "* abc1234 (HEAD -> main) Initial commit"
		local entries = git_branch.parse_graph(raw .. "\n", nil)

		T.assert_equals(
			entries[1].raw, raw,
			"raw should be the original line"
		)
	end,

	-- ── Graph data fetch via stub ───────────────────────────────────────

	["graph function returns parsed entries from git stub"] = function()
		local err, entries, current = T.wait_async(function(done)
			git_branch.graph({}, function(e, g, c)
				done(e, g, c)
			end)
		end)

		T.assert_true(err == nil, "graph should not error: " .. (err or ""))
		T.assert_true(
			type(entries) == "table" and #entries > 0,
			"graph should return entries"
		)
		T.assert_true(
			current ~= nil and current ~= "",
			"graph should return current branch"
		)
	end,

	["graph entries contain commit data from stub"] = function()
		local err, entries = T.wait_async(function(done)
			git_branch.graph({}, function(e, g)
				done(e, g)
			end)
		end)

		T.assert_true(err == nil, "graph should not error")
		-- Stub returns lines with hashes abc1234, def5678, fed9012
		local has_hash = false
		for _, entry in ipairs(entries) do
			if entry.hash then
				has_hash = true
				break
			end
		end
		T.assert_true(has_hash, "at least one entry should have a hash")
	end,

	-- ── Branch panel list view (baseline) ───────────────────────────────

	["branch panel opens in list view by default"] = function()
		close_panel()
		local ok, err = T.pcall_message(function()
			branch_panel.open(cfg)
		end)
		T.assert_true(
			ok,
			"opening branch panel should not error: " .. (err or "")
		)
		T.drain_jobs(3000)

		T.assert_equals(
			branch_panel.state.view_mode, "list",
			"default view mode should be list"
		)

		local bufnr = ui.buffer.get("branch")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"branch buffer should exist"
		)

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Local") ~= nil,
			"list view should show Local section"
		)

		close_panel()
	end,

	-- ── Toggle view ─────────────────────────────────────────────────────

	["G keymap toggles to graph view"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		T.assert_equals(
			branch_panel.state.view_mode, "list",
			"should start in list mode"
		)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		T.assert_equals(
			branch_panel.state.view_mode, "graph",
			"toggle should switch to graph mode"
		)

		local bufnr = ui.buffer.get("branch")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"buffer should still be valid after toggle"
		)

		close_panel()
	end,

	["G keymap toggles back to list view"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		-- Toggle to graph
		branch_panel.toggle_view()
		T.drain_jobs(3000)
		T.assert_equals(
			branch_panel.state.view_mode, "graph",
			"first toggle to graph"
		)

		-- Toggle back to list
		branch_panel.toggle_view()
		T.drain_jobs(3000)
		T.assert_equals(
			branch_panel.state.view_mode, "list",
			"second toggle back to list"
		)

		local bufnr = ui.buffer.get("branch")
		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Local") ~= nil,
			"list view should show Local section after toggle back"
		)

		close_panel()
	end,

	-- ── Graph view rendering ────────────────────────────────────────────

	["graph view renders commit graph lines"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"buffer should exist in graph view"
		)

		local lines = T.buf_lines(bufnr)
		-- Graph view should contain commit hashes and graph chars
		local has_graph_char = false
		for _, line in ipairs(lines) do
			if line:find("*", 1, true) and line:find("%x%x%x%x") then
				has_graph_char = true
				break
			end
		end
		T.assert_true(
			has_graph_char,
			"graph view should contain lines with * and commit hashes"
		)

		close_panel()
	end,

	["graph view shows Branch Graph title"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Branch Graph") ~= nil,
			"graph view should have Branch Graph title"
		)

		close_panel()
	end,

	["graph view shows branch decorations from stub"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		local lines = T.buf_lines(bufnr)

		-- Stub returns lines with (HEAD -> main), (feature/test)
		local has_main = false
		local has_feature = false
		for _, line in ipairs(lines) do
			if line:find("main", 1, true) then
				has_main = true
			end
			if line:find("feature/test", 1, true) then
				has_feature = true
			end
		end
		T.assert_true(has_main, "graph should show main branch")
		T.assert_true(has_feature, "graph should show feature/test branch")

		close_panel()
	end,

	-- ── Graph highlights ────────────────────────────────────────────────

	["graph highlight groups are defined"] = function()
		T.assert_true(
			T.hl_exists("GitflowGraphLine"),
			"GitflowGraphLine should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowGraphHash"),
			"GitflowGraphHash should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowGraphDecoration"),
			"GitflowGraphDecoration should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowGraphCurrent"),
			"GitflowGraphCurrent should be defined"
		)
		T.assert_true(
			T.hl_exists("GitflowGraphSubject"),
			"GitflowGraphSubject should be defined"
		)
	end,

	["graph view applies extmark highlights"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"buffer should exist"
		)

		local marks = T.get_extmarks(bufnr, "gitflow_branch_graph_hl")
		T.assert_true(
			#marks > 0,
			"graph view should have highlight extmarks"
		)

		close_panel()
	end,

	-- ── Keymaps ─────────────────────────────────────────────────────────

	["branch panel has G keymap for toggle"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		T.assert_keymaps(bufnr, { "G" })

		close_panel()
	end,

	["branch panel has all expected keymaps"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		T.assert_keymaps(bufnr, {
			"<CR>", "c", "d", "D", "r", "R", "f", "G", "q",
		})

		close_panel()
	end,

	-- ── Fetch integration ───────────────────────────────────────────────

	["fetch refreshes graph view"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		T.assert_equals(
			branch_panel.state.view_mode, "graph",
			"should be in graph mode"
		)

		-- Fetch should trigger refresh of graph
		branch_panel.fetch_remotes()
		T.drain_jobs(3000)

		-- After fetch, graph should still render
		local bufnr = ui.buffer.get("branch")
		local lines = T.buf_lines(bufnr)
		local has_graph = false
		for _, line in ipairs(lines) do
			if line:find("*", 1, true) then
				has_graph = true
				break
			end
		end
		T.assert_true(
			has_graph,
			"graph view should still render after fetch refresh"
		)

		close_panel()
	end,

	-- ── State reset on close ────────────────────────────────────────────

	["close resets view mode to list"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)
		T.assert_equals(
			branch_panel.state.view_mode, "graph",
			"should be in graph mode before close"
		)

		branch_panel.close()

		T.assert_equals(
			branch_panel.state.view_mode, "list",
			"close should reset view_mode to list"
		)
		T.assert_true(
			branch_panel.state.graph_lines == nil,
			"close should clear graph_lines"
		)
	end,

	-- ── Graph view scrolling ────────────────────────────────────────────

	["graph view buffer is scrollable"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("branch")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"buffer should exist"
		)

		-- Buffer should not be modifiable (read-only display)
		local modifiable = vim.api.nvim_get_option_value(
			"modifiable", { buf = bufnr }
		)
		T.assert_false(
			modifiable,
			"graph buffer should not be modifiable"
		)

		close_panel()
	end,

	-- ── Switch hint in graph mode ───────────────────────────────────────

	["switch_under_cursor gives hint in graph mode"] = function()
		close_panel()
		branch_panel.open(cfg)
		T.drain_jobs(3000)

		branch_panel.toggle_view()
		T.drain_jobs(3000)

		-- In graph mode, entry_under_cursor returns nil
		-- switch_under_cursor should notify about switching to list view
		local notified = false
		local orig_notify = vim.notify
		vim.notify = function(msg)
			if msg:find("list view", 1, true) then
				notified = true
			end
		end

		branch_panel.switch_under_cursor()

		vim.notify = orig_notify
		T.assert_true(
			notified,
			"switch in graph mode should hint to use list view"
		)

		close_panel()
	end,
})
