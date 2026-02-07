local git = require("gitflow.git")

---@class GitflowStatusEntry
---@field raw string
---@field index_status string
---@field worktree_status string
---@field path string
---@field original_path string|nil
---@field staged boolean
---@field unstaged boolean
---@field untracked boolean
---@field ignored boolean

---@class GitflowStatusGroups
---@field staged GitflowStatusEntry[]
---@field unstaged GitflowStatusEntry[]
---@field untracked GitflowStatusEntry[]

---@class GitflowStatusRevertOpts: GitflowGitRunOpts
---@field untracked? boolean

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = true })
end

---@param pathspec string
---@return string, string|nil
local function parse_paths(pathspec)
	local source, destination = pathspec:match("^(.-) %-%> (.+)$")
	if source and destination then
		return destination, source
	end
	return pathspec, nil
end

---@param line string
---@return GitflowStatusEntry|nil
function M.parse_line(line)
	if line == "" then
		return nil
	end

	if vim.startswith(line, "?? ") then
		local path = line:sub(4)
		return {
			raw = line,
			index_status = "?",
			worktree_status = "?",
			path = path,
			original_path = nil,
			staged = false,
			unstaged = false,
			untracked = true,
			ignored = false,
		}
	end

	if vim.startswith(line, "!! ") then
		local path = line:sub(4)
		return {
			raw = line,
			index_status = "!",
			worktree_status = "!",
			path = path,
			original_path = nil,
			staged = false,
			unstaged = false,
			untracked = false,
			ignored = true,
		}
	end

	local xy, pathspec = line:match("^(..) (.+)$")
	if not xy or not pathspec then
		return nil
	end

	local index_status = xy:sub(1, 1)
	local worktree_status = xy:sub(2, 2)
	local path, original_path = parse_paths(pathspec)

	return {
		raw = line,
		index_status = index_status,
		worktree_status = worktree_status,
		path = path,
		original_path = original_path,
		staged = index_status ~= " ",
		unstaged = worktree_status ~= " ",
		untracked = false,
		ignored = false,
	}
end

---@param output string
---@return GitflowStatusEntry[]
function M.parse(output)
	local entries = {}
	for _, line in ipairs(split_lines(output)) do
		local entry = M.parse_line(line)
		if entry then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

---@param entries GitflowStatusEntry[]
---@return GitflowStatusGroups
function M.group(entries)
	local grouped = {
		staged = {},
		unstaged = {},
		untracked = {},
	}

	for _, entry in ipairs(entries) do
		if entry.untracked then
			grouped.untracked[#grouped.untracked + 1] = entry
		elseif not entry.ignored then
			if entry.staged then
				grouped.staged[#grouped.staged + 1] = entry
			end
			if entry.unstaged then
				grouped.unstaged[#grouped.unstaged + 1] = entry
			end
		end
	end

	table.sort(grouped.staged, function(a, b)
		return a.path < b.path
	end)
	table.sort(grouped.unstaged, function(a, b)
		return a.path < b.path
	end)
	table.sort(grouped.untracked, function(a, b)
		return a.path < b.path
	end)

	return grouped
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
---@param cb fun(err: string|nil, entries: table|nil, grouped: table|nil, result: GitflowGitResult)
function M.fetch(opts, cb)
	git.git({ "status", "--porcelain=v1" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "status"), nil, nil, result)
			return
		end

		local entries = M.parse(result.stdout)
		cb(nil, entries, M.group(entries), result)
	end)
end

---@param path string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.stage_file(path, opts, cb)
	git.git({ "add", "--", path }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "add"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.stage_all(opts, cb)
	git.git({ "add", "-A" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "add -A"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param path string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.unstage_file(path, opts, cb)
	git.git({ "restore", "--staged", "--", path }, opts, function(result)
		if result.code == 0 then
			cb(nil, result)
			return
		end

		git.git({ "reset", "HEAD", "--", path }, opts, function(fallback)
			if fallback.code ~= 0 then
				cb(error_from_result(fallback, "restore --staged"), fallback)
				return
			end
			cb(nil, fallback)
		end)
	end)
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.unstage_all(opts, cb)
	git.git({ "reset" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "reset"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param output string
---@return boolean
local function output_mentions_unknown_path(output)
	local normalized = output:lower()
	if normalized:find("did not match any file", 1, true) then
		return true
	end
	if normalized:find("pathspec", 1, true) then
		return true
	end
	return false
end

---@param path string
---@param opts GitflowStatusRevertOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.revert_file(path, opts, cb)
	local options = opts or {}
	git.git({ "restore", "--source=HEAD", "--staged", "--worktree", "--", path }, options, function(result)
		if result.code == 0 then
			cb(nil, result)
			return
		end

		git.git({ "reset", "HEAD", "--", path }, options, function()
			git.git({ "checkout", "--", path }, options, function(checkout_result)
				if checkout_result.code == 0 then
					cb(nil, checkout_result)
					return
				end

				local output = git.output(checkout_result)
				local should_clean = options.untracked or output_mentions_unknown_path(output)
				if not should_clean then
					cb(error_from_result(checkout_result, "checkout --"), checkout_result)
					return
				end

				git.git({ "clean", "-f", "--", path }, options, function(clean_result)
					if clean_result.code ~= 0 then
						cb(error_from_result(clean_result, "clean -f"), clean_result)
						return
					end
					cb(nil, clean_result)
				end)
			end)
		end)
	end)
end

---@param grouped GitflowStatusGroups
---@return integer
function M.count_staged(grouped)
	return #grouped.staged
end

return M
