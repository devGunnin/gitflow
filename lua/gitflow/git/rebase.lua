local git = require("gitflow.git")

---@class GitflowRebaseEntry
---@field action "pick"|"reword"|"edit"|"squash"|"fixup"|"drop"
---@field sha string
---@field short_sha string
---@field subject string
---@field author string
---@field relative_time string
---@field message? string  new commit message for a `reword` action

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
		local sha, author, rel_time, subject =
			line:match("^([0-9a-fA-F]+)\t([^\t]*)\t([^\t]*)\t(.*)$")
		if sha then
			entries[#entries + 1] = {
				action = "pick",
				sha = sha,
				short_sha = sha:sub(1, 7),
				subject = subject,
				author = author,
				relative_time = rel_time,
			}
		end
	end
	return entries
end

---Fetch commits eligible for interactive rebase (base_ref..HEAD).
---Results are returned oldest-first to match rebase todo order.
---@param base_ref string
---@param opts table|nil  { count?: integer }
---@param cb fun(err: string|nil, entries: GitflowRebaseEntry[]|nil)
function M.list_commits(base_ref, opts, cb)
	local options = opts or {}
	local count = tonumber(options.count) or 50
	local args = {
		"log",
		"--pretty=format:%H\t%an\t%ar\t%s",
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
---A `reword` entry carrying a `message` is emitted as a `pick` followed by an
---`exec git commit --amend` so the new message is applied deterministically,
---without depending on an interactive $GIT_EDITOR.
---@param entries GitflowRebaseEntry[]
---@return string
function M.build_todo(entries)
	local lines = {}
	for _, entry in ipairs(entries) do
		local commit = entry.sha or entry.short_sha or ""
		if entry.action == "reword"
			and entry.message
			and entry.message ~= ""
		then
			lines[#lines + 1] = ("pick %s %s"):format(
				commit, entry.subject or ""
			)
			lines[#lines + 1] = ("exec git commit --amend -m %s"):format(
				vim.fn.shellescape(entry.message)
			)
		else
			lines[#lines + 1] = ("%s %s %s"):format(
				entry.action, commit, entry.subject or ""
			)
		end
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

	-- GIT_SEQUENCE_EDITOR feeds git our prepared todo list. GIT_EDITOR must
	-- also be neutralised: reword/squash/fixup otherwise launch $GIT_EDITOR
	-- (falling back to `vi`) to edit the commit message, which cannot run in
	-- the headless subprocess and leaves the rebase stuck mid-way. Pointing it
	-- at the shell no-op `:` reuses the prepared message non-interactively.
	local env = {
		GIT_SEQUENCE_EDITOR = editor_cmd,
		GIT_EDITOR = ":",
	}
	local existing_env = (opts or {}).env
	if type(existing_env) == "table" then
		env = vim.tbl_extend("force", existing_env, env)
	end
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

---Execute a plain (non-interactive) rebase of the current branch onto base_ref.
---Uses a non-interactive editor so a stopped rebase never blocks on $GIT_EDITOR.
---@param base_ref string
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.start(base_ref, opts, cb)
	git.git(
		{ "rebase", base_ref },
		git.with_noninteractive_editor(opts),
		function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "rebase"), result)
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
	-- Reuse the prepared commit message non-interactively so the continue
	-- never blocks on $GIT_EDITOR (e.g. `vi`) when finalizing a commit.
	git.git({ "rebase", "--continue" }, git.with_noninteractive_editor(opts), function(result)
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
