---@class GitflowNotifyOpts
---@field title? string
---@field context? GitflowNotificationContext

local M = {}

---@type table<string, string[]>
local PANEL_CONTEXT_COMMANDS = {
	branch = { "branch" },
	blame = { "blame" },
	conflict = { "conflicts" },
	diff = { "diff" },
	issues = { "issue", "list" },
	log = { "log" },
	notifications = { "notifications" },
	prs = { "pr", "list" },
	stash = { "stash", "list" },
	status = { "status" },
}

---@return GitflowNotificationContext|nil
local function infer_notification_context()
	for stack_level = 3, 10 do
		local info = debug.getinfo(stack_level, "S")
		if not info or type(info.source) ~= "string" then
			break
		end

		local source = info.source
		if source:sub(1, 1) == "@" then
			source = source:sub(2)
		end

		local panel = source:match("lua/gitflow/panels/([%w_]+)%.lua$")
		if panel then
			local command_args = PANEL_CONTEXT_COMMANDS[panel]
			if command_args then
				return {
					command_args = vim.deepcopy(command_args),
					label = panel,
				}
			end
		end

		if source:match("lua/gitflow/ui/conflict%.lua$") then
			return {
				command_args = { "conflicts" },
				label = "conflicts",
			}
		end
	end

	return nil
end

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
	local context = (opts and opts.context)
		or infer_notification_context()
	local ok, notif = pcall(require, "gitflow.notifications")
	if ok and notif and type(notif.push) == "function" then
		notif.push(message, resolved_level, context)
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
