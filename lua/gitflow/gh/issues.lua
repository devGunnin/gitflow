local gh = require("gitflow.gh")

local M = {}

local ISSUE_LIST_FIELDS = table.concat({
	"number",
	"title",
	"state",
	"labels",
	"assignees",
	"author",
	"updatedAt",
}, ",")

local ISSUE_VIEW_FIELDS = table.concat({
	"number",
	"title",
	"body",
	"state",
	"labels",
	"assignees",
	"author",
	"comments",
	"createdAt",
	"updatedAt",
}, ",")

---@param value string|string[]|nil
---@return string|nil
local function to_csv(value)
	if value == nil then
		return nil
	end
	if type(value) == "string" then
		local trimmed = vim.trim(value)
		if trimmed == "" then
			return nil
		end
		return trimmed
	end

	local parts = {}
	for _, item in ipairs(value) do
		local trimmed = vim.trim(tostring(item))
		if trimmed ~= "" then
			parts[#parts + 1] = trimmed
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ",")
end

---@param number integer|string
---@return string
local function normalize_number(number)
	if number == nil then
		error("gitflow gh issue error: number is required", 3)
	end
	local value = tostring(number)
	if vim.trim(value) == "" then
		error("gitflow gh issue error: number is required", 3)
	end
	return value
end

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = gh.output(result)
	if output == "" then
		return ("gh issue %s failed"):format(action)
	end
	return ("gh issue %s failed: %s"):format(action, output)
end

---@param params table|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, issues: table[]|nil, result: GitflowGitResult)
function M.list(params, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local options = params or {}
	local args = { "issue", "list", "--json", ISSUE_LIST_FIELDS }

	if options.state and options.state ~= "" then
		args[#args + 1] = "--state"
		args[#args + 1] = tostring(options.state)
	end
	if options.label and options.label ~= "" then
		args[#args + 1] = "--label"
		args[#args + 1] = tostring(options.label)
	end
	if options.assignee and options.assignee ~= "" then
		args[#args + 1] = "--assignee"
		args[#args + 1] = tostring(options.assignee)
	end
	if options.search and options.search ~= "" then
		args[#args + 1] = "--search"
		args[#args + 1] = tostring(options.search)
	end
	if options.limit and tonumber(options.limit) then
		args[#args + 1] = "--limit"
		args[#args + 1] = tostring(options.limit)
	end

	gh.json(args, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data or {}, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, issue: table|nil, result: GitflowGitResult)
function M.view(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.json({
		"issue",
		"view",
		normalize_number(number),
		"--json",
		ISSUE_VIEW_FIELDS,
	}, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data, result)
	end)
end

---@param input table
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, response: table|nil, result: GitflowGitResult)
function M.create(input, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local data = input or {}
	local title = vim.trim(tostring(data.title or ""))
	if title == "" then
		error("gitflow gh issue error: create(input, opts, cb) requires input.title", 2)
	end

	local args = {
		"issue",
		"create",
		"--title",
		title,
		"--body",
		tostring(data.body or ""),
	}

	local label_csv = to_csv(data.labels)
	if label_csv then
		args[#args + 1] = "--label"
		args[#args + 1] = label_csv
	end

	local assignee_csv = to_csv(data.assignees)
	if assignee_csv then
		args[#args + 1] = "--assignee"
		args[#args + 1] = assignee_csv
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "create"), nil, result)
			return
		end

		cb(nil, {
			url = vim.trim(result.stdout or ""),
			output = gh.output(result),
		}, result)
	end)
end

---@param number integer|string
---@param body string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.comment(number, body, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local message_body = vim.trim(tostring(body or ""))
	if message_body == "" then
		error("gitflow gh issue error: comment(number, body, opts, cb) requires body", 2)
	end

	gh.run({ "issue", "comment", normalize_number(number), "--body", message_body }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "comment"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.close(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run({ "issue", "close", normalize_number(number) }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "close"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.reopen(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run({ "issue", "reopen", normalize_number(number) }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "reopen"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param input table
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.edit(number, input, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local options = input or {}
	local args = { "issue", "edit", normalize_number(number) }
	local changed = false

	if options.title and vim.trim(tostring(options.title)) ~= "" then
		args[#args + 1] = "--title"
		args[#args + 1] = tostring(options.title)
		changed = true
	end

	if options.body ~= nil then
		args[#args + 1] = "--body"
		args[#args + 1] = tostring(options.body)
		changed = true
	end

	local add_labels = to_csv(options.add_labels)
	if add_labels then
		args[#args + 1] = "--add-label"
		args[#args + 1] = add_labels
		changed = true
	end

	local remove_labels = to_csv(options.remove_labels)
	if remove_labels then
		args[#args + 1] = "--remove-label"
		args[#args + 1] = remove_labels
		changed = true
	end

	local add_assignees = to_csv(options.add_assignees)
	if add_assignees then
		args[#args + 1] = "--add-assignee"
		args[#args + 1] = add_assignees
		changed = true
	end

	local remove_assignees = to_csv(options.remove_assignees)
	if remove_assignees then
		args[#args + 1] = "--remove-assignee"
		args[#args + 1] = remove_assignees
		changed = true
	end

	if not changed then
		cb(nil, {
			code = 0,
			signal = 0,
			stdout = "No issue edits requested",
			stderr = "",
			cmd = { "gh", "issue", "edit", normalize_number(number) },
		})
		return
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "edit"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
