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

---@class GitflowDiffFileMarker
---@field line integer  buffer line (1-based)
---@field path string
---@field status string  "A"|"D"|"R"|"M"

---@class GitflowDiffHunkMarker
---@field line integer  buffer line (1-based)
---@field path string|nil
---@field header string

---@class GitflowDiffLineContext
---@field path string|nil
---@field hunk string|nil
---@field diff_line integer|nil
---@field old_line integer|nil
---@field new_line integer|nil

---Parse a hunk header to extract old/new starting line numbers.
---@param header string
---@return integer|nil, integer|nil
function M.parse_hunk_header(header)
	local old_start = header:match("^@@ %-(%d+)")
	local new_start = header:match("^@@ %-%d+,?%d* %+(%d+)")
	return tonumber(old_start), tonumber(new_start)
end

---Detect file status from metadata lines following a diff --git header.
---@param line string
---@return string  "A"|"D"|"R"|"M"
local function detect_file_status(line)
	if line:match("^new file mode") then
		return "A"
	elseif line:match("^deleted file mode") then
		return "D"
	elseif line:match("^rename from")
		or line:match("^similarity index") then
		return "R"
	end
	return "M"
end

---Collect file markers, hunk markers, and per-line context from diff lines.
---@param lines string[]  raw diff lines
---@param start_line integer  buffer line offset (1-based) for the first diff line
---@return GitflowDiffFileMarker[], GitflowDiffHunkMarker[]
---@return table<integer, GitflowDiffLineContext>
function M.collect_markers(lines, start_line)
	local files = {}
	local hunks = {}
	local line_context = {}
	local current_file = nil
	local current_hunk = nil
	local old_line = nil
	local new_line = nil

	for index, line in ipairs(lines) do
		local line_no = start_line + index - 1
		local old_path, new_path =
			line:match("^diff %-%-git a/(.+) b/(.+)$")
		if old_path and new_path then
			current_file = new_path
			current_hunk = nil
			old_line = nil
			new_line = nil
			files[#files + 1] = {
				line = line_no,
				path = new_path,
				status = nil,
			}
		elseif current_file and #files > 0
			and not files[#files].status then
			local status = detect_file_status(line)
			if status ~= "M" then
				files[#files].status = status
			end
		end

		if vim.startswith(line, "@@") then
			current_hunk = line
			local os, ns = M.parse_hunk_header(line)
			old_line = os
			new_line = ns
			hunks[#hunks + 1] = {
				line = line_no,
				path = current_file,
				header = line,
			}
			line_context[line_no] = {
				path = current_file,
				hunk = current_hunk,
			}
		elseif old_line and new_line then
			if vim.startswith(line, "+") then
				line_context[line_no] = {
					path = current_file,
					hunk = current_hunk,
					diff_line = new_line,
					old_line = nil,
					new_line = new_line,
				}
				new_line = new_line + 1
			elseif vim.startswith(line, "-") then
				line_context[line_no] = {
					path = current_file,
					hunk = current_hunk,
					diff_line = old_line,
					old_line = old_line,
					new_line = nil,
				}
				old_line = old_line + 1
			elseif vim.startswith(line, " ") then
				line_context[line_no] = {
					path = current_file,
					hunk = current_hunk,
					diff_line = new_line,
					old_line = old_line,
					new_line = new_line,
				}
				old_line = old_line + 1
				new_line = new_line + 1
			else
				line_context[line_no] = {
					path = current_file,
					hunk = current_hunk,
				}
			end
		else
			line_context[line_no] = {
				path = current_file,
				hunk = current_hunk,
			}
		end
	end

	for _, f in ipairs(files) do
		if not f.status then
			f.status = "M"
		end
	end

	return files, hunks, line_context
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
