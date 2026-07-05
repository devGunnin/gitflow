-- Tests for the shared state-feedback components introduced in the second
-- UI/UX overhaul: styled loading / error / empty states, grouped hint blocks,
-- split-only hint bars, and the float-detection helper they build on.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, total = 0, 0
local function assert_true(cond, msg)
	total = total + 1
	if not cond then
		error(msg, 2)
	end
	passed = passed + 1
end
local function assert_equals(actual, expected, msg)
	total = total + 1
	if actual ~= expected then
		error(("%s (expected=%s, actual=%s)"):format(
			msg, vim.inspect(expected), vim.inspect(actual)
		), 2)
	end
	passed = passed + 1
end

local function line_has_group(B, line_no, group)
	for _, span in ipairs(B.spans[line_no] or {}) do
		if span[3] == group then
			return true
		end
	end
	return false
end

local icons = require("gitflow.icons")
icons.setup({ icons = { enable = true } })
local highlights = require("gitflow.highlights")
highlights.setup({})
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")

-- ── empty() backward compatibility (no opts → single muted line) ──────
do
	local B = ui_render.builder()
	local n = components.empty(B, "nothing here")
	assert_equals(#B.lines, 1, "empty() with no opts should push exactly one line")
	assert_equals(n, 1, "empty() should return the pushed line number")
	assert_true(B.lines[1]:find("nothing here", 1, true) ~= nil,
		"empty() line should contain the text")
	assert_true(line_has_group(B, 1, "GitflowMeta"),
		"plain empty() should keep the GitflowMeta styling")
end

-- ── empty() with icon + hint → two lines, styled ─────────────────────
do
	local B = ui_render.builder()
	components.empty(B, "No worktrees yet", { hint = "Press a to add a worktree." })
	assert_equals(#B.lines, 2, "empty() with hint should push text + hint lines")
	assert_true(line_has_group(B, 1, "GitflowEmptyIcon"),
		"enriched empty() should style the leading icon")
	assert_true(line_has_group(B, 1, "GitflowEmptyText"),
		"enriched empty() should style the text")
	assert_true(line_has_group(B, 2, "GitflowEmptyHint"),
		"enriched empty() should style the hint")
	assert_true(B.lines[2]:find("Press a", 1, true) ~= nil,
		"hint line should carry the affordance text")
end

-- ── loading() → icon + label, optional detail ────────────────────────
do
	local B = ui_render.builder()
	components.loading(B, "Loading things…", { detail = "Fetching." })
	assert_equals(#B.lines, 2, "loading() with detail should push two lines")
	assert_true(line_has_group(B, 1, "GitflowLoadingIcon"),
		"loading() should style its glyph with GitflowLoadingIcon")
	assert_true(line_has_group(B, 1, "GitflowLoadingText"),
		"loading() should style its label with GitflowLoadingText")
	assert_true(B.lines[1]:find("Loading things", 1, true) ~= nil,
		"loading() label should be present")
end

-- ── loading_lines() → plain placeholder for buffer creation ──────────
do
	local lines = components.loading_lines("Loading blame…")
	assert_true(#lines >= 1, "loading_lines() should produce at least one line")
	local joined = table.concat(lines, "\n")
	assert_true(joined:find("Loading blame", 1, true) ~= nil,
		"loading_lines() should include the label")
end

-- ── error_state() → error line + multi-line detail + hint ────────────
do
	local B = ui_render.builder()
	components.error_state(B, "It broke", { detail = "line one\nline two", hint = "Press r." })
	assert_true(line_has_group(B, 1, "GitflowStateError"),
		"error_state() message should use GitflowStateError")
	assert_true(line_has_group(B, 1, "GitflowStateErrorIcon"),
		"error_state() should style its icon")
	-- detail splits across lines; a blank line then the hint follow.
	local found_detail, found_hint = false, false
	for i, l in ipairs(B.lines) do
		if l:find("line two", 1, true) and line_has_group(B, i, "GitflowStateErrorDetail") then
			found_detail = true
		end
		if l:find("Press r", 1, true) and line_has_group(B, i, "GitflowEmptyHint") then
			found_hint = true
		end
	end
	assert_true(found_detail, "error_state() should render styled multi-line detail")
	assert_true(found_hint, "error_state() should render a styled hint")
end

-- ── hint_group() → accent label line + hint chunks ───────────────────
do
	local B = ui_render.builder()
	components.hint_group(B, "NAVIGATE", { { "]f", "next file" }, { "[f", "prev file" } })
	assert_equals(#B.lines, 2, "hint_group() should push a label and a hints line")
	assert_true(line_has_group(B, 1, "GitflowHintGroupLabel"),
		"hint_group() label should use GitflowHintGroupLabel")
	assert_true(line_has_group(B, 2, "GitflowHintKey"),
		"hint_group() hints should style keys with GitflowHintKey")
	assert_true(B.lines[2]:find("next file", 1, true) ~= nil,
		"hint_group() should render hint labels")
end

-- ── is_floating() / split_hint_bar() ─────────────────────────────────
do
	-- No window context → treated as a split.
	assert_equals(ui_render.is_floating({}), false,
		"is_floating() should be false without a window")

	local B = ui_render.builder()
	local n = components.split_hint_bar(B, {}, { { "q", "close" } })
	assert_true(n ~= nil, "split_hint_bar() should render in split layout")
	assert_true(#B.lines >= 2, "split_hint_bar() should add a blank + hint line in split")

	-- Float window → is_floating true, split_hint_bar suppresses output.
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor", row = 1, col = 1, width = 40, height = 6,
		style = "minimal", border = "rounded",
	})
	assert_equals(ui_render.is_floating({ winid = win }), true,
		"is_floating() should be true for a float window")
	local B2 = ui_render.builder()
	local n2 = components.split_hint_bar(B2, { winid = win }, { { "q", "close" } })
	assert_equals(n2, nil, "split_hint_bar() should return nil for a float")
	assert_equals(#B2.lines, 0, "split_hint_bar() should push nothing for a float")
	vim.api.nvim_win_close(win, true)
	vim.api.nvim_buf_delete(buf, { force = true })
end

-- ── highlight groups + state icons resolve ───────────────────────────
do
	local groups = {
		"GitflowLoadingIcon", "GitflowLoadingText",
		"GitflowStateError", "GitflowStateErrorIcon", "GitflowStateErrorDetail",
		"GitflowEmptyIcon", "GitflowEmptyText", "GitflowEmptyHint",
		"GitflowHintGroupLabel",
	}
	for _, g in ipairs(groups) do
		assert_true(highlights.DEFAULT_GROUPS[g] ~= nil,
			("%s should exist in DEFAULT_GROUPS"):format(g))
		local hl = vim.api.nvim_get_hl(0, { name = g })
		assert_true(hl and (hl.link or hl.fg or hl.bg) ~= nil,
			("%s should be defined after setup"):format(g))
	end

	-- Nerd-font glyphs present when icons enabled…
	icons.setup({ icons = { enable = true } })
	for _, name in ipairs({ "loading", "error", "empty" }) do
		assert_true(icons.get("ui", name) ~= "",
			("ui icon '%s' should resolve to a glyph"):format(name))
	end
	-- …and a clean ASCII fallback when disabled.
	icons.setup({ icons = { enable = false } })
	assert_equals(icons.get("ui", "error"), "!",
		"error icon should fall back to '!' in ascii mode")
	icons.setup({ icons = { enable = true } })
end

print(("State component tests passed (%d/%d assertions)"):format(passed, total))
