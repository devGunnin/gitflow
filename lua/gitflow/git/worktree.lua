local git = require("gitflow.git")

---@class GitflowWorktreeEntry
---@field path string
---@field sha string
---@field short_sha string
---@field branch string|nil
---@field is_bare boolean
---@field is_main boolean

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

---Parse `git worktree list --porcelain` output into structured entries.
---@param output string
---@return GitflowWorktreeEntry[]
function M.parse(output)
	local entries = {}
	local current = nil

	for line in output:gmatch("[^\n]+") do
		if line:match("^worktree ") then
			if current then
				entries[#entries + 1] = current
			end
			current = {
				path = line:match("^worktree (.+)$"),
				sha = "",
				short_sha = "",
				branch = nil,
				is_bare = false,
				is_main = false,
			}
		elseif current then
			local sha = line:match("^HEAD (.+)$")
			if sha then
				current.sha = sha
				current.short_sha = sha:sub(1, 7)
			end
			local branch = line:match("^branch (.+)$")
			if branch then
				current.branch = branch:gsub("^refs/heads/", "")
			end
			if line == "bare" then
				current.is_bare = true
			end
		end
	end

	if current then
		entries[#entries + 1] = current
	end

	-- Mark the first entry as the main worktree
	if #entries > 0 then
		entries[1].is_main = true
	end

	return entries
end

---List all worktrees asynchronously.
---@param opts table|nil
---@param cb fun(err: string|nil, entries: GitflowWorktreeEntry[]|nil)
function M.list(opts, cb)
	git.git(
		{ "worktree", "list", "--porcelain" },
		opts or {},
		function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "worktree list"))
				return
			end
			local entries = M.parse(result.stdout or "")
			cb(nil, entries)
		end
	)
end

---Add a new worktree.
---@param path string  filesystem path for the new worktree
---@param branch string  branch to check out
---@param cb fun(err: string|nil, result: GitflowGitResult|nil)
function M.add(path, branch, cb)
	if not path or path == "" then
		error(
			"gitflow worktree error: add() requires a path", 2
		)
	end
	if not branch or branch == "" then
		error(
			"gitflow worktree error: add() requires a branch", 2
		)
	end

	git.git(
		{ "worktree", "add", path, branch },
		{},
		function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "worktree add"))
				return
			end
			cb(nil, result)
		end
	)
end

---Remove a worktree.
---@param path string  filesystem path of the worktree to remove
---@param cb fun(err: string|nil, result: GitflowGitResult|nil)
function M.remove(path, cb)
	if not path or path == "" then
		error(
			"gitflow worktree error: remove() requires a path",
			2
		)
	end

	git.git(
		{ "worktree", "remove", path },
		{},
		function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "worktree remove"))
				return
			end
			cb(nil, result)
		end
	)
end

return M
