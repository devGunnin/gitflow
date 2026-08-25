--- Multi-select label picker with live fuzzy filtering and color previews.
--- Press `/` to type and watch labels narrow as you go; <Space> toggles,
--- <CR> applies.
---
--- A thin wrapper over gitflow.ui.picker (the shared engine with
--- list_picker.lua): normalizes `opts.labels` into the engine's item shape
--- (carrying `color`), fixes multi_select on, and supplies this picker's
--- namespace pair, title, placeholder text and the per-label color chip.

local picker = require("gitflow.ui.picker")
local highlights = require("gitflow.highlights")

local M = {}

-- Named so a caller (or a test deriving the same id by name) resolves the
-- same namespace this module renders into.
local SPEC = {
	namespace_hl = vim.api.nvim_create_namespace("gitflow_label_picker_hl"),
	namespace_active = vim.api.nvim_create_namespace("gitflow_label_picker_active"),
	search_augroup = "GitflowLabelPickerSearch",
	filetype = "gitflow-label-picker",
	placeholder = "filter labels…",
	empty_text = "(no matching labels)",
	default_title = "Select Labels",
	name_highlight = function(item)
		return highlights.label_color_group(item.color or "")
	end,
}

---@class GitflowLabelPickerLabel
---@field name string
---@field color? string
---@field description? string

---@class GitflowLabelPickerOpts
---@field labels GitflowLabelPickerLabel[]
---@field selected? string[]
---@field title? string
---@field on_submit fun(selected: string[])
---@field on_cancel? fun()

---@param labels GitflowLabelPickerLabel[]
---@param query string|nil
---@return GitflowLabelPickerLabel[]
function M.filter_labels(labels, query)
	return picker.filter_items(labels, query)
end

---@param opts GitflowLabelPickerOpts
---@return table|nil  nil when the terminal is too small for the float
function M.open(opts)
	local labels = {}
	for _, label in ipairs(opts.labels or {}) do
		if type(label) == "table" then
			local name = vim.trim(tostring(label.name or ""))
			if name ~= "" then
				labels[#labels + 1] = {
					name = name,
					color = label.color,
					description = label.description,
				}
			end
		end
	end

	return picker.open(SPEC, {
		items = labels,
		selected = opts.selected,
		title = opts.title,
		multi_select = true,
		on_submit = opts.on_submit,
		on_cancel = opts.on_cancel,
	})
end

return M
