local git = require("gitflow.git")
local git_log = require("gitflow.git.log")
local git_branch = require("gitflow.git.branch")

---@class GitflowCherryPickEntry
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

---List local and remote branches, excluding the current branch and HEAD.
---@param opts table|nil
---@param cb fun(err: string|nil, branches: string[]|nil)
function M.list_branches(opts, cb)
	git_branch.current(opts, function(cur_err, current)
		if cur_err then
			cb(cur_err, nil)
			return
		end

		git_branch.list(opts, function(err, entries)
			if err then
				cb(err, nil)
				return
			end

			local branches = {}
			for _, entry in ipairs(entries or {}) do
				if not entry.is_current
					and entry.name ~= current
					and not entry.name:match("/HEAD$")
				then
					branches[#branches + 1] = entry.name
				end
			end
			cb(nil, branches)
		end)
	end)
end

---Parse branch names from raw git output.
---@param output string
---@param current_branch string|nil
---@return string[]
function M.parse_branches(output, current_branch)
	local branches = {}
	for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
		local name = vim.trim(line)
		name = name:gsub("^%* ", "")
		if name ~= ""
			and name ~= current_branch
			and not name:match("/HEAD$")
			and not name:match("^%(HEAD")
		then
			branches[#branches + 1] = name
		end
	end
	return branches
end

---List commits on source_branch that are NOT on the current branch.
---Uses `git log --cherry-pick --right-only --no-merges`.
---@param source_branch string
---@param opts table|nil  { count?: integer }
---@param cb fun(err: string|nil, entries: GitflowCherryPickEntry[]|nil)
function M.list_unique_commits(source_branch, opts, cb)
	local options = opts or {}
	local count = tonumber(options.count) or 50
	local args = {
		"log",
		"--cherry-pick",
		"--right-only",
		"--no-merges",
		("--pretty=format:%%H%%x09%%h %%s"):format(),
	}
	if count > 0 then
		args[#args + 1] = ("-n%d"):format(count)
	end
	args[#args + 1] = ("HEAD...%s"):format(source_branch)

	git.git(args, opts or {}, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(result, "log --cherry-pick"),
				nil
			)
			return
		end
		cb(nil, M.parse_commits(result.stdout or ""))
	end)
end

---Parse commit log output into structured entries.
---@param output string
---@return GitflowCherryPickEntry[]
function M.parse_commits(output)
	local entries = {}
	for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
		local sha, summary = line:match("^([0-9a-fA-F]+)\t(.*)$")
		if sha then
			entries[#entries + 1] = {
				sha = sha,
				short_sha = sha:sub(1, 7),
				summary = summary,
			}
		end
	end
	return entries
end

---Execute git cherry-pick for a single commit.
---@param sha string
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.cherry_pick(sha, cb)
	if not sha or sha == "" then
		error(
			"gitflow cherry-pick error: cherry_pick(sha, cb)"
				.. " requires a SHA",
			2
		)
	end

	git.git({ "cherry-pick", sha }, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "cherry-pick"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
