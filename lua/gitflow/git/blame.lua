local git = require("gitflow.git")

---@class GitflowBlameEntry
---@field sha string
---@field short_sha string
---@field author string
---@field date string
---@field line_number integer
---@field content string
---@field boundary boolean

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true })
end

--- Parse `git blame --line-porcelain` output into structured entries.
--- Each stanza starts with a SHA line: `<sha> <orig_line> <final_line> [group_lines]`
--- Followed by header fields (author, author-time, etc.) and a content line prefixed with \t.
---@param output string
---@return GitflowBlameEntry[]
function M.parse(output)
	local entries = {}
	local lines = split_lines(output)
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local sha, final_str = line:match("^(%x+)%s+%d+%s+(%d+)")
		if sha and final_str then
			local final_line = tonumber(final_str) or 0
			local short_sha = sha:sub(1, 7)
			local is_boundary = false
			local author = ""
			local author_time = ""
			local content_text = ""

			i = i + 1
			while i <= #lines do
				local header = lines[i]
				if header:sub(1, 1) == "\t" then
					content_text = header:sub(2)
					i = i + 1
					break
				end

				local author_val = header:match("^author (.+)$")
				if author_val then
					author = author_val
				end

				local time_val = header:match("^author%-time (.+)$")
				if time_val then
					author_time = time_val
				end

				if header == "boundary" then
					is_boundary = true
				end

				i = i + 1
			end

			local date_str = ""
			local epoch = tonumber(author_time)
			if epoch and epoch > 0 then
				date_str = os.date("%Y-%m-%d", epoch)
			end

			entries[#entries + 1] = {
				sha = sha,
				short_sha = short_sha,
				author = author,
				date = date_str,
				line_number = final_line,
				content = content_text,
				boundary = is_boundary,
			}
		else
			i = i + 1
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

---@class GitflowBlameOpts: GitflowGitRunOpts
---@field filepath? string

---@param opts GitflowBlameOpts|nil
---@param cb fun(err: string|nil, entries: GitflowBlameEntry[]|nil, result: GitflowGitResult)
function M.run(opts, cb)
	local options = opts or {}
	local args = { "blame", "--line-porcelain" }
	if options.filepath and options.filepath ~= "" then
		args[#args + 1] = "--"
		args[#args + 1] = options.filepath
	end

	git.git(args, options, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "blame"), nil, result)
			return
		end
		cb(nil, M.parse(result.stdout or ""), result)
	end)
end

return M
