-- tests/e2e/statusline_spec.lua — statusline refresh E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/statusline_spec.lua
--
-- Verifies:
--   1. The repository root is resolved once across repeated refreshes
--   2. Mutable state (branch, divergence, dirtiness) is re-read every refresh
--   3. Invalidating the root cache forces a re-resolve

local T = _G.T

local statusline = require("gitflow.statusline")

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

---@param lines string[]
---@param needle string
---@return integer
local function count_invocations(lines, needle)
	local count = 0
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			count = count + 1
		end
	end
	return count
end

--- Run `count` sequential refreshes, awaiting each so they are not deduplicated
--- into a single in-flight update.
---@param count integer
local function refresh_times(count)
	for _ = 1, count do
		T.wait_async(function(done)
			statusline.refresh(function(_value)
				done()
			end)
		end)
	end
end

--- Plugin setup leaves a refresh in flight, and a leftover in-flight refresh
--- satisfies the next waiter without spawning git — which would undercount.
local function reset_statusline()
	T.drain_jobs(3000)
	statusline.invalidate_root_cache()
	statusline.state.updating = false
	statusline.state.pending = false
	statusline.state.waiters = {}
end

T.run_suite("E2E: Statusline", {

	-- ── Repo-root memoization ───────────────────────────────────────────

	["repeated refreshes resolve the repo root once"] = function()
		reset_statusline()

		local lines = {}
		with_temp_git_log(function(log_path)
			refresh_times(3)
			lines = T.read_file(log_path)
		end)

		T.assert_equals(
			count_invocations(lines, "rev-parse --show-toplevel"),
			1,
			"repo root should be resolved once across three refreshes"
		)
	end,

	["refresh re-reads branch and dirty state every time"] = function()
		reset_statusline()

		local lines = {}
		with_temp_git_log(function(log_path)
			refresh_times(3)
			lines = T.read_file(log_path)
		end)

		-- Caching these would pin a stale branch in the statusline forever.
		T.assert_equals(
			count_invocations(lines, "rev-parse --abbrev-ref HEAD"),
			3,
			"branch must be re-read on every refresh"
		)
		T.assert_equals(
			count_invocations(lines, "rev-list --left-right"),
			3,
			"divergence must be re-read on every refresh"
		)
		T.assert_equals(
			count_invocations(lines, "status --porcelain"),
			3,
			"working-tree dirtiness must be re-read on every refresh"
		)
	end,

	["invalidating the root cache forces a re-resolve"] = function()
		reset_statusline()

		local lines = {}
		with_temp_git_log(function(log_path)
			refresh_times(1)
			statusline.invalidate_root_cache()
			refresh_times(1)
			lines = T.read_file(log_path)
		end)

		T.assert_equals(
			count_invocations(lines, "rev-parse --show-toplevel"),
			2,
			"an invalidated root cache should be re-resolved"
		)
	end,
})

print("E2E statusline tests passed")
