--- lua/gitflow/review/cache.lua
---
--- Persistent on-disk cache for pending PR review comments. Each PR's
--- pending comments are written to a JSON file under
---     stdpath('data')/gitflow/review/<repo-slug>/<pr-number>.json
--- The cache is rewritten on every mutation so a crashed neovim can resume
--- a draft review.

---@class GitflowReviewCachedComment
---@field id integer
---@field path string
---@field body string
---@field hunk string|nil
---@field new_line integer|nil  anchor on the +/RIGHT side
---@field old_line integer|nil  anchor on the -/LEFT side
---@field start_new_line integer|nil  range start (new side)
---@field start_old_line integer|nil  range start (old side)
---@field created_at string

---@class GitflowReviewCacheState
---@field pr_number integer
---@field comments GitflowReviewCachedComment[]
---@field updated_at string

local M = {}

---@return string
local function root_dir()
	local data_dir = vim.fn.stdpath("data")
	return data_dir .. "/gitflow/review"
end

---@param path string
local function ensure_dir(path)
	vim.fn.mkdir(path, "p")
end

---@param value string
---@return string
local function slugify(value)
	return (tostring(value or "")):gsub("[^%w%-_%.]", "_")
end

-- Memoized repo slug. Resolving it costs a subprocess (a network round-trip
-- when `gh` answers), and it is read on every comment load and save; it can
-- only change when the working directory moves to another repo, so cwd is the
-- cache key.
local slug_cache = { cwd = nil, slug = nil }

--- Drop the memoized slug. Only needed when the repo's gh remote changes
--- underneath a session; a `:cd` invalidates on its own.
function M.invalidate_repo_slug()
	slug_cache = { cwd = nil, slug = nil }
end

---@param value string|nil
---@return string|nil  the first non-empty output line, slugified
local function first_line_slug(value)
	local first = vim.trim(tostring(value or ""):gsub("\n.*", ""))
	if first == "" then
		return nil
	end
	return slugify(first)
end

---@param cwd string
---@param slug string
---@return string
local function memoize(cwd, slug)
	assert(type(slug) == "string" and slug ~= "", "repo slug must be non-empty")
	slug_cache = { cwd = cwd, slug = slug }
	return slug
end

local GH_SLUG_ARGS = { "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" }
local GIT_SLUG_ARGS = { "rev-parse", "--show-toplevel" }

---@param exe string
---@param args string[]
---@return string|nil
local function slug_from(exe, args)
	local cmd = { exe }
	for _, arg in ipairs(args) do
		cmd[#cmd + 1] = arg
	end
	local out = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 or not out then
		return nil
	end
	return first_line_slug(out[1])
end

---@return string
local function compute_repo_slug()
	return slug_from("gh", GH_SLUG_ARGS)
		or slug_from("git", GIT_SLUG_ARGS)
		or "unknown"
end

--- Stable slug for the current repository. Prefers the gh nameWithOwner so
--- multiple checkouts of the same repo share a draft; falls back to the
--- toplevel path. Memoized per cwd.
---
--- Blocking. Kept for the paths that need the answer before they can write
--- (`path_for` with no slug handed in); anything that can wait should call
--- `resolve_repo_slug`, which never freezes the editor.
---@return string
function M.repo_slug()
	local cwd = vim.fn.getcwd()
	assert(type(cwd) == "string", "getcwd must return a string")
	if slug_cache.slug and slug_cache.cwd == cwd then
		return slug_cache.slug
	end
	return memoize(cwd, compute_repo_slug())
end

--- Callbacks waiting on the resolve that is currently out, or nil when none
--- is. Without this, every caller before the first answer spawns its own
--- `gh repo view`. Keyed by the cwd the lookup was launched from: a caller
--- from another repo must never be handed this repo's slug, or it loads this
--- repo's unsent drafts into that repo's review.
---@type { cwd: string, [integer]: fun(slug: string) }|nil
local pending_resolves = nil

--- Resolve the slug without blocking the editor.
---
--- `gh repo view` is a network round-trip, so opening review mode must not
--- wait on it. Same fallback order and same memo as `repo_slug`, so both name
--- the same cache file for the same answers; they can still differ if gh
--- succeeds for one and fails for the other (flaky network, a token expiring
--- between the two), and the later answer then takes the memo. Nothing is
--- lost when that happens — `hydrate_drafts` refuses to clobber drafts held
--- in memory — but the older slug's file is left behind.
---@param cb fun(slug: string)
function M.resolve_repo_slug(cb)
	local cwd = vim.fn.getcwd()
	assert(type(cwd) == "string", "getcwd must return a string")
	if slug_cache.slug and slug_cache.cwd == cwd then
		cb(slug_cache.slug)
		return
	end
	if pending_resolves and pending_resolves.cwd == cwd then
		pending_resolves[#pending_resolves + 1] = cb
		return
	end
	-- A resolve out for another cwd keeps its own waiters; only the newest
	-- one is joinable, so neither set is orphaned.
	local waiting = { cwd = cwd, cb }
	pending_resolves = waiting

	local settled = false
	---@param slug string
	local function settle(slug)
		if settled then
			return
		end
		settled = true
		if pending_resolves == waiting then
			pending_resolves = nil
		end
		memoize(cwd, slug)
		for _, waiter in ipairs(waiting) do
			waiter(slug)
		end
	end

	local git = require("gitflow.git")
	local gh = require("gitflow.gh")

	-- `vim.system` raises rather than answers when the executable is missing,
	-- and the caller restores the reviewer's drafts from this callback: a
	-- machine without gh must still get a slug, not an exception.
	local function fall_back_to_git()
		local ok = pcall(git.git, GIT_SLUG_ARGS, {}, function(git_result)
			local fallback = git_result.code == 0
				and first_line_slug(git_result.stdout) or nil
			settle(fallback or "unknown")
		end)
		if not ok then
			settle("unknown")
		end
	end

	local ok = pcall(gh.run, GH_SLUG_ARGS, {}, function(gh_result)
		local slug = gh_result.code == 0 and first_line_slug(gh_result.stdout) or nil
		if slug then
			settle(slug)
			return
		end
		fall_back_to_git()
	end)
	if not ok then
		fall_back_to_git()
	end
end

---@param pr_number integer|string
---@param repo_slug string|nil
---@return string
function M.path_for(pr_number, repo_slug)
	local slug = repo_slug or M.repo_slug()
	local dir = ("%s/%s"):format(root_dir(), slug)
	ensure_dir(dir)
	return ("%s/%s.json"):format(dir, tostring(pr_number))
end

---@param pr_number integer|string
---@param repo_slug string|nil
---@return GitflowReviewCacheState
function M.load(pr_number, repo_slug)
	local path = M.path_for(pr_number, repo_slug)
	local empty = {
		pr_number = tonumber(pr_number) or 0,
		comments = {},
		updated_at = "",
	}

	local file = io.open(path, "r")
	if not file then
		return empty
	end
	local raw = file:read("*a")
	file:close()
	if not raw or raw == "" then
		return empty
	end

	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return empty
	end

	decoded.pr_number = tonumber(decoded.pr_number)
		or tonumber(pr_number) or 0
	if type(decoded.comments) ~= "table" then
		decoded.comments = {}
	else
		-- The writer only ever encodes tables; a hand-edited or corrupted
		-- file can hold anything, and a scalar here crashes submit.
		local comments = {}
		for _, comment in ipairs(decoded.comments) do
			if type(comment) == "table" then
				comments[#comments + 1] = comment
			end
		end
		decoded.comments = comments
	end
	decoded.updated_at = tostring(decoded.updated_at or "")
	return decoded
end

---@param pr_number integer|string
---@param state GitflowReviewCacheState
---@param repo_slug string|nil
function M.save(pr_number, state, repo_slug)
	local path = M.path_for(pr_number, repo_slug)
	local payload = {
		pr_number = tonumber(pr_number) or state.pr_number or 0,
		comments = state.comments or {},
		updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	local encoded = vim.json.encode(payload)
	-- Write beside the target and rename over it: opening the target itself
	-- truncates, so a write that fails part-way would destroy the drafts
	-- already on disk. Same directory, so the rename is atomic.
	local tmp_path = path .. ".tmp"
	local file, open_err = io.open(tmp_path, "w")
	if not file then
		return false, ("could not open %s for writing: %s"):format(
			tmp_path, open_err or "unknown error")
	end
	-- Buffered: a full disk usually surfaces at close, not at write.
	local ok, write_err = file:write(encoded)
	if ok then
		ok, write_err = file:close()
	else
		file:close()
	end
	if not ok then
		os.remove(tmp_path)
		return false, ("could not write %s: %s"):format(
			tmp_path, write_err or "unknown error")
	end

	local renamed, rename_err = os.rename(tmp_path, path)
	if not renamed then
		os.remove(tmp_path)
		return false, ("could not replace %s: %s"):format(
			path, rename_err or "unknown error")
	end
	return true
end

--- Remove a PR's draft cache. A cache that survives a submitted review is
--- re-hydrated on the next open as already-posted comments, so a delete that
--- did not happen is reported rather than swallowed.
---@param pr_number integer|string
---@param repo_slug string|nil
---@return boolean ok
---@return string|nil err
function M.clear(pr_number, repo_slug)
	local path = M.path_for(pr_number, repo_slug)
	if vim.fn.filereadable(path) == 0 then
		return true
	end
	-- `vim.fn.delete` answers -1 rather than raising; the pcall is only for
	-- the call itself failing.
	local called, result = pcall(vim.fn.delete, path)
	if not called then
		return false, ("could not delete %s: %s"):format(path, tostring(result))
	end
	if result ~= 0 then
		return false, ("could not delete %s"):format(path)
	end
	return true
end

return M
