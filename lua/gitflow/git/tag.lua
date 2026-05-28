local git = require("gitflow.git")

---@class GitflowTagEntry
---@field name string
---@field sha string
---@field subject string|nil
---@field is_annotated boolean

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

---Parse for-each-ref output for tags.
---Format: refname:short<TAB>objecttype<TAB>*objectname<TAB>subject
---@param output string
---@return GitflowTagEntry[]
function M.parse(output)
	if output == "" then
		return {}
	end
	local entries = {}
	for _, line in
		ipairs(vim.split(output, "\n", { plain = true, trimempty = true }))
	do
		local name, obj_type, deref_sha, subject =
			line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
		if name then
			entries[#entries + 1] = {
				name = name,
				sha = deref_sha ~= "" and deref_sha or "",
				subject = subject ~= "" and subject or nil,
				is_annotated = obj_type == "tag",
			}
		end
	end
	return entries
end

---List tags sorted by creator date descending (newest first).
---@param opts table|nil
---@param cb fun(err: string|nil, entries: GitflowTagEntry[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	git.git({
		"for-each-ref",
		"--sort=-creatordate",
		"--format=%(refname:short)\t%(objecttype)\t%(*objectname)\t%(subject)",
		"refs/tags",
	}, opts or {}, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(result, "for-each-ref refs/tags"),
				nil,
				result
			)
			return
		end
		cb(nil, M.parse(result.stdout or ""), result)
	end)
end

---Create a tag. If message is provided, creates an annotated tag.
---@param name string
---@param opts table|nil  { message?: string, ref?: string }
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.create(name, opts, cb)
	if not name or vim.trim(name) == "" then
		error("gitflow tag error: create requires name", 2)
	end
	local options = opts or {}
	local args = { "tag" }
	if options.message and options.message ~= "" then
		args[#args + 1] = "-a"
		args[#args + 1] = name
		args[#args + 1] = "-m"
		args[#args + 1] = options.message
	else
		args[#args + 1] = name
	end
	if options.ref and options.ref ~= "" then
		args[#args + 1] = options.ref
	end
	git.git(args, {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "tag"), result)
			return
		end
		cb(nil, result)
	end)
end

---Delete a local tag.
---@param name string
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.delete(name, opts, cb)
	if not name or vim.trim(name) == "" then
		error("gitflow tag error: delete requires name", 2)
	end
	git.git({ "tag", "-d", name }, opts or {}, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "tag -d"), result)
			return
		end
		cb(nil, result)
	end)
end

---Delete a remote tag.
---@param name string
---@param remote string|nil  defaults to "origin"
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.delete_remote(name, remote, opts, cb)
	if not name or vim.trim(name) == "" then
		error("gitflow tag error: delete_remote requires name", 2)
	end
	local r = remote and vim.trim(remote) ~= "" and remote or "origin"
	local tag_ref = "refs/tags/" .. name
	git.git(
		{ "push", r, "--delete", tag_ref },
		opts or {},
		function(result)
			if result.code ~= 0 then
				cb(
					error_from_result(
						result,
						"push " .. r .. " --delete " .. tag_ref
					),
					result
				)
				return
			end
			cb(nil, result)
		end
	)
end

---Push a tag to a remote.
---@param name string
---@param remote string|nil  defaults to "origin"
---@param opts table|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.push(name, remote, opts, cb)
	if not name or vim.trim(name) == "" then
		error("gitflow tag error: push requires name", 2)
	end
	local r = remote and vim.trim(remote) ~= "" and remote or "origin"
	local tag_ref = "refs/tags/" .. name
	git.git({ "push", r, tag_ref }, opts or {}, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(result, "push " .. r .. " " .. tag_ref),
				result
			)
			return
		end
		cb(nil, result)
	end)
end

return M
