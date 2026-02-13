local M = {}

local CACHE_TTL_SECONDS = 60

---@type table{fetched_at: integer, labels: string[]}
local cache = {
	fetched_at = 0,
	labels = {},
}

---@return string[]
function M.fetch_repo_label_candidates()
	local cmd = { "gh", "label", "list", "--json", "name", "--limit", "200" }
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

	local ok, decoded = pcall(vim.json.decode, text)
	if not ok or type(decoded) ~= "table" then
		return {}
	end

	local names = {}
	for _, label in ipairs(decoded) do
		local name = type(label) == "table" and vim.trim(tostring(label.name or "")) or ""
		if name ~= "" then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names
end

---@return string[]
function M.list_repo_label_candidates()
	local now = os.time()
	if now - cache.fetched_at <= CACHE_TTL_SECONDS then
		return cache.labels
	end

	local labels = M.fetch_repo_label_candidates()
	cache = {
		fetched_at = now,
		labels = labels,
	}
	return labels
end

---@param prefix_csv string
---@param strip_sign boolean
---@return table<string, boolean>
local function selected_labels(prefix_csv, strip_sign)
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
---@param key "add"|"remove"
---@return string[]
function M.complete_token(arglead, key)
	local prefix = ("%s="):format(key)
	if not vim.startswith(arglead, prefix) then
		return {}
	end

	local raw = arglead:sub(#prefix + 1)
	local prefix_csv = raw:match("^(.*,)") or ""
	local current = raw:match("([^,]*)$") or raw
	local selected = selected_labels(prefix_csv, false)

	local candidates = {}
	for _, label in ipairs(M.list_repo_label_candidates()) do
		if not selected[label] and (current == "" or vim.startswith(label, current)) then
			candidates[#candidates + 1] = ("%s%s%s"):format(prefix, prefix_csv, label)
		end
	end
	return candidates
end

---@param arglead string|nil
---@return string[]
function M.complete_create_labels(arglead)
	local raw = arglead or ""
	local prefix_csv = raw:match("^(.*,)") or ""
	local current = raw:match("([^,]*)$") or raw

	local selected = selected_labels(prefix_csv, false)
	local candidates = {}
	for _, label in ipairs(M.list_repo_label_candidates()) do
		if not selected[label]
			and (current == "" or vim.startswith(label, current))
		then
			candidates[#candidates + 1] = ("%s%s"):format(prefix_csv, label)
		end
	end
	return candidates
end

---@param arglead string|nil
---@return string[]
function M.complete_issue_patch(arglead)
	local raw = arglead or ""
	local prefix_csv = raw:match("^(.*,)") or ""
	local current = raw:match("([^,]*)$") or raw
	local sign = ""
	local current_label = current
	if vim.startswith(current, "+") then
		sign = "+"
		current_label = current:sub(2)
	elseif vim.startswith(current, "-") then
		sign = "-"
		current_label = current:sub(2)
	end

	local selected = selected_labels(prefix_csv, true)
	local candidates = {}
	for _, label in ipairs(M.list_repo_label_candidates()) do
		if not selected[label] and (current_label == "" or vim.startswith(label, current_label)) then
			candidates[#candidates + 1] = ("%s%s%s"):format(prefix_csv, sign, label)
		end
	end
	return candidates
end

return M
