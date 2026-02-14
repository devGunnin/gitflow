-- tests/e2e_smoke_test.lua — validates the E2E test infrastructure
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e_smoke_test.lua
--
-- Verifies:
--   1. minimal_init.lua loads gitflow without error
--   2. All helpers functions are available
--   3. Git stub is executable and returns expected output
--   4. Gh stub is executable and returns expected output
--   5. Fixture JSON files load correctly
--   6. Helpers async wait, buffer read, and window inspection work

local T = _G.T
local cfg = _G.TestConfig

T.run_suite("E2E Infrastructure", {

	["minimal_init loads gitflow"] = function()
		T.assert_true(cfg ~= nil, "TestConfig should be set by minimal_init")
		T.assert_equals(cfg.ui.split.size, 40, "split size from test config")
		T.assert_equals(
			cfg.ui.default_layout,
			"split",
			"default layout from test config"
		)
	end,

	["gitflow module is initialized"] = function()
		local gitflow = require("gitflow")
		T.assert_true(
			gitflow.initialized,
			"gitflow.initialized should be true after setup"
		)
	end,

	[":Gitflow command is registered"] = function()
		local cmds = vim.api.nvim_get_commands({})
		T.assert_true(
			cmds.Gitflow ~= nil,
			":Gitflow command should be registered"
		)
	end,

	["helpers module loads all functions"] = function()
		local required_fns = {
			"assert_true",
			"assert_equals",
			"assert_deep_equals",
			"assert_contains",
			"assert_false",
			"feedkeys",
			"exec_command",
			"buf_lines",
			"buf_find_line",
			"list_windows",
			"is_float",
			"find_floats",
			"assert_buf_name",
			"window_layout",
			"get_extmarks",
			"hl_exists",
			"wait_until",
			"wait_async",
			"drain_jobs",
			"pcall_message",
			"simulate_input",
			"contains",
			"find_line",
			"count_lines_with",
			"assert_keymaps",
			"write_file",
			"read_file",
			"run_suite",
		}
		for _, fn_name in ipairs(required_fns) do
			T.assert_true(
				type(T[fn_name]) == "function",
				("helpers.%s should be a function"):format(fn_name)
			)
		end
	end,

	["git stub is executable and returns status"] = function()
		local result = vim.system(
			{ "git", "status", "--porcelain=v1" },
			{ text = true }
		):wait()
		T.assert_equals(result.code, 0, "git stub should exit 0 for status")
		T.assert_contains(
			result.stdout,
			"tracked.txt",
			"git stub status should mention tracked.txt"
		)
		T.assert_contains(
			result.stdout,
			"new.txt",
			"git stub status should mention new.txt"
		)
	end,

	["git stub returns porcelain v2 status format"] = function()
		local result = vim.system(
			{ "git", "status", "--porcelain=v2" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"git stub should exit 0 for porcelain v2 status"
		)
		T.assert_contains(
			result.stdout,
			"# branch.head main",
			"porcelain v2 output should include branch head metadata"
		)
		T.assert_contains(
			result.stdout,
			"1 .M N... 100644 100644 100644 abc1234 abc1234 tracked.txt",
			"porcelain v2 output should include a v2 tracked record"
		)
		T.assert_contains(
			result.stdout,
			"? new.txt",
			"porcelain v2 output should include untracked file record"
		)
		T.assert_false(
			result.stdout:find(" M tracked.txt", 1, true) ~= nil,
			"porcelain v2 output should not include v1 tracked lines"
		)
	end,

	["git stub returns diff output"] = function()
		local result =
			vim.system({ "git", "diff" }, { text = true }):wait()
		T.assert_equals(result.code, 0, "git stub should exit 0 for diff")
		T.assert_contains(
			result.stdout,
			"diff --git",
			"git stub diff should contain diff header"
		)
		T.assert_contains(
			result.stdout,
			"+gamma",
			"git stub diff should contain added line"
		)
	end,

	["git stub returns log output"] = function()
		local result =
			vim.system({ "git", "log" }, { text = true }):wait()
		T.assert_equals(result.code, 0, "git stub should exit 0 for log")
		T.assert_contains(
			result.stdout,
			"Initial commit",
			"git stub log should contain commit message"
		)
	end,

	["git stub returns branch output"] = function()
		local result = vim.system(
			{ "git", "branch", "-a", "--format=%(refname:short)" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"git stub should exit 0 for branch"
		)
		T.assert_contains(
			result.stdout,
			"main",
			"git stub branch should list main"
		)
		T.assert_contains(
			result.stdout,
			"feature/test",
			"git stub branch should list feature/test"
		)
	end,

	["git stub returns rev-parse --show-toplevel"] = function()
		local result = vim.system(
			{ "git", "rev-parse", "--show-toplevel" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"git stub should exit 0 for rev-parse"
		)
		T.assert_true(
			vim.trim(result.stdout) ~= "",
			"rev-parse should return a path"
		)
	end,

	["git stub returns stash list"] = function()
		local result = vim.system(
			{ "git", "stash", "list" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"git stub should exit 0 for stash list"
		)
		T.assert_contains(
			result.stdout,
			"stash@{0}",
			"git stub stash should list entries"
		)
	end,

	["git stub fails for unknown commands"] = function()
		local result = vim.system(
			{ "git", "nonexistent" },
			{ text = true }
		):wait()
		T.assert_true(
			result.code ~= 0,
			"git stub should exit non-zero for unknown commands"
		)
	end,

	["git stub simulates failure with GITFLOW_GIT_FAIL"] = function()
		local result = vim.system(
			{ "git", "push" },
			{ text = true, env = { GITFLOW_GIT_FAIL = "push" } }
		):wait()
		T.assert_true(
			result.code ~= 0,
			"git stub should fail when GITFLOW_GIT_FAIL=push"
		)
	end,

	["gh stub returns version"] = function()
		local result = vim.system(
			{ "gh", "--version" },
			{ text = true }
		):wait()
		T.assert_equals(result.code, 0, "gh stub should exit 0 for version")
		T.assert_contains(
			result.stdout,
			"gh version",
			"gh stub should return version string"
		)
	end,

	["gh stub returns auth status"] = function()
		local result = vim.system(
			{ "gh", "auth", "status" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"gh stub should exit 0 for auth status"
		)
		T.assert_contains(
			result.stdout,
			"Logged in",
			"gh stub should confirm auth"
		)
	end,

	["gh stub returns pr list from fixture"] = function()
		local result = vim.system(
			{ "gh", "pr", "list" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"gh stub should exit 0 for pr list"
		)
		local ok, data = pcall(vim.json.decode, result.stdout)
		T.assert_true(ok, "gh pr list output should be valid JSON")
		T.assert_true(#data >= 2, "pr list should contain at least 2 PRs")
		T.assert_equals(
			data[1].number,
			42,
			"first PR number should be 42"
		)
	end,

	["gh stub returns issue list from fixture"] = function()
		local result = vim.system(
			{ "gh", "issue", "list" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"gh stub should exit 0 for issue list"
		)
		local ok, data = pcall(vim.json.decode, result.stdout)
		T.assert_true(ok, "gh issue list output should be valid JSON")
		T.assert_true(
			#data >= 3,
			"issue list should contain at least 3 issues"
		)
	end,

	["gh stub returns label list from fixture"] = function()
		local result = vim.system(
			{ "gh", "label", "list" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"gh stub should exit 0 for label list"
		)
		local ok, data = pcall(vim.json.decode, result.stdout)
		T.assert_true(ok, "gh label list output should be valid JSON")
		T.assert_true(
			#data >= 5,
			"label list should contain at least 5 labels"
		)
	end,

	["gh stub returns pr view from fixture"] = function()
		local result = vim.system(
			{ "gh", "pr", "view", "42" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"gh stub should exit 0 for pr view"
		)
		local ok, data = pcall(vim.json.decode, result.stdout)
		T.assert_true(ok, "gh pr view output should be valid JSON")
		T.assert_equals(data.number, 42, "pr view number should be 42")
		T.assert_equals(
			data.title,
			"Add dark mode support",
			"pr view title"
		)
	end,

	["gh stub returns issue view from fixture"] = function()
		local result = vim.system(
			{ "gh", "issue", "view", "1" },
			{ text = true }
		):wait()
		T.assert_equals(
			result.code,
			0,
			"gh stub should exit 0 for issue view"
		)
		local ok, data = pcall(vim.json.decode, result.stdout)
		T.assert_true(ok, "gh issue view output should be valid JSON")
		T.assert_equals(data.number, 1, "issue view number should be 1")
	end,

	["gh stub fails for unknown commands"] = function()
		local result = vim.system(
			{ "gh", "nonexistent" },
			{ text = true }
		):wait()
		T.assert_true(
			result.code ~= 0,
			"gh stub should exit non-zero for unknown commands"
		)
	end,

	["helpers async wait works"] = function()
		local value = T.wait_async(function(done)
			vim.defer_fn(function()
				done("hello")
			end, 50)
		end, 2000)
		T.assert_equals(value, "hello", "wait_async should return value")
	end,

	["helpers buffer read works"] = function()
		local buf = require("gitflow.ui.buffer")
		local bufnr = buf.create("e2e-test-buf", {
			lines = { "line1", "line2", "line3" },
		})
		T.assert_true(
			vim.api.nvim_buf_is_valid(bufnr),
			"test buffer should be valid"
		)
		local lines = T.buf_lines(bufnr)
		T.assert_equals(#lines, 3, "buffer should have 3 lines")
		T.assert_equals(lines[1], "line1", "first line content")
		local found = T.buf_find_line(bufnr, "line2")
		T.assert_equals(found, 2, "buf_find_line should find line2 at 2")
		buf.teardown("e2e-test-buf")
	end,

	["helpers window inspection works"] = function()
		local layout = T.window_layout()
		T.assert_true(
			layout.total >= 1,
			"should have at least one window"
		)
		T.assert_true(
			layout.splits >= 1,
			"should have at least one split"
		)

		-- Open a float and verify detection
		local test_buf = vim.api.nvim_create_buf(false, true)
		local float_win = vim.api.nvim_open_win(test_buf, false, {
			relative = "editor",
			width = 20,
			height = 5,
			row = 1,
			col = 1,
		})
		T.assert_true(
			T.is_float(float_win),
			"opened window should be detected as float"
		)
		local floats = T.find_floats()
		T.assert_true(
			#floats >= 1,
			"find_floats should find at least 1 float"
		)
		vim.api.nvim_win_close(float_win, true)
		vim.api.nvim_buf_delete(test_buf, { force = true })
	end,

	["helpers wait_until works"] = function()
		local flag = false
		vim.defer_fn(function()
			flag = true
		end, 50)
		T.wait_until(function()
			return flag
		end, "flag should become true", 2000)
		T.assert_true(flag, "flag should be true after wait")
	end,

	["helpers drain_jobs waits for async processes"] = function()
		local uv = vim.uv or vim.loop
		local done = false
		local started_at = uv.hrtime()
		vim.system(
			{ "sh", "-c", "sleep 0.15; echo drained" },
			{ text = true },
			function()
				done = true
			end
		)

		T.drain_jobs(2000)

		local elapsed_ms = (uv.hrtime() - started_at) / 1e6
		T.assert_true(done, "drain_jobs should wait for vim.system callback")
		T.assert_true(
			elapsed_ms >= 100,
			("drain_jobs returned too early (elapsed=%.2fms)"):format(elapsed_ms)
		)
	end,

	["helpers pcall_message captures errors"] = function()
		local ok, msg = T.pcall_message(function()
			error("test error", 2)
		end)
		T.assert_false(ok, "pcall_message should return false on error")
		T.assert_contains(
			msg,
			"test error",
			"pcall_message should capture error text"
		)
	end,

	["fixture JSON files are valid"] = function()
		local script_path = debug.getinfo(1, "S").source:sub(2)
		local tests_dir = vim.fn.fnamemodify(script_path, ":p:h")
		local fixture_dir = tests_dir .. "/fixtures/gh"
		local fixtures = {
			"pr_view.json",
			"pr_create.json",
			"pr_list.json",
			"pr_review.json",
			"issue_list.json",
			"issue_view.json",
			"label_list.json",
		}
		for _, name in ipairs(fixtures) do
			local path = fixture_dir .. "/" .. name
			T.assert_true(
				vim.fn.filereadable(path) == 1,
				("fixture %s should exist"):format(name)
			)
			local content = table.concat(vim.fn.readfile(path), "\n")
			local trimmed = vim.trim(content)
			-- pr_create.json is a URL, not JSON — skip decode
			if name ~= "pr_create.json" then
				local ok, _ = pcall(vim.json.decode, trimmed)
				T.assert_true(
					ok,
					("fixture %s should be valid JSON"):format(name)
				)
			end
		end
	end,

	["git stub logs invocations when GITFLOW_GIT_LOG is set"] = function()
		local log_path = vim.fn.tempname()
		local result = vim.system(
			{ "git", "status" },
			{ text = true, env = { GITFLOW_GIT_LOG = log_path } }
		):wait()
		T.assert_equals(result.code, 0, "git stub should succeed")
		local lines = T.read_file(log_path)
		T.assert_true(#lines >= 1, "git log should have at least 1 line")
		T.assert_true(
			T.find_line(lines, "status") ~= nil,
			"git log should record status invocation"
		)
		vim.fn.delete(log_path)
	end,

	["gh stub logs invocations when GITFLOW_GH_LOG is set"] = function()
		local log_path = vim.fn.tempname()
		local result = vim.system(
			{ "gh", "pr", "list" },
			{ text = true, env = { GITFLOW_GH_LOG = log_path } }
		):wait()
		T.assert_equals(result.code, 0, "gh stub should succeed")
		local lines = T.read_file(log_path)
		T.assert_true(#lines >= 1, "gh log should have at least 1 line")
		T.assert_true(
			T.find_line(lines, "pr") ~= nil,
			"gh log should record pr invocation"
		)
		vim.fn.delete(log_path)
	end,
})

print("E2E infrastructure smoke tests passed")
