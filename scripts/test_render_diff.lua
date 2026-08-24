-- Tests for the diffing render path: an unchanged re-render must not touch the
-- buffer, a changed line must rewrite only that line, and highlight spans must
-- reach the buffer as extmarks (nvim_buf_add_highlight is deprecated).

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
local function assert_errors(fn, msg)
	total = total + 1
	local ok = pcall(fn)
	if ok then
		error(msg, 2)
	end
	passed = passed + 1
end

local ui_render = require("gitflow.ui.render")

-- ── set_lines call counting ──────────────────────────────────────────
local set_lines_calls = {}
local original_set_lines = vim.api.nvim_buf_set_lines
vim.api.nvim_buf_set_lines = function(bufnr, start, stop, strict, lines)
	set_lines_calls[#set_lines_calls + 1] = { start = start, stop = stop, count = #lines }
	return original_set_lines(bufnr, start, stop, strict, lines)
end

local function counted(fn)
	set_lines_calls = {}
	fn()
	return set_lines_calls
end

local ns = vim.api.nvim_create_namespace("test_render_diff")

---@return integer bufnr
local function fresh_buffer()
	return vim.api.nvim_create_buf(false, true)
end

---@param items table[]  { text, hl } pairs
---@return GitflowRenderBuilder
local function build(items)
	local B = ui_render.builder()
	for _, item in ipairs(items) do
		B:raw(item[1], item[2])
	end
	return B
end

local BASE = {
	{ "alpha", "GitflowTitle" },
	{ "bravo", nil },
	{ "charlie", "GitflowMeta" },
	{ "delta", nil },
}

-- ── an unchanged re-render touches nothing ───────────────────────────
do
	local bufnr = fresh_buffer()
	build(BASE):render(bufnr, bufnr, ns)

	local calls = counted(function()
		build(BASE):render(bufnr, bufnr, ns)
	end)
	assert_equals(#calls, 0, "an unchanged re-render should issue no nvim_buf_set_lines")

	-- and the extmarks are still exactly the ones it drew.
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	assert_equals(#marks, 2, "unchanged re-render should leave the original spans in place")
	assert_equals(marks[1][4].hl_group, "GitflowTitle", "first span should survive")
	assert_equals(marks[3 - 1][4].hl_group, "GitflowMeta", "second span should survive")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── one changed line rewrites only that line ─────────────────────────
do
	local bufnr = fresh_buffer()
	build(BASE):render(bufnr, bufnr, ns)

	local changed = vim.deepcopy(BASE)
	changed[3] = { "charlie prime", "GitflowMeta" }
	local calls = counted(function()
		build(changed):render(bufnr, bufnr, ns)
	end)
	assert_equals(#calls, 1, "a one-line change should issue exactly one set_lines")
	assert_equals(calls[1].start, 2, "the rewrite should start at the changed line")
	assert_equals(calls[1].stop, 3, "the rewrite should end at the changed line")
	assert_equals(calls[1].count, 1, "the rewrite should carry only the changed line")
	assert_equals(
		vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1],
		"charlie prime",
		"the changed line should be in the buffer"
	)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── an inserted line rewrites only the insertion point ───────────────
do
	local bufnr = fresh_buffer()
	build(BASE):render(bufnr, bufnr, ns)

	local inserted = { BASE[1], { "inserted", nil }, BASE[2], BASE[3], BASE[4] }
	local calls = counted(function()
		build(inserted):render(bufnr, bufnr, ns)
	end)
	assert_equals(#calls, 1, "an insertion should issue exactly one set_lines")
	assert_equals(calls[1].start, 1, "the insertion should start after the common prefix")
	assert_equals(calls[1].stop, 1, "an insertion should replace no existing lines")
	assert_equals(calls[1].count, 1, "the insertion should carry one line")

	-- The trailing spans shifted with the edit and must still be correct.
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	local charlie_row
	for _, mark in ipairs(marks) do
		if mark[4].hl_group == "GitflowMeta" then
			charlie_row = mark[2]
		end
	end
	assert_equals(charlie_row, 3, "a shifted line's span should follow it")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── a span-only change repaints without rewriting the buffer ─────────
do
	local bufnr = fresh_buffer()
	build(BASE):render(bufnr, bufnr, ns)

	local restyled = vim.deepcopy(BASE)
	restyled[2] = { "bravo", "GitflowFooter" }
	local calls = counted(function()
		build(restyled):render(bufnr, bufnr, ns)
	end)
	assert_equals(#calls, 0, "a highlight-only change should not rewrite the buffer")

	local marks = vim.api.nvim_buf_get_extmarks(
		bufnr, ns, { 1, 0 }, { 1, -1 }, { details = true }
	)
	assert_equals(#marks, 1, "the restyled line should carry one span")
	assert_equals(marks[1][4].hl_group, "GitflowFooter", "the new span should be applied")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── dropped lines lose their spans ───────────────────────────────────
do
	local bufnr = fresh_buffer()
	build(BASE):render(bufnr, bufnr, ns)
	build({ BASE[1] }):render(bufnr, bufnr, ns)

	assert_equals(
		vim.api.nvim_buf_line_count(bufnr), 1,
		"a shorter render should shrink the buffer"
	)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	assert_equals(#marks, 1, "dropped lines should take their spans with them")
	assert_equals(marks[1][4].hl_group, "GitflowTitle", "the surviving span should be intact")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── chunk spans land as extmarks with the right byte columns ─────────
do
	local bufnr = fresh_buffer()
	local B = ui_render.builder()
	B:push({
		{ "ab", "GitflowMetaKey" },
		{ "cde", nil },
		{ "fg", "GitflowChip" },
	})
	B:render(bufnr, bufnr, ns)

	local marks = vim.api.nvim_buf_get_extmarks(
		bufnr, ns, { 0, 0 }, { 0, -1 }, { details = true }
	)
	assert_equals(#marks, 2, "only chunks with a highlight should produce a span")
	assert_equals(marks[1][3], 0, "first span should start at column 0")
	assert_equals(marks[1][4].end_col, 2, "first span should end at the chunk boundary")
	assert_equals(marks[1][4].hl_group, "GitflowMetaKey", "first span group")
	assert_equals(marks[2][3], 5, "second span should start after the unstyled chunk")
	assert_equals(marks[2][4].end_col, 7, "second span should end at the line end")
	assert_equals(marks[2][4].hl_group, "GitflowChip", "second span group")

	-- B:raw's whole-line form spans exactly the line's bytes.
	local B2 = ui_render.builder()
	B2:raw("abcdefg", "GitflowSeparator")
	B2:render(bufnr, bufnr, ns)
	local whole = vim.api.nvim_buf_get_extmarks(
		bufnr, ns, { 0, 0 }, { 0, -1 }, { details = true }
	)
	assert_equals(#whole, 1, "a raw line should carry one whole-line span")
	assert_equals(whole[1][3], 0, "whole-line span should start at column 0")
	assert_equals(whole[1][4].end_col, 7, "whole-line span should cover the line")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── a buffer created after another dies still gets a genuine full render ──
-- Neovim never reuses a bufnr within a session, so this cannot force an
-- actual snapshot-table collision; it instead pins that a brand-new buffer's
-- first render is one real full write, never a diff against stale state.
do
	local bufnr = fresh_buffer()
	build(BASE):render(bufnr, bufnr, ns)
	vim.api.nvim_buf_delete(bufnr, { force = true })

	local reused = fresh_buffer()
	local calls = counted(function()
		build(BASE):render(reused, reused, ns)
	end)
	assert_equals(#calls, 1, "a fresh buffer's first render should be a single write")
	assert_equals(calls[1].start, 0, "the full write should start at line 0")
	assert_equals(calls[1].count, #BASE, "the full write should cover every line")
	assert_equals(
		vim.api.nvim_buf_get_lines(reused, 0, -1, false)[3],
		"charlie",
		"the fresh buffer should hold the rendered lines"
	)
	vim.api.nvim_buf_delete(reused, { force = true })
end

-- ── a builder is single-use: a second flush must hard-error ──────────
do
	local bufnr = fresh_buffer()
	local B = build(BASE)
	B:render(bufnr, bufnr, ns)
	assert_errors(function()
		B:render(bufnr, bufnr, ns)
	end, "flushing the same builder twice should error")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

vim.api.nvim_buf_set_lines = original_set_lines

print(("Render diff tests passed (%d/%d assertions)"):format(passed, total))
