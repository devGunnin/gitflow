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

---@param value unknown
---@return boolean
local function is_map(value)
	if type(value) ~= "table" then
		return false
	end
	local islist = vim.islist or vim.tbl_islist
	return not islist(value)
end

---Levenshtein distance, capped so a wildly different key scores no suggestion.
---@param a string
---@param b string
---@return integer
local function edit_distance(a, b)
	local previous = {}
	for j = 0, #b do
		previous[j] = j
	end

	for i = 1, #a do
		local current = { [0] = i }
		for j = 1, #b do
			local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
			current[j] = math.min(
				previous[j] + 1,
				current[j - 1] + 1,
				previous[j - 1] + cost
			)
		end
		previous = current
	end

	return previous[#b]
end

--- Longest edit distance still considered a typo rather than a different key.
local MAX_SUGGESTION_DISTANCE = 3

---Find the valid key closest to `key`, for "did you mean" hints.
---@param key string
---@param candidates table<string, unknown>
---@return string|nil
function M.nearest_key(key, candidates)
	local best, best_distance = nil, math.huge

	for _, candidate in ipairs(M.sorted_keys(candidates)) do
		local distance = edit_distance(key, candidate)
		-- A suggestion must be closer to the typo than it is long.
		if distance < best_distance and distance <= math.min(MAX_SUGGESTION_DISTANCE, #candidate) then
			best, best_distance = candidate, distance
		end
	end

	return best
end

---Collect keys present in `overrides` that the `schema` does not define.
---Recurses only into map-like tables the schema also defines as maps, so
---lists and free-form maps (see `open_paths`) keep accepting any content.
---@param schema table  the defaults table acting as the schema
---@param overrides table|nil  user-supplied config
---@param open_paths table<string, true>|nil  dotted paths to leave unchecked
---@return { path: string, key: string, suggestion: string|nil }[]
function M.unknown_keys(schema, overrides, open_paths)
	assert(is_map(schema), "unknown_keys: schema must be a map-like table")

	local open = open_paths or {}
	local found = {}

	---@param schema_node table
	---@param override_node table
	---@param prefix string
	local function walk(schema_node, override_node, prefix)
		for key, override_value in pairs(override_node) do
			local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
			local schema_value = schema_node[key]

			if schema_value == nil then
				found[#found + 1] = {
					path = path,
					key = tostring(key),
					suggestion = M.nearest_key(tostring(key), schema_node),
				}
			elseif not open[path] and is_map(schema_value) and is_map(override_value) then
				walk(schema_value, override_value, path)
			end
		end
	end

	if type(overrides) == "table" then
		walk(schema, overrides, "")
	end

	-- Sorted so the reported order does not depend on pairs() iteration order.
	table.sort(found, function(a, b)
		return a.path < b.path
	end)

	return found
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
