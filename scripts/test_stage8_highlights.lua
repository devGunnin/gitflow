local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
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
end

local function get_highlight(name, opts)
	local options = vim.tbl_extend("force", { name = name }, opts or {})
	local ok, value = pcall(vim.api.nvim_get_hl, 0, options)
	assert_true(ok, ("expected highlight '%s' to exist"):format(name))
	return value
end

local highlights = require("gitflow.highlights")
local config = require("gitflow.config")

local defaults = config.defaults()
assert_true(
	type(defaults.highlights) == "table",
	"config.defaults should include highlights table"
)

local invalid = vim.deepcopy(defaults)
invalid.highlights = "invalid"
local ok_invalid, err_invalid = pcall(config.validate, invalid)
assert_true(not ok_invalid, "config.validate should reject non-table highlights")
assert_true(
	tostring(err_invalid):find("highlights", 1, true) ~= nil,
	"invalid highlight config error should mention highlights"
)

-- ── PALETTE validation ───────────────────────────────────────────
assert_true(type(highlights.PALETTE) == "table", "highlights.PALETTE should exist")
local expected_palette_keys = {
	"accent_primary", "accent_secondary", "separator_fg",
	"backdrop_bg", "dark_fg", "log_hash", "stash_ref",
}
for _, key in ipairs(expected_palette_keys) do
	assert_true(
		type(highlights.PALETTE[key]) == "string",
		("PALETTE.%s should be a string"):format(key)
	)
	assert_true(
		highlights.PALETTE[key]:match("^#%x%x%x%x%x%x$") ~= nil,
		("PALETTE.%s should be a 6-digit hex color"):format(key)
	)
end

for group, attrs in pairs(highlights.DEFAULT_GROUPS) do
	local has_link = type(attrs.link) == "string"
	local has_explicit = attrs.fg ~= nil or attrs.bg ~= nil
	assert_true(
		has_link or has_explicit,
		("%s should define a default link or explicit colors"):format(
			group
		)
	)
end

local original_background = vim.o.background
vim.o.background = "dark"
highlights.setup({})

for group, attrs in pairs(highlights.DEFAULT_GROUPS) do
	local hl = get_highlight(group)
	if attrs.link then
		assert_equals(
			hl.link, attrs.link,
			("%s should link to %s"):format(group, attrs.link)
		)
	else
		local resolved = get_highlight(group, { link = false })
		if attrs.fg then
			local expected_fg = tonumber(attrs.fg:gsub("^#", ""), 16)
			assert_equals(
				resolved.fg, expected_fg,
				("%s should have fg=%s"):format(group, attrs.fg)
			)
		end
		if attrs.bg then
			local expected_bg = tonumber(attrs.bg:gsub("^#", ""), 16)
			assert_equals(
				resolved.bg, expected_bg,
				("%s should have bg=%s"):format(group, attrs.bg)
			)
		end
	end
end

-- ── Themed accent groups: attribute validation after setup ────────
local accent_primary_num = tonumber(
	highlights.PALETTE.accent_primary:gsub("^#", ""), 16
)
local separator_fg_num = tonumber(
	highlights.PALETTE.separator_fg:gsub("^#", ""), 16
)

local border_hl = get_highlight("GitflowBorder", { link = false })
assert_equals(
	border_hl.fg, accent_primary_num,
	"GitflowBorder fg should match PALETTE.accent_primary"
)

local title_hl = get_highlight("GitflowTitle", { link = false })
assert_equals(
	title_hl.fg, accent_primary_num,
	"GitflowTitle fg should match PALETTE.accent_primary"
)
assert_true(title_hl.bold == true, "GitflowTitle should be bold after setup")

local header_hl = get_highlight("GitflowHeader", { link = false })
assert_equals(
	header_hl.fg, accent_primary_num,
	"GitflowHeader fg should match PALETTE.accent_primary"
)
assert_true(header_hl.bold == true, "GitflowHeader should be bold after setup")

local footer_hl = get_highlight("GitflowFooter", { link = false })
assert_equals(
	footer_hl.fg, accent_primary_num,
	"GitflowFooter fg should match PALETTE.accent_primary"
)
assert_true(
	footer_hl.italic == true,
	"GitflowFooter should be italic after setup"
)

local sep_hl = get_highlight("GitflowSeparator", { link = false })
assert_equals(
	sep_hl.fg, separator_fg_num,
	"GitflowSeparator fg should match PALETTE.separator_fg"
)

vim.o.background = "light"
highlights.setup({})
assert_equals(
	get_highlight("GitflowAdded").link,
	"DiffAdd",
	"defaults should remain link-based in light"
)
assert_equals(
	get_highlight("GitflowPaletteSelection").link,
	"PmenuSel",
	"palette selection highlight should remain defined"
)

highlights.setup({
	GitflowAdded = { fg = "#00ff00", bold = true },
})

local added_no_link = get_highlight("GitflowAdded", { link = false })
assert_equals(
	added_no_link.fg,
	tonumber("00ff00", 16),
	"override should set GitflowAdded fg"
)
assert_true(added_no_link.bold == true, "override should set GitflowAdded bold")
assert_true(get_highlight("GitflowAdded").link == nil, "override should replace default link")

highlights.setup({})
assert_equals(
	get_highlight("GitflowAdded").link,
	"DiffAdd",
	"setup should be idempotent across calls"
)

-- ── Override round-trip for explicit-color group ──────────────────
highlights.setup({ GitflowBorder = { fg = "#FF00FF" } })
local border_override = get_highlight("GitflowBorder", { link = false })
assert_equals(
	border_override.fg,
	tonumber("FF00FF", 16),
	"GitflowBorder override should apply custom fg"
)

highlights.setup({})
local border_restored = get_highlight("GitflowBorder", { link = false })
assert_equals(
	border_restored.fg,
	accent_primary_num,
	"GitflowBorder should restore PALETTE.accent_primary after reset"
)

local gh = require("gitflow.gh")
local original_check_prerequisites = gh.check_prerequisites

gh.check_prerequisites = function(_)
	gh.state.checked = true
	gh.state.available = true
	gh.state.authenticated = true
	return true
end

local gitflow = require("gitflow")
gitflow.setup({
	highlights = {
		GitflowAdded = { fg = "#123456" },
	},
})

local setup_override = get_highlight("GitflowAdded", { link = false })
assert_equals(
	setup_override.fg,
	tonumber("123456", 16),
	"gitflow.setup highlights override should propagate"
)

gh.check_prerequisites = original_check_prerequisites
vim.o.background = original_background

print("Stage 8 highlight tests passed")
