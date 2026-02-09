local git = require("gitflow.git")

---@class GitflowConflictMarker
---@field start_line integer
---@field middle_line integer|nil
---@field end_line integer|nil

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = true })
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

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, paths: string[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	git.git({ "diff", "--name-only", "--diff-filter=U" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "diff --name-only --diff-filter=U"), nil, result)
			return
		end

		local paths = {}
		for _, line in ipairs(split_lines(result.stdout or "")) do
			local path = vim.trim(line)
			if path ~= "" then
				paths[#paths + 1] = path
			end
		end
		table.sort(paths)
		cb(nil, paths, result)
	end)
end

---@param path string
---@param side "ours"|"theirs"
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.checkout(path, side, opts, cb)
	if side ~= "ours" and side ~= "theirs" then
		error("gitflow conflict error: checkout side must be 'ours' or 'theirs'", 2)
	end
	if not path or vim.trim(path) == "" then
		error("gitflow conflict error: checkout(path, side, opts, cb) requires path", 2)
	end

	git.git({ "checkout", ("--%s"):format(side), "--", path }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, ("checkout --%s -- %s"):format(side, path)), result)
			return
		end
		cb(nil, result)
	end)
end

---@param path string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.stage(path, opts, cb)
	if not path or vim.trim(path) == "" then
		error("gitflow conflict error: stage(path, opts, cb) requires path", 2)
	end

	git.git({ "add", "--", path }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, ("add -- %s"):format(path)), result)
			return
		end
		cb(nil, result)
	end)
end

---@param paths string[]
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult|nil)
function M.stage_paths(paths, opts, cb)
	if type(paths) ~= "table" or #paths == 0 then
		cb(nil, nil)
		return
	end

	local args = { "add", "--" }
	for _, path in ipairs(paths) do
		if path and vim.trim(path) ~= "" then
			args[#args + 1] = path
		end
	end

	if #args == 2 then
		cb(nil, nil)
		return
	end

	git.git(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "add"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param lines string[]
---@return GitflowConflictMarker[]
function M.parse_markers(lines)
	local markers = {}
	local active = nil

	for line_no, line in ipairs(lines) do
		if vim.startswith(line, "<<<<<<<") then
			active = {
				start_line = line_no,
				middle_line = nil,
				end_line = nil,
			}
			markers[#markers + 1] = active
		elseif vim.startswith(line, "=======") and active and not active.middle_line then
			active.middle_line = line_no
		elseif vim.startswith(line, ">>>>>>>") and active then
			active.end_line = line_no
			active = nil
		end
	end

	return markers
end

---@param path string
---@return string|nil, GitflowConflictMarker[]
function M.read_markers(path)
	if not path or vim.trim(path) == "" then
		return "Path is required", {}
	end
	if vim.fn.filereadable(path) ~= 1 then
		return nil, {}
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return ("Could not read conflicted file '%s'"):format(path), {}
	end
	if type(lines) ~= "table" then
		return ("Could not read conflicted file '%s'"):format(path), {}
	end

	return nil, M.parse_markers(lines)
end

return M
