-- tests/helpers.lua — shared test utilities for E2E tests
local M = {}

-- ── Assertion helpers ──────────────────────────────────────────────────

--- Assert a condition is truthy; raises on failure.
---@param condition any
---@param message string
function M.assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

--- Assert two values are equal; raises with diff on failure.
---@param actual any
---@param expected any
---@param message string
function M.assert_equals(actual, expected, message)
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			),
			2
		)
	end
end

--- Assert two tables are deeply equal.
---@param actual any
---@param expected any
---@param message string
function M.assert_deep_equals(actual, expected, message)
	if not vim.deep_equal(actual, expected) then
		error(
			("%s (expected=%s, actual=%s)"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			),
			2
		)
	end
end

--- Assert a string contains a substring.
---@param haystack string
---@param needle string
---@param message string
function M.assert_contains(haystack, needle, message)
	if not haystack:find(needle, 1, true) then
		error(
			("%s (needle=%s not found in %s)"):format(
				message,
				vim.inspect(needle),
				vim.inspect(haystack)
			),
			2
		)
	end
end

--- Assert a condition is falsy; raises on failure.
---@param condition any
---@param message string
function M.assert_false(condition, message)
	if condition then
		error(message, 2)
	end
end

-- ── Feedkeys / command helpers ─────────────────────────────────────────

--- Send keystrokes in a blocking-safe manner.
---@param keys string  raw key notation (e.g. "<CR>", "jj")
---@param mode? string  feedkeys mode flag (default "x")
function M.feedkeys(keys, mode)
	local escaped = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(escaped, mode or "x", false)
end

--- Execute a Vim command and return its output.
---@param cmd string
---@return string
function M.exec_command(cmd)
	return vim.api.nvim_exec2(cmd, { output = true }).output or ""
end

-- ── Buffer content reader ──────────────────────────────────────────────

--- Read all lines from a buffer.
---@param bufnr integer
---@return string[]
function M.buf_lines(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Search for a needle in buffer lines.
---@param bufnr integer
---@param needle string
---@param start_line? integer  1-indexed start (default 1)
---@return integer|nil  1-indexed line number
function M.buf_find_line(bufnr, needle, start_line)
	local lines = M.buf_lines(bufnr)
	for i = (start_line or 1), #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

-- ── Window helpers ─────────────────────────────────────────────────────

--- Return a list of all currently open window IDs.
---@return integer[]
function M.list_windows()
	return vim.api.nvim_list_wins()
end

--- Return whether a window is a floating window.
---@param winid integer
---@return boolean
function M.is_float(winid)
	local cfg = vim.api.nvim_win_get_config(winid)
	return cfg.relative ~= nil and cfg.relative ~= ""
end

--- Find all floating windows.
---@return integer[]
function M.find_floats()
	local floats = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if M.is_float(win) then
			floats[#floats + 1] = win
		end
	end
	return floats
end

--- Assert the expected buffer name for a window.
---@param winid integer
---@param expected string  pattern to match against buf name
---@param message string
function M.assert_buf_name(winid, expected, message)
	local bufnr = vim.api.nvim_win_get_buf(winid)
	local name = vim.api.nvim_buf_get_name(bufnr)
	M.assert_true(
		name:find(expected, 1, true) ~= nil,
		("%s (buf name=%s, expected pattern=%s)"):format(
			message,
			vim.inspect(name),
			vim.inspect(expected)
		)
	)
end

-- ── Window layout verification ─────────────────────────────────────────

--- Return a summary of the current window layout.
---@return { total: integer, floats: integer, splits: integer }
function M.window_layout()
	local wins = vim.api.nvim_list_wins()
	local floats = 0
	for _, w in ipairs(wins) do
		if M.is_float(w) then
			floats = floats + 1
		end
	end
	return {
		total = #wins,
		floats = floats,
		splits = #wins - floats,
	}
end

-- ── Extmark / highlight inspection ─────────────────────────────────────

--- Get all extmarks in a buffer for a given namespace.
---@param bufnr integer
---@param ns_name string  namespace name
---@return table[]
function M.get_extmarks(bufnr, ns_name)
	local ns_id = vim.api.nvim_get_namespaces()[ns_name]
	if not ns_id then
		return {}
	end
	return vim.api.nvim_buf_get_extmarks(
		bufnr,
		ns_id,
		0,
		-1,
		{ details = true }
	)
end

--- Check whether a highlight group is defined.
---@param group string
---@return boolean
function M.hl_exists(group)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
	if not ok then
		return false
	end
	return hl and (hl.link ~= nil or hl.fg ~= nil or hl.bg ~= nil)
end

-- ── Async wait with bounded timeout ────────────────────────────────────

--- Poll a predicate until truthy or timeout.
---@param predicate fun(): boolean
---@param message string  error message on timeout
---@param timeout_ms? integer  default 5000
function M.wait_until(predicate, message, timeout_ms)
	local ok = vim.wait(timeout_ms or 5000, predicate, 20)
	M.assert_true(ok, message)
end

--- Run an async operation (callback-style) synchronously with timeout.
---@param start fun(done: fun(...))  function that takes a done callback
---@param timeout_ms? integer  default 5000
---@return any ...  values passed to done()
function M.wait_async(start, timeout_ms)
	local done = false
	local result = nil
	start(function(...)
		result = { ... }
		done = true
	end)
	local ok = vim.wait(timeout_ms or 5000, function()
		return done
	end, 10)
	M.assert_true(ok, "async callback timed out")
	return (table.unpack or unpack)(result)
end

-- ── Deterministic job synchronization ──────────────────────────────────

--- Count currently active async process jobs.
---@return integer
local function active_job_count()
	local count = 0

	for _, chan in ipairs(vim.api.nvim_list_chans()) do
		if chan.stream == "job" then
			count = count + 1
		end
	end

	local uv = vim.uv or vim.loop
	if uv and uv.walk then
		uv.walk(function(handle)
			local handle_type = uv.handle_get_type
				and uv.handle_get_type(handle)
				or nil
			if handle_type ~= "process" then
				return
			end

			local ok_active, active = pcall(function()
				return handle:is_active()
			end)
			local ok_closing, closing = pcall(function()
				return handle:is_closing()
			end)
			if ok_active and active and (not ok_closing or not closing) then
				count = count + 1
			end
		end)
	end

	return count
end

--- Block until async jobs are drained (useful after git/gh calls).
---@param timeout_ms? integer  default 3000
function M.drain_jobs(timeout_ms)
	local timeout = timeout_ms or 3000
	local stable_idle_polls = 0

	local ok = vim.wait(timeout, function()
		if active_job_count() == 0 then
			stable_idle_polls = stable_idle_polls + 1
		else
			stable_idle_polls = 0
		end
		-- Require two idle polls so queued callbacks can run.
		return stable_idle_polls >= 2
	end, 20)

	M.assert_true(
		ok,
		("timed out waiting for jobs to drain (%d active)"):format(
			active_job_count()
		)
	)
end

-- ── Safe error capture ─────────────────────────────────────────────────

--- Run a function and capture any error without propagating.
---@param fn fun()
---@return boolean ok
---@return string|nil error_message
function M.pcall_message(fn)
	local ok, err = pcall(fn)
	if ok then
		return true, nil
	end
	if type(err) == "string" then
		return false, err
	end
	return false, vim.inspect(err)
end

-- ── User input simulation ──────────────────────────────────────────────

--- Simulate user input by scheduling feedkeys on next event loop tick.
---@param input string  keystrokes to feed
---@param delay_ms? integer  delay before feeding (default 50)
function M.simulate_input(input, delay_ms)
	vim.defer_fn(function()
		M.feedkeys(input)
	end, delay_ms or 50)
end

-- ── List / table helpers ───────────────────────────────────────────────

--- Check if a list contains a value.
---@param list any[]
---@param value any
---@return boolean
function M.contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

--- Search lines for a needle (plain text).
---@param lines string[]
---@param needle string
---@param start_line? integer  1-indexed (default 1)
---@return integer|nil  1-indexed line number
function M.find_line(lines, needle, start_line)
	for i = (start_line or 1), #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

--- Count lines matching a needle.
---@param lines string[]
---@param needle string
---@return integer
function M.count_lines_with(lines, needle)
	local n = 0
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			n = n + 1
		end
	end
	return n
end

--- Assert buffer-local keymaps exist.
---@param bufnr integer
---@param required string[]  list of lhs keys expected
function M.assert_keymaps(bufnr, required)
	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local missing = {}
	for _, lhs in ipairs(required) do
		missing[lhs] = true
	end
	for _, map in ipairs(keymaps) do
		missing[map.lhs] = nil
	end
	for lhs, _ in pairs(missing) do
		error(("missing keymap '%s'"):format(lhs), 2)
	end
end

-- ── Panel cleanup ─────────────────────────────────────────────────────

--- All panel module names used across the plugin.
local ALL_PANELS = {
	"status", "diff", "log", "stash", "branch",
	"conflict", "issues", "prs", "labels", "review",
	"palette", "cherry_pick", "reset", "revert", "tag",
	"notifications",
	"actions",
}

--- Close all open panel windows and reset shared state.
function M.cleanup_panels()
	for _, panel_name in ipairs(ALL_PANELS) do
		local mod_ok, mod = pcall(
			require, "gitflow.panels." .. panel_name
		)
		if mod_ok and mod.close then
			pcall(mod.close)
		end
	end
	local cmd_ok, commands = pcall(require, "gitflow.commands")
	if cmd_ok then
		pcall(function()
			commands.state.panel_window = nil
		end)
	end
	local ui_ok, ui = pcall(require, "gitflow.ui")
	if ui_ok then
		pcall(ui.window.close, "main")
	end
end

-- ── File helpers ───────────────────────────────────────────────────────

--- Write lines to a file on disk.
---@param path string
---@param lines string[]
function M.write_file(path, lines)
	vim.fn.writefile(lines, path)
end

--- Read lines from a file on disk (returns {} if not readable).
---@param path string
---@return string[]
function M.read_file(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.fn.readfile(path)
end

-- ── Test runner ────────────────────────────────────────────────────────

--- Simple test collector/runner. Returns pass/fail counts.
---@param name string  suite name
---@param tests table<string, fun()>  name -> test function
---@return { passed: integer, failed: integer, errors: string[] }
function M.run_suite(name, tests)
	local passed = 0
	local failed = 0
	local errors = {}

	print(("=== %s ==="):format(name))

	for test_name, test_fn in pairs(tests) do
		local ok, err = pcall(test_fn)
		if ok then
			passed = passed + 1
			print(("  PASS: %s"):format(test_name))
		else
			failed = failed + 1
			local msg = type(err) == "string" and err or vim.inspect(err)
			errors[#errors + 1] = ("%s: %s"):format(test_name, msg)
			print(("  FAIL: %s — %s"):format(test_name, msg))
		end
	end

	print(("--- %s: %d passed, %d failed ---"):format(name, passed, failed))

	if failed > 0 then
		print("FAILURES:")
		for _, e in ipairs(errors) do
			print("  " .. e)
		end
		vim.cmd("cquit! 1")
	end

	return { passed = passed, failed = failed, errors = errors }
end

return M
