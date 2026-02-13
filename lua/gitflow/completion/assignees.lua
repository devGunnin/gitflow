local M = {}

local CACHE_TTL_SECONDS = 60

---@type table{fetched_at: integer, assignees: string[]}
local cache = {
	fetched_at = 0,
	assignees = {},
}

---@return string[]
function M.fetch_repo_assignee_candidates()
	local cmd = {
		"gh", "api", "repos/{owner}/{repo}/assignees",
		"--jq", ".[].login",
		"--paginate",
	}
	local stdout = ""
	if vim.system then
		local result = vim.system(cmd, { text = true }):wait()
		if (result.code or 1) ~= 0 then
			return {}
		end
		stdout = result.stdout or ""
	else
		local output = vim.fn.system(cmd)
		if vim.v.shell_error ~= 0 then
			return {}
		end
		stdout = output or ""
	end

	local text = vim.trim(stdout)
	if text == "" then
		return {}
	end

	local names = {}
	for _, line in ipairs(vim.split(text, "\n", { trimempty = true })) do
		local name = vim.trim(line)
		if name ~= "" then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

---@return string[]
function M.list_repo_assignee_candidates()
	local now = os.time()
	if now - cache.fetched_at <= CACHE_TTL_SECONDS then
		return cache.assignees
	end

	local assignees = M.fetch_repo_assignee_candidates()
	cache = {
		fetched_at = now,
		assignees = assignees,
	}
	return assignees
end

---@param prefix_csv string
---@param strip_sign boolean
---@return table<string, boolean>
local function selected_assignees(prefix_csv, strip_sign)
	local selected = {}
	if prefix_csv == "" then
		return selected
	end

	for _, token in ipairs(vim.split(prefix_csv, ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if strip_sign then
			trimmed = trimmed:gsub("^[-+]", "")
		end
		if trimmed ~= "" then
			selected[trimmed] = true
		end
	end
	return selected
end

---@param arglead string
---@param key "add_assignees"|"remove_assignees"
---@return string[]
function M.complete_token(arglead, key)
	local prefix = ("%s="):format(key)
	if not vim.startswith(arglead, prefix) then
		return {}
	end

	local raw = arglead:sub(#prefix + 1)
	local prefix_csv = raw:match("^(.*,)") or ""
	local current = raw:match("([^,]*)$") or raw
	local selected = selected_assignees(prefix_csv, false)

	local candidates = {}
	for _, name in ipairs(M.list_repo_assignee_candidates()) do
		if not selected[name]
			and (current == "" or vim.startswith(name, current))
		then
			candidates[#candidates + 1] =
				("%s%s%s"):format(prefix, prefix_csv, name)
		end
	end
	return candidates
end

---@param arglead string|nil
---@return string[]
function M.complete_assignee_patch(arglead)
	local raw = arglead or ""
	local prefix_csv = raw:match("^(.*,)") or ""
	local current = raw:match("([^,]*)$") or raw
	local sign = ""
	local current_name = current
	if vim.startswith(current, "+") then
		sign = "+"
		current_name = current:sub(2)
	elseif vim.startswith(current, "-") then
		sign = "-"
		current_name = current:sub(2)
	end

	local selected = selected_assignees(prefix_csv, true)
	local candidates = {}
	for _, name in ipairs(M.list_repo_assignee_candidates()) do
		if not selected[name]
			and (current_name == "" or vim.startswith(name, current_name))
		then
			candidates[#candidates + 1] =
				("%s%s%s"):format(prefix_csv, sign, name)
		end
	end
	return candidates
end

return M
