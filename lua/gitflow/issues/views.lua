--- lua/gitflow/issues/views.lua
---
--- Saved issue-panel views — a named filter + sort combination persisted to
---     stdpath('data')/gitflow/issues/views.json
--- so it survives a Neovim restart.
---
--- A file that cannot be read or understood is reported to the caller as an
--- error and left untouched: the panel surfaces it and refuses to write, so a
--- corrupt file never silently costs the user their saved views.

---@class GitflowIssueView
---@field name string
---@field filters table
---@field sort table  { key, direction }

local M = {}

local SCHEMA_VERSION = 1

---@return string
function M.path()
	local dir = ("%s/gitflow/issues"):format(vim.fn.stdpath("data"))
	vim.fn.mkdir(dir, "p")
	return dir .. "/views.json"
end

---@param value any
---@return string
local function text_of(value)
	return vim.trim(tostring(value or ""))
end

---@param value any
---@return string|nil  nil for absent/blank, so filters stay sparse
local function optional_text(value)
	local text = text_of(value)
	return text ~= "" and text or nil
end

---@param entry any
---@return GitflowIssueView|nil view, string|nil err
local function normalize(entry)
	if type(entry) ~= "table" then
		return nil, "a saved view is not an object"
	end

	local name = text_of(entry.name)
	if name == "" then
		return nil, "a saved view has no name"
	end
	if type(entry.filters) ~= "table" then
		return nil, ("saved view %q has no filters"):format(name)
	end

	local sort = type(entry.sort) == "table" and entry.sort or {}
	return {
		name = name,
		filters = {
			state = optional_text(entry.filters.state) or "open",
			label = optional_text(entry.filters.label),
			assignee = optional_text(entry.filters.assignee),
			milestone = optional_text(entry.filters.milestone),
		},
		sort = {
			key = optional_text(sort.key) or "updated",
			direction = text_of(sort.direction) == "asc" and "asc" or "desc",
		},
	}, nil
end

---Read the saved views. A missing file is an empty list, not an error.
---@return GitflowIssueView[]|nil views, string|nil err
function M.load()
	local path = M.path()
	local file = io.open(path, "r")
	if not file then
		return {}, nil
	end

	local raw = file:read("*a")
	file:close()
	if not raw or vim.trim(raw) == "" then
		return {}, nil
	end

	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok then
		return nil, ("%s is not valid JSON (%s)"):format(path, tostring(decoded))
	end
	if type(decoded) ~= "table" or type(decoded.views) ~= "table" then
		return nil, ("%s is not a gitflow saved-views file"):format(path)
	end

	local views = {}
	for _, entry in ipairs(decoded.views) do
		local view, err = normalize(entry)
		if not view then
			return nil, ("%s is corrupt: %s"):format(path, err)
		end
		views[#views + 1] = view
	end
	return views, nil
end

---@param views GitflowIssueView[]
---@return boolean ok, string|nil err
function M.save(views)
	assert(type(views) == "table", "views.save: views must be a list")

	local path = M.path()
	local encoded = vim.json.encode({
		version = SCHEMA_VERSION,
		views = views,
	})

	local file, open_err = io.open(path, "w")
	if not file then
		return false, ("could not write %s: %s"):format(path, tostring(open_err))
	end
	local written, write_err = file:write(encoded)
	file:close()
	if not written then
		return false, ("could not write %s: %s"):format(path, tostring(write_err))
	end
	return true, nil
end

---@param views GitflowIssueView[]
---@param name string
---@return GitflowIssueView|nil
function M.find(views, name)
	local wanted = text_of(name)
	for _, view in ipairs(views) do
		if view.name == wanted then
			return view
		end
	end
	return nil
end

---Insert or replace a view by name, without mutating the input list.
---@param views GitflowIssueView[]
---@param view GitflowIssueView
---@return GitflowIssueView[]
function M.upsert(views, view)
	assert(type(view) == "table" and text_of(view.name) ~= "",
		"views.upsert: view must have a name")

	local out, replaced = {}, false
	for _, existing in ipairs(views) do
		if existing.name == view.name then
			out[#out + 1] = view
			replaced = true
		else
			out[#out + 1] = existing
		end
	end
	if not replaced then
		out[#out + 1] = view
	end
	return out
end

---@param views GitflowIssueView[]
---@param name string
---@return GitflowIssueView[] remaining, boolean removed
function M.remove(views, name)
	local wanted = text_of(name)
	local out, removed = {}, false
	for _, view in ipairs(views) do
		if view.name == wanted then
			removed = true
		else
			out[#out + 1] = view
		end
	end
	return out, removed
end

return M
