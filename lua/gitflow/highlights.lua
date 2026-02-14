local M = {}

M.DEFAULT_GROUPS = {
	-- Diff / git state
	GitflowAdded = { link = "DiffAdd" },
	GitflowRemoved = { link = "DiffDelete" },
	GitflowModified = { link = "DiffChange" },
	GitflowStaged = { link = "DiffAdd" },
	GitflowUnstaged = { link = "DiffChange" },
	GitflowUntracked = { link = "Comment" },
	-- Conflict
	GitflowConflictLocal = { link = "DiffAdd" },
	GitflowConflictBase = { link = "DiffChange" },
	GitflowConflictRemote = { link = "DiffDelete" },
	GitflowConflictResolved = { link = "DiffText" },
	-- Branch
	GitflowBranchCurrent = { link = "Title" },
	GitflowBranchRemote = { link = "Comment" },
	-- PR state
	GitflowPROpen = { link = "DiagnosticOk" },
	GitflowPRMerged = { link = "Special" },
	GitflowPRClosed = { link = "DiagnosticError" },
	GitflowPRDraft = { link = "Comment" },
	-- Issue state
	GitflowIssueOpen = { link = "DiagnosticOk" },
	GitflowIssueClosed = { link = "DiagnosticError" },
	-- Review
	GitflowReviewApproved = { link = "DiagnosticOk" },
	GitflowReviewChangesRequested = { link = "WarningMsg" },
	GitflowReviewComment = { link = "Comment" },
	-- Window chrome — themed accent colors (cyan primary, gold secondary)
	GitflowBorder = { fg = "#56B6C2" },
	GitflowTitle = { fg = "#56B6C2", bold = true },
	GitflowHeader = { fg = "#56B6C2", bold = true },
	GitflowFooter = { fg = "#56B6C2", italic = true },
	GitflowSeparator = { fg = "#3E4452" },
	GitflowNormal = { link = "NormalFloat" },
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
