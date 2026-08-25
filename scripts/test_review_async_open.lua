-- scripts/test_review_async_open.lua — review mode opens without blocking.
--
-- Opening a review used to run `gh repo view` synchronously (to decide which
-- file the drafts cache lives in) before it drew anything, so the editor
-- froze for a network round-trip on every open. The slug is resolved off the
-- main loop now, and the tabpage is on screen before it lands.
--
-- Deleting a submitted comment had the same problem one level down: it read
-- the current login with a blocking `gh api user`.
--
-- Run: nvim --headless -u NONE -l scripts/test_review_async_open.lua

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, failed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " — " .. tostring(err))
	end
end

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(("%s (expected=%s, actual=%s)"):format(
			message, vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

local gitflow = require("gitflow")
gitflow.setup({ ui = { default_layout = "split" } })
local cfg = require("gitflow.config").current

local gh = require("gitflow.gh")
local gh_prs = require("gitflow.gh.prs")
local cache = require("gitflow.review.cache")
local rstate = require("gitflow.review.state")
local review = require("gitflow.panels.review")

---Every subprocess `vim.fn.system*` runs while `fn` does, as argv tables.
---This is the shape a blocking call takes in this codebase: the async path
---goes through `gitflow.git.run`, which never touches `vim.fn.system`.
---@param fn fun()
---@return table[]
local function record_blocking_calls(fn)
	local real_systemlist, real_system = vim.fn.systemlist, vim.fn.system
	local calls = {}
	local function record(cmd)
		calls[#calls + 1] = type(cmd) == "table" and cmd or { tostring(cmd) }
	end
	vim.fn.systemlist = function(cmd, ...)
		record(cmd)
		return real_systemlist(cmd, ...)
	end
	vim.fn.system = function(cmd, ...)
		record(cmd)
		return real_system(cmd, ...)
	end

	local ok, err = pcall(fn)

	vim.fn.systemlist, vim.fn.system = real_systemlist, real_system
	if not ok then
		error(err, 0)
	end
	return calls
end

---@param calls table[]
---@param exe string
---@return boolean
local function ran(calls, exe)
	for _, cmd in ipairs(calls) do
		if cmd[1] == exe then
			return true
		end
	end
	return false
end

---Replace the network with recorders, run `fn`, then put it all back.
---@param fn fun(seen: table)
local function with_stubbed_network(fn)
	local real = {
		resolve = cache.resolve_repo_slug,
		repo_slug = cache.repo_slug,
		view = gh_prs.view,
		list_files = gh_prs.list_files,
		review_comments = gh_prs.review_comments,
		run = gh.run,
	}
	local seen = { slug_resolves = 0, blocking_slugs = 0, views = 0, gh_runs = {} }

	cache.resolve_repo_slug = function(cb)
		seen.slug_resolves = seen.slug_resolves + 1
		seen.deliver_slug = cb
	end
	cache.repo_slug = function()
		seen.blocking_slugs = seen.blocking_slugs + 1
		return "stub_slug"
	end
	gh_prs.view = function()
		seen.views = seen.views + 1
	end
	gh_prs.list_files = function() end
	gh_prs.review_comments = function() end
	gh.run = function(args, _, cb)
		seen.gh_runs[#seen.gh_runs + 1] = args
		seen.deliver_gh = cb
	end

	local ok, err = pcall(fn, seen)

	cache.resolve_repo_slug = real.resolve
	cache.repo_slug = real.repo_slug
	gh_prs.view = real.view
	gh_prs.list_files = real.list_files
	gh_prs.review_comments = real.review_comments
	gh.run = real.run
	pcall(review.close)
	if not ok then
		error(err, 0)
	end
end

---@param bufnr integer
---@return string
local function buf_text(bufnr)
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

test("open paints the review before any slug lookup answers", function()
	with_stubbed_network(function(seen)
		local calls = record_blocking_calls(function()
			review.open(cfg, 42)
		end)

		assert_true(review.is_open(), "the review should be open when open returns")
		assert_true(vim.api.nvim_buf_is_valid(review.state.bufnr),
			"the file-list buffer should exist immediately")
		assert_true(vim.api.nvim_win_is_valid(review.state.diff_winid),
			"and so should the diff pane")
		assert_true(buf_text(review.state.bufnr):find("PR REVIEW", 1, true) ~= nil,
			"the pane should already name the PR")
		assert_true(
			buf_text(review.state.bufnr):find("Loading changed files", 1, true) ~= nil,
			"and say it is still loading"
		)

		assert_true(not ran(calls, "gh"),
			"open ran a blocking gh call: " .. vim.inspect(calls))
		assert_equals(seen.blocking_slugs, 0,
			"open resolved the draft-cache slug the blocking way")
		-- Non-vacuous: the slug must actually have been asked for, off the
		-- main loop, or the assertions above would pass on a review that
		-- simply never resolves one.
		assert_equals(seen.slug_resolves, 1,
			"open should resolve the draft-cache slug asynchronously")
	end)
end)

test("the PR load waits for the slug, then starts", function()
	with_stubbed_network(function(seen)
		review.open(cfg, 43)
		assert_equals(seen.views, 0,
			"nothing may be loaded before the drafts cache location is known")

		seen.deliver_slug("owner_repo")
		assert_equals(review.state.repo_slug, "owner_repo",
			"the resolved slug is what drafts are saved under")
		assert_equals(seen.views, 1, "and the load starts once it lands")
	end)
end)

test("a slug answering after the review moved on is dropped", function()
	with_stubbed_network(function(seen)
		review.open(cfg, 44)
		local stale = seen.deliver_slug
		review.close()

		stale("late_slug")
		assert_equals(review.state.repo_slug, nil,
			"a slug for a closed review must not be adopted")
		assert_equals(seen.views, 0, "and must not start a load")
	end)
end)

test("refreshing before the slug lands does not fall back to a blocking lookup", function()
	with_stubbed_network(function(seen)
		review.open(cfg, 46)

		local calls = record_blocking_calls(function()
			require("gitflow.review.load").refresh()
		end)

		assert_true(not ran(calls, "gh"),
			"r ran a blocking gh call: " .. vim.inspect(calls))
		assert_equals(seen.blocking_slugs, 0,
			"r resolved the draft-cache slug the blocking way")
		assert_equals(seen.views, 0,
			"and loaded nothing before the drafts cache location is known")
	end)
end)

test("closing before the drafts are read back still warns", function()
	with_stubbed_network(function(seen)
		review.open(cfg, 47)

		local input = require("gitflow.ui.input")
		local real_confirm = input.confirm
		local asked
		input.confirm = function(msg)
			asked = msg
			return false
		end

		local ok, err = pcall(review.close_with_guard)

		input.confirm = real_confirm
		assert_true(ok, tostring(err))
		assert_true(asked ~= nil,
			"closing while the disk copy is unread must not claim zero drafts")
		assert_true(review.is_open(), "and declining keeps the review open")

		-- Non-vacuous: once the drafts are known, closing is silent again.
		seen.deliver_slug("owner_repo")
		asked = nil
		input.confirm = function(msg)
			asked = msg
			return true
		end
		local closed_ok, close_err = pcall(review.close_with_guard)
		input.confirm = real_confirm
		assert_true(closed_ok, tostring(close_err))
		assert_true(asked == nil, "a review with no drafts closes without a prompt")
	end)
end)

test("deleting a submitted comment reads the login without blocking", function()
	with_stubbed_network(function(seen)
		review.open(cfg, 45)
		seen.deliver_slug("owner_repo")

		local threads = require("gitflow.review.threads")
		rstate.state.active_path = "a.lua"
		rstate.state.comment_threads = threads.build({
			{ id = 7, path = "a.lua", line = 1, body = "ship it",
				user = { login = "ann" } },
		})
		vim.api.nvim_win_set_buf(rstate.state.diff_winid,
			vim.api.nvim_create_buf(false, true))
		vim.api.nvim_win_set_cursor(rstate.state.diff_winid, { 1, 0 })

		local before = #seen.gh_runs
		local calls = record_blocking_calls(function()
			review.delete_comment_at_cursor()
		end)

		assert_true(not ran(calls, "gh"),
			"the login lookup blocked the editor: " .. vim.inspect(calls))
		assert_equals(#seen.gh_runs, before + 1,
			"it should have gone out asynchronously instead")
		assert_equals(table.concat(seen.gh_runs[#seen.gh_runs], " "),
			"api user -q .login", "and asked gh for the current login")
	end)
end)

-- Restoring a review's drafts creates that slug's cache directory; the
-- stubbed slug's is this script's litter, so it goes back out.
pcall(vim.fn.delete,
	("%s/gitflow/review/owner_repo"):format(vim.fn.stdpath("data")), "d")

print(string.rep("\u{2500}", 50))
print(("review async open: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
