-- scripts/test_content_width.lua — unit tests for ui.render.content_width()
-- Covers the dynamic width resolution path with mock window contexts.
--
-- Run: nvim --headless -u NONE -l scripts/test_content_width.lua

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

local ui_render = require("gitflow.ui.render")

-- ── 1. Fallback: no opts ─────────────────────────────────────────────

local w_nil = ui_render.content_width()
assert_equals(w_nil, 50, "content_width() with no args should return default fallback (50)")

-- ── 2. Fallback: empty opts ──────────────────────────────────────────

local w_empty = ui_render.content_width({})
assert_equals(w_empty, 50, "content_width({}) should return default fallback (50)")

-- ── 3. Custom fallback ───────────────────────────────────────────────

local w_custom = ui_render.content_width({ fallback = 80 })
assert_equals(w_custom, 80, "content_width({ fallback = 80 }) should return 80")

-- ── 4. Invalid winid falls back ──────────────────────────────────────

local w_invalid_win = ui_render.content_width({ winid = 99999, fallback = 42 })
assert_equals(w_invalid_win, 42, "content_width with invalid winid should use fallback")

-- ── 5. Invalid bufnr falls back ──────────────────────────────────────

local w_invalid_buf = ui_render.content_width({ bufnr = 99999, fallback = 33 })
assert_equals(w_invalid_buf, 33, "content_width with invalid bufnr should use fallback")

-- ── 6. Dynamic width from a real split window ────────────────────────

local split_buf = vim.api.nvim_create_buf(false, true)
vim.cmd("vsplit")
local split_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(split_win, split_buf)
vim.api.nvim_win_set_width(split_win, 60)

local w_split = ui_render.content_width({ winid = split_win })
local expected_split = vim.api.nvim_win_get_width(split_win)
local ok_split, info_split = pcall(vim.fn.getwininfo, split_win)
if ok_split and type(info_split) == "table" and info_split[1] then
	expected_split = expected_split - (tonumber(info_split[1].textoff) or 0)
end
assert_equals(
	w_split,
	math.max(24, math.floor(expected_split)),
	"content_width with split window should return actual content width"
)
assert_true(w_split >= 24, "split window width should be at least min_width (24)")

vim.api.nvim_win_close(split_win, true)
vim.api.nvim_buf_delete(split_buf, { force = true })

-- ── 7. Dynamic width from a real float window ────────────────────────

local float_buf = vim.api.nvim_create_buf(false, true)
local float_win = vim.api.nvim_open_win(float_buf, false, {
	relative = "editor",
	row = 1,
	col = 1,
	width = 72,
	height = 10,
	style = "minimal",
})

local w_float = ui_render.content_width({ winid = float_win })
assert_equals(w_float, 72, "content_width with minimal float (no textoff) should return window width")

vim.api.nvim_win_close(float_win, true)
vim.api.nvim_buf_delete(float_buf, { force = true })

-- ── 8. Dynamic width via bufnr lookup ────────────────────────────────

local buf_lookup = vim.api.nvim_create_buf(false, true)
local buf_win = vim.api.nvim_open_win(buf_lookup, true, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 55,
	height = 5,
	style = "minimal",
})

local w_bufnr = ui_render.content_width({ bufnr = buf_lookup })
assert_equals(w_bufnr, 55, "content_width with bufnr should resolve via bufwinid and return width")

vim.api.nvim_win_close(buf_win, true)
vim.api.nvim_buf_delete(buf_lookup, { force = true })

-- ── 9. winid takes precedence over bufnr ─────────────────────────────

local buf_a = vim.api.nvim_create_buf(false, true)
local win_a = vim.api.nvim_open_win(buf_a, false, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 40,
	height = 5,
	style = "minimal",
})

local buf_b = vim.api.nvim_create_buf(false, true)
local win_b = vim.api.nvim_open_win(buf_b, false, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 90,
	height = 5,
	style = "minimal",
})

local w_precedence = ui_render.content_width({ winid = win_a, bufnr = buf_b })
assert_equals(w_precedence, 40, "content_width should prefer winid over bufnr")

vim.api.nvim_win_close(win_a, true)
vim.api.nvim_win_close(win_b, true)
vim.api.nvim_buf_delete(buf_a, { force = true })
vim.api.nvim_buf_delete(buf_b, { force = true })

-- ── 10. min_width clamp ──────────────────────────────────────────────

local narrow_buf = vim.api.nvim_create_buf(false, true)
local narrow_win = vim.api.nvim_open_win(narrow_buf, false, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 10,
	height = 5,
	style = "minimal",
})

local w_narrow = ui_render.content_width({ winid = narrow_win })
assert_equals(w_narrow, 24, "content_width with narrow window should clamp to min_width (24)")

vim.api.nvim_win_close(narrow_win, true)
vim.api.nvim_buf_delete(narrow_buf, { force = true })

-- ── 11. Custom min_width ─────────────────────────────────────────────

local narrow_buf2 = vim.api.nvim_create_buf(false, true)
local narrow_win2 = vim.api.nvim_open_win(narrow_buf2, false, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 10,
	height = 5,
	style = "minimal",
})

local w_custom_min = ui_render.content_width({ winid = narrow_win2, min_width = 15 })
assert_equals(w_custom_min, 15, "content_width should honor custom min_width")

vim.api.nvim_win_close(narrow_win2, true)
vim.api.nvim_buf_delete(narrow_buf2, { force = true })

-- ── 12. textoff subtraction with number column ───────────────────────

local numcol_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(numcol_buf, 0, -1, false, { "a", "b", "c" })
local numcol_win = vim.api.nvim_open_win(numcol_buf, true, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 80,
	height = 10,
})
vim.api.nvim_set_option_value("number", true, { win = numcol_win })
vim.api.nvim_set_option_value("signcolumn", "no", { win = numcol_win })

local w_numcol = ui_render.content_width({ winid = numcol_win })
local numcol_info = vim.fn.getwininfo(numcol_win)
local textoff = 0
if type(numcol_info) == "table" and numcol_info[1] then
	textoff = tonumber(numcol_info[1].textoff) or 0
end
assert_true(textoff > 0, "number column should produce non-zero textoff")
assert_equals(w_numcol, 80 - textoff, "content_width should subtract textoff from window width")

vim.api.nvim_win_close(numcol_win, true)
vim.api.nvim_buf_delete(numcol_buf, { force = true })

-- ── 13. separator() integrates with content_width via window ─────────

local sep_buf = vim.api.nvim_create_buf(false, true)
local sep_win = vim.api.nvim_open_win(sep_buf, false, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 45,
	height = 5,
	style = "minimal",
})

local sep = ui_render.separator({ winid = sep_win })
local char_len = #"\u{2500}"
assert_equals(#sep, 45 * char_len, "separator with window context should use content_width")

vim.api.nvim_win_close(sep_win, true)
vim.api.nvim_buf_delete(sep_buf, { force = true })

-- ── 14. bufnr not displayed in any window falls back ─────────────────

local hidden_buf = vim.api.nvim_create_buf(false, true)
local w_hidden = ui_render.content_width({ bufnr = hidden_buf, fallback = 66 })
assert_equals(w_hidden, 66, "content_width with bufnr not in any window should use fallback")

vim.api.nvim_buf_delete(hidden_buf, { force = true })

-- ── 15. closed window after capture falls back ───────────────────────

local ephemeral_buf = vim.api.nvim_create_buf(false, true)
local ephemeral_win = vim.api.nvim_open_win(ephemeral_buf, false, {
	relative = "editor",
	row = 0,
	col = 0,
	width = 50,
	height = 5,
	style = "minimal",
})
vim.api.nvim_win_close(ephemeral_win, true)

local w_closed = ui_render.content_width({ winid = ephemeral_win, fallback = 99 })
assert_equals(w_closed, 99, "content_width with closed winid should use fallback")

vim.api.nvim_buf_delete(ephemeral_buf, { force = true })

print(("content_width tests passed (%d/%d assertions)"):format(passed, total))
