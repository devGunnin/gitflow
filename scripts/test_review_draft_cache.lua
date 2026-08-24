-- scripts/test_review_draft_cache.lua — the review's draft cache is user data.
--
-- A pending review comment lives only in memory and in this cache, so a bug
-- here loses someone's unsent work. The load path in particular must never
-- overwrite drafts the reviewer has in hand, and the two ways the cache path
-- is resolved (blocking `repo_slug`, async `resolve_repo_slug`) must agree —
-- if they could disagree, one review's drafts would silently split across two
-- files and half of them would look lost.
--
-- Everything here is scoped to its own throwaway slug, so it can never touch
-- a real repository's drafts.
--
-- Run: nvim --headless -u NONE -l scripts/test_review_draft_cache.lua

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

local cache = require("gitflow.review.cache")
local gh = require("gitflow.gh")
local git = require("gitflow.git")

local TEST_SLUG = "gitflow_selftest_draft_cache"
local TEST_PR = 999901

local function clean()
	pcall(cache.clear, TEST_PR, TEST_SLUG)
end

clean()

---@param comments table[]
local function save(comments)
	return cache.save(TEST_PR, { pr_number = TEST_PR, comments = comments }, TEST_SLUG)
end

test("a saved draft survives a round trip byte for byte", function()
	local draft = {
		id = 3,
		path = "lua/a.lua",
		body = "needs a guard here\n\nsecond paragraph",
		hunk = "@@ -1,3 +1,4 @@",
		new_line = 12,
		start_new_line = 10,
		created_at = "2026-08-24T00:00:00Z",
	}
	assert_true(save({ draft }), "save should report success")

	local loaded = cache.load(TEST_PR, TEST_SLUG)
	assert_equals(#loaded.comments, 1, "the draft comes back")
	local back = loaded.comments[1]
	for key, value in pairs(draft) do
		assert_equals(back[key], value, ("draft field %q survived"):format(key))
	end
	assert_true(loaded.updated_at ~= "", "the save is stamped")
	clean()
end)

test("loading a cache that was never written yields no drafts, not an error", function()
	clean()
	local loaded = cache.load(TEST_PR, TEST_SLUG)
	assert_equals(#loaded.comments, 0, "an absent cache is empty")
	assert_equals(loaded.pr_number, TEST_PR, "and still knows its PR")
end)

test("a corrupt cache file loses nothing else and reports empty", function()
	local path = cache.path_for(TEST_PR, TEST_SLUG)
	local file = assert(io.open(path, "w"))
	file:write("{ this is not json")
	file:close()

	local loaded = cache.load(TEST_PR, TEST_SLUG)
	assert_equals(#loaded.comments, 0, "unparseable content reads as no drafts")
	clean()
end)

test("clear removes the file for that PR only", function()
	save({ { id = 1, path = "a.lua", body = "one" } })
	local other = 999902
	cache.save(other, { pr_number = other, comments = { { id = 1, body = "two" } } },
		TEST_SLUG)

	cache.clear(TEST_PR, TEST_SLUG)
	assert_equals(#cache.load(TEST_PR, TEST_SLUG).comments, 0,
		"the cleared PR has no drafts")
	assert_equals(#cache.load(other, TEST_SLUG).comments, 1,
		"another PR's drafts are untouched")
	pcall(cache.clear, other, TEST_SLUG)
end)

test("hydrating never overwrites drafts the reviewer has in hand", function()
	-- The exact shape of the bug this guards: reopening or refreshing a PR
	-- reads the cache, and an in-memory list that is newer must win.
	save({ { id = 1, path = "a.lua", body = "from disk" } })

	local rstate = require("gitflow.review.state")
	local file_list = require("gitflow.review.file_list")
	rstate.reset()
	rstate.state.cfg = {}
	rstate.state.pr_number = TEST_PR
	rstate.state.repo_slug = TEST_SLUG
	rstate.state.pending_comments = {
		{ id = 9, path = "b.lua", body = "typed just now" },
	}

	-- `load.start` is the only path that hydrates on open; drive it with the
	-- slug already known so nothing goes near the network.
	local real_resolve = cache.resolve_repo_slug
	local real_refresh = require("gitflow.review.load").refresh
	local real_render = file_list.render
	cache.resolve_repo_slug = function(cb)
		cb(TEST_SLUG)
	end
	local load = require("gitflow.review.load")
	load.refresh = function() end
	file_list.render = function() end

	local ok, err = pcall(load.start, TEST_PR)

	cache.resolve_repo_slug = real_resolve
	load.refresh = real_refresh
	file_list.render = real_render
	assert_true(ok, tostring(err))

	assert_equals(#rstate.state.pending_comments, 1, "the in-memory list stands")
	assert_equals(rstate.state.pending_comments[1].body, "typed just now",
		"the cached draft must not clobber an unsaved one")
	rstate.reset()
	clean()
end)

test("hydrating restores drafts when there are none in memory", function()
	save({
		{ id = 1, path = "a.lua", body = "from disk" },
		{ id = 2, path = "b.lua", body = "also from disk" },
	})

	local rstate = require("gitflow.review.state")
	local file_list = require("gitflow.review.file_list")
	local load = require("gitflow.review.load")
	rstate.reset()
	rstate.state.cfg = {}
	rstate.state.pr_number = TEST_PR

	local real_resolve = cache.resolve_repo_slug
	local real_refresh, real_render = load.refresh, file_list.render
	cache.resolve_repo_slug = function(cb)
		cb(TEST_SLUG)
	end
	load.refresh = function() end
	file_list.render = function() end

	local ok, err = pcall(load.start, TEST_PR)

	cache.resolve_repo_slug = real_resolve
	load.refresh, file_list.render = real_refresh, real_render
	assert_true(ok, tostring(err))

	assert_equals(#rstate.state.pending_comments, 2, "both drafts come back")
	rstate.reset()
	clean()
end)

-- ── a cache that cannot be written ─────────────────────────────────────

---A cache path no process can ever write: its parent is a regular file, so
---`io.open` fails with ENOTDIR for every user, root included.
---@return string path, string blocker
local function unwritable_path()
	local blocker = vim.fn.tempname()
	local file = assert(io.open(blocker, "w"))
	file:write("not a directory")
	file:close()
	return blocker .. "/drafts.json", blocker
end

test("a draft cache that cannot be written is reported, not silently dropped", function()
	local rstate = require("gitflow.review.state")
	local utils = require("gitflow.utils")
	local path, blocker = unwritable_path()

	local real_path_for, real_notify = cache.path_for, utils.notify
	local notes = {}
	cache.path_for = function()
		return path
	end
	utils.notify = function(msg, level)
		notes[#notes + 1] = { msg = tostring(msg), level = level }
	end

	rstate.reset()
	rstate.state.pr_number = TEST_PR
	rstate.state.repo_slug = TEST_SLUG
	rstate.state.pending_comments = { { id = 1, path = "a.lua", body = "unsent" } }

	-- Three mutations, as a reviewer typing produces: the failure must be
	-- visible, and it must not be shouted once per keystroke.
	local ok, err = pcall(function()
		rstate.persist_pending()
		rstate.persist_pending()
		rstate.persist_pending()
	end)

	cache.path_for, utils.notify = real_path_for, real_notify
	pcall(vim.fn.delete, blocker)
	assert_true(ok, tostring(err))

	assert_equals(#notes, 1, "a failed draft save is reported exactly once")
	assert_equals(notes[1].level, vim.log.levels.ERROR, "and reported as an error")
	assert_true(notes[1].msg:find("save review drafts", 1, true) ~= nil,
		"naming what could not be saved: " .. notes[1].msg)
	assert_true(rstate.state.draft_save_error ~= nil,
		"and recorded, so the close prompt stops promising the disk copy")

	-- Recovery: a save that lands clears the record, so a later failure is
	-- reported again instead of being swallowed by the first one.
	rstate.persist_pending()
	assert_equals(rstate.state.draft_save_error, nil,
		"a successful save clears the failure")
	assert_equals(#cache.load(TEST_PR, TEST_SLUG).comments, 1,
		"and actually writes the draft")

	rstate.reset()
	clean()
end)

-- ── a failed save must not destroy what is already on disk ────────────

test("a save that cannot be completed leaves the previous drafts on disk", function()
	-- Opening the target itself truncates it, so the write goes to a
	-- neighbouring file and is renamed over. Failing the rename is the only
	-- way to reach a half-done save from a test.
	save({ { id = 1, path = "a.lua", body = "the good copy" } })

	local real_rename = os.rename
	os.rename = function()
		return nil, "simulated failure"
	end
	local ok, err = save({ { id = 2, path = "b.lua", body = "the failed copy" } })
	os.rename = real_rename

	assert_true(not ok, "the save reports failure")
	assert_true(tostring(err):find("simulated failure", 1, true) ~= nil,
		"and carries the reason: " .. tostring(err))

	local loaded = cache.load(TEST_PR, TEST_SLUG)
	assert_equals(#loaded.comments, 1, "the drafts already on disk are still there")
	assert_equals(loaded.comments[1].body, "the good copy",
		"unchanged by the save that failed")
	assert_equals(
		vim.fn.filereadable(cache.path_for(TEST_PR, TEST_SLUG) .. ".tmp"), 0,
		"and the half-written file is not left behind")
	clean()
end)

-- ── a delete that did not happen is reported ──────────────────────────

test("clearing a cache that is already gone is not a failure", function()
	clean()
	local ok, err = cache.clear(TEST_PR, TEST_SLUG)
	assert_true(ok, "nothing to delete is nothing to report: " .. tostring(err))
end)

test("a draft cache that cannot be deleted is reported, not swallowed", function()
	-- `vim.fn.delete` answers -1 rather than raising, so the failure is only
	-- visible in its return value. A cache that survives a submit comes back
	-- on the next open as comments that are already posted.
	save({ { id = 1, path = "a.lua", body = "posted already" } })

	local real_delete = vim.fn.delete
	vim.fn.delete = function()
		return -1
	end
	local ok, err = cache.clear(TEST_PR, TEST_SLUG)
	vim.fn.delete = real_delete

	assert_true(not ok, "a failed delete is reported")
	assert_true(tostring(err):find(tostring(TEST_PR), 1, true) ~= nil,
		"and names the file: " .. tostring(err))
	clean()
end)

test("clearing a cache that is there answers success", function()
	save({ { id = 1, path = "a.lua", body = "unsent" } })
	local ok, err = cache.clear(TEST_PR, TEST_SLUG)
	assert_true(ok, "a delete that happened is a success: " .. tostring(err))
	assert_equals(#cache.load(TEST_PR, TEST_SLUG).comments, 0, "and the file is gone")
end)

-- ── an externally corrupted cache must not reach the submit path ──────

test("cached comments that are not tables are dropped, not handed on", function()
	local path = cache.path_for(TEST_PR, TEST_SLUG)
	local file = assert(io.open(path, "w"))
	file:write(vim.json.encode({
		pr_number = TEST_PR,
		comments = { 7, { id = 2, path = "a.lua", body = "real draft" }, "x" },
		updated_at = "2026-08-24T00:00:00Z",
	}))
	file:close()

	local loaded = cache.load(TEST_PR, TEST_SLUG)
	assert_equals(#loaded.comments, 1, "only the draft-shaped entry survives")
	assert_equals(loaded.comments[1].body, "real draft", "and it is intact")
	clean()
end)

-- ── submitting clears the disk copy ────────────────────────────────────

test("an accepted review leaves no drafts on disk", function()
	-- Without this, a regressed clear would re-restore already-submitted
	-- comments on the next open and post them to the PR a second time.
	local rstate = require("gitflow.review.state")
	local load = require("gitflow.review.load")
	local submit = require("gitflow.review.submit")
	local gh_prs = require("gitflow.gh.prs")

	local draft = {
		id = 1,
		path = "a.lua",
		body = "please rename this",
		new_line = 12,
		created_at = "2026-08-24T00:00:00Z",
	}
	save({ draft })
	assert_equals(#cache.load(TEST_PR, TEST_SLUG).comments, 1,
		"the draft is on disk before the submit")

	rstate.reset()
	rstate.state.cfg = {}
	rstate.state.pr_number = TEST_PR
	rstate.state.repo_slug = TEST_SLUG
	rstate.state.pending_comments = { draft }
	-- Only drafts anchored to a line in the diff are sent, so the submit
	-- needs a diff that carries this one.
	rstate.state.file_diffs = {
		["a.lua"] = { hunks = { { lines = { { new_line = 12 } } } } },
	}

	local real_submit, real_refresh = gh_prs.submit_review, load.refresh
	local sent
	gh_prs.submit_review = function(_, _, _, comments, _, cb)
		sent = comments
		cb(nil)
	end
	load.refresh = function() end

	local ok, err = pcall(submit.submit_review_direct, "approve", "lgtm")

	gh_prs.submit_review, load.refresh = real_submit, real_refresh
	assert_true(ok, tostring(err))

	assert_true(sent ~= nil and #sent == 1, "the draft was sent to GitHub")
	assert_equals(#rstate.state.pending_comments, 0, "nothing is left in memory")
	assert_equals(#cache.load(TEST_PR, TEST_SLUG).comments, 0,
		"and nothing on disk for the next open to re-post")

	rstate.reset()
	clean()
end)

test("a submit whose draft cache survives says so", function()
	-- The drafts are posted; if the file is still there the next open
	-- restores them and they can be posted a second time.
	local rstate = require("gitflow.review.state")
	local load = require("gitflow.review.load")
	local submit = require("gitflow.review.submit")
	local gh_prs = require("gitflow.gh.prs")
	local utils = require("gitflow.utils")

	rstate.reset()
	rstate.state.cfg = {}
	rstate.state.pr_number = TEST_PR
	rstate.state.repo_slug = TEST_SLUG
	rstate.state.pending_comments = {
		{ id = 1, path = "a.lua", body = "please rename this", new_line = 12 },
	}
	rstate.state.file_diffs = {
		["a.lua"] = { hunks = { { lines = { { new_line = 12 } } } } },
	}

	local real_clear, real_notify = cache.clear, utils.notify
	local real_submit, real_refresh = gh_prs.submit_review, load.refresh
	local notes = {}
	cache.clear = function()
		return false, "could not delete /nope/999901.json"
	end
	utils.notify = function(msg, level)
		notes[#notes + 1] = { msg = tostring(msg), level = level }
	end
	gh_prs.submit_review = function(_, _, _, _, _, cb)
		cb(nil)
	end
	load.refresh = function() end

	local ok, err = pcall(submit.submit_review_direct, "approve", "lgtm")

	cache.clear, utils.notify = real_clear, real_notify
	gh_prs.submit_review, load.refresh = real_submit, real_refresh
	assert_true(ok, tostring(err))

	local warned = false
	for _, note in ipairs(notes) do
		if note.msg:find("still on disk", 1, true) then
			warned = true
			assert_equals(note.level, vim.log.levels.WARN,
				"a surviving draft cache is a warning")
		end
	end
	assert_true(warned, "the surviving draft cache is reported")

	rstate.reset()
	clean()
end)

-- ── the two slug paths must agree ──────────────────────────────────────

---Run `fn` with both the blocking and the async subprocess layers answering
---the same fabricated results, so the two resolution paths can be compared.
---@param gh_answer { code: integer, stdout: string }
---@param git_answer { code: integer, stdout: string }
---@return string blocking, string async
local function both_slugs(gh_answer, git_answer)
	local real_systemlist = vim.fn.systemlist
	local real_gh_run, real_git_git = gh.run, git.git

	vim.fn.systemlist = function(cmd)
		local answer = cmd[1] == "gh" and gh_answer or git_answer
		vim.v.errmsg = ""
		-- vim.v.shell_error is read-only; run a real process with the matching
		-- exit status so the caller's check sees what it would in the wild.
		real_systemlist({ "sh", "-c", ("exit %d"):format(answer.code) })
		return vim.split(answer.stdout, "\n", { plain = true })
	end
	gh.run = function(_, _, cb)
		cb({ code = gh_answer.code, stdout = gh_answer.stdout, stderr = "" })
	end
	git.git = function(_, _, cb)
		cb({ code = git_answer.code, stdout = git_answer.stdout, stderr = "" })
	end

	local ok, blocking, async = pcall(function()
		cache.invalidate_repo_slug()
		local sync = cache.repo_slug()
		cache.invalidate_repo_slug()
		local resolved
		cache.resolve_repo_slug(function(slug)
			resolved = slug
		end)
		return sync, resolved
	end)

	vim.fn.systemlist = real_systemlist
	gh.run, git.git = real_gh_run, real_git_git
	cache.invalidate_repo_slug()
	if not ok then
		error(blocking, 0)
	end
	return blocking, async
end

test("both slug paths agree when gh answers", function()
	local blocking, async = both_slugs(
		{ code = 0, stdout = "octo/gitflow\n" },
		{ code = 0, stdout = "/home/someone/src/gitflow\n" }
	)
	assert_equals(blocking, "octo_gitflow", "gh's nameWithOwner is slugified")
	assert_equals(async, blocking,
		"the async path must resolve the same cache directory")
end)

test("both slug paths agree when gh fails and git answers", function()
	local blocking, async = both_slugs(
		{ code = 1, stdout = "" },
		{ code = 0, stdout = "/home/someone/src/gitflow\n" }
	)
	assert_equals(blocking, "_home_someone_src_gitflow", "the toplevel is the fallback")
	assert_equals(async, blocking, "and the async path falls back the same way")
end)

test("both slug paths agree when nothing answers", function()
	local blocking, async = both_slugs({ code = 1, stdout = "" }, { code = 1, stdout = "" })
	assert_equals(blocking, "unknown", "an unidentifiable repo has one name")
	assert_equals(async, blocking, "and the async path uses it too")
end)

test("both slug paths agree when gh answers empty", function()
	local blocking, async = both_slugs(
		{ code = 0, stdout = "\n" },
		{ code = 0, stdout = "/tmp/repo\n" }
	)
	assert_equals(blocking, "_tmp_repo", "a blank gh answer is not a slug")
	assert_equals(async, blocking, "and the async path rejects it too")
end)

test("the resolved slug is memoized, not re-fetched per draft save", function()
	local calls = 0
	local real_gh_run = gh.run
	gh.run = function(_, _, cb)
		calls = calls + 1
		cb({ code = 0, stdout = "octo/gitflow\n", stderr = "" })
	end
	cache.invalidate_repo_slug()

	local first, second
	cache.resolve_repo_slug(function(slug) first = slug end)
	cache.resolve_repo_slug(function(slug) second = slug end)

	gh.run = real_gh_run
	cache.invalidate_repo_slug()

	assert_equals(calls, 1, "the second call is answered from the memo")
	assert_equals(first, second, "and gives the same slug")
end)

test("callers that arrive while a resolve is out share it", function()
	local calls, deliver = 0, nil
	local real_gh_run = gh.run
	gh.run = function(_, _, cb)
		calls = calls + 1
		deliver = cb
	end
	cache.invalidate_repo_slug()

	local first, second
	cache.resolve_repo_slug(function(slug) first = slug end)
	cache.resolve_repo_slug(function(slug) second = slug end)

	local in_flight = calls
	local answered_early = first ~= nil or second ~= nil
	if deliver then
		deliver({ code = 0, stdout = "octo/gitflow\n", stderr = "" })
	end
	gh.run = real_gh_run
	cache.invalidate_repo_slug()

	assert_equals(in_flight, 1,
		"a second caller joins the lookup in flight instead of spawning gh again")
	assert_true(not answered_early, "and neither is answered before gh is")
	assert_equals(first, "octo_gitflow", "the first caller gets the slug")
	assert_equals(second, first, "and so does the one that joined")
end)

test("a missing gh still resolves a slug, so drafts are not stranded", function()
	-- vim.system raises rather than answering when the executable is absent,
	-- and the caller restores the reviewer's drafts from this callback.
	local real_gh_run, real_git_git = gh.run, git.git
	gh.run = function()
		error("ENOENT: no such file or directory: gh")
	end
	git.git = function(_, _, cb)
		cb({ code = 0, stdout = "/home/someone/src/gitflow\n", stderr = "" })
	end
	cache.invalidate_repo_slug()

	local resolved
	local ok, err = pcall(cache.resolve_repo_slug, function(slug)
		resolved = slug
	end)

	gh.run, git.git = real_gh_run, real_git_git
	cache.invalidate_repo_slug()
	assert_true(ok, "a missing gh must not escape the resolve: " .. tostring(err))
	assert_equals(resolved, "_home_someone_src_gitflow",
		"it falls back to the git toplevel")
end)

test("neither gh nor git available still answers, with the last-resort slug", function()
	local real_gh_run, real_git_git = gh.run, git.git
	gh.run = function()
		error("ENOENT: no such file or directory: gh")
	end
	git.git = function()
		error("ENOENT: no such file or directory: git")
	end
	cache.invalidate_repo_slug()

	local resolved
	local ok, err = pcall(cache.resolve_repo_slug, function(slug)
		resolved = slug
	end)

	gh.run, git.git = real_gh_run, real_git_git
	cache.invalidate_repo_slug()
	assert_true(ok, "no subprocess at all must not raise: " .. tostring(err))
	assert_equals(resolved, "unknown", "the drafts still get a cache file")
end)

clean()
pcall(vim.fn.delete, ("%s/gitflow/review/%s"):format(vim.fn.stdpath("data"), TEST_SLUG), "d")

print(string.rep("\u{2500}", 50))
print(("review draft cache: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
