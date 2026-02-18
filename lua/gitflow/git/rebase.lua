local git = require("gitflow.git")

---@class GitflowRebaseEntry
---@field action "pick"|"reword"|"edit"|"squash"|"fixup"|"drop"
---@field sha string
---@field short_sha string
---@field subject string

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

---Parse commit log output into rebase todo entries.
---Each entry defaults to action "pick".
---@param output string
---@return GitflowRebaseEntry[]
function M.parse_commits(output)
	local entries = {}
	for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
		local sha, subject = line:match("^([0-9a-fA-F]+)\t(.*)$")
		if sha then
			entries[#entries + 1] = {
				action = "pick",
				sha = sha,
				short_sha = sha:sub(1, 7),
				subject = subject,
			}
		end
	end
	return entries
end

---Fetch commits eligible for interactive rebase (base_ref..HEAD).
---Results are in reverse chronological order from git log;
---the panel reverses them to show oldest-first (rebase todo order).
---@param base_ref string
---@param opts table|nil  { count?: integer }
---@param cb fun(err: string|nil, entries: GitflowRebaseEntry[]|nil)
function M.list_commits(base_ref, opts, cb)
	local options = opts or {}
	local count = tonumber(options.count) or 50
	local args = {
		"log",
		"--pretty=format:%H\t%s",
		"--reverse",
	}
	if count > 0 then
		args[#args + 1] = ("-n%d"):format(count)
	end
	args[#args + 1] = ("%s..HEAD"):format(base_ref)

	git.git(args, opts or {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "log"), nil)
			return
		end
		cb(nil, M.parse_commits(result.stdout or ""))
	end)
end

---Build the rebase todo file content from entries.
---@param entries GitflowRebaseEntry[]
---@return string
function M.build_todo(entries)
	local lines = {}
	for _, entry in ipairs(entries) do
		lines[#lines + 1] = ("%s %s %s"):format(
			entry.action, entry.short_sha, entry.subject
		)
	end
	return table.concat(lines, "\n") .. "\n"
end

---Execute an interactive rebase using GIT_SEQUENCE_EDITOR override.
---Writes the todo content to a temp file and uses a shell command
---to replace the editor output.
---@param base_ref string
---@param entries GitflowRebaseEntry[]
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.start_interactive(base_ref, entries, opts, cb)
	local todo_content = M.build_todo(entries)
	local tmpfile = vim.fn.tempname()
	vim.fn.writefile(
		vim.split(todo_content, "\n", { trimempty = false }),
		tmpfile
	)

	local editor_cmd
	if vim.fn.has("win32") == 1 then
		editor_cmd = ("copy /Y %s"):format(
			vim.fn.shellescape(tmpfile)
		)
	else
		editor_cmd = ("cp %s"):format(
			vim.fn.shellescape(tmpfile)
		)
	end

	local env = { GIT_SEQUENCE_EDITOR = editor_cmd }
	local run_opts = vim.tbl_extend("force", opts or {}, { env = env })

	git.git(
		{ "rebase", "-i", base_ref },
		run_opts,
		function(result)
			pcall(vim.fn.delete, tmpfile)
			if result.code ~= 0 then
				cb(
					error_from_result(result, "rebase -i"),
					result
				)
				return
			end
			cb(nil, result)
		end
	)
end

---Abort an in-progress rebase.
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.abort(opts, cb)
	git.git({ "rebase", "--abort" }, opts or {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "rebase --abort"), result)
			return
		end
		cb(nil, result)
	end)
end

---Continue a paused rebase.
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.continue(opts, cb)
	git.git({ "rebase", "--continue" }, opts or {}, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(result, "rebase --continue"),
				result
			)
			return
		end
		cb(nil, result)
	end)
end

return M
