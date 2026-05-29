local M = {}

--- Dark palette — used when vim.o.background == "dark" (default).
--- A cohesive, contemporary scheme: a luminous sapphire keeps Gitflow's
--- cyan brand identity while peach/mauve accents and a soft surface
--- separator give panels a polished, modern feel.
---@type table<string, string>
M.PALETTE_DARK = {
	accent_primary = "#74C7EC",   -- sapphire — chrome, borders, titles
	accent_secondary = "#F9E2AF", -- soft gold — counts, header bars
	separator_fg = "#45475A",     -- muted surface — quiet dividers
	backdrop_bg = "#11111B",      -- deep crust — modal backdrop
	dark_fg = "#181825",          -- near-black — text on accent fills
	log_hash = "#FAB387",         -- peach — commit hashes
	stash_ref = "#CBA6F7",        -- mauve — refs / stashes
	diff_file_header = "#FAB387", -- peach — diff file headers
	diff_hunk_header = "#CBA6F7", -- mauve — diff hunk headers
	diff_line_nr = "#6C7086",     -- overlay — diff line numbers
}

--- Light palette — used when vim.o.background == "light".
---@type table<string, string>
M.PALETTE_LIGHT = {
	accent_primary = "#209FB5",   -- latte sapphire
	accent_secondary = "#DF8E1D", -- latte gold
	separator_fg = "#BCC0CC",     -- latte surface
	backdrop_bg = "#DCE0E8",      -- latte crust
	dark_fg = "#11111B",          -- near-black text on accent fills
	log_hash = "#FE640B",         -- latte peach
	stash_ref = "#8839EF",        -- latte mauve
	diff_file_header = "#FE640B",
	diff_hunk_header = "#8839EF",
	diff_line_nr = "#9CA0B0",
}

--- Active palette — set by setup() based on vim.o.background.
--- Defaults to dark palette until setup() is called.
---@type table<string, string>
M.PALETTE = vim.deepcopy(M.PALETTE_DARK)

--- Build default highlight groups from the given palette.
---@param palette table<string, string>
---@return table<string, table>
local function build_default_groups(palette)
	return {
		-- Diff / git state
		GitflowAdded = { link = "DiffAdd" },
		GitflowRemoved = { link = "DiffDelete" },
		GitflowModified = { link = "DiffChange" },
		-- Sign column indicators (linked to the base groups so user overrides
		-- via setup({ highlights = { GitflowSignAdded = ... } }) take effect —
		-- signs.lua uses these names as texthl targets).
		GitflowSignAdded = { link = "GitflowAdded" },
		GitflowSignModified = { link = "GitflowModified" },
		GitflowSignDeleted = { link = "GitflowRemoved" },
		GitflowSignConflict = { link = "GitflowConflictLocal" },
		-- Diff view — distinct styling for file headers, hunk headers, context
		GitflowDiffFileHeader = { fg = palette.diff_file_header, bold = true },
		GitflowDiffHunkHeader = { fg = palette.diff_hunk_header, bold = true },
		GitflowDiffContext = { link = "Comment" },
		GitflowDiffLineNr = { fg = palette.diff_line_nr },
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
		-- Worktree panel
		GitflowWorktreeCurrent = { link = "GitflowBranchCurrent" },
		GitflowWorktreeLocked = { link = "WarningMsg" },
		GitflowWorktreePrunable = { link = "Comment" },
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
		GitflowReviewAuthor = { fg = palette.accent_secondary, bold = true },
		GitflowReviewComment = { link = "Comment" },
		-- Inline comment "note box" rendered below diff lines
		GitflowReviewCommentBox = { fg = palette.separator_fg },
		GitflowReviewCommentBody = { link = "Normal" },
		GitflowReviewDraftBox = { fg = palette.accent_secondary },
		GitflowReviewDraftOutOfScope = { link = "DiagnosticError" },
		-- PR review file-tree chrome (folders / counts / decorations)
		GitflowReviewTreeDir = { fg = palette.accent_primary, bold = true },
		GitflowReviewTreeGuide = { fg = palette.separator_fg },
		GitflowReviewCountAdd = { link = "GitflowAdded" },
		GitflowReviewCountDel = { link = "GitflowRemoved" },
		GitflowReviewHint = { link = "Comment" },
		-- Log / Stash entry accents
		GitflowLogHash = { fg = palette.log_hash, bold = true },
		GitflowStashRef = { fg = palette.stash_ref, bold = true },
		-- Inline (current-line) blame virtual text
		GitflowBlameInline = { link = "Comment" },
		-- Window chrome — themed accent colors
		GitflowBorder = { fg = palette.accent_primary },
		GitflowTitle = { fg = palette.accent_primary, bold = true },
		GitflowHeader = { fg = palette.accent_primary, bold = true },
		GitflowFooter = { fg = palette.accent_primary, italic = true },
		GitflowSeparator = { fg = palette.separator_fg },
		-- Shared UI accents — footer keycaps, descriptions, section counts
		GitflowMuted = { link = "Comment" },
		GitflowKey = { fg = palette.accent_primary, bold = true },
		GitflowKeyDesc = { link = "Comment" },
		GitflowCount = { fg = palette.accent_secondary, bold = true },
		-- Dimmed backdrop drawn behind every floating panel for modal focus
		GitflowBackdrop = { bg = palette.backdrop_bg },
		-- Dashboard chrome
		GitflowDashLogo = { fg = palette.accent_primary, bold = true },
		GitflowDashTagline = { link = "Comment" },
		GitflowDashAction = { fg = palette.accent_secondary, bold = true },
		GitflowNormal = { link = "NormalFloat" },
		GitflowPaletteSelection = { link = "PmenuSel" },
		GitflowPaletteHeader = { bold = true, link = "Type" },
		GitflowPaletteKeybind = { link = "Special" },
		GitflowPaletteDescription = { link = "Comment" },
		GitflowPaletteIndex = { link = "Number" },
		GitflowPaletteCommand = { link = "Function" },
		GitflowPaletteNormal = { link = "NormalFloat" },
		GitflowPaletteHeaderBar = {
			fg = palette.dark_fg, bg = palette.accent_secondary, bold = true,
		},
		GitflowPaletteHeaderIcon = {
			fg = palette.accent_primary, bg = palette.accent_secondary,
			bold = true,
		},
		GitflowPaletteEntryIcon = { fg = palette.accent_primary },
		GitflowPaletteBackdrop = { bg = palette.backdrop_bg },
		-- Blame
		GitflowBlameHash = { fg = palette.log_hash, bold = true },
		GitflowBlameAuthor = { fg = palette.accent_primary },
		GitflowBlameDate = { link = "Comment" },
		-- Reset
		GitflowResetMergeBase = { link = "WarningMsg" },
		-- Revert
		GitflowRevertMergeBase = { link = "WarningMsg" },
		-- Reflog
		GitflowReflogHash = { fg = palette.log_hash, bold = true },
		GitflowReflogAction = { fg = palette.accent_secondary },
		-- Tag
		GitflowTagAnnotated = { fg = palette.stash_ref, bold = true },
		-- Actions / CI
		GitflowActionsPass = { link = "DiagnosticOk" },
		GitflowActionsFail = { link = "DiagnosticError" },
		GitflowActionsPending = { link = "DiagnosticWarn" },
		GitflowActionsCancelled = { link = "Comment" },
		-- Cherry Pick
		GitflowCherryPickBranch = { fg = palette.stash_ref, bold = true },
		GitflowCherryPickHash = { fg = palette.log_hash, bold = true },
		-- Interactive Rebase
		GitflowRebasePick = { link = "DiagnosticOk" },
		GitflowRebaseReword = { fg = palette.stash_ref, bold = true },
		GitflowRebaseEdit = { fg = palette.accent_primary, bold = true },
		GitflowRebaseSquash = { fg = palette.accent_secondary, bold = true },
		GitflowRebaseFixup = { fg = palette.accent_secondary },
		GitflowRebaseDrop = { link = "DiagnosticError" },
		GitflowRebaseHash = { fg = palette.log_hash, bold = true },
		-- Notifications
		GitflowNotificationError = { link = "ErrorMsg" },
		GitflowNotificationWarn = { link = "WarningMsg" },
		GitflowNotificationInfo = { link = "Normal" },
		-- Form
		GitflowFormLabel = { fg = palette.accent_primary, bold = true },
		GitflowFormActiveField = { link = "CursorLine" },
		-- Branch graph
		GitflowGraphLine = { fg = palette.accent_primary },
		GitflowGraphHash = { fg = palette.log_hash, bold = true },
		GitflowGraphDecoration = { fg = palette.stash_ref, bold = true },
		GitflowGraphCurrent = { fg = palette.accent_primary, bold = true },
		GitflowGraphSubject = { link = "Normal" },
		GitflowGraphNode = { fg = palette.accent_secondary, bold = true },
		GitflowGraphBranch1 = { fg = palette.accent_primary },
		GitflowGraphBranch2 = { fg = palette.accent_secondary },
		GitflowGraphBranch3 = { fg = "#98C379" },
		GitflowGraphBranch4 = { fg = "#E06C75" },
		GitflowGraphBranch5 = { fg = "#61AFEF" },
		GitflowGraphBranch6 = { fg = "#C678DD" },
		GitflowGraphBranch7 = { fg = "#E5C07B" },
		GitflowGraphBranch8 = { fg = "#7F848E" },
	}
end

--- Current default groups — rebuilt by setup() for background-aware palettes.
M.DEFAULT_GROUPS = build_default_groups(M.PALETTE_DARK)

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

	-- Select palette based on vim.o.background
	local palette = vim.o.background == "light"
		and M.PALETTE_LIGHT or M.PALETTE_DARK
	M.PALETTE = vim.deepcopy(palette)
	M.DEFAULT_GROUPS = build_default_groups(palette)

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
