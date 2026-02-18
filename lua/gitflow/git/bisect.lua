local git = require("gitflow.git")
local git_log = require("gitflow.git.log")

---@class GitflowBisectEntry
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
---@param cb fun(err: string|nil, entries: GitflowBisectEntry[]|nil)
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

---Start a bisect session.
---@param bad_sha string  the known bad commit
---@param good_sha string  the known good commit
---@param cb fun(err: string|nil, output: string|nil)
function M.start(bad_sha, good_sha, cb)
	if not bad_sha or bad_sha == "" then
		error(
			"gitflow bisect error: start(bad_sha, good_sha, cb)"
				.. " requires a bad SHA",
			2
		)
	end
	if not good_sha or good_sha == "" then
		error(
			"gitflow bisect error: start(bad_sha, good_sha, cb)"
				.. " requires a good SHA",
			2
		)
	end

	git.git(
		{ "bisect", "start", bad_sha, good_sha },
		{},
		function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "bisect start"), nil)
				return
			end
			cb(nil, git.output(result))
		end
	)
end

---Mark the current bisect HEAD as good.
---@param cb fun(err: string|nil, output: string|nil)
function M.good(cb)
	git.git({ "bisect", "good" }, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "bisect good"), nil)
			return
		end
		cb(nil, git.output(result))
	end)
end

---Mark the current bisect HEAD as bad.
---@param cb fun(err: string|nil, output: string|nil)
function M.bad(cb)
	git.git({ "bisect", "bad" }, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "bisect bad"), nil)
			return
		end
		cb(nil, git.output(result))
	end)
end

---Reset (end) the bisect session.
---@param cb fun(err: string|nil, output: string|nil)
function M.reset_bisect(cb)
	git.git({ "bisect", "reset" }, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "bisect reset"), nil)
			return
		end
		cb(nil, git.output(result))
	end)
end

---Run bisect with an automated test script.
---@param script_path string  path to the test script
---@param cb fun(err: string|nil, output: string|nil)
function M.run(script_path, cb)
	if not script_path or script_path == "" then
		error(
			"gitflow bisect error: run(script_path, cb)"
				.. " requires a script path",
			2
		)
	end

	git.git(
		{ "bisect", "run", script_path },
		{},
		function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "bisect run"), nil)
				return
			end
			cb(nil, git.output(result))
		end
	)
end

---Check whether a bisect session is currently active.
---@param cb fun(is_active: boolean)
function M.is_bisecting(cb)
	git.git({ "bisect", "log" }, {}, function(result)
		cb(result.code == 0)
	end)
end

---Parse the first bad commit from bisect output.
---@param output string
---@return string|nil sha  the first bad commit SHA, or nil
function M.parse_first_bad(output)
	if not output then
		return nil
	end
	local sha = output:match(
		"(%x+) is the first bad commit"
	)
	return sha
end

return M
