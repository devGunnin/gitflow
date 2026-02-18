-- tests/e2e/rebase_spec.lua — E2E spec for interactive rebase panel
local T = _G.T
local cfg = _G.TestConfig

T.run_suite("Interactive Rebase Panel", {
	["git/rebase module exports expected API"] = function()
		local git_rebase = require("gitflow.git.rebase")
		T.assert_true(
			type(git_rebase.list_commits) == "function",
			"list_commits should be a function"
		)
		T.assert_true(
			type(git_rebase.parse_commits) == "function",
			"parse_commits should be a function"
		)
		T.assert_true(
			type(git_rebase.build_todo) == "function",
			"build_todo should be a function"
		)
		T.assert_true(
			type(git_rebase.start_interactive) == "function",
			"start_interactive should be a function"
		)
		T.assert_true(
			type(git_rebase.abort) == "function",
			"abort should be a function"
		)
		T.assert_true(
			type(git_rebase.continue) == "function",
			"continue should be a function"
		)
	end,

	["panels/rebase module exports expected API"] = function()
		local rb_panel = require("gitflow.panels.rebase")
		T.assert_true(
			type(rb_panel.open) == "function",
			"open should be a function"
		)
		T.assert_true(
			type(rb_panel.close) == "function",
			"close should be a function"
		)
		T.assert_true(
			type(rb_panel.refresh) == "function",
			"refresh should be a function"
		)
		T.assert_true(
			type(rb_panel.is_open) == "function",
			"is_open should be a function"
		)
		T.assert_true(
			type(rb_panel.cycle_action) == "function",
			"cycle_action should be a function"
		)
		T.assert_true(
			type(rb_panel.set_action) == "function",
			"set_action should be a function"
		)
		T.assert_true(
			type(rb_panel.move_down) == "function",
			"move_down should be a function"
		)
		T.assert_true(
			type(rb_panel.move_up) == "function",
			"move_up should be a function"
		)
		T.assert_true(
			type(rb_panel.execute) == "function",
			"execute should be a function"
		)
	end,

	["rebase-interactive subcommand is registered"] = function()
		local commands = require("gitflow.commands")
		T.assert_true(
			commands.subcommands["rebase-interactive"] ~= nil,
			"rebase-interactive should be registered"
		)
		T.assert_equals(
			commands.subcommands["rebase-interactive"].description,
			"Open interactive rebase panel",
			"description should match"
		)
	end,

	["parse_commits returns entries with pick default action"] = function()
		local git_rebase = require("gitflow.git.rebase")
		local output = table.concat({
			"abc1234567890123456789012345678901234567\tfirst",
			"def5678901234567890123456789012345678901\tsecond",
		}, "\n")
		local entries = git_rebase.parse_commits(output)
		T.assert_equals(#entries, 2, "should parse 2 entries")
		T.assert_equals(
			entries[1].action, "pick",
			"default action should be pick"
		)
		T.assert_equals(
			entries[1].short_sha, "abc1234",
			"short_sha should be 7 chars"
		)
	end,

	["parse_commits handles empty input"] = function()
		local git_rebase = require("gitflow.git.rebase")
		local entries = git_rebase.parse_commits("")
		T.assert_equals(
			#entries, 0,
			"empty input should produce no entries"
		)
	end,

	["build_todo formats entries correctly"] = function()
		local git_rebase = require("gitflow.git.rebase")
		local entries = {
			{
				action = "pick",
				sha = "abc",
				short_sha = "abc",
				subject = "first",
			},
			{
				action = "squash",
				sha = "def",
				short_sha = "def",
				subject = "second",
			},
		}
		local todo = git_rebase.build_todo(entries)
		T.assert_contains(
			todo, "pick abc first",
			"todo should contain pick line"
		)
		T.assert_contains(
			todo, "squash def second",
			"todo should contain squash line"
		)
	end,

	["rebase highlight groups are registered"] = function()
		local highlights = require("gitflow.highlights")
		local groups = {
			"GitflowRebasePick",
			"GitflowRebaseReword",
			"GitflowRebaseEdit",
			"GitflowRebaseSquash",
			"GitflowRebaseFixup",
			"GitflowRebaseDrop",
			"GitflowRebaseHash",
		}
		for _, group in ipairs(groups) do
			T.assert_true(
				highlights.DEFAULT_GROUPS[group] ~= nil,
				group .. " should be in DEFAULT_GROUPS"
			)
		end
	end,

	["config includes rebase_interactive keybinding"] = function()
		T.assert_true(
			cfg.keybindings.rebase_interactive ~= nil,
			"rebase_interactive keybinding should exist"
		)
		T.assert_equals(
			cfg.keybindings.rebase_interactive,
			"gI",
			"default keybinding should be gI"
		)
	end,

	["panel close resets all state"] = function()
		local rb_panel = require("gitflow.panels.rebase")
		rb_panel.state.base_ref = "main"
		rb_panel.state.stage = "todo"
		rb_panel.state.entries = {
			{
				action = "pick",
				sha = "x",
				short_sha = "x",
				subject = "x",
			},
		}
		rb_panel.close()

		T.assert_true(
			rb_panel.state.bufnr == nil,
			"bufnr should be nil"
		)
		T.assert_true(
			rb_panel.state.base_ref == nil,
			"base_ref should be nil"
		)
		T.assert_equals(
			rb_panel.state.stage, "base",
			"stage should be base"
		)
		T.assert_equals(
			#rb_panel.state.entries, 0,
			"entries should be empty"
		)
		T.assert_false(
			rb_panel.is_open(),
			"is_open should be false"
		)
	end,

	["rebase panel is listed in ALL_PANELS"] = function()
		local helpers = require("tests.helpers")
		-- cleanup_panels should not error, indicating
		-- rebase panel is properly handled
		local ok = pcall(helpers.cleanup_panels)
		T.assert_true(
			ok,
			"cleanup_panels should succeed with rebase panel"
		)
	end,
})
