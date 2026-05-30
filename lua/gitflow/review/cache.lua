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

--- Compute a stable slug for the current repository. Prefers the gh
--- nameWithOwner so multiple checkouts of the same repo share a draft.
--- Falls back to the absolute path of the toplevel directory.
---@return string
function M.repo_slug()
	local function via_git()
		local out = vim.fn.systemlist({
			"git", "rev-parse", "--show-toplevel",
		})
		if vim.v.shell_error == 0 and out and out[1] then
			return slugify(vim.trim(out[1]))
		end
		return nil
	end

	local function via_gh()
		local out = vim.fn.systemlist({
			"gh", "repo", "view", "--json", "nameWithOwner", "-q",
			".nameWithOwner",
		})
		if vim.v.shell_error == 0 and out and out[1] then
			local trimmed = vim.trim(out[1])
			if trimmed ~= "" then
				return slugify(trimmed)
			end
		end
		return nil
	end

	return via_gh() or via_git() or "unknown"
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
