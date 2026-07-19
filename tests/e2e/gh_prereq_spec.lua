-- tests/e2e/gh_prereq_spec.lua — gh prerequisite checking E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/gh_prereq_spec.lua
--
-- Verifies:
--   1. setup() spawns no gh subprocess (startup is off the network)
--   2. setup() stays fast even when gh hangs (offline startup)
--   3. An unauthenticated user is still told, on first GitHub command
--   4. Failure classification keys off real gh output, not guesses
--   5. A 404 never reads as a network error
--   6. Raw gh error text is never replaced by a friendly message
--   7. An auth-shaped failure invalidates the cached verdict

local T = _G.T

local gitflow = require("gitflow")
local gh = require("gitflow.gh")

---@param fn fun(log_path: string)
local function with_gh_log(fn)
	local log_path = vim.fn.tempname()
	local previous = vim.env.GITFLOW_GH_LOG
	vim.env.GITFLOW_GH_LOG = log_path

	local ok, err = xpcall(function()
		fn(log_path)
	end, debug.traceback)

	vim.env.GITFLOW_GH_LOG = previous
	pcall(vim.fn.delete, log_path)

	if not ok then
		error(err, 0)
	end
end

--- Run `fn` with a throwaway `gh` earlier on PATH than the fixture stub.
--- Lines are separate list entries: vim.fn.writefile turns an embedded \n
--- into a NUL byte, which yields an unexecutable script.
---@param body string[]  shell script lines for the fake gh
---@param fn fun()
local function with_fake_gh(body, fn)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local gh_path = dir .. "/gh"
	local script = { "#!/bin/sh" }
	for _, line in ipairs(body) do
		script[#script + 1] = line
	end
	vim.fn.writefile(script, gh_path)
	vim.fn.setfperm(gh_path, "rwxr-xr-x")

	local previous_path = vim.env.PATH
	vim.env.PATH = dir .. ":" .. previous_path
	T.assert_equals(
		vim.fn.exepath("gh"),
		gh_path,
		"fake gh should win the PATH lookup"
	)

	local ok, err = xpcall(fn, debug.traceback)

	vim.env.PATH = previous_path
	pcall(vim.fn.delete, dir, "rf")

	if not ok then
		error(err, 0)
	end
end

---@param fn fun()
local function with_saved_gh_state(fn)
	local saved = vim.deepcopy(gh.state)
	local ok, err = xpcall(fn, debug.traceback)
	gh.state = saved
	if not ok then
		error(err, 0)
	end
end

---@param fn fun()
---@return table[]  captured { message, level }
local function capture_notifications(fn)
	local captured = {}
	local original = vim.notify
	vim.notify = function(message, level, _)
		captured[#captured + 1] = {
			message = tostring(message),
			level = level,
		}
	end
	local ok, err = xpcall(fn, debug.traceback)
	vim.notify = original
	if not ok then
		error(err, 0)
	end
	return captured
end

local SETUP_OPTS = {
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 40 },
	},
}

-- Real gh 2.95.0 output, captured from live invocations. These strings are
-- the contract M.classify_failure keys off.
local REAL_GH_OUTPUT = {
	no_login = "You are not logged into any GitHub hosts. To log in, run: gh auth login",
	bad_token = "X Failed to log in to github.com using token (GH_TOKEN)\n"
		.. "- The token in GH_TOKEN is invalid.",
	unauthorized = '{"message":"Bad credentials","status":"401"}'
		.. "gh: Bad credentials (HTTP 401)",
	offline = "error connecting to nonexistent.invalid\n"
		.. "check your internet connection or https://githubstatus.com",
	forbidden = "gh: You must have repository read permissions. (HTTP 403)",
	missing_repo = "gh: Not Found (HTTP 404)",
}

T.run_suite("gh prerequisites", {
	-- ── 1. Startup does not touch gh ──────────────────────────────────

	["setup spawns no gh subprocess"] = function()
		with_gh_log(function(log_path)
			gitflow.setup(SETUP_OPTS)
			T.drain_jobs()

			local lines = T.read_file(log_path)
			T.assert_equals(
				#lines,
				0,
				"setup must not invoke gh (startup would hit the network)"
			)
		end)
	end,

	-- ── 2. Startup stays fast when gh hangs ───────────────────────────

	["setup does not block when gh is slow"] = function()
		with_fake_gh({ "sleep 5", "echo 'slow gh' >&2", "exit 1" }, function()
			local started = vim.uv.hrtime()
			gitflow.setup(SETUP_OPTS)
			local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

			T.assert_true(
				elapsed_ms < 1000,
				("setup must not wait on gh (took %.0fms)"):format(elapsed_ms)
			)
		end)
	end,

	-- ── 3. Unauthenticated users are still told ───────────────────────

	["first GitHub command reports an unauthenticated gh"] = function()
		with_saved_gh_state(function()
			local body = {
				'if [ "$1" = "--version" ]; then',
				'  echo "gh version 2.95.0"',
				"  exit 0",
				"fi",
				"echo 'You are not logged into any GitHub hosts."
					.. " To log in, run: gh auth login' >&2",
				"exit 1",
			}
			with_fake_gh(body, function()
				gh.state = {
					checked = false,
					available = false,
					authenticated = false,
					message = nil,
				}

				local ok, message
				local notifications = capture_notifications(function()
					ok, message = gh.ensure_prerequisites()
				end)

				T.assert_false(ok, "unauthenticated gh must not pass the gate")
				T.assert_contains(
					message,
					"gh auth login",
					"message must name the recovery command"
				)
				T.assert_true(
					#notifications > 0,
					"the user must be notified, not failed silently"
				)
				T.assert_contains(
					notifications[1].message,
					"gh auth login",
					"notification must name the recovery command"
				)
				T.assert_equals(
					notifications[1].level,
					vim.log.levels.ERROR,
					"an unusable gh is an error, not a hint"
				)
			end)
		end)
	end,

	-- ── 4/5. Classification keys off real gh output ───────────────────

	["classify_failure matches real gh output"] = function()
		local cases = {
			{ REAL_GH_OUTPUT.no_login, "auth" },
			{ REAL_GH_OUTPUT.bad_token, "auth" },
			{ REAL_GH_OUTPUT.unauthorized, "auth" },
			{ REAL_GH_OUTPUT.offline, "network" },
			{ REAL_GH_OUTPUT.forbidden, "permission" },
			{ REAL_GH_OUTPUT.missing_repo, "not_found" },
			{ "some unrecognised gh failure", "unknown" },
			{ "", "unknown" },
		}

		for _, case in ipairs(cases) do
			T.assert_equals(
				gh.classify_failure(case[1]),
				case[2],
				("classify_failure(%s)"):format(vim.inspect(case[1]))
			)
		end
	end,

	["an inaccessible repo does not read as a network error"] = function()
		local kind = gh.classify_failure(REAL_GH_OUTPUT.missing_repo)
		T.assert_equals(
			kind,
			"not_found",
			"HTTP 404 must not be classified as a network failure"
		)

		local hint = gh.failure_hint(kind)
		T.assert_contains(
			hint,
			"access",
			"404 hint must raise the possibility of missing access"
		)
		T.assert_true(
			hint:find("internet", 1, true) == nil,
			"404 hint must not blame the connection"
		)
	end,

	["only classifiable failures get a hint"] = function()
		T.assert_equals(
			gh.failure_hint("unknown"),
			nil,
			"an unclassified failure must not get an invented recovery step"
		)
		T.assert_contains(
			gh.failure_hint("missing"),
			"PATH",
			"a missing binary must read differently from an auth failure"
		)
		T.assert_true(
			gh.failure_hint("missing") ~= gh.failure_hint("auth"),
			"missing gh and unauthenticated gh must not share a message"
		)
	end,

	-- ── 6. Raw error text survives ────────────────────────────────────

	["gh errors keep their underlying text"] = function()
		local err = T.wait_async(function(done)
			gh.json({ "pr", "view", "999" }, nil, function(e)
				done(e)
			end)
		end)

		T.assert_true(err ~= nil, "a failing gh command must report an error")
		T.assert_contains(
			err,
			"gh pr view 999 failed",
			"error must name the failing invocation"
		)
	end,

	-- ── 7. Cached verdict is invalidated on auth failure ──────────────

	["an auth failure re-arms the prerequisite check"] = function()
		with_saved_gh_state(function()
			with_fake_gh(
				{ "echo 'gh: Bad credentials (HTTP 401)' >&2", "exit 1" },
				function()
					gh.state = {
						checked = true,
						available = true,
						authenticated = true,
						message = nil,
					}

					T.wait_async(function(done)
						gh.run({ "pr", "list" }, nil, done)
					end)

					T.assert_false(
						gh.state.checked,
						"an auth failure must invalidate the cached verdict"
					)
				end
			)
		end)
	end,

	["a network failure does not re-arm the check"] = function()
		with_saved_gh_state(function()
			with_fake_gh(
				{ "echo 'error connecting to github.com' >&2", "exit 1" },
				function()
					gh.state = {
						checked = true,
						available = true,
						authenticated = true,
						message = nil,
					}

					T.wait_async(function(done)
						gh.run({ "pr", "list" }, nil, done)
					end)

					T.assert_true(
						gh.state.checked,
						"being offline does not mean the login changed"
					)
				end
			)
		end)
	end,
})
