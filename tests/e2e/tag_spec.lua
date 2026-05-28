-- tests/e2e/tag_spec.lua — tag panel E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/tag_spec.lua
--
-- Verifies:
--   1. Tag subcommand registration and dispatch
--   2. Tag panel open/close, buffer creation, keymaps
--   3. Tag list parsing for annotated and lightweight tags
--   4. Tag create/delete/push command dispatch
--   5. Git stub invocation logging

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local git_tag = require("gitflow.git.tag")

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

T.run_suite("E2E: Tag Panel", {

	-- ── Subcommand registration ─────────────────────────────────────

	["tag subcommand is registered"] = function()
		T.assert_true(
			commands.subcommands["tag"] ~= nil,
			"tag subcommand should be registered"
		)
	end,

	["tag subcommand has description and run"] = function()
		local sub = commands.subcommands["tag"]
		T.assert_true(
			type(sub.description) == "string" and sub.description ~= "",
			"tag should have a non-empty description"
		)
		T.assert_true(
			type(sub.run) == "function",
			"tag should have a run function"
		)
	end,

	-- ── Tag list dispatch ───────────────────────────────────────────

	["tag list opens panel without crash"] = function()
		local ok, err = T.pcall_message(function()
			commands.dispatch({ "tag", "list" }, cfg)
		end)
		T.assert_true(ok, "tag list should not crash: " .. (err or ""))
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("tag")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"tag buffer should exist after :Gitflow tag list"
		)
		T.cleanup_panels()
	end,

	["tag default action is list"] = function()
		local result
		local ok, err = T.pcall_message(function()
			result = commands.dispatch({ "tag" }, cfg)
		end)
		T.assert_true(ok, "tag default should not crash: " .. (err or ""))
		T.assert_contains(
			result, "Tag panel opened",
			"default tag action should open panel"
		)
		T.drain_jobs(3000)
		T.cleanup_panels()
	end,

	-- ── Panel keymaps ───────────────────────────────────────────────

	["tag panel has expected keymaps"] = function()
		local tag_panel = require("gitflow.panels.tag")
		commands.dispatch({ "tag", "list" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("tag")
		T.assert_true(bufnr ~= nil, "tag buffer should exist")
		T.assert_keymaps(bufnr, { "q", "r", "c", "D", "X", "P" })

		tag_panel.close()
	end,

	-- ── Panel content ───────────────────────────────────────────────

	["tag panel renders tag entries from stub"] = function()
		local tag_panel = require("gitflow.panels.tag")
		commands.dispatch({ "tag", "list" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("tag")
		T.assert_true(bufnr ~= nil, "tag buffer should exist")

		local lines = T.buf_lines(bufnr)
		local found_v1 = T.find_line(lines, "v1.0.0")
		local found_v09 = T.find_line(lines, "v0.9.0")
		local found_v08 = T.find_line(lines, "v0.8.0")
		T.assert_true(
			found_v1 ~= nil, "should render v1.0.0 tag"
		)
		T.assert_true(
			found_v09 ~= nil, "should render v0.9.0 tag"
		)
		T.assert_true(
			found_v08 ~= nil, "should render v0.8.0 tag"
		)

		tag_panel.close()
	end,

	["tag panel shows annotated/lightweight indicators"] = function()
		local tag_panel = require("gitflow.panels.tag")
		commands.dispatch({ "tag", "list" }, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("tag")
		T.assert_true(bufnr ~= nil, "tag buffer should exist")

		local lines = T.buf_lines(bufnr)
		local annotated_count = T.count_lines_with(
			lines, "[annotated]"
		)
		local lightweight_count = T.count_lines_with(
			lines, "[lightweight]"
		)
		T.assert_true(
			annotated_count >= 2,
			("expected >= 2 annotated tags, got %d"):format(
				annotated_count
			)
		)
		T.assert_true(
			lightweight_count >= 1,
			("expected >= 1 lightweight tag, got %d"):format(
				lightweight_count
			)
		)

		tag_panel.close()
	end,

	-- ── Tag list parser ─────────────────────────────────────────────

	["parse handles annotated tag line"] = function()
		local entries = git_tag.parse(
			"v1.0.0\ttag\tabc1234\tRelease 1.0.0\n"
		)
		T.assert_equals(#entries, 1, "should parse one entry")
		T.assert_equals(entries[1].name, "v1.0.0", "name")
		T.assert_true(
			entries[1].is_annotated,
			"should be annotated"
		)
		T.assert_equals(
			entries[1].subject, "Release 1.0.0", "subject"
		)
		T.assert_equals(entries[1].sha, "abc1234", "sha")
	end,

	["parse handles lightweight tag line"] = function()
		local entries = git_tag.parse(
			"v0.9.0\tcommit\t\tBeta release\n"
		)
		T.assert_equals(#entries, 1, "should parse one entry")
		T.assert_equals(entries[1].name, "v0.9.0", "name")
		T.assert_false(
			entries[1].is_annotated,
			"should not be annotated"
		)
		T.assert_equals(entries[1].sha, "", "sha should be empty")
	end,

	["parse handles empty output"] = function()
		local entries = git_tag.parse("")
		T.assert_equals(#entries, 0, "empty output => no entries")
	end,

	["parse handles multi-line output"] = function()
		local output =
			"v1.0.0\ttag\tabc123\tRelease 1\n"
			.. "v0.9.0\tcommit\t\tBeta\n"
			.. "v0.8.0\ttag\tdef456\tAlpha\n"
		local entries = git_tag.parse(output)
		T.assert_equals(
			#entries, 3, "should parse three entries"
		)
	end,

	["list uses creatordate sorting"] = function()
		with_temp_git_log(function(log_path)
			local done = false
			local call_err = nil
			git_tag.list({}, function(err)
				call_err = err
				done = true
			end)

			T.wait_until(
				function()
					return done
				end,
				"git_tag.list callback should run",
				3000
			)
			T.assert_true(
				call_err == nil,
				"git_tag.list should succeed with stub"
			)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "for-each-ref --sort=-creatordate")
					~= nil,
				"list should request creatordate sorting"
			)
		end)
	end,

	-- ── Command dispatch ────────────────────────────────────────────

	["tag create without name returns usage"] = function()
		local result = commands.dispatch(
			{ "tag", "create" }, cfg
		)
		T.assert_contains(
			result, "Usage",
			"create without name should show usage"
		)
	end,

	["tag create dispatches git tag"] = function()
		with_temp_git_log(function(log_path)
			local result = commands.dispatch(
				{ "tag", "create", "v2.0.0" }, cfg
			)
			T.assert_contains(
				result, "Creating tag",
				"should return creating message"
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "tag v2.0.0") ~= nil,
				"should invoke git tag v2.0.0"
			)
		end)
	end,

	["tag create with message dispatches annotated tag"] = function()
		with_temp_git_log(function(log_path)
			commands.dispatch(
				{ "tag", "create", "v2.1.0", "My", "release" }, cfg
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "tag -a v2.1.0 -m My release")
					~= nil,
				"should invoke git tag -a with message"
			)
		end)
	end,

	["tag delete without name returns usage"] = function()
		local result = commands.dispatch(
			{ "tag", "delete" }, cfg
		)
		T.assert_contains(
			result, "Usage",
			"delete without name should show usage"
		)
	end,

	["tag delete dispatches git tag -d"] = function()
		with_temp_git_log(function(log_path)
			local result = commands.dispatch(
				{ "tag", "delete", "v1.0.0" }, cfg
			)
			T.assert_contains(
				result, "Deleting tag",
				"should return deleting message"
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(lines, "tag -d v1.0.0") ~= nil,
				"should invoke git tag -d v1.0.0"
			)
		end)
	end,

	["tag push without name returns usage"] = function()
		local result = commands.dispatch(
			{ "tag", "push" }, cfg
		)
		T.assert_contains(
			result, "Usage",
			"push without name should show usage"
		)
	end,

	["tag push dispatches git push origin refs/tags/<tag>"] = function()
		with_temp_git_log(function(log_path)
			local result = commands.dispatch(
				{ "tag", "push", "v1.0.0" }, cfg
			)
			T.assert_contains(
				result, "Pushing tag",
				"should return pushing message"
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(
					lines, "push origin refs/tags/v1.0.0"
				) ~= nil,
				"should invoke git push origin refs/tags/v1.0.0"
			)
		end)
	end,

	["tag delete_remote uses git push --delete refs/tags/<tag>"] = function()
		with_temp_git_log(function(log_path)
			local done = false
			local call_err = nil
			git_tag.delete_remote(
				"v1.0.0",
				nil,
				{},
				function(err)
					call_err = err
					done = true
				end
			)

			T.wait_until(
				function()
					return done
				end,
				"git_tag.delete_remote callback should run",
				3000
			)
			T.assert_true(
				call_err == nil,
				"delete_remote should succeed with stub"
			)

			local lines = T.read_file(log_path)
			T.assert_true(
				T.find_line(
					lines,
					"push origin --delete refs/tags/v1.0.0"
				) ~= nil,
				"should invoke git push --delete refs/tags/<tag>"
			)
		end)
	end,

	["tag unknown action returns error"] = function()
		local result = commands.dispatch(
			{ "tag", "bogus" }, cfg
		)
		T.assert_contains(
			result, "Unknown",
			"unknown tag action should say Unknown"
		)
	end,

	-- ── Keybinding / Plug wiring ────────────────────────────────────

	["Plug(GitflowTag) mapping exists"] = function()
		local maps = vim.api.nvim_get_keymap("n")
		local found = false
		for _, map in ipairs(maps) do
			if map.lhs == "<Plug>(GitflowTag)" then
				found = true
				break
			end
		end
		T.assert_true(
			found, "<Plug>(GitflowTag) should be registered"
		)
	end,

	["gT keybinding wired to Plug(GitflowTag)"] = function()
		local maps = vim.api.nvim_get_keymap("n")
		local found = false
		for _, map in ipairs(maps) do
			if map.lhs == cfg.keybindings.tag then
				T.assert_contains(
					map.rhs or "",
					"GitflowTag",
					"gT should map to GitflowTag plug"
				)
				found = true
				break
			end
		end
		T.assert_true(
			found,
			("keybinding '%s' should be registered"):format(
				cfg.keybindings.tag
			)
		)
	end,

	-- ── Tab completion ──────────────────────────────────────────────

	["tab completion includes tag"] = function()
		local candidates = commands.complete("", "Gitflow ", 9)
		T.assert_true(
			T.contains(candidates, "tag"),
			"completion should include 'tag'"
		)
	end,

	["tag subaction completion returns actions"] = function()
		local candidates = commands.complete(
			"", "Gitflow tag ", 13
		)
		T.assert_true(
			T.contains(candidates, "list"),
			"tag completion should include 'list'"
		)
		T.assert_true(
			T.contains(candidates, "create"),
			"tag completion should include 'create'"
		)
		T.assert_true(
			T.contains(candidates, "delete"),
			"tag completion should include 'delete'"
		)
		T.assert_true(
			T.contains(candidates, "push"),
			"tag completion should include 'push'"
		)
	end,

	-- ── Palette entry ───────────────────────────────────────────────

	["palette entries include tag"] = function()
		local entries = commands.palette_entries(cfg)
		local found = false
		for _, entry in ipairs(entries) do
			if entry.name == "tag" then
				found = true
				T.assert_true(
					entry.description ~= nil
						and entry.description ~= "",
					"tag palette entry should have description"
				)
				break
			end
		end
		T.assert_true(
			found, "palette entries should include tag"
		)
	end,

	-- ── Highlight group ─────────────────────────────────────────────

	["GitflowTagAnnotated highlight group exists"] = function()
		T.assert_true(
			T.hl_exists("GitflowTagAnnotated"),
			"GitflowTagAnnotated highlight should be defined"
		)
	end,

	-- ── Panel close and cleanup ─────────────────────────────────────

	["tag panel close resets state"] = function()
		local tag_panel = require("gitflow.panels.tag")
		commands.dispatch({ "tag", "list" }, cfg)
		T.drain_jobs(3000)

		T.assert_true(tag_panel.is_open(), "panel should be open")

		tag_panel.close()

		T.assert_false(
			tag_panel.is_open(),
			"panel should be closed after close()"
		)
		T.assert_true(
			tag_panel.state.bufnr == nil,
			"bufnr should be nil after close"
		)
		T.assert_true(
			tag_panel.state.winid == nil,
			"winid should be nil after close"
		)
	end,
})

print("E2E tag panel tests passed")
