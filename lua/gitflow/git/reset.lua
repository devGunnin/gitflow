local git = require("gitflow.git")
local git_log = require("gitflow.git.log")

---@class GitflowResetEntry
---@field sha string
---@field short_sha string
---@field summary string

local M = {}

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = git.output(result)
	if output == "" then
		return ("git %s failed"):format(action)
	end
	return ("git %s failed: %s"):format(action, output)
end

---List recent commits on the current branch.
---Delegates to git log with a tab-separated full-SHA + summary format.
---@param opts table|nil  { count?: integer }
---@param cb fun(err: string|nil, entries: GitflowResetEntry[]|nil)
function M.list_commits(opts, cb)
	local options = opts or {}
	local count = tonumber(options.count) or 50
	git_log.list({ count = count }, function(err, entries)
		if err then
			cb(err, nil)
			return
		end
		cb(nil, entries)
	end)
end

---Find the merge-base commit between HEAD and the default branch.
---Tries main, then master, then origin/HEAD.
---@param opts table|nil
---@param cb fun(err: string|nil, sha: string|nil)
function M.find_merge_base(opts, cb)
	local candidates = { "main", "master", "origin/HEAD" }

	local function try_next(index)
		if index > #candidates then
			cb(nil, nil)
			return
		end

		local ref = candidates[index]
		git.git({ "merge-base", "HEAD", ref }, opts or {}, function(result)
			if result.code == 0 then
				local sha = vim.trim(result.stdout or "")
				if sha ~= "" then
					cb(nil, sha)
					return
				end
			end
			try_next(index + 1)
		end)
	end

	try_next(1)
end

---Execute git reset to a given commit.
---@param sha string  target commit SHA
---@param mode "soft"|"hard"  reset mode
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.reset(sha, mode, cb)
	if not sha or sha == "" then
		error("gitflow reset error: reset(sha, mode, cb) requires a SHA", 2)
	end
	if mode ~= "soft" and mode ~= "hard" then
		error(
			"gitflow reset error: mode must be 'soft' or 'hard'", 2
		)
	end

	local flag = ("--" .. mode)
	git.git({ "reset", flag, sha }, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "reset"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
