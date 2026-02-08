local gh = require("gitflow.gh")

local M = {}

local REPO_FIELDS = table.concat({
	"name",
	"nameWithOwner",
	"url",
	"description",
	"isPrivate",
	"defaultBranchRef",
}, ",")

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = gh.output(result)
	if output == "" then
		return ("gh repo %s failed"):format(action)
	end
	return ("gh repo %s failed: %s"):format(action, output)
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, repo: table|nil, result: GitflowGitResult)
function M.info(opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.json({ "repo", "view", "--json", REPO_FIELDS }, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data, result)
	end)
end

---@param repo string
---@param target string|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.clone(repo, target, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local repo_name = vim.trim(tostring(repo or ""))
	if repo_name == "" then
		error("gitflow gh repo error: clone(repo, target, opts, cb) requires repo", 2)
	end

	local args = { "repo", "clone", repo_name }
	if target and vim.trim(tostring(target)) ~= "" then
		args[#args + 1] = tostring(target)
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "clone"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param input table|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.fork(input, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local options = input or {}
	local args = { "repo", "fork" }
	if options.clone then
		args[#args + 1] = "--clone"
	end
	if options.remote then
		args[#args + 1] = "--remote"
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "fork"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
