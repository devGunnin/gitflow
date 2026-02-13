local git = require("gitflow.git")

---@class GitflowStashEntry
---@field ref string
---@field index integer
---@field description string

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
---@return GitflowStashEntry[]
function M.parse(output)
	local entries = {}
	for _, line in ipairs(split_lines(output)) do
		local ref, description = line:match("^(stash@{%d+}):%s*(.*)$")
		if ref then
			local index = tonumber(ref:match("^stash@{(%d+)}$")) or -1
			entries[#entries + 1] = {
				ref = ref,
				index = index,
				description = description,
			}
		end
	end
	return entries
end

---@param index integer|nil
---@return string|nil
local function index_to_ref(index)
	if index == nil then
		return nil
	end
	return ("stash@{%d}"):format(index)
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

---@param opts table|nil
---@param cb fun(err: string|nil, entries: GitflowStashEntry[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	git.git({ "stash", "list" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "stash list"), nil, result)
			return
		end
		cb(nil, M.parse(result.stdout), result)
	end)
end

---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.push(opts, cb)
	local options = opts or {}
	local args = { "stash", "push" }
	if options.message and options.message ~= "" then
		args[#args + 1] = "-m"
		args[#args + 1] = options.message
	end

	git.git(args, options, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "stash push"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.pop(opts, cb)
	local options = opts or {}
	local args = { "stash", "pop" }
	local ref = index_to_ref(options.index)
	if ref then
		args[#args + 1] = ref
	end

	git.git(args, options, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "stash pop"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param index integer
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.drop(index, opts, cb)
	local ref = index_to_ref(index)
	if not ref then
		error("gitflow stash error: drop(index, opts, cb) requires stash index", 2)
	end

	git.git({ "stash", "drop", ref }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "stash drop"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param output string
---@return boolean
function M.output_mentions_no_local_changes(output)
	return output:lower():find("no local changes to save", 1, true) ~= nil
end

return M
