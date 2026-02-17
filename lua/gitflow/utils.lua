---@class GitflowNotifyOpts
---@field title? string

local M = {}

---@generic T: table
---@param defaults T
---@param overrides table|nil
---@return T
function M.deep_merge(defaults, overrides)
	local merged = vim.tbl_deep_extend("force", defaults, overrides or {})
	return merged
end

---@param message string
---@param level integer|nil
---@param opts GitflowNotifyOpts|nil
function M.notify(message, level, opts)
	local resolved_level = level or vim.log.levels.INFO
	local ok, notif = pcall(require, "gitflow.notifications")
	if ok and notif and type(notif.push) == "function" then
		notif.push(message, resolved_level)
	end
	vim.notify(message, resolved_level, {
		title = (opts and opts.title) or "gitflow",
	})
end

---@param value unknown
---@return boolean
function M.is_non_empty_string(value)
	return type(value) == "string" and value ~= ""
end

---@param input table<string, unknown>
---@return string[]
function M.sorted_keys(input)
	local keys = {}
	for key, _ in pairs(input) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

return M
