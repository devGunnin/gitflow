local gh = require("gitflow.gh")

local M = {}

local LABEL_FIELDS = table.concat({ "name", "color", "description", "isDefault" }, ",")

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = gh.output(result)
	if output == "" then
		return ("gh label %s failed"):format(action)
	end
	return ("gh label %s failed: %s"):format(action, output)
end

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
		error("gitflow gh label error: number is required", 3)
	end
	local value = tostring(number)
	if vim.trim(value) == "" then
		error("gitflow gh label error: number is required", 3)
	end
	return value
end

---@param color string
---@return string
local function normalize_color(color)
	local value = vim.trim(tostring(color or "")):gsub("^#", "")
	if value == "" then
		error("gitflow gh label error: color is required", 2)
	end
	if not value:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
		error("gitflow gh label error: color must be a 6-digit hex value", 2)
	end
	return value:lower()
end

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, labels: table[]|nil, result: GitflowGitResult)
function M.list(opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.json({ "label", "list", "--json", LABEL_FIELDS }, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data or {}, result)
	end)
end

---@param name string
---@param color string
---@param description string|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.create(name, color, description, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local label_name = vim.trim(tostring(name or ""))
	if label_name == "" then
		error("gitflow gh label error: create(name, color, description, opts, cb) requires name", 2)
	end

	local args = {
		"label",
		"create",
		label_name,
		"--color",
		normalize_color(color),
	}

	if description and vim.trim(tostring(description)) ~= "" then
		args[#args + 1] = "--description"
		args[#args + 1] = tostring(description)
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "create"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param name string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.delete(name, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local label_name = vim.trim(tostring(name or ""))
	if label_name == "" then
		error("gitflow gh label error: delete(name, opts, cb) requires name", 2)
	end

	gh.run({ "label", "delete", label_name, "--yes" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "delete"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param labels string|string[]|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.assign_to_issue(number, labels, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local label_csv = to_csv(labels)
	if not label_csv then
		cb(nil, {
			code = 0,
			signal = 0,
			stdout = "No labels to assign",
			stderr = "",
			cmd = { "gh", "issue", "edit", normalize_number(number) },
		})
		return
	end

	gh.run({ "issue", "edit", normalize_number(number), "--add-label", label_csv }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "assign"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param labels string|string[]|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.remove_from_issue(number, labels, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local label_csv = to_csv(labels)
	if not label_csv then
		cb(nil, {
			code = 0,
			signal = 0,
			stdout = "No labels to remove",
			stderr = "",
			cmd = { "gh", "issue", "edit", normalize_number(number) },
		})
		return
	end

	gh.run({ "issue", "edit", normalize_number(number), "--remove-label", label_csv }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "remove"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param labels string|string[]|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.assign_to_pr(number, labels, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local label_csv = to_csv(labels)
	if not label_csv then
		cb(nil, {
			code = 0,
			signal = 0,
			stdout = "No labels to assign",
			stderr = "",
			cmd = { "gh", "pr", "edit", normalize_number(number) },
		})
		return
	end

	gh.run({ "pr", "edit", normalize_number(number), "--add-label", label_csv }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "assign"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param labels string|string[]|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.remove_from_pr(number, labels, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local label_csv = to_csv(labels)
	if not label_csv then
		cb(nil, {
			code = 0,
			signal = 0,
			stdout = "No labels to remove",
			stderr = "",
			cmd = { "gh", "pr", "edit", normalize_number(number) },
		})
		return
	end

	gh.run({ "pr", "edit", normalize_number(number), "--remove-label", label_csv }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "remove"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
