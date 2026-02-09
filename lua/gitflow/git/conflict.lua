local git = require("gitflow.git")

---@alias GitflowConflictOperation "merge"|"rebase"|"cherry-pick"
---@alias GitflowConflictResolution "local"|"base"|"remote"|"edit"

---@class GitflowConflictHunk
---@field start_line integer
---@field middle_line integer
---@field end_line integer
---@field local_lines string[]
---@field base_lines string[]
---@field remote_lines string[]
---@field resolved boolean
---@field resolution GitflowConflictResolution|nil

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end

	local lines = vim.split(text, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines, #lines)
	end
	return lines
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

---@param path string
---@return string
local function normalize_path(path)
	local normalized = vim.trim(path or "")
	if normalized == "" then
		error("gitflow conflict error: path is required", 3)
	end
	return normalized
end

---@param value string
---@return string
local function lower(value)
	return (value or ""):lower()
end

---@param git_dir string
---@param leaf string
---@return string
local function join_git_path(git_dir, leaf)
	local abs = vim.fn.fnamemodify(git_dir, ":p")
	local cleaned = abs:gsub("/$", "")
	return ("%s/%s"):format(cleaned, leaf)
end

---@param path string
---@return boolean
local function file_exists(path)
	return vim.fn.filereadable(path) == 1
end

---@param path string
---@return boolean
local function dir_exists(path)
	return vim.fn.isdirectory(path) == 1
end

---@param output string
---@return boolean
local function output_mentions_missing_stage(output)
	local normalized = lower(output)
	if normalized:find("does not exist at stage", 1, true) then
		return true
	end
	if normalized:find("not at stage", 1, true) then
		return true
	end
	if normalized:find("path not in index", 1, true) then
		return true
	end
	if normalized:find("exists on disk, but not in", 1, true) then
		return true
	end
	return false
end

---@param lines string[]
---@return boolean
local function contains_binary(lines)
	for _, line in ipairs(lines) do
		if line:find("\0", 1, true) then
			return true
		end
	end
	return false
end

---@param lines string[]
---@return string[]
local function copy_lines(lines)
	local copied = {}
	for i, line in ipairs(lines) do
		copied[i] = tostring(line)
	end
	return copied
end

---@param output string
---@return string[]
function M.parse_conflicted_paths_from_output(output)
	local conflicts = {}
	local seen = {}

	for _, line in ipairs(vim.split(output or "", "\n", { trimempty = true })) do
		local path = line:match("^CONFLICT%s+%b()%:%s+.+%s+in%s+(.+)$")
		if path then
			local trimmed = vim.trim(path)
			if trimmed ~= "" and not seen[trimmed] then
				seen[trimmed] = true
				conflicts[#conflicts + 1] = trimmed
			end
		end
	end

	table.sort(conflicts)
	return conflicts
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

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, operation: GitflowConflictOperation|nil, result: GitflowGitResult)
function M.active_operation(opts, cb)
	git.git({ "rev-parse", "--git-dir" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "rev-parse --git-dir"), nil, result)
			return
		end

		local git_dir = vim.trim(result.stdout or "")
		if git_dir == "" then
			cb("Could not resolve .git directory", nil, result)
			return
		end

		local operation = nil
		if file_exists(join_git_path(git_dir, "MERGE_HEAD")) then
			operation = "merge"
		elseif dir_exists(join_git_path(git_dir, "rebase-merge"))
			or dir_exists(join_git_path(git_dir, "rebase-apply"))
			or file_exists(join_git_path(git_dir, "REBASE_HEAD"))
		then
			operation = "rebase"
		elseif file_exists(join_git_path(git_dir, "CHERRY_PICK_HEAD")) then
			operation = "cherry-pick"
		end

		cb(nil, operation, result)
	end)
end

---@param lines string[]
---@return GitflowConflictHunk[]
function M.parse_markers(lines)
	local hunks = {}
	local active = nil

	for line_no, line in ipairs(lines) do
		if active == nil then
			if vim.startswith(line, "<<<<<<<") then
				active = {
					start_line = line_no,
					middle_line = 0,
					end_line = 0,
					local_lines = {},
					base_lines = {},
					remote_lines = {},
					resolved = false,
					resolution = nil,
					_section = "local",
				}
			end
		elseif vim.startswith(line, "|||||||") and active._section == "local" then
			active._section = "base"
		elseif vim.startswith(line, "=======")
			and (active._section == "local" or active._section == "base")
		then
			active.middle_line = line_no
			active._section = "remote"
		elseif vim.startswith(line, ">>>>>>>") and active._section == "remote" then
			active.end_line = line_no
			active._section = nil
			hunks[#hunks + 1] = active
			active = nil
		elseif active._section == "local" then
			active.local_lines[#active.local_lines + 1] = line
		elseif active._section == "base" then
			active.base_lines[#active.base_lines + 1] = line
		elseif active._section == "remote" then
			active.remote_lines[#active.remote_lines + 1] = line
		end
	end

	for _, hunk in ipairs(hunks) do
		hunk._section = nil
	end
	return hunks
end

---@param path string
---@return string|nil, string[]|nil
local function read_file(path)
	local normalized = normalize_path(path)
	if vim.fn.filereadable(normalized) ~= 1 then
		return nil, {}
	end

	local ok, lines = pcall(vim.fn.readfile, normalized, "b")
	if not ok or type(lines) ~= "table" then
		return ("Could not read conflicted file '%s'"):format(normalized), nil
	end
	if contains_binary(lines) then
		return ("File '%s' appears to be binary and cannot be parsed"):format(normalized), nil
	end
	return nil, lines
end

---@param path string
---@return string|nil, GitflowConflictHunk[]
function M.read_markers(path)
	local err, lines = read_file(path)
	if err then
		return err, {}
	end
	return nil, M.parse_markers(lines or {})
end

---@param path string
---@param stage "local"|"base"|"remote"|1|2|3
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, lines: string[]|nil, result: GitflowGitResult)
function M.get_version(path, stage, opts, cb)
	local normalized = normalize_path(path)
	local stage_index = nil

	if stage == "base" or stage == 1 then
		stage_index = 1
	elseif stage == "local" or stage == 2 then
		stage_index = 2
	elseif stage == "remote" or stage == 3 then
		stage_index = 3
	else
		error("gitflow conflict error: stage must be base/local/remote or 1/2/3", 2)
	end

	git.git({ "show", (":%d:%s"):format(stage_index, normalized) }, opts, function(result)
		if result.code ~= 0 then
			local output = git.output(result)
			if output_mentions_missing_stage(output) then
				cb(nil, {}, result)
				return
			end
			cb(
				error_from_result(result, ("show :%d:%s"):format(stage_index, normalized)),
				nil,
				result
			)
			return
		end

		cb(nil, split_lines(result.stdout or ""), result)
	end)
end

---@param path string
---@param side "ours"|"theirs"
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.checkout(path, side, opts, cb)
	local normalized = normalize_path(path)
	if side ~= "ours" and side ~= "theirs" then
		error("gitflow conflict error: checkout side must be 'ours' or 'theirs'", 2)
	end

	git.git({ "checkout", ("--%s"):format(side), "--", normalized }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, ("checkout --%s -- %s"):format(side, normalized)), result)
			return
		end
		cb(nil, result)
	end)
end

---@param path string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.stage(path, opts, cb)
	local normalized = normalize_path(path)
	git.git({ "add", "--", normalized }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, ("add -- %s"):format(normalized)), result)
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
		local trimmed = vim.trim(path or "")
		if trimmed ~= "" then
			args[#args + 1] = trimmed
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

---@param path string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.mark_resolved(path, opts, cb)
	M.stage(path, opts, cb)
end

---@param hunk GitflowConflictHunk
---@param choice GitflowConflictResolution
---@param edited_lines string[]|string|nil
---@return string[]|nil, string|nil
local function resolve_replacement(hunk, choice, edited_lines)
	if choice == "local" then
		return copy_lines(hunk.local_lines), nil
	end
	if choice == "base" then
		return copy_lines(hunk.base_lines), nil
	end
	if choice == "remote" then
		return copy_lines(hunk.remote_lines), nil
	end
	if choice ~= "edit" then
		return nil, "Resolution choice must be local, base, remote, or edit"
	end

	if edited_lines == nil then
		return nil, "Edited lines are required for manual conflict resolution"
	end
	if type(edited_lines) == "string" then
		return split_lines(edited_lines), nil
	end
	if type(edited_lines) ~= "table" then
		return nil, "Edited lines must be a string or string[]"
	end
	return copy_lines(edited_lines), nil
end

---@param lines string[]
---@param hunk GitflowConflictHunk
---@param replacement string[]
---@return string[]
local function replace_hunk(lines, hunk, replacement)
	local result = {}
	local cursor = 1

	while cursor < hunk.start_line do
		result[#result + 1] = lines[cursor]
		cursor = cursor + 1
	end

	for _, line in ipairs(replacement) do
		result[#result + 1] = line
	end

	cursor = hunk.end_line + 1
	while cursor <= #lines do
		result[#result + 1] = lines[cursor]
		cursor = cursor + 1
	end

	return result
end

---@param path string
---@param lines string[]
---@return string|nil
local function write_file(path, lines)
	local normalized = normalize_path(path)
	local ok, err = pcall(vim.fn.writefile, lines, normalized, "b")
	if not ok then
		return ("Could not write conflicted file '%s': %s"):format(normalized, tostring(err))
	end
	return nil
end

---@param path string
---@param hunk_index integer
---@param choice GitflowConflictResolution|"ours"|"theirs"
---@param edited_lines string[]|string|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, hunks: GitflowConflictHunk[]|nil, selected: table|nil)
function M.resolve_hunk(path, hunk_index, choice, edited_lines, opts, cb)
	local normalized = normalize_path(path)
	if type(hunk_index) ~= "number" or hunk_index < 1 then
		error("gitflow conflict error: hunk_index must be a positive integer", 2)
	end

	local resolution = choice
	if choice == "ours" then
		resolution = "local"
	elseif choice == "theirs" then
		resolution = "remote"
	end

	local err, lines = read_file(normalized)
	if err then
		cb(err, nil, nil)
		return
	end

	local hunks = M.parse_markers(lines or {})
	local selected = hunks[hunk_index]
	if not selected then
		cb(("Conflict hunk %d not found in '%s'"):format(hunk_index, normalized), nil, nil)
		return
	end

	local replacement, replacement_err = resolve_replacement(selected, resolution, edited_lines)
	if replacement_err then
		cb(replacement_err, nil, selected)
		return
	end

	local updated_lines = replace_hunk(lines or {}, selected, replacement or {})
	local write_err = write_file(normalized, updated_lines)
	if write_err then
		cb(write_err, nil, selected)
		return
	end

	local _, refreshed = M.read_markers(normalized)
	cb(nil, refreshed, selected)
end

---@param action "continue"|"abort"
---@param operation GitflowConflictOperation|nil
---@return string[]|nil, string|nil
local function action_args(operation, action)
	if operation == "merge" then
		return { "merge", ("--%s"):format(action) }, nil
	end
	if operation == "rebase" then
		return { "rebase", ("--%s"):format(action) }, nil
	end
	if operation == "cherry-pick" then
		return { "cherry-pick", ("--%s"):format(action) }, nil
	end
	return nil, ("No active operation to %s"):format(action)
end

---@param operation GitflowConflictOperation|nil
---@param action "continue"|"abort"
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, operation: string|nil, result: GitflowGitResult|nil)
local function run_known_operation_action(operation, action, opts, cb)
	local args, arg_err = action_args(operation, action)
	if arg_err then
		cb(arg_err, nil, nil)
		return
	end

	git.git(args or {}, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, table.concat(args or {}, " ")), operation, result)
			return
		end
		cb(nil, operation, result)
	end)
end

---@param action "continue"|"abort"
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, operation: string|nil, result: GitflowGitResult|nil)
local function run_operation_action(action, opts, cb)
	M.active_operation(opts, function(err, operation, active_result)
		if err then
			cb(err, nil, active_result)
			return
		end
		run_known_operation_action(operation, action, opts, cb)
	end)
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, operation: string|nil, result: GitflowGitResult|nil)
function M.continue_operation(opts, cb)
	run_operation_action("continue", opts, cb)
end

---@param operation GitflowConflictOperation|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, operation: string|nil, result: GitflowGitResult|nil)
function M.continue_operation_for(operation, opts, cb)
	run_known_operation_action(operation, "continue", opts, cb)
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, operation: string|nil, result: GitflowGitResult|nil)
function M.abort_operation(opts, cb)
	run_operation_action("abort", opts, cb)
end

return M
