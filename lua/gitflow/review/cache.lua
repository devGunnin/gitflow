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

--- Resolve the slug without blocking the editor.
---
--- `gh repo view` is a network round-trip, so opening review mode must not
--- wait on it. The fallback order is the same as `repo_slug` and both share
--- one memo, so a draft written through the blocking path and one written
--- after this lands can never disagree about where the cache file is — which
--- would silently split a reviewer's drafts across two files.
---@param cb fun(slug: string)
function M.resolve_repo_slug(cb)
	local cwd = vim.fn.getcwd()
	assert(type(cwd) == "string", "getcwd must return a string")
	if slug_cache.slug and slug_cache.cwd == cwd then
		cb(slug_cache.slug)
		return
	end

	local git = require("gitflow.git")
	local gh = require("gitflow.gh")
	gh.run(GH_SLUG_ARGS, {}, function(gh_result)
		local slug = gh_result.code == 0 and first_line_slug(gh_result.stdout) or nil
		if slug then
			cb(memoize(cwd, slug))
			return
		end
		git.git(GIT_SLUG_ARGS, {}, function(git_result)
			local fallback = git_result.code == 0
				and first_line_slug(git_result.stdout) or nil
			cb(memoize(cwd, fallback or "unknown"))
		end)
	end)
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
	local file = io.open(path, "w")
	if not file then
		return false, ("could not open %s for writing"):format(path)
	end
	file:write(encoded)
	file:close()
	return true
end

---@param pr_number integer|string
---@param repo_slug string|nil
function M.clear(pr_number, repo_slug)
	local path = M.path_for(pr_number, repo_slug)
	pcall(vim.fn.delete, path)
end

return M
