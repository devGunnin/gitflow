local M = {}

M.DEFAULT_GROUPS = {
	GitflowAdded = { link = "DiffAdd" },
	GitflowRemoved = { link = "DiffDelete" },
	GitflowModified = { link = "DiffChange" },
	GitflowStaged = { link = "DiffAdd" },
	GitflowUnstaged = { link = "DiffChange" },
	GitflowUntracked = { link = "Comment" },
	GitflowStatusStaged = { link = "DiffAdd" },
	GitflowStatusUnstaged = { link = "DiffChange" },
	GitflowStatusUntracked = { link = "Comment" },
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
	GitflowBorder = { link = "FloatBorder" },
	GitflowTitle = { link = "Title" },
	GitflowHeader = { link = "TabLineSel" },
	GitflowSection = { link = "Special" },
	GitflowSeparator = { link = "Comment" },
	GitflowMuted = { link = "Comment" },
	GitflowFooter = { link = "Comment" },
	GitflowKeyHint = { link = "Special" },
	GitflowPaletteSelection = { link = "PmenuSel" },
	GitflowPaletteHeader = { bold = true, link = "Type" },
	GitflowPaletteKeybind = { link = "Special" },
	GitflowPaletteDescription = { link = "Comment" },
	GitflowPaletteIndex = { link = "Number" },
	GitflowPaletteCommand = { link = "Function" },
	GitflowPaletteNormal = { link = "NormalFloat" },
	GitflowPaletteHeaderBar = { link = "Title" },
	GitflowPaletteHeaderIcon = { link = "Title" },
	GitflowPaletteEntryIcon = { link = "Special" },
	GitflowPaletteBackdrop = { link = "NormalFloat" },
}

---@param user_overrides table<string, table>|nil
function M.setup(user_overrides)
	local overrides = type(user_overrides) == "table" and user_overrides or {}
	local groups = vim.deepcopy(M.DEFAULT_GROUPS)

	for group, attrs in pairs(overrides) do
		if type(attrs) == "table" then
			groups[group] = vim.deepcopy(attrs)
		end
	end

	for group, attrs in pairs(groups) do
		vim.api.nvim_set_hl(0, group, attrs)
	end
end

return M
