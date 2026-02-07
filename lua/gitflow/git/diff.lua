local git = require("gitflow.git")

---@class GitflowDiffHunk
---@field header string

---@class GitflowDiffFile
---@field header string
---@field old_path string|nil
---@field new_path string|nil
---@field hunks GitflowDiffHunk[]

---@class GitflowDiffParsed
---@field files GitflowDiffFile[]

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true })
end

---@param output string
---@return GitflowDiffParsed
function M.parse(output)
	local parsed = { files = {} }
	local current = nil

	for _, line in ipairs(split_lines(output)) do
		if vim.startswith(line, "diff --git ") then
			local old_path, new_path = line:match("^diff %-%-git a/(.+) b/(.+)$")
			current = {
				header = line,
				old_path = old_path,
				new_path = new_path,
				hunks = {},
			}
			parsed.files[#parsed.files + 1] = current
		elseif current and vim.startswith(line, "@@") then
			current.hunks[#current.hunks + 1] = { header = line }
		end
	end

	return parsed
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
---@return string[]
local function build_diff_args(opts)
	local options = opts or {}

	if options.commit then
		return { "show", "--patch", options.commit }
	end

	local args = { "diff" }
	if options.staged then
		args[#args + 1] = "--staged"
	end
	if options.path and options.path ~= "" then
		args[#args + 1] = "--"
		args[#args + 1] = options.path
	end
	return args
end

---@param opts table|nil
---@param cb fun(err: string|nil, output: string|nil, parsed: table|nil, result: GitflowGitResult)
function M.get(opts, cb)
	local args = build_diff_args(opts)
	git.git(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, table.concat(args, " ")), nil, nil, result)
			return
		end

		local output = result.stdout or ""
		cb(nil, output, M.parse(output), result)
	end)
end

return M
