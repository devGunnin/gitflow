-- tests/e2e/branch_push_spec.lua — push upstream resolution & branch panel jump
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/branch_push_spec.lua
--
-- Verifies:
--   1. (#345) A branch whose upstream has a different name still pushes: the
--      fallback pushes the branch to a same-named branch and sets upstream
--   2. (#284) Remote resolution order: branch.<name>.pushRemote ->
--      remote.pushDefault -> branch.<name>.remote -> single remote / origin
--   3. An ambiguous or unknown push remote is refused, never guessed
--   4. (#368) The branch panel jumps the cursor to the checked-out branch

local T = _G.T
local cfg = _G.TestConfig

local commands = require("gitflow.commands")
local ui = require("gitflow.ui")
local branch_panel = require("gitflow.panels.branch")

---@param vars table<string, string>
---@param fn fun()
local function with_env(vars, fn)
	local previous = {}
	for name, value in pairs(vars) do
		previous[name] = vim.env[name]
		vim.env[name] = value
	end

	local ok, err = xpcall(fn, debug.traceback)

	for name, _ in pairs(vars) do
		vim.env[name] = previous[name]
	end

	if not ok then
		error(err, 0)
	end
end

---@param fn fun()
---@return table[] notifications  list of {message, level}
local function capture_notifications(fn)
	local notifications = {}
	local orig_notify = vim.notify
	vim.notify = function(msg, level, ...)
		notifications[#notifications + 1] = { message = msg, level = level }
		return orig_notify(msg, level, ...)
	end

	local ok, err = xpcall(fn, debug.traceback)
	vim.notify = orig_notify

	if not ok then
		error(err, 0)
	end
	return notifications
end

---@param notifications table[]
---@param needle string
---@param level integer|nil
---@return boolean
local function has_notification(notifications, needle, level)
	for _, n in ipairs(notifications) do
		if n.message and n.message:find(needle, 1, true) then
			if level == nil or n.level == level then
				return true
			end
		end
	end
	return false
end

--- Dispatch `:Gitflow push` against a stub git configured by `env`.
--- Returns the recorded git invocations and the notifications raised.
---@param env table<string, string>
---@return string[] git_log, table[] notifications
local function push_with_env(env)
	local log_path = vim.fn.tempname()
	local git_log, notifications

	with_env(vim.tbl_extend("force", { GITFLOW_GIT_LOG = log_path }, env), function()
		notifications = capture_notifications(function()
			commands.dispatch({ "push" }, cfg)
			T.drain_jobs(3000)
		end)
		git_log = T.read_file(log_path)
	end)

	pcall(vim.fn.delete, log_path)
	return git_log, notifications
end

--- Env for the #345 scenario: bare `git push` refused for a name-mismatched
--- upstream, so the fallback resolution runs.
---@param extra table<string, string>|nil
---@return table<string, string>
local function mismatch_env(extra)
	local env = { GITFLOW_GIT_UPSTREAM_MISMATCH = "1" }
	return vim.tbl_extend("force", env, extra or {})
end

--- Open the branch panel and wait for its first render.
---@return integer bufnr, integer winid
local function open_branch_panel()
	commands.dispatch({ "branch" }, cfg)
	T.drain_jobs(3000)

	local bufnr = ui.buffer.get("branch")
	local winid = branch_panel.state.winid
	T.assert_true(bufnr ~= nil, "branch buffer should exist")
	T.assert_true(winid ~= nil, "branch window should exist")
	return bufnr, winid
end

T.run_suite("E2E: Push Upstream Resolution & Branch Jump", {

	-- ── #345 upstream fallback ──────────────────────────────────────────

	["#345 mismatched upstream falls back to pushing the branch to itself"] = function()
		local git_log, notifications = push_with_env(mismatch_env())

		T.assert_true(
			T.find_line(git_log, "push -u origin main") ~= nil,
			"should push the branch to a same-named branch and set upstream"
		)
		T.assert_false(
			has_notification(notifications, "does not match", vim.log.levels.ERROR),
			"the mismatch should be recovered from, not reported as a dead end"
		)
	end,

	["#345 fallback is not triggered when a plain push succeeds"] = function()
		local git_log = push_with_env({})

		T.assert_true(
			T.find_line(git_log, "push") ~= nil,
			"a plain push should still run"
		)
		T.assert_true(
			T.find_line(git_log, "push -u") == nil,
			"a successful push must not be followed by an upstream push"
		)
	end,

	-- ── #284 remote resolution order ────────────────────────────────────

	["branch.<name>.pushRemote selects the push remote"] = function()
		local git_log = push_with_env(mismatch_env({
			GITFLOW_GIT_REMOTES = "origin fork",
			GITFLOW_GIT_CONFIG = "branch.main.pushRemote=fork",
		}))

		T.assert_true(
			T.find_line(git_log, "push -u fork main") ~= nil,
			"branch.<name>.pushRemote should win over the origin heuristic"
		)
	end,

	["remote.pushDefault selects the push remote when pushRemote is unset"] = function()
		local git_log = push_with_env(mismatch_env({
			GITFLOW_GIT_REMOTES = "origin fork",
			GITFLOW_GIT_CONFIG = "remote.pushDefault=fork",
		}))

		T.assert_true(
			T.find_line(git_log, "push -u fork main") ~= nil,
			"remote.pushDefault should win over the origin heuristic"
		)
	end,

	["branch.<name>.pushRemote takes precedence over remote.pushDefault"] = function()
		local git_log = push_with_env(mismatch_env({
			GITFLOW_GIT_REMOTES = "origin fork",
			GITFLOW_GIT_CONFIG = "branch.main.pushRemote=fork;remote.pushDefault=origin",
		}))

		T.assert_true(
			T.find_line(git_log, "push -u fork main") ~= nil,
			"pushRemote should be consulted before pushDefault"
		)
	end,

	["the branch tracking remote is used when no push-specific config is set"] = function()
		local git_log = push_with_env(mismatch_env({
			GITFLOW_GIT_REMOTES = "origin fork",
			GITFLOW_GIT_CONFIG = "branch.main.remote=fork",
		}))

		T.assert_true(
			T.find_line(git_log, "push -u fork main") ~= nil,
			"branch.<name>.remote should be preferred over the origin heuristic"
		)
	end,

	["a '.' tracking remote is not mistaken for a real remote"] = function()
		local git_log = push_with_env(mismatch_env({
			GITFLOW_GIT_REMOTES = "origin fork",
			GITFLOW_GIT_CONFIG = "branch.main.remote=.",
		}))

		T.assert_true(
			T.find_line(git_log, "push -u origin main") ~= nil,
			"a locally-tracking branch should fall through to the origin heuristic"
		)
	end,

	-- ── Never guess a remote ────────────────────────────────────────────

	["an ambiguous push remote is refused, not guessed"] = function()
		local git_log, notifications = push_with_env(mismatch_env({
			GITFLOW_GIT_REMOTES = "fork upstream",
		}))

		T.assert_true(
			has_notification(notifications, "Ambiguous push remote", vim.log.levels.ERROR),
			"several remotes and no origin should raise an actionable error"
		)
		T.assert_true(
			T.find_line(git_log, "push -u") == nil,
			"nothing may be pushed while the remote is ambiguous"
		)
	end,

	["a configured push remote that does not exist is refused"] = function()
		local git_log, notifications = push_with_env(mismatch_env({
			GITFLOW_GIT_REMOTES = "origin",
			GITFLOW_GIT_CONFIG = "branch.main.pushRemote=nope",
		}))

		T.assert_true(
			has_notification(notifications, "is not a known remote", vim.log.levels.ERROR),
			"an unknown configured remote should raise an actionable error"
		)
		T.assert_true(
			T.find_line(git_log, "push -u") == nil,
			"nothing may be pushed to an unknown remote"
		)
	end,

	-- ── #368 jump to current branch ─────────────────────────────────────

	["#368 branch panel binds the jump-to-current key"] = function()
		local bufnr = open_branch_panel()
		T.assert_keymaps(bufnr, { "." })
		T.cleanup_panels()
	end,

	["#368 jump moves the cursor to the checked-out branch"] = function()
		local _, winid = open_branch_panel()

		local current_line
		for line, entry in pairs(branch_panel.state.line_entries) do
			if entry.is_current then
				current_line = line
			end
		end
		T.assert_true(current_line ~= nil, "stub repo should render a current branch")

		vim.api.nvim_win_set_cursor(winid, { 1, 0 })
		branch_panel.jump_to_current()

		T.assert_equals(
			vim.api.nvim_win_get_cursor(winid)[1],
			current_line,
			"cursor should land on the current branch"
		)

		T.cleanup_panels()
	end,

	["#368 jump warns and holds the cursor when no current branch is listed"] = function()
		local _, winid = open_branch_panel()

		branch_panel.state.line_entries = {
			[2] = {
				name = "feature/test",
				ref = "refs/heads/feature/test",
				is_remote = false,
				short_name = "feature/test",
				is_current = false,
			},
		}
		vim.api.nvim_win_set_cursor(winid, { 2, 0 })

		local notifications = capture_notifications(function()
			branch_panel.jump_to_current()
		end)

		T.assert_true(
			has_notification(notifications, "No current branch in view", vim.log.levels.WARN),
			"a detached or filtered-out HEAD should warn"
		)
		T.assert_equals(
			vim.api.nvim_win_get_cursor(winid)[1],
			2,
			"cursor must not move when there is nothing to jump to"
		)

		T.cleanup_panels()
	end,

	["#368 jump points at the list view while the graph is shown"] = function()
		open_branch_panel()
		branch_panel.state.view_mode = "graph"

		local notifications = capture_notifications(function()
			branch_panel.jump_to_current()
		end)
		branch_panel.state.view_mode = "list"

		T.assert_true(
			has_notification(notifications, "list view", vim.log.levels.INFO),
			"graph view should point the user back to the list view"
		)

		T.cleanup_panels()
	end,
})

print("E2E push upstream resolution & branch jump tests passed")
