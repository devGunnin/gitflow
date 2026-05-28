local git = require("gitflow.git")

---@class GitflowReflogEntry
---@field sha string
---@field short_sha string
---@field selector string
---@field action string
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

---Parse reflog output in tab-delimited format:
---full_sha<TAB>selector<TAB>description
---@param output string
---@return GitflowReflogEntry[]
function M.parse(output)
	local entries = {}
	for _, line in ipairs(split_lines(output)) do
		local sha, selector, desc =
			line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
		if sha then
			local short = sha:sub(1, 7)
			local action = desc:match("^(%S+):") or ""
			entries[#entries + 1] = {
				sha = sha,
				short_sha = short,
				selector = selector,
				action = action,
				description = desc,
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

---List recent reflog entries.
---@param opts table|nil  { count?: integer }
---@param cb fun(err: string|nil, entries: GitflowReflogEntry[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	local options = opts or {}
	local count = options.count or 50
	git.git({
		"reflog", "show",
		("--format=%%H\t%%gd\t%%gs"):format(),
		"-n", tostring(count),
	}, options, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(result, "reflog show"),
				nil,
				result
			)
			return
		end
		cb(nil, M.parse(result.stdout or ""), result)
	end)
end

---Checkout to a specific reflog entry.
---@param sha string
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.checkout(sha, opts, cb)
	if not sha or vim.trim(sha) == "" then
		error("gitflow reflog error: checkout requires sha", 2)
	end
	git.git({ "checkout", sha }, opts or {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "checkout"), result)
			return
		end
		cb(nil, result)
	end)
end

---Reset to a specific reflog entry.
---@param sha string
---@param mode string  "soft"|"mixed"|"hard"
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.reset(sha, mode, opts, cb)
	if not sha or vim.trim(sha) == "" then
		error("gitflow reflog error: reset requires sha", 2)
	end
	local flag = "--" .. (mode or "mixed")
	git.git({ "reset", flag, sha }, opts or {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "reset"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
