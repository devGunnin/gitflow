local git = require("gitflow.git")

---@class GitflowBranchEntry
---@field name string
---@field ref string
---@field is_remote boolean
---@field remote string|nil
---@field short_name string
---@field is_current boolean

local M = {}
local run_branch_cmd

---@param output string
---@return boolean
local function output_mentions_no_upstream(output)
	local normalized = (output or ""):lower()
	if normalized:find("no upstream configured", 1, true) then
		return true
	end
	if normalized:find("no upstream", 1, true) then
		return true
	end
	if normalized:find("does not point to a branch", 1, true) then
		return true
	end
	if normalized:find("has no upstream branch", 1, true) then
		return true
	end
	return false
end

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

---@param result GitflowGitResult
---@return GitflowBranchEntry[]
function M.parse_list(result)
	local entries = {}
	for _, line in ipairs(split_lines(result.stdout or "")) do
		local head_marker, name, ref = line:match("^([* ]?)\t([^\t]+)\t(.+)$")
		if name and ref and not name:match("/HEAD$") then
			local is_remote = vim.startswith(ref, "refs/remotes/")
			local remote = nil
			local short_name = name
			if is_remote then
				remote, short_name = name:match("^([^/]+)/(.+)$")
				if not remote or not short_name then
					remote = nil
					short_name = name
				end
			end

			entries[#entries + 1] = {
				name = name,
				ref = ref,
				is_remote = is_remote,
				remote = remote,
				short_name = short_name,
				is_current = head_marker == "*",
			}
		end
	end

	table.sort(entries, function(a, b)
		if a.is_remote ~= b.is_remote then
			return not a.is_remote
		end
		return a.name < b.name
	end)

	return entries
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, entries: GitflowBranchEntry[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	git.git({
		"for-each-ref",
		"--format=%(HEAD)%09%(refname:short)%09%(refname)",
		"refs/heads",
		"refs/remotes",
	}, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "for-each-ref"), nil, result)
			return
		end
		cb(nil, M.parse_list(result), result)
	end)
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, branch: string|nil, result: GitflowGitResult)
function M.current(opts, cb)
	git.git({ "rev-parse", "--abbrev-ref", "HEAD" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "rev-parse --abbrev-ref HEAD"), nil, result)
			return
		end

		local branch = vim.trim(result.stdout or "")
		if branch == "" then
			cb("Could not determine current branch", nil, result)
			return
		end
		if branch == "HEAD" then
			cb(nil, "HEAD (detached)", result)
			return
		end
		cb(nil, branch, result)
	end)
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, ahead: boolean|nil, count: integer|nil, result: GitflowGitResult)
function M.is_ahead_of_upstream(opts, cb)
	git.git({ "rev-parse", "--abbrev-ref", "HEAD" }, opts, function(head_result)
		if head_result.code ~= 0 then
			cb(error_from_result(head_result, "rev-parse --abbrev-ref HEAD"), nil, nil, head_result)
			return
		end

		local branch = vim.trim(head_result.stdout or "")
		if branch == "" or branch == "HEAD" then
			cb(nil, false, 0, head_result)
			return
		end

		git.git({
			"rev-parse",
			"--abbrev-ref",
			"--symbolic-full-name",
			"@{upstream}",
		}, opts, function(upstream_result)
			if upstream_result.code ~= 0 then
				local output = git.output(upstream_result)
				if output_mentions_no_upstream(output) then
					cb(nil, false, 0, upstream_result)
					return
				end
				cb(error_from_result(upstream_result, "rev-parse @{upstream}"), nil, nil, upstream_result)
				return
			end

			git.git({ "rev-list", "--count", "@{upstream}..HEAD" }, opts, function(count_result)
				if count_result.code ~= 0 then
					cb(
						error_from_result(count_result, "rev-list --count @{upstream}..HEAD"),
						nil,
						nil,
						count_result
					)
					return
				end

				local trimmed = vim.trim(count_result.stdout or "")
				local count = tonumber(trimmed)
				if count == nil then
					cb(("Could not parse ahead count from '%s'"):format(trimmed), nil, nil, count_result)
					return
				end

				cb(nil, count > 0, count, count_result)
			end)
		end)
	end)
end

---@param entries GitflowBranchEntry[]
---@return GitflowBranchEntry[], GitflowBranchEntry[]
function M.partition(entries)
	local local_entries = {}
	local remote_entries = {}
	for _, entry in ipairs(entries) do
		if entry.is_remote then
			remote_entries[#remote_entries + 1] = entry
		else
			local_entries[#local_entries + 1] = entry
		end
	end
	return local_entries, remote_entries
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, merged: table<string, boolean>|nil, result: GitflowGitResult)
function M.list_merged(opts, cb)
	git.git({ "branch", "--format=%(refname:short)", "--merged" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "branch --merged"), nil, result)
			return
		end

		local merged = {}
		for _, line in ipairs(split_lines(result.stdout or "")) do
			merged[vim.trim(line)] = true
		end
		cb(nil, merged, result)
	end)
end

---@param remote string|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.fetch(remote, opts, cb)
	local trimmed_remote = remote and vim.trim(remote) or nil
	local args = { "fetch", "--prune" }
	local action = "fetch --prune"

	if trimmed_remote and trimmed_remote ~= "" then
		args[#args + 1] = trimmed_remote
		action = ("%s %s"):format(action, trimmed_remote)
	else
		args[#args + 1] = "--all"
		action = action .. " --all"
	end

	run_branch_cmd(args, opts, action, cb)
end

---@param cmd string[]
---@param opts GitflowGitRunOpts|nil
---@param action string
---@param cb fun(err: string|nil, result: GitflowGitResult)
run_branch_cmd = function(cmd, opts, action, cb)
	git.git(cmd, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, action), result)
			return
		end
		cb(nil, result)
	end)
end

---@param name string
---@param base string|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.create(name, base, opts, cb)
	if not name or vim.trim(name) == "" then
		error("gitflow branch error: create(name, base, opts, cb) requires name", 2)
	end

	local switch_args = { "switch", "-c", name }
	local checkout_args = { "checkout", "-b", name }
	if base and vim.trim(base) ~= "" then
		switch_args[#switch_args + 1] = base
		checkout_args[#checkout_args + 1] = base
	end

	git.git(switch_args, opts, function(result)
		if result.code == 0 then
			cb(nil, result)
			return
		end

		run_branch_cmd(checkout_args, opts, "checkout -b", cb)
	end)
end

---@param entry GitflowBranchEntry
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.switch(entry, opts, cb)
	if not entry or not entry.name then
		error("gitflow branch error: switch(entry, opts, cb) requires entry", 2)
	end

	if not entry.is_remote then
		git.git({ "switch", entry.name }, opts, function(result)
			if result.code == 0 then
				cb(nil, result)
				return
			end
			run_branch_cmd({ "checkout", entry.name }, opts, "checkout", cb)
		end)
		return
	end

	if entry.short_name == "HEAD" then
		cb("Cannot switch to symbolic remote HEAD", {
			code = 1,
			signal = 0,
			stdout = "",
			stderr = "symbolic remote HEAD",
			cmd = { "git", "switch", entry.name },
		})
		return
	end

	git.git({ "switch", entry.short_name }, opts, function(local_result)
		if local_result.code == 0 then
			cb(nil, local_result)
			return
		end

		git.git({ "switch", "--track", entry.name }, opts, function(track_result)
			if track_result.code == 0 then
				cb(nil, track_result)
				return
			end

			run_branch_cmd({ "checkout", "-t", entry.name }, opts, "checkout -t", cb)
		end)
	end)
end

---@param name string
---@param force boolean
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.delete(name, force, opts, cb)
	if not name or vim.trim(name) == "" then
		error("gitflow branch error: delete(name, force, opts, cb) requires name", 2)
	end

	local flag = force and "-D" or "-d"
	run_branch_cmd({ "branch", flag, name }, opts, ("branch %s"):format(flag), cb)
end

---@param old_name string
---@param new_name string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.rename(old_name, new_name, opts, cb)
	if not old_name or vim.trim(old_name) == "" then
		error("gitflow branch error: rename(old_name, new_name, opts, cb) requires old_name", 2)
	end
	if not new_name or vim.trim(new_name) == "" then
		error("gitflow branch error: rename(old_name, new_name, opts, cb) requires new_name", 2)
	end

	run_branch_cmd({ "branch", "-m", old_name, new_name }, opts, "branch -m", cb)
end

---@class GitflowGraphLine
---@field graph string  graph drawing characters (e.g. "* ", "| ", "|/")
---@field hash string|nil  short commit hash
---@field decoration string|nil  branch/tag decoration text
---@field subject string|nil  commit subject
---@field raw string  full raw line

---@param output string
---@param current_branch string|nil
---@return GitflowGraphLine[]
function M.parse_graph(output, current_branch)
	local entries = {}
	for _, raw_line in ipairs(split_lines(output)) do
		local graph_part = ""
		local hash = nil
		local decoration = nil
		local subject = nil

		-- Keep connector-only rows entirely in the flow column.
		-- Without this guard, the split regex can backtrack and leak the last
		-- connector glyph into subject text.
		if raw_line:match("^[%s%*|/\\_%.]+$") then
			graph_part = raw_line
		else
			-- Split graph prefix from commit data.
			-- Graph chars: *, |, /, \, _, space, and box-drawing variants.
			local g, rest = raw_line:match("^([%s%*|/\\_%.]+)(%S.*)$")
			if g and rest then
				graph_part = g
				-- Try to match: <hash> (<decorations>) <subject>
				local h, d, s = rest:match("^(%x+)%s+%((.-)%)%s+(.*)$")
				if h then
					hash = h
					decoration = d
					subject = s
				else
					-- Try: <hash> <subject>
					h, s = rest:match("^(%x+)%s+(.*)$")
					if h then
						hash = h
						subject = s
					else
						-- Bare hash or continuation
						h = rest:match("^(%x+)$")
						if h then
							hash = h
						else
							subject = rest
						end
					end
				end
			else
				-- Entire line is graph drawing (e.g. "| |", "| * ")
				graph_part = raw_line
			end
		end

		entries[#entries + 1] = {
			graph = graph_part,
			hash = hash,
			decoration = decoration,
			subject = subject,
			raw = raw_line,
		}
	end
	return entries
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, lines: GitflowGraphLine[]|nil,
---  current: string|nil, result: GitflowGitResult)
function M.graph(opts, cb)
	M.current(opts, function(cur_err, current_branch)
		if cur_err then
			current_branch = nil
		end

		git.git({
			"log", "--all", "--graph", "--oneline",
			"--decorate=short", "-n100",
		}, opts, function(result)
			if result.code ~= 0 then
				cb(error_from_result(result, "log --graph"), nil, nil, result)
				return
			end
			local parsed = M.parse_graph(result.stdout or "", current_branch)
			cb(nil, parsed, current_branch, result)
		end)
	end)
end

return M
