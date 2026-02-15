local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed = 0
local total = 0

local function assert_true(condition, message)
	total = total + 1
	if not condition then
		error(message, 2)
	end
	passed = passed + 1
end

local function assert_equals(actual, expected, message)
	total = total + 1
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			),
			2
		)
	end
	passed = passed + 1
end

-- ── 1. PALETTE table ─────────────────────────────────────────────

local highlights = require("gitflow.highlights")

assert_true(
	type(highlights.PALETTE) == "table",
	"highlights should export PALETTE table"
)

local expected_keys = {
	"accent_primary",
	"accent_secondary",
	"separator_fg",
	"backdrop_bg",
	"dark_fg",
	"log_hash",
	"stash_ref",
}

for _, key in ipairs(expected_keys) do
	local value = highlights.PALETTE[key]
	assert_true(
		type(value) == "string",
		("PALETTE.%s should be a string"):format(key)
	)
	assert_true(
		value:match("^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]"
			.. "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") ~= nil,
		("PALETTE.%s should be a valid hex color, got: %s"):format(
			key, value
		)
	)
end

-- ── 2. New highlight groups ──────────────────────────────────────

local new_groups = {
	GitflowLogHash = { has_fg = true, has_bold = true },
	GitflowStashRef = { has_fg = true, has_bold = true },
}

for group, expected in pairs(new_groups) do
	local attrs = highlights.DEFAULT_GROUPS[group]
	assert_true(
		attrs ~= nil,
		("%s should exist in DEFAULT_GROUPS"):format(group)
	)
	if expected.has_fg then
		assert_true(
			attrs.fg ~= nil,
			("%s should have explicit fg color"):format(group)
		)
	end
	if expected.has_bold then
		assert_true(
			attrs.bold == true,
			("%s should be bold"):format(group)
		)
	end
end

-- Verify accent colors match PALETTE
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowLogHash.fg,
	highlights.PALETTE.log_hash,
	"GitflowLogHash fg should match PALETTE.log_hash"
)
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowStashRef.fg,
	highlights.PALETTE.stash_ref,
	"GitflowStashRef fg should match PALETTE.stash_ref"
)

-- ── 3. Setup applies new groups ──────────────────────────────────

highlights.setup({})

local function get_hl(name)
	return vim.api.nvim_get_hl(0, { name = name, link = false })
end

local log_hash_hl = get_hl("GitflowLogHash")
assert_true(
	log_hash_hl.fg ~= nil,
	"GitflowLogHash should have fg after setup"
)
assert_true(
	log_hash_hl.bold == true,
	"GitflowLogHash should be bold after setup"
)

local stash_ref_hl = get_hl("GitflowStashRef")
assert_true(
	stash_ref_hl.fg ~= nil,
	"GitflowStashRef should have fg after setup"
)
assert_true(
	stash_ref_hl.bold == true,
	"GitflowStashRef should be bold after setup"
)

-- ── 4. Split window winhighlight ─────────────────────────────────

local window = require("gitflow.ui.window")
local test_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, { "test" })

local split_winid = window.open_split({
	bufnr = test_buf,
	name = "test_split_hl",
	orientation = "vertical",
	size = 30,
})

local winhighlight = vim.api.nvim_get_option_value(
	"winhighlight", { win = split_winid }
)
assert_true(
	winhighlight:find("Normal:GitflowNormal") ~= nil,
	"split winhighlight should map Normal to GitflowNormal"
)

window.close("test_split_hl")
vim.api.nvim_buf_delete(test_buf, { force = true })

-- ── 5. Panel module loads ────────────────────────────────────────

local panel_modules = {
	"gitflow.panels.log",
	"gitflow.panels.stash",
	"gitflow.panels.issues",
	"gitflow.panels.prs",
	"gitflow.panels.labels",
	"gitflow.panels.conflict",
	"gitflow.panels.review",
}

for _, mod_name in ipairs(panel_modules) do
	local ok, _ = pcall(require, mod_name)
	assert_true(ok, ("panel %s should load without error"):format(mod_name))
end

-- ── 6. PALETTE consistency with DEFAULT_GROUPS ───────────────────

-- Chrome groups should use PALETTE accent_primary
local chrome_groups = {
	"GitflowBorder",
	"GitflowTitle",
	"GitflowHeader",
	"GitflowFooter",
	"GitflowFormLabel",
	"GitflowPaletteEntryIcon",
}
for _, group in ipairs(chrome_groups) do
	local attrs = highlights.DEFAULT_GROUPS[group]
	assert_true(attrs ~= nil, ("%s should exist"):format(group))
	assert_equals(
		attrs.fg,
		highlights.PALETTE.accent_primary,
		("%s fg should match PALETTE.accent_primary"):format(group)
	)
end

-- Open issue/PR rows should preserve the requested DiagnosticOk green
local open_state_groups = {
	"GitflowIssueOpen",
	"GitflowPROpen",
}
for _, group in ipairs(open_state_groups) do
	local attrs = highlights.DEFAULT_GROUPS[group]
	assert_true(attrs ~= nil, ("%s should exist"):format(group))
	assert_equals(
		attrs.link,
		"DiagnosticOk",
		("%s should link to DiagnosticOk"):format(group)
	)
end

-- Separator should use PALETTE separator_fg
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowSeparator.fg,
	highlights.PALETTE.separator_fg,
	"GitflowSeparator fg should match PALETTE.separator_fg"
)

-- Palette header bar should use PALETTE accent_secondary
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowPaletteHeaderBar.bg,
	highlights.PALETTE.accent_secondary,
	"GitflowPaletteHeaderBar bg should match PALETTE.accent_secondary"
)
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowPaletteHeaderBar.fg,
	highlights.PALETTE.dark_fg,
	"GitflowPaletteHeaderBar fg should match PALETTE.dark_fg"
)

-- Backdrop should use PALETTE backdrop_bg
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowPaletteBackdrop.bg,
	highlights.PALETTE.backdrop_bg,
	"GitflowPaletteBackdrop bg should match PALETTE.backdrop_bg"
)

print(
	("Palette accent parity tests passed (%d/%d assertions)")
		:format(passed, total)
)
