local git = require("gitflow.git")

---@class GitflowLogEntry
---@field sha string
---@field short_sha string
---@field summary string

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = true })
end

---@param output string
---@return GitflowLogEntry[]
function M.parse(output)
	local entries = {}
	for _, line in ipairs(split_lines(output)) do
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

---@class GitflowLogListOpts: GitflowGitRunOpts
---@field count? integer
---@field format? string
---@field range? string
---@field reverse? boolean

---@param opts GitflowLogListOpts|nil
---@param cb fun(err: string|nil, entries: GitflowLogEntry[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	local options = opts or {}
	local count = tonumber(options.count) or 50
	local format = options.format or "%h %s"
	local args = { "log" }
	if options.reverse then
		args[#args + 1] = "--reverse"
	end
	if count > 0 then
		args[#args + 1] = ("-n%d"):format(count)
	end
	if options.range and options.range ~= "" then
		args[#args + 1] = options.range
	end
	args[#args + 1] = ("--pretty=format:%%H%%x09%s"):format(format)

	git.git(args, options, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "log"), nil, result)
			return
		end
		cb(nil, M.parse(result.stdout), result)
	end)
end

---@param commit_sha string
---@param opts table|nil
---@param cb fun(err: string|nil, output: string|nil, result: GitflowGitResult)
function M.show(commit_sha, opts, cb)
	local args = { "show", "--patch", commit_sha }
	git.git(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "show"), nil, result)
			return
		end
		cb(nil, result.stdout or "", result)
	end)
end

return M
