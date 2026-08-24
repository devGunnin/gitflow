-- The two accent tokens are derived from the colorscheme instead of being
-- stamped in: Special -> accent_primary, Identifier -> accent_secondary, with
-- the background palette's hexes as the fallback. Verified against two stub
-- colorschemes plus a colorscheme that defines neither.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, total = 0, 0
local function assert_equals(actual, expected, msg)
	total = total + 1
	if actual ~= expected then
		error(("%s (expected=%s, actual=%s)"):format(
			msg, vim.inspect(expected), vim.inspect(actual)
		), 2)
	end
	passed = passed + 1
end

local highlights = require("gitflow.highlights")

---Stand in for a colorscheme: wipe the two accent sources, then set whatever
---this stub defines.
---@param stub table  { Special = "#RRGGBB"|nil, Identifier = "#RRGGBB"|nil }
local function apply_colorscheme(stub)
	for _, group in ipairs({ "Special", "Identifier" }) do
		vim.api.nvim_set_hl(0, group, stub[group] and { fg = stub[group] } or {})
	end
	highlights.setup({})
end

---@param group string
---@return integer|nil
local function applied_fg(group)
	local attrs = vim.api.nvim_get_hl(0, { name = group, link = false })
	return type(attrs) == "table" and attrs.fg or nil
end

---@param hex string
---@return integer
local function as_number(hex)
	return tonumber(hex:gsub("^#", ""), 16)
end

local original_background = vim.o.background
vim.o.background = "dark"

-- ── stub colorscheme A ───────────────────────────────────────────────
apply_colorscheme({ Special = "#B16286", Identifier = "#83A598" })
assert_equals(
	highlights.PALETTE.accent_primary, "#B16286",
	"accent_primary should follow the colorscheme's Special"
)
assert_equals(
	highlights.PALETTE.accent_secondary, "#83A598",
	"accent_secondary should follow the colorscheme's Identifier"
)
assert_equals(
	applied_fg("GitflowTitle"), as_number("#B16286"),
	"GitflowTitle should be painted with the derived primary accent"
)
assert_equals(
	applied_fg("GitflowHintKey"), as_number("#83A598"),
	"GitflowHintKey should be painted with the derived secondary accent"
)

-- ── stub colorscheme B — a different theme moves the accents ─────────
apply_colorscheme({ Special = "#F5C2E7", Identifier = "#89B4FA" })
assert_equals(
	highlights.PALETTE.accent_primary, "#F5C2E7",
	"a second colorscheme should move accent_primary with it"
)
assert_equals(
	applied_fg("GitflowBorder"), as_number("#F5C2E7"),
	"GitflowBorder should follow the second colorscheme"
)

-- Semantic groups stay linked whatever the colorscheme does: the link=
-- discipline is what makes gitflow inherit the user's theme.
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowAdded.link, "DiffAdd",
	"linked semantic groups should be unchanged by accent derivation"
)
assert_equals(
	highlights.DEFAULT_GROUPS.GitflowPROpen.link, "DiagnosticOk",
	"PR state groups should stay linked"
)

-- ── a colorscheme defining neither falls back to the hardcoded hexes ─
apply_colorscheme({})
assert_equals(
	highlights.PALETTE.accent_primary,
	highlights.PALETTE_DARK.accent_primary,
	"accent_primary should fall back to the dark palette hex"
)
assert_equals(
	highlights.PALETTE.accent_secondary,
	highlights.PALETTE_DARK.accent_secondary,
	"accent_secondary should fall back to the dark palette hex"
)

vim.o.background = "light"
apply_colorscheme({})
assert_equals(
	highlights.PALETTE.accent_primary,
	highlights.PALETTE_LIGHT.accent_primary,
	"the fallback should follow the background"
)

-- ── the chrome tokens are not accents and never derive ───────────────
vim.o.background = "dark"
apply_colorscheme({ Special = "#B16286", Identifier = "#83A598" })
assert_equals(
	highlights.PALETTE.separator_fg,
	highlights.PALETTE_DARK.separator_fg,
	"separator_fg is chrome, not an accent, and should not derive"
)

-- ── a user override still wins over a derived accent ─────────────────
highlights.setup({ GitflowTitle = { fg = "#FF0000" } })
assert_equals(
	applied_fg("GitflowTitle"), as_number("#FF0000"),
	"a user override should beat the derived accent"
)

vim.o.background = original_background
highlights.setup({})

print(("Palette derivation tests passed (%d/%d assertions)"):format(passed, total))
