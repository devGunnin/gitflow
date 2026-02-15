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

-- ── 1. render.lua helpers ────────────────────────────────────────

local ui_render = require("gitflow.ui.render")

-- separator() returns adaptive width (vim.o.columns when no window context)
local sep = ui_render.separator()
local expected_default_width = vim.o.columns
local char_len_check = #"\u{2500}"
assert_equals(
	#sep,
	expected_default_width * char_len_check,
	"separator default should adapt to vim.o.columns"
)
assert_true(sep:find("─") ~= nil, "separator should use box-drawing horizontal char")

-- separator(n) returns correct custom width
local sep10 = ui_render.separator(10)
local char_len = #"\u{2500}"
assert_equals(#sep10, 10 * char_len, "separator(10) should repeat 10 times")

-- separator(opts) uses fallback width when no window context is available
local sep_opts = ui_render.separator({ fallback = 37 })
assert_equals(#sep_opts, 37 * char_len, "separator(opts) should use fallback width")

-- content_width() with no opts uses vim.o.columns as fallback
local cw_default = ui_render.content_width()
assert_equals(
	cw_default,
	vim.o.columns,
	"content_width() with no opts should return vim.o.columns"
)

-- content_width() with explicit fallback honors that value
local cw_explicit = ui_render.content_width({ fallback = 42 })
assert_equals(cw_explicit, 42, "content_width() should honor explicit fallback")

-- ui.separator_width config override takes precedence over vim.o.columns
local cfg = require("gitflow.config")
local saved = cfg.current.ui.separator_width
cfg.current.ui.separator_width = 60
local cw_cfg = ui_render.content_width()
assert_equals(cw_cfg, 60, "content_width() should use ui.separator_width when set")
local sep_cfg = ui_render.separator()
assert_equals(#sep_cfg, 60 * char_len, "separator() should use ui.separator_width when set")
cfg.current.ui.separator_width = saved

-- title() returns text as-is
assert_equals(ui_render.title("Gitflow Status"), "Gitflow Status", "title should return text as-is")

-- section() returns header and separator
local header, section_sep = ui_render.section("Staged Changes", 5)
assert_equals(header, "Staged Changes (5)", "section header should include count")
assert_true(section_sep:find("─") ~= nil, "section separator should be a separator line")

-- section() without count
local header_no_count = ui_render.section("Details")
assert_equals(header_no_count, "Details", "section header without count should be plain text")

-- empty() default
assert_equals(ui_render.empty(), "  (none)", "empty() default should be indented '(none)'")

-- empty() with custom text
assert_equals(ui_render.empty("no items"), "  no items", "empty() should indent custom text")

-- entry() indents text
assert_equals(ui_render.entry("file.txt"), "  file.txt", "entry should indent with 2 spaces")

-- footer() returns text as-is
assert_equals(
	ui_render.footer("q quit  r refresh"),
	"q quit  r refresh",
	"footer should return hints"
)

-- format_key_hints()
local hints = ui_render.format_key_hints({
	{ "q", "quit" },
	{ "r", "refresh" },
})
assert_equals(
	hints,
	"q quit  r refresh",
	"format_key_hints should join pairs with double space"
)

-- panel_header() keeps inline title by default/split layout
local ph_split = ui_render.panel_header("Gitflow Test")
assert_equals(#ph_split, 2, "panel_header should return title+separator in split/default layout")
assert_equals(ph_split[1], "Gitflow Test", "split/default panel_header first line should be title")
assert_true(
	ph_split[2]:find("─") ~= nil,
	"split/default panel_header second line should be separator"
)

-- panel_header() omits inline title in float layout to avoid duplicate title chrome
local ph_float_buf = vim.api.nvim_create_buf(false, true)
local ph_float_win = vim.api.nvim_open_win(ph_float_buf, false, {
	relative = "editor",
	row = 1,
	col = 1,
	width = 40,
	height = 5,
	style = "minimal",
	border = "rounded",
})
local ph_float = ui_render.panel_header("Gitflow Test", { winid = ph_float_win })
assert_equals(#ph_float, 1, "panel_header should only include separator in float layout")
assert_true(ph_float[1]:find("─") ~= nil, "float panel_header line should be separator")
vim.api.nvim_win_close(ph_float_win, true)
vim.api.nvim_buf_delete(ph_float_buf, { force = true })

-- panel_header() should suppress inline title for float windows
local header_buf = vim.api.nvim_create_buf(false, true)
local header_win = vim.api.nvim_open_win(header_buf, false, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 40,
	height = 4,
	style = "minimal",
	border = "single",
})
local ph_float = ui_render.panel_header("Gitflow Float Header", { winid = header_win })
assert_equals(#ph_float, 1, "panel_header should omit inline title in float layout")
assert_true(ph_float[1]:find("─") ~= nil, "float panel_header should keep separator line")
vim.api.nvim_win_close(header_win, true)
vim.api.nvim_buf_delete(header_buf, { force = true })

-- panel_footer() with branch and hints
local pf = ui_render.panel_footer("main", "q quit")
assert_true(#pf >= 3, "panel_footer with branch+hints should have at least 3 lines")
local has_branch = false
local has_footer = false
for _, line in ipairs(pf) do
	if line:find("Current branch: main") then
		has_branch = true
	end
	if line == "q quit" then
		has_footer = true
	end
end
assert_true(has_branch, "panel_footer should include current branch")
assert_true(has_footer, "panel_footer should include key hints")

-- panel_footer() without branch
local pf_no_branch = ui_render.panel_footer(nil, "q quit")
local found_branch = false
for _, line in ipairs(pf_no_branch) do
	if line:find("Current branch") then
		found_branch = true
	end
end
assert_true(not found_branch, "panel_footer without branch should not include branch line")

-- ── 2. apply_panel_highlights ────────────────────────────────────

local ns = vim.api.nvim_create_namespace("test_unified_theme")
local bufnr = vim.api.nvim_create_buf(false, true)

local test_lines = {
	"Gitflow Test Panel",
	ui_render.separator(),
	"Section Header",
	"  entry one",
	"  entry two",
	"",
	"q: quit  r: refresh",
}

vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, test_lines)
vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

-- apply with footer and entry highlights
ui_render.apply_panel_highlights(bufnr, ns, test_lines, {
	footer_line = 7,
	entry_highlights = {
		[3] = "GitflowHeader",
	},
})

-- Check title highlight (line 0)
local title_hl =
	vim.api.nvim_buf_get_extmarks(bufnr, ns, { 0, 0 }, { 0, -1 }, { details = true })
assert_true(#title_hl > 0, "title line should have highlights")
assert_equals(title_hl[1][4].hl_group, "GitflowTitle", "title should use GitflowTitle highlight")

-- Check separator highlight (line 1)
local sep_hl =
	vim.api.nvim_buf_get_extmarks(bufnr, ns, { 1, 0 }, { 1, -1 }, { details = true })
assert_true(#sep_hl > 0, "separator line should have highlights")
assert_equals(
	sep_hl[1][4].hl_group,
	"GitflowSeparator",
	"separator should use GitflowSeparator highlight"
)

-- Check footer highlight (line 6)
local footer_hl =
	vim.api.nvim_buf_get_extmarks(bufnr, ns, { 6, 0 }, { 6, -1 }, { details = true })
assert_true(#footer_hl > 0, "footer line should have highlights")
assert_equals(
	footer_hl[1][4].hl_group,
	"GitflowFooter",
	"footer should use GitflowFooter highlight"
)

-- Check entry highlight (line 2)
local entry_hl =
	vim.api.nvim_buf_get_extmarks(bufnr, ns, { 2, 0 }, { 2, -1 }, { details = true })
assert_true(#entry_hl > 0, "entry_highlights line should have highlights")
assert_equals(
	entry_hl[1][4].hl_group,
	"GitflowHeader",
	"entry_highlights should apply specified group"
)

-- Clearing: re-apply and check old marks are gone
ui_render.apply_panel_highlights(bufnr, ns, { "Title Only" }, {})
local old_sep_hl =
	vim.api.nvim_buf_get_extmarks(bufnr, ns, { 1, 0 }, { 1, -1 }, { details = true })
assert_equals(#old_sep_hl, 0, "re-apply should clear previous namespace highlights")

-- Separator-first headers should not receive GitflowTitle highlight
local separator_only_lines = { ui_render.separator(), "Body line" }
ui_render.apply_panel_highlights(bufnr, ns, separator_only_lines, {})
local separator_title_hl =
	vim.api.nvim_buf_get_extmarks(bufnr, ns, { 0, 0 }, { 0, -1 }, { details = true })
assert_true(#separator_title_hl > 0, "separator line should be highlighted")
assert_equals(
	separator_title_hl[1][4].hl_group,
	"GitflowSeparator",
	"separator-first header should not apply GitflowTitle to line 0"
)

-- Invalid buffer should not error
ui_render.apply_panel_highlights(-1, ns, test_lines, {})
assert_true(true, "apply_panel_highlights with invalid bufnr should not error")

-- Separator-first headers (float mode) should not apply GitflowTitle on line 0
local bufnr_no_title = vim.api.nvim_create_buf(false, true)
local no_title_lines = { ui_render.separator(20), "content" }
vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr_no_title })
vim.api.nvim_buf_set_lines(bufnr_no_title, 0, -1, false, no_title_lines)
vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr_no_title })
ui_render.apply_panel_highlights(bufnr_no_title, ns, no_title_lines, {})
local line0_hl =
	vim.api.nvim_buf_get_extmarks(bufnr_no_title, ns, { 0, 0 }, { 0, -1 }, { details = true })
local found_title_hl = false
for _, mark in ipairs(line0_hl) do
	if mark[4].hl_group == "GitflowTitle" then
		found_title_hl = true
	end
end
assert_true(not found_title_hl, "separator-first header should not apply GitflowTitle to line 0")
vim.api.nvim_buf_delete(bufnr_no_title, { force = true })

vim.api.nvim_buf_delete(bufnr, { force = true })

-- ── 3. highlight group definitions ──────────────────────────────

local highlights = require("gitflow.highlights")

-- Theme accent groups should have explicit fg colors (not links)
local themed_groups = {
	"GitflowBorder",
	"GitflowTitle",
	"GitflowHeader",
	"GitflowFooter",
	"GitflowSeparator",
}

for _, group in ipairs(themed_groups) do
	local attrs = highlights.DEFAULT_GROUPS[group]
	assert_true(attrs ~= nil, ("%s should exist in DEFAULT_GROUPS"):format(group))
	assert_true(attrs.fg ~= nil, ("%s should have explicit fg color"):format(group))
	assert_true(attrs.link == nil, ("%s should not be a link (uses explicit color)"):format(group))
end

-- GitflowNormal should link to NormalFloat
local normal_attrs = highlights.DEFAULT_GROUPS.GitflowNormal
assert_true(normal_attrs ~= nil, "GitflowNormal should exist in DEFAULT_GROUPS")
assert_equals(normal_attrs.link, "NormalFloat", "GitflowNormal should link to NormalFloat")

-- Accent color consistency: border and title share the same fg
local border_fg = highlights.DEFAULT_GROUPS.GitflowBorder.fg
local title_fg = highlights.DEFAULT_GROUPS.GitflowTitle.fg
local header_fg = highlights.DEFAULT_GROUPS.GitflowHeader.fg
assert_equals(border_fg, title_fg, "border and title should share accent color")
assert_equals(title_fg, header_fg, "title and header should share accent color")

-- GitflowTitle and GitflowHeader should be bold
assert_true(
	highlights.DEFAULT_GROUPS.GitflowTitle.bold == true,
	"GitflowTitle should be bold"
)
assert_true(
	highlights.DEFAULT_GROUPS.GitflowHeader.bold == true,
	"GitflowHeader should be bold"
)

-- GitflowFooter should be italic
assert_true(
	highlights.DEFAULT_GROUPS.GitflowFooter.italic == true,
	"GitflowFooter should be italic"
)

-- Setup applies highlights correctly
highlights.setup({})
local function get_hl(name)
	return vim.api.nvim_get_hl(0, { name = name, link = false })
end

local title_hl_applied = get_hl("GitflowTitle")
assert_true(title_hl_applied.fg ~= nil, "GitflowTitle should have fg after setup")
assert_true(title_hl_applied.bold == true, "GitflowTitle should be bold after setup")

local sep_hl_applied = get_hl("GitflowSeparator")
assert_true(sep_hl_applied.fg ~= nil, "GitflowSeparator should have fg after setup")

-- Overrides still work for themed groups
highlights.setup({
	GitflowBorder = { fg = "#FF0000" },
})
local border_override = get_hl("GitflowBorder")
assert_equals(border_override.fg, tonumber("FF0000", 16), "GitflowBorder override should apply")

-- Reset
highlights.setup({})

-- ── 4. window.lua winhighlight ──────────────────────────────────

local window = require("gitflow.ui.window")
local test_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, { "test" })

local float_winid = window.open_float({
	bufnr = test_buf,
	name = "test_theme_float",
	width = 40,
	height = 10,
	border = "rounded",
	title = "Test Float",
})

local winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = float_winid })
assert_true(
	winhighlight:find("FloatBorder:GitflowBorder") ~= nil,
	"float winhighlight should map FloatBorder to GitflowBorder"
)
assert_true(
	winhighlight:find("FloatTitle:GitflowTitle") ~= nil,
	"float winhighlight should map FloatTitle to GitflowTitle"
)
assert_true(
	winhighlight:find("FloatFooter:GitflowFooter") ~= nil,
	"float winhighlight should map FloatFooter to GitflowFooter"
)
assert_true(
	winhighlight:find("NormalFloat:GitflowNormal") ~= nil,
	"float winhighlight should map NormalFloat to GitflowNormal"
)

window.close("test_theme_float")
vim.api.nvim_buf_delete(test_buf, { force = true })

-- ── 5. panels use ui_render imports ─────────────────────────────

-- Verify all panels can be loaded without errors
local panel_names = {
	"gitflow.panels.status",
	"gitflow.panels.branch",
	"gitflow.panels.diff",
	"gitflow.panels.log",
	"gitflow.panels.stash",
	"gitflow.panels.issues",
	"gitflow.panels.prs",
	"gitflow.panels.conflict",
	"gitflow.panels.review",
	"gitflow.panels.labels",
}

for _, panel_name in ipairs(panel_names) do
	local ok, mod = pcall(require, panel_name)
	assert_true(ok, ("panel %s should load without error"):format(panel_name))
	assert_true(type(mod) == "table", ("panel %s should return a table"):format(panel_name))
end

-- ── 6. ui.render is exported ────────────────────────────────────

local ui = require("gitflow.ui")
assert_true(ui.render ~= nil, "ui module should export render sub-module")
assert_equals(ui.render.separator, ui_render.separator, "ui.render should be the render module")

print(("Unified theme tests passed (%d/%d assertions)"):format(passed, total))
