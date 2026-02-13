local utils = require("gitflow.utils")

local M = {}

M.DEFAULT_GROUPS = {
	GitflowBorder = { link = "FloatBorder" },
	GitflowTitle = { link = "FloatTitle" },
	GitflowHeader = { link = "Title" },
	GitflowSection = { link = "Special" },
	GitflowSeparator = { link = "Comment" },
	GitflowMuted = { link = "Comment" },
	GitflowFooter = { link = "Comment" },
	GitflowKeyHint = { link = "Special" },
	GitflowStatusStaged = { link = "DiffAdd" },
	GitflowStatusUnstaged = { link = "DiffChange" },
	GitflowStatusUntracked = { link = "DiffText" },
}

---@param group string
---@param attrs table
local function set_highlight(group, attrs)
	if not utils.is_non_empty_string(group) then
		return
	end
	if type(attrs) ~= "table" then
		return
	end
	vim.api.nvim_set_hl(0, group, attrs)
end

---@param overrides table<string, table>|nil
function M.setup(overrides)
	local groups = vim.deepcopy(M.DEFAULT_GROUPS)
	for group, attrs in pairs(overrides or {}) do
		if type(attrs) == "table" then
			groups[group] = vim.deepcopy(attrs)
		end
	end

	for group, attrs in pairs(groups) do
		set_highlight(group, attrs)
	end
	return groups
end

return M
