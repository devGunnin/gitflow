local M = {}

---@type table<string, table>
M.DEFAULT_GROUPS = {
	GitflowBorder = { link = "FloatBorder" },
	GitflowTitle = { link = "Title" },
	GitflowFooter = { link = "Comment" },
	GitflowPaletteSelection = { link = "CursorLine" },
	GitflowPaletteHeader = { link = "Title" },
	GitflowPaletteKeybind = { link = "Special" },
	GitflowPaletteDescription = { link = "Comment" },
	GitflowPaletteCategory = { link = "Type" },
	GitflowPaletteIcon = { link = "Identifier" },
	GitflowPaletteSeparator = { link = "NonText" },
	GitflowPaletteNumber = { link = "Number" },
}

---@param overrides table<string, table>|nil
function M.setup(overrides)
	for group, attrs in pairs(M.DEFAULT_GROUPS) do
		local merged = attrs
		if overrides and overrides[group] then
			merged = vim.tbl_extend("force", attrs, overrides[group])
		end
		vim.api.nvim_set_hl(0, group, merged)
	end
end

return M
