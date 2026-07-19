--- lua/gitflow/issues/derive.lua
---
--- Pure derivation of the rendered issue list from the fetched cache. The
--- panel fetches a broad list once and derives what it shows from
--- cache + filters + sort + grouping, so no filter change costs a `gh` call.
--- Nothing here touches Neovim state, so the whole pipeline is testable.

local M = {}

---@param value any
---@return string
local function text_of(value)
	return vim.trim(tostring(value or ""))
end

---gh selectors such as `@me` resolve against the authenticated user, so the
---client cannot evaluate them; they stay part of the server-side query.
---@param value string|nil
---@return boolean
function M.is_server_selector(value)
	return type(value) == "string" and vim.startswith(text_of(value), "@")
end

---@param issue table
---@return string  lowercase "open"/"closed", or "" when absent
function M.state_of(issue)
	return text_of(issue.state):lower()
end

---Collect a named field off a list of label/assignee objects.
---@param list any
---@param field string
---@return string[]
local function names_from(list, field)
	local names = {}
	if type(list) ~= "table" then
		return names
	end
	for _, entry in ipairs(list) do
		local name = type(entry) == "table" and entry[field] or entry
		name = text_of(name)
		if name ~= "" then
			names[#names + 1] = name
		end
	end
	return names
end

---@param issue table
---@return string[]
function M.label_names(issue)
	return names_from(issue.labels, "name")
end

---@param issue table
---@return string[]
function M.assignee_logins(issue)
	return names_from(issue.assignees, "login")
end

---@param issue table
---@return string  empty string when the issue has no milestone
function M.milestone_title(issue)
	if type(issue.milestone) ~= "table" then
		return ""
	end
	return text_of(issue.milestone.title)
end

---@param values string[]
---@param wanted string
---@return boolean
local function contains_ci(values, wanted)
	local needle = wanted:lower()
	for _, value in ipairs(values) do
		if value:lower() == needle then
			return true
		end
	end
	return false
end

---@param csv string
---@return string[]
local function split_csv(csv)
	local parts = {}
	for _, token in ipairs(vim.split(csv, ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if trimmed ~= "" then
			parts[#parts + 1] = trimmed
		end
	end
	return parts
end

---@param issue table
---@param filters table|nil
---@return boolean
function M.matches(issue, filters)
	assert(type(issue) == "table", "derive.matches: issue must be a table")
	filters = filters or {}

	local state = text_of(filters.state):lower()
	if state ~= "" and state ~= "all" and M.state_of(issue) ~= state then
		return false
	end

	-- Comma-separated labels are ANDed, matching `gh issue list --label`.
	for _, wanted in ipairs(split_csv(text_of(filters.label))) do
		if not contains_ci(M.label_names(issue), wanted) then
			return false
		end
	end

	local assignee = text_of(filters.assignee)
	if assignee ~= "" and not M.is_server_selector(assignee) then
		if not contains_ci(M.assignee_logins(issue), assignee) then
			return false
		end
	end

	local milestone = text_of(filters.milestone)
	if milestone ~= "" then
		if M.milestone_title(issue):lower() ~= milestone:lower() then
			return false
		end
	end

	return true
end

---@param issues table[]
---@param filters table|nil
---@return table[]
function M.filter(issues, filters)
	assert(type(issues) == "table", "derive.filter: issues must be a list")
	local kept = {}
	for _, issue in ipairs(issues) do
		if M.matches(issue, filters) then
			kept[#kept + 1] = issue
		end
	end
	return kept
end

M.SORT_KEYS = { "updated", "number", "title", "milestone" }
M.SORT_DIRECTIONS = { "desc", "asc" }

--- Sorts after every real milestone title, so unmilestoned issues trail the
--- ascending order instead of leading it.
local NO_MILESTONE_RANK = "\255"

---Ordering value for an issue under a sort key. All issues must yield the
---same Lua type for a key so `table.sort` sees a total order.
---@param key string
---@param issue table
---@return number|string
local function rank_of(key, issue)
	if key == "number" then
		return tonumber(issue.number) or 0
	end
	if key == "title" then
		return text_of(issue.title):lower()
	end
	if key == "milestone" then
		local title = M.milestone_title(issue)
		return title ~= "" and title:lower() or NO_MILESTONE_RANK
	end
	return text_of(issue.updatedAt)
end

---@param sort table|nil  { key, direction }
---@return string key, boolean descending
local function normalize_sort(sort)
	sort = sort or {}
	local key = text_of(sort.key)
	if not vim.tbl_contains(M.SORT_KEYS, key) then
		key = M.SORT_KEYS[1]
	end
	return key, text_of(sort.direction):lower() ~= "asc"
end

---Sort a list without mutating it. Ties break on issue number so the order is
---stable regardless of the incoming sequence.
---@param issues table[]
---@param sort table|nil
---@return table[]
function M.sort(issues, sort)
	assert(type(issues) == "table", "derive.sort: issues must be a list")
	local key, descending = normalize_sort(sort)

	local ranked = {}
	for index, issue in ipairs(issues) do
		ranked[index] = {
			issue = issue,
			rank = rank_of(key, issue),
			number = tonumber(issue.number) or 0,
		}
	end

	table.sort(ranked, function(left, right)
		if left.rank ~= right.rank then
			if descending then
				return left.rank > right.rank
			end
			return left.rank < right.rank
		end
		return left.number < right.number
	end)

	local sorted = {}
	for index, entry in ipairs(ranked) do
		sorted[index] = entry.issue
	end
	return sorted
end

---Filter then sort — the full list derivation from the fetched cache.
---@param issues table[]
---@param filters table|nil
---@param sort table|nil
---@return table[]
function M.apply(issues, filters, sort)
	return M.sort(M.filter(issues, filters), sort)
end

M.GROUP_KEYS = { "none", "milestone", "assignee", "label" }

--- Bucket key for issues that carry no value for the grouping field. Empty so
--- it can never collide with a real milestone/assignee/label name.
local NO_GROUP_KEY = ""

local GROUP_EXTRACTORS = {
	milestone = function(issue)
		local title = M.milestone_title(issue)
		return title ~= "" and { title } or {}
	end,
	assignee = function(issue)
		return M.assignee_logins(issue)
	end,
	label = function(issue)
		return M.label_names(issue)
	end,
}

---@param group_by string
---@return string  heading for the bucket of issues with no such value
function M.empty_group_label(group_by)
	if group_by == "assignee" then
		return "Unassigned"
	end
	return ("No %s"):format(group_by)
end

---Bucket an already filtered and sorted list. Issues with several labels or
---assignees appear under each of them. Named groups come first alphabetically,
---the empty bucket last; issue order inside a group is preserved.
---@param issues table[]
---@param group_by string|nil  nil or "none" yields one unnamed group
---@return table[]  { { key = string, issues = table[] }, ... }
function M.group(issues, group_by)
	assert(type(issues) == "table", "derive.group: issues must be a list")

	if group_by == nil or group_by == "none" then
		return { { key = NO_GROUP_KEY, issues = issues } }
	end

	local collect = GROUP_EXTRACTORS[group_by]
	assert(collect, ("derive.group: unknown group key %q"):format(group_by))

	local buckets, keys = {}, {}
	for _, issue in ipairs(issues) do
		local values = collect(issue)
		if #values == 0 then
			values = { NO_GROUP_KEY }
		end
		for _, value in ipairs(values) do
			if not buckets[value] then
				buckets[value] = {}
				keys[#keys + 1] = value
			end
			local bucket = buckets[value]
			bucket[#bucket + 1] = issue
		end
	end

	table.sort(keys, function(left, right)
		if (left == NO_GROUP_KEY) ~= (right == NO_GROUP_KEY) then
			return right == NO_GROUP_KEY
		end
		return left < right
	end)

	local groups = {}
	for index, key in ipairs(keys) do
		groups[index] = { key = key, issues = buckets[key] }
	end
	return groups
end

---Distinct values of a field across the cache, sorted, for the filter pickers.
---@param issues table[]
---@param field "label"|"assignee"|"milestone"
---@return string[]
function M.distinct_values(issues, field)
	assert(type(issues) == "table", "derive.distinct_values: issues must be a list")
	local extract = {
		label = M.label_names,
		assignee = M.assignee_logins,
		milestone = function(issue)
			local title = M.milestone_title(issue)
			return title ~= "" and { title } or {}
		end,
	}
	local collect = extract[field]
	assert(collect, ("derive.distinct_values: unknown field %q"):format(field))

	local seen, values = {}, {}
	for _, issue in ipairs(issues) do
		for _, value in ipairs(collect(issue)) do
			if not seen[value] then
				seen[value] = true
				values[#values + 1] = value
			end
		end
	end
	table.sort(values)
	return values
end

---Next entry in a fixed cycle, wrapping around; unknown values restart it.
---@param values string[]
---@param current string|nil
---@return string
function M.cycle(values, current)
	assert(#values > 0, "derive.cycle: values must not be empty")
	for index, value in ipairs(values) do
		if value == current then
			return values[(index % #values) + 1]
		end
	end
	return values[1]
end

return M
