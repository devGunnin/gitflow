local M = {}

--- Dark palette — used when vim.o.background == "dark" (default).
---@type table<string, string>
M.PALETTE_DARK = {
	accent_primary = "#56B6C2",
	accent_secondary = "#DCA561",
	separator_fg = "#3E4452",
	backdrop_bg = "#000000",
	dark_fg = "#222222",
	log_hash = "#E5C07B",
	stash_ref = "#C678DD",
	diff_file_header = "#E5C07B",
	diff_hunk_header = "#C678DD",
	diff_line_nr = "#5C6370",
}

--- Light palette — used when vim.o.background == "light".
---@type table<string, string>
M.PALETTE_LIGHT = {
	accent_primary = "#0E7490",
	accent_secondary = "#B5651D",
	separator_fg = "#C8CCD4",
	backdrop_bg = "#E8E8E8",
	dark_fg = "#222222",
	log_hash = "#986801",
	stash_ref = "#A626A4",
	diff_file_header = "#986801",
	diff_hunk_header = "#A626A4",
	diff_line_nr = "#999999",
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
		-- Single-pane inline conflict resolver
		GitflowConflictOurs = { link = "DiffAdd" },
		GitflowConflictTheirs = { link = "DiffText" },
		GitflowConflictMarker = { fg = palette.separator_fg, bold = true, italic = true },
		GitflowConflictOursLabel = { fg = palette.accent_primary, bold = true },
		GitflowConflictTheirsLabel = { fg = palette.stash_ref, bold = true },
		-- Branch
		GitflowBranchCurrent = { link = "Title" },
		GitflowBranchRemote = { link = "Comment" },
		-- Worktree panel
		GitflowWorktreeCurrent = { link = "GitflowBranchCurrent" },
		GitflowWorktreeLocked = { link = "WarningMsg" },
		GitflowWorktreePrunable = { link = "Comment" },
		GitflowWorktreeDirty = { link = "DiagnosticWarn" },
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
		-- UI/UX overhaul — cards, chips, sections, hint bars, pickers, forms
		GitflowNumber = { fg = palette.accent_secondary, bold = true },
		GitflowMeta = { link = "Comment" },
		GitflowMetaKey = { fg = palette.separator_fg },
		GitflowCardTitle = { link = "Normal" },
		GitflowCardTitleDim = { link = "Comment" },
		GitflowRelTime = { link = "Comment" },
		GitflowAuthor = { fg = palette.accent_primary },
		GitflowChip = { fg = palette.accent_primary },
		GitflowCount = { fg = palette.accent_secondary },
		GitflowSectionIcon = { fg = palette.accent_primary, bold = true },
		GitflowSectionTitle = { fg = palette.accent_primary, bold = true },
		GitflowDetailTitle = { fg = palette.accent_primary, bold = true },
		GitflowHintKey = { fg = palette.accent_secondary, bold = true },
		GitflowHintText = { link = "Comment" },
		GitflowHintSep = { fg = palette.separator_fg },
		GitflowPickerPrompt = { fg = palette.accent_primary, bold = true },
		GitflowPickerPromptIcon = { fg = palette.accent_secondary, bold = true },
		GitflowPickerMatch = { fg = palette.accent_secondary, bold = true },
		GitflowPickerCheck = { link = "DiagnosticOk" },
		GitflowPickerCheckOff = { fg = palette.separator_fg },
		GitflowPickerCount = { link = "Comment" },
		GitflowFormHeader = { fg = palette.accent_primary, bold = true },
		GitflowFormPlaceholder = { fg = palette.separator_fg, italic = true },
		GitflowFormSection = { fg = palette.accent_secondary, bold = true },
		GitflowFormHint = { link = "Comment" },
		-- Shared state feedback — loading / error / empty placeholders so every
		-- surface shows the same cohesive language instead of plain text. The
		-- error/spinner accents link to standard semantic groups so they follow
		-- the user's colorscheme.
		GitflowLoadingIcon = { fg = palette.accent_primary, bold = true },
		GitflowLoadingText = { link = "Comment" },
		GitflowStateError = { link = "DiagnosticError" },
		GitflowStateErrorIcon = { link = "DiagnosticError" },
		GitflowStateErrorDetail = { link = "Comment" },
		GitflowEmptyIcon = { fg = palette.separator_fg },
		GitflowEmptyText = { link = "Comment" },
		GitflowEmptyHint = { link = "Comment" },
		-- Grouped key-hint blocks (review panel and other dense surfaces): a dim
		-- group label sits above its hints, matching the form-section accent.
		GitflowHintGroupLabel = { fg = palette.accent_secondary, bold = true },
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

---@class GitflowHighlightsState
---@field augroup integer|nil
---@field overrides table<string, table>|nil  nil until setup() runs

---@type GitflowHighlightsState
M.state = {
	augroup = nil,
	overrides = nil,
}

---Rebuild the palette from vim.o.background and apply every group.
---@param overrides table<string, table>
local function apply_groups(overrides)
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

---Re-apply highlights against the current theme, reusing the overrides
---setup() was called with. No-op when gitflow was never set up.
function M.refresh()
	if M.state.overrides == nil then
		return
	end
	apply_groups(M.state.overrides)
end

---A ColorScheme change wipes user highlight groups, and a background flip
---changes which palette applies — both need the groups recomputed.
local function register_theme_autocmds()
	if M.state.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M.state.augroup)
	end
	M.state.augroup = vim.api.nvim_create_augroup("GitflowHighlights", { clear = true })

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = M.state.augroup,
		desc = "gitflow: re-apply highlights after a colorscheme change",
		callback = function()
			M.refresh()
		end,
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = M.state.augroup,
		pattern = "background",
		desc = "gitflow: re-apply highlights after a background change",
		callback = function()
			M.refresh()
		end,
	})
end

---@param user_overrides table<string, table>|nil
function M.setup(user_overrides)
	M.state.overrides = type(user_overrides) == "table"
		and vim.deepcopy(user_overrides) or {}
	apply_groups(M.state.overrides)
	register_theme_autocmds()
end

return M
