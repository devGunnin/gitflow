local M = {}

--- Centralized color palette — single source of truth for accent colors.
---@type table<string, string>
M.PALETTE = {
	accent_primary = "#56B6C2",
	accent_secondary = "#DCA561",
	separator_fg = "#3E4452",
	backdrop_bg = "#000000",
	dark_fg = "#222222",
	log_hash = "#E5C07B",
	stash_ref = "#C678DD",
}

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
	-- Log / Stash entry accents
	GitflowLogHash = { fg = "#E5C07B", bold = true },
	GitflowStashRef = { fg = "#C678DD", bold = true },
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
	-- Form
	GitflowFormLabel = { fg = "#56B6C2", bold = true },
	GitflowFormActiveField = { link = "CursorLine" },
}

---Create or retrieve a dynamic highlight group for a label hex color.
---@param hex_color string  6-digit hex (with or without leading #)
---@return string  highlight group name
function M.label_color_group(hex_color)
	local color = vim.trim(tostring(hex_color or "")):gsub("^#", ""):lower()
	if not color:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then
		return "Comment"
	end

	local group_name = ("GitflowLabel_%s"):format(color)
	-- Determine foreground contrast: use luminance to pick black or white.
	local r = tonumber(color:sub(1, 2), 16) / 255
	local g = tonumber(color:sub(3, 4), 16) / 255
	local b = tonumber(color:sub(5, 6), 16) / 255
	local luminance = 0.299 * r + 0.587 * g + 0.114 * b
	local fg = luminance > 0.5 and "#000000" or "#ffffff"

	vim.api.nvim_set_hl(0, group_name, { fg = fg, bg = "#" .. color, bold = true })
	return group_name
end

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
