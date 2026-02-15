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
	assert_equals(hl.link, attrs.link, ("%s should link to default group"):format(group))
end

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

-- Light background should use light palette colors
local light_sep = get_highlight("GitflowSeparator", { link = false })
assert_equals(
	light_sep.fg,
	tonumber(highlights.PALETTE_LIGHT.separator_fg:sub(2), 16),
	"light background should apply light separator color"
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
