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

-- A fixed ui.separator_width is honored even with a real window present --
-- "fixed" would otherwise only ever apply on the windowless fallback path.
local win_buf = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
local win_id = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win_id, win_buf)
vim.api.nvim_win_set_width(win_id, 90)
local cw_windowed_fixed = ui_render.content_width({ winid = win_id })
assert_equals(
	cw_windowed_fixed, 60,
	"a fixed ui.separator_width should win over the window's actual width"
)
vim.api.nvim_win_close(win_id, true)
vim.api.nvim_buf_delete(win_buf, { force = true })

-- A fixed ui.separator_width wider than the window is clamped to it -- it
-- must never blow past what the window can actually show.
cfg.current.ui.separator_width = 200
local narrow_buf = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
local narrow_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(narrow_win, narrow_buf)
vim.api.nvim_win_set_width(narrow_win, 40)
local cw_clamped = ui_render.content_width({ winid = narrow_win })
assert_true(
	cw_clamped <= 40,
	"a fixed ui.separator_width wider than the window should clamp to the window width"
)
vim.api.nvim_win_close(narrow_win, true)
vim.api.nvim_buf_delete(narrow_buf, { force = true })

cfg.current.ui.separator_width = saved

-- ui.separator_width validation rejects non-integers, accepts 0 and positive
-- integers.
local function with_separator_width(value, fn)
	local before = cfg.current.ui.separator_width
	cfg.current.ui.separator_width = value
	local ok, err = pcall(fn)
	cfg.current.ui.separator_width = before
	return ok, err
end

assert_true(
	select(1, with_separator_width(0.5, function()
		cfg.validate(cfg.current)
	end)) == false,
	"ui.separator_width must reject a non-integer value like 0.5"
)
assert_true(
	select(1, with_separator_width(45, function()
		cfg.validate(cfg.current)
	end)),
	"ui.separator_width must accept a positive integer"
)
assert_true(
	select(1, with_separator_width(0, function()
		cfg.validate(cfg.current)
	end)),
	"ui.separator_width must accept 0 (adaptive)"
)

-- ── 1b. components.header — the one way to draw a panel header ───

local components = require("gitflow.ui.components")

-- Split (no window context): inline title + rule.
local B_split = ui_render.builder()
components.header(B_split, "Gitflow Test")
assert_equals(#B_split.lines, 2, "header should push title+rule in split layout")
assert_equals(B_split.lines[1], "Gitflow Test", "split header first line should be the title")
assert_true(
	ui_render.is_separator(B_split.lines[2]),
	"split header second line should be the panel rule"
)
assert_true(
	ui_render.wants_inline_title({}),
	"wants_inline_title should be true without a window"
)

-- Float: the frame chrome already carries the title, so only the rule.
local header_buf = vim.api.nvim_create_buf(false, true)
local header_win = vim.api.nvim_open_win(header_buf, false, {
	relative = "editor",
	row = 1,
	col = 1,
	width = 40,
	height = 5,
	style = "minimal",
	border = "rounded",
})
assert_true(
	not ui_render.wants_inline_title({ winid = header_win }),
	"wants_inline_title should be false for a float"
)
local B_float = ui_render.builder()
components.header(B_float, "Gitflow Test", { winid = header_win })
assert_equals(#B_float.lines, 1, "float header should push the rule only")
assert_true(
	ui_render.is_separator(B_float.lines[1]),
	"float header line should be the panel rule"
)
vim.api.nvim_win_close(header_win, true)
vim.api.nvim_buf_delete(header_buf, { force = true })

-- ── 1c. design tokens ────────────────────────────────────────────

assert_equals(ui_render.spacing.edge, " ", "edge spacing should be one column")
assert_equals(ui_render.spacing.gutter, "  ", "gutter spacing should be two columns")
assert_equals(ui_render.spacing.indent, "    ", "indent spacing should be four columns")
assert_equals(ui_render.glyphs.rule, "\u{2500}", "rule glyph should be box-drawing horizontal")

-- Every component that indents does so with a token, so the whole design
-- system shares one spacing scale.
local B_tokens = ui_render.builder()
components.section(B_tokens, "*", "Section")
components.summary(B_tokens, "*", "Summary")
components.meta_row(B_tokens, "Key", { { "value", nil } })
components.empty(B_tokens, "nothing")
components.loading(B_tokens, "loading")
for line_no, expected in pairs({
	[1] = ui_render.spacing.edge,
	[2] = ui_render.spacing.edge,
	[3] = ui_render.spacing.gutter,
	[4] = ui_render.spacing.gutter,
	[5] = ui_render.spacing.gutter,
	[6] = ui_render.spacing.gutter,
}) do
	local line = B_tokens.lines[line_no]
	assert_equals(
		line:match("^ *"), expected,
		("component line %d should indent with its spacing token"):format(line_no)
	)
end

-- ── 2. builder spans reach the buffer as extmarks ────────────────

local ns = vim.api.nvim_create_namespace("test_unified_theme")
local bufnr = vim.api.nvim_create_buf(false, true)

local B = ui_render.builder()
B:raw("Gitflow Test Panel", "GitflowTitle")
B:raw(ui_render.separator(20), "GitflowSeparator")
B:raw("Section Header", "GitflowSectionTitle")
B:raw("  entry one")
B:raw("  entry two")
B:blank()
B:raw("q: quit  r: refresh", "GitflowFooter")
B:flush(bufnr, bufnr, ns)

local function first_group(row)
	local marks = vim.api.nvim_buf_get_extmarks(
		bufnr, ns, { row, 0 }, { row, -1 }, { details = true }
	)
	return marks[1] and marks[1][4].hl_group or nil
end

assert_equals(
	vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1],
	"Gitflow Test Panel",
	"flush should write the builder's lines into the buffer"
)
assert_equals(first_group(0), "GitflowTitle", "title line should carry GitflowTitle")
assert_equals(first_group(1), "GitflowSeparator", "rule line should carry GitflowSeparator")
assert_equals(first_group(2), "GitflowSectionTitle", "entry line should carry its own group")
assert_equals(first_group(6), "GitflowFooter", "footer line should carry GitflowFooter")

-- Re-rendering different content replaces the old spans rather than layering.
local B2 = ui_render.builder()
B2:raw("Title Only", "GitflowTitle")
B2:flush(bufnr, bufnr, ns)
assert_equals(
	#vim.api.nvim_buf_get_extmarks(bufnr, ns, { 1, 0 }, { 1, -1 }, {}),
	0,
	"a shorter re-render should leave no spans on dropped lines"
)

-- render.highlight() is the extmark-based replacement for the deprecated
-- nvim_buf_add_highlight, including its col_end = -1 whole-line form.
ui_render.highlight(bufnr, ns, "GitflowSeparator", 0, 0, -1)
local whole_line = vim.api.nvim_buf_get_extmarks(
	bufnr, ns, { 0, 0 }, { 0, -1 }, { details = true }
)
local found_span = false
for _, mark in ipairs(whole_line) do
	if mark[4].hl_group == "GitflowSeparator" then
		found_span = true
		assert_equals(mark[4].end_col, #"Title Only", "col_end -1 should span the whole line")
	end
end
assert_true(found_span, "render.highlight should apply the requested group")

-- An invalid buffer should not error.
ui_render.highlight(-1, ns, "GitflowTitle", 0, 0, -1)
assert_true(true, "render.highlight with an invalid bufnr should not error")

vim.api.nvim_buf_delete(bufnr, { force = true })

-- ── 3. highlight group definitions ──────────────────────────────

local highlights = require("gitflow.highlights")

-- Theme accent groups should have explicit fg colors (not links)
local themed_groups = {
	"GitflowBorder",
	"GitflowTitle",
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
assert_equals(border_fg, title_fg, "border and title should share accent color")

-- GitflowTitle should be bold
assert_true(
	highlights.DEFAULT_GROUPS.GitflowTitle.bold == true,
	"GitflowTitle should be bold"
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
	"gitflow.panels.palette",
	"gitflow.panels.cherry_pick",
	"gitflow.panels.reset",
}

for _, panel_name in ipairs(panel_names) do
	local ok, mod = pcall(require, panel_name)
	assert_true(ok, ("panel %s should load without error"):format(panel_name))
	assert_true(type(mod) == "table", ("panel %s should return a table"):format(panel_name))
end

-- ── 6. ui.render is exported ────────────────────────────────────

local ui = require("gitflow.ui")
assert_true(
	ui.render ~= nil,
	"ui module should export render sub-module"
)
assert_equals(
	ui.render.separator,
	ui_render.separator,
	"ui.render should be the render module"
)

-- ── 7. palette highlight groups exist ──────────────────────────

local palette_hl_groups = {
	"GitflowPaletteSelection",
	"GitflowPaletteHeader",
	"GitflowPaletteKeybind",
	"GitflowPaletteDescription",
	"GitflowPaletteIndex",
	"GitflowPaletteCommand",
	"GitflowPaletteNormal",
	"GitflowPaletteHeaderBar",
	"GitflowPaletteHeaderIcon",
	"GitflowPaletteEntryIcon",
	"GitflowPaletteBackdrop",
}

for _, group in ipairs(palette_hl_groups) do
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
	assert_true(
		ok and hl
			and (hl.link ~= nil or hl.fg ~= nil or hl.bg ~= nil),
		("palette highlight group '%s' should be defined"):format(
			group
		)
	)
end

print(
	("Unified theme tests passed (%d/%d assertions)"):format(
		passed, total
	)
)
