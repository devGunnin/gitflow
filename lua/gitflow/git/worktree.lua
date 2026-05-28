local git = require("gitflow.git")

---@class GitflowWorktreeEntry
---@field path string            absolute worktree path
---@field sha string             checked-out commit (empty for bare)
---@field branch string|nil      short branch name (nil if detached/bare)
---@field is_detached boolean
---@field is_bare boolean
---@field is_locked boolean
---@field lock_reason string|nil
---@field is_prunable boolean
---@field prune_reason string|nil

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

---Parse `git worktree list --porcelain` output.
---Records are separated by blank lines; each record has a `worktree <path>`
---line followed by attribute lines (HEAD, branch/detached/bare, locked,
---prunable).
---@param output string
---@return GitflowWorktreeEntry[]
function M.parse(output)
	if not output or output == "" then
		return {}
	end

	local entries = {}
	local current = nil

	local function flush()
		if current then
			entries[#entries + 1] = current
			current = nil
		end
	end

	for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
		if line == "" then
			flush()
		else
			local path = line:match("^worktree (.+)$")
			if path then
				flush()
				current = {
					path = path,
					sha = "",
					branch = nil,
					is_detached = false,
					is_bare = false,
					is_locked = false,
					lock_reason = nil,
					is_prunable = false,
					prune_reason = nil,
				}
			elseif current then
				local sha = line:match("^HEAD (%x+)$")
				local branch = line:match("^branch refs/heads/(.+)$")
				if sha then
					current.sha = sha
				elseif branch then
					current.branch = branch
				elseif line == "detached" then
					current.is_detached = true
				elseif line == "bare" then
					current.is_bare = true
				elseif line == "locked" or vim.startswith(line, "locked ") then
					current.is_locked = true
					local reason = line:match("^locked (.+)$")
					current.lock_reason = reason
				elseif vim.startswith(line, "prunable") then
					current.is_prunable = true
					current.prune_reason = line:match("^prunable (.+)$")
				end
			end
		end
	end
	flush()

	return entries
end

---List worktrees for the current repository.
---@param opts table|nil
---@param cb fun(err: string|nil, entries: GitflowWorktreeEntry[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	git.git(
		{ "worktree", "list", "--porcelain" },
		opts or {},
		function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "worktree list"), nil, result)
				return
			end
			cb(nil, M.parse(result.stdout or ""), result)
		end
	)
end

---Add a worktree.
---@param path string
---@param opts table|nil  { ref?: string, new_branch?: string, force?: boolean, detach?: boolean }
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.add(path, opts, cb)
	if not path or vim.trim(path) == "" then
		error("gitflow worktree error: add requires a path", 2)
	end
	local options = opts or {}
	local args = { "worktree", "add" }
	if options.force then
		args[#args + 1] = "--force"
	end
	if options.detach then
		args[#args + 1] = "--detach"
	end
	if options.new_branch and vim.trim(options.new_branch) ~= "" then
		args[#args + 1] = "-b"
		args[#args + 1] = options.new_branch
	end
	args[#args + 1] = path
	if options.ref and vim.trim(options.ref) ~= "" then
		args[#args + 1] = options.ref
	end

	git.git(args, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "worktree add"), result)
			return
		end
		cb(nil, result)
	end)
end

---Remove a worktree.
---@param path string
---@param opts table|nil  { force?: boolean }
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.remove(path, opts, cb)
	if not path or vim.trim(path) == "" then
		error("gitflow worktree error: remove requires a path", 2)
	end
	local options = opts or {}
	local args = { "worktree", "remove" }
	if options.force then
		args[#args + 1] = "--force"
	end
	args[#args + 1] = path

	git.git(args, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "worktree remove"), result)
			return
		end
		cb(nil, result)
	end)
end

---Prune stale worktree administrative entries.
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.prune(opts, cb)
	git.git({ "worktree", "prune" }, opts or {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "worktree prune"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
