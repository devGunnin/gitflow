local M = {}

M.DEFAULT_GROUPS = {
	GitflowAdded = { link = "DiffAdd" },
	GitflowRemoved = { link = "DiffDelete" },
	GitflowModified = { link = "DiffChange" },
	GitflowStaged = { link = "DiffAdd" },
	GitflowUnstaged = { link = "DiffChange" },
	GitflowUntracked = { link = "Comment" },
	GitflowConflictLocal = { link = "DiffAdd" },
	GitflowConflictBase = { link = "DiffChange" },
	GitflowConflictRemote = { link = "DiffDelete" },
	GitflowConflictResolved = { link = "DiffText" },
	GitflowBranchCurrent = { link = "Title" },
	GitflowBranchRemote = { link = "Comment" },
	GitflowPROpen = { link = "DiagnosticOk" },
	GitflowPRMerged = { link = "Special" },
	GitflowPRClosed = { link = "DiagnosticError" },
	GitflowPRDraft = { link = "Comment" },
	GitflowIssueOpen = { link = "DiagnosticOk" },
	GitflowIssueClosed = { link = "DiagnosticError" },
	GitflowReviewApproved = { link = "DiagnosticOk" },
	GitflowReviewChangesRequested = { link = "WarningMsg" },
	GitflowReviewComment = { link = "Comment" },
	GitflowBorder = { fg = "#DCA561", bg = "#111318" },
	GitflowTitle = { fg = "#F5E6C8", bg = "#4A3514", bold = true },
	GitflowHeader = { fg = "#F5E6C8", bg = "#6B4B16", bold = true },
	GitflowFooter = { fg = "#D8C8A9", bg = "#1A1D24", italic = true },
	GitflowPaletteSelection = { link = "PmenuSel" },
	GitflowPaletteHeader = { bold = true, link = "Type" },
	GitflowPaletteKeybind = { link = "Special" },
	GitflowPaletteDescription = { link = "Comment" },
	GitflowPaletteIndex = { link = "Number" },
	GitflowPaletteCommand = { link = "Function" },
	GitflowPaletteNormal = { link = "NormalFloat" },
	GitflowPaletteHeaderBar = {
		fg = "#222222", bg = "#DCA561", bold = true,
	},
	GitflowPaletteHeaderIcon = {
		fg = "#56B6C2", bg = "#DCA561", bold = true,
	},
	GitflowPaletteEntryIcon = { fg = "#56B6C2" },
	GitflowPaletteBackdrop = { bg = "#000000" },
}

---@param user_overrides table<string, table>|nil
function M.setup(user_overrides)
	local overrides = type(user_overrides) == "table" and user_overrides or {}

	for group, default_attrs in pairs(M.DEFAULT_GROUPS) do
		local attrs = vim.deepcopy(default_attrs)
		local override = overrides[group]
		if type(override) == "table" then
			attrs = vim.deepcopy(override)
		end
		vim.api.nvim_set_hl(0, group, attrs)
	end
end

return M
