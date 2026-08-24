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

---@param params { limit?: integer }|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, labels: table[]|nil, result: GitflowGitResult)
function M.list(params, opts, cb)
	-- The signature gained `params` (#283); a caller left on the old shape
	-- passes its callback as `opts` and would otherwise just never be called.
	assert(type(cb) == "function", "gh_labels.list expects (params, opts, cb)")
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local options = params or {}
	local args = { "label", "list", "--json", LABEL_FIELDS }
	-- `gh label list` defaults to 30; without an explicit limit a repo with
	-- more labels silently loses the rest.
	if options.limit ~= nil then
		local limit = tonumber(options.limit)
		assert(
			limit and limit >= 1,
			"gh_labels.list: limit must be a positive number"
		)
		args[#args + 1] = "--limit"
		args[#args + 1] = tostring(math.floor(limit))
	end

	gh.json(args, opts, function(err, data, result)
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

return M
