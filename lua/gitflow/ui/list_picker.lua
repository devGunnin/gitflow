--- Generic single/multi-select picker for branches, assignees, reviewers, etc.
--- Live, incremental fuzzy filtering: press `/` to type and watch results
--- narrow as you go; navigate with j/k, toggle with <Space>, apply with <CR>.
---
--- A thin wrapper over gitflow.ui.picker (the shared engine with
--- label_picker.lua): normalizes `opts.items` (string or table form) into
--- the engine's item shape and supplies this picker's namespace pair, title
--- and placeholder text.

local picker = require("gitflow.ui.picker")

local M = {}

-- Named so a caller (or a test deriving the same id by name) resolves the
-- same namespace this module renders into.
local SPEC = {
	namespace_hl = vim.api.nvim_create_namespace("gitflow_list_picker_hl"),
	namespace_active = vim.api.nvim_create_namespace("gitflow_list_picker_active"),
	search_augroup = "GitflowListPickerSearch",
	filetype = "gitflow-list-picker",
	placeholder = "type to filter…",
	empty_text = "(no matching items)",
	default_title = "Select",
	name_highlight = function()
		return "GitflowChip"
	end,
}

---@class GitflowListPickerItem
---@field name string
---@field description? string

---@class GitflowListPickerOpts
---@field items GitflowListPickerItem[]
---@field selected? string[]
---@field title? string
---@field multi_select? boolean  default true
---@field on_submit fun(selected: string[])
---@field on_cancel? fun()

---@param items GitflowListPickerItem[]
---@param query string|nil
---@return GitflowListPickerItem[]
function M.filter_items(items, query)
	return picker.filter_items(items, query)
end

---@param opts GitflowListPickerOpts
---@return table|nil  nil when the terminal is too small for the float
function M.open(opts)
	local items = {}
	for _, item in ipairs(opts.items or {}) do
		if type(item) == "table" then
			local name = vim.trim(tostring(item.name or ""))
			if name ~= "" then
				items[#items + 1] = {
					name = name,
					description = item.description,
				}
			end
		elseif type(item) == "string" then
			local name = vim.trim(item)
			if name ~= "" then
				items[#items + 1] = { name = name }
			end
		end
	end

	return picker.open(SPEC, {
		items = items,
		selected = opts.selected,
		title = opts.title,
		multi_select = opts.multi_select,
		on_submit = opts.on_submit,
		on_cancel = opts.on_cancel,
	})
end

return M
