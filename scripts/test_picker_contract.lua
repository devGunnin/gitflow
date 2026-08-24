-- scripts/test_picker_contract.lua — exercises ui/list_picker.lua and
-- ui/label_picker.lua against the SAME contract, over both of their call
-- shapes (items=/table-or-string entries/multi_select on-or-off vs
-- labels=/always-multi-select/color chips). Both wrap the shared
-- ui/picker.lua engine; this spec is the guard against the two shapes
-- drifting apart again.
--
-- Run: nvim --headless -u NONE -l scripts/test_picker_contract.lua

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed = 0

local function assert_true(cond, message)
	if not cond then
		error(message, 2)
	end
	passed = passed + 1
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(
				message, vim.inspect(expected), vim.inspect(actual)
			),
			2
		)
	end
	passed = passed + 1
end

local function find_line(lines, needle)
	for i, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function wait_until(predicate, message, timeout_ms)
	assert_true(vim.wait(timeout_ms or 2000, predicate, 20), message)
end

require("gitflow").setup({})

local list_picker = require("gitflow.ui.list_picker")
local label_picker = require("gitflow.ui.label_picker")

---@class PickerShape
---@field name string
---@field module table
---@field namespace_hl integer
---@field namespace_active integer
---@field open fun(entries: table, opts: table|nil): table|nil  opens with the shape's own entry key

local shapes = {
	{
		name = "list_picker (multi_select)",
		module = list_picker,
		namespace_hl = vim.api.nvim_create_namespace("gitflow_list_picker_hl"),
		namespace_active = vim.api.nvim_create_namespace("gitflow_list_picker_active"),
		open = function(entries, opts)
			opts = opts or {}
			opts.items = entries
			return list_picker.open(opts)
		end,
	},
	{
		name = "list_picker (single_select)",
		module = list_picker,
		namespace_hl = vim.api.nvim_create_namespace("gitflow_list_picker_hl"),
		namespace_active = vim.api.nvim_create_namespace("gitflow_list_picker_active"),
		open = function(entries, opts)
			opts = opts or {}
			opts.items = entries
			opts.multi_select = false
			return list_picker.open(opts)
		end,
	},
	{
		name = "label_picker",
		module = label_picker,
		namespace_hl = vim.api.nvim_create_namespace("gitflow_label_picker_hl"),
		namespace_active = vim.api.nvim_create_namespace("gitflow_label_picker_active"),
		open = function(entries, opts)
			opts = opts or {}
			opts.labels = entries
			return label_picker.open(opts)
		end,
	},
}

local function press(winid, lhs)
	vim.api.nvim_set_current_win(winid)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes(lhs, true, false, true), "x", false
	)
end

-- ── 1. Every shape opens, renders and exposes the same field set ────

for _, shape in ipairs(shapes) do
	local entries = {
		{ name = "alpha", description = "first" },
		{ name = "beta", description = "second" },
	}
	-- Submission itself is exercised end-to-end in 5b/5d; this section only
	-- covers what open/render/keymap wiring look like.
	local state = shape.open(entries, {
		title = "Contract Test",
		on_submit = function() end,
	})

	assert_true(state ~= nil, shape.name .. ": open should return a state")
	assert_true(state.winid ~= nil, shape.name .. ": state.winid should be set")
	assert_true(vim.api.nvim_win_is_valid(state.winid), shape.name .. ": window should be valid")
	assert_true(state.bufnr ~= nil, shape.name .. ": state.bufnr should be set")

	-- The caller's title must actually reach the float, not just get
	-- accepted and dropped in favor of the spec's default_title.
	local win_title_chunks = vim.api.nvim_win_get_config(state.winid).title
	local win_title = win_title_chunks and win_title_chunks[1] and win_title_chunks[1][1]
	assert_equals(
		win_title, "  Contract Test  ",
		shape.name .. ": window title should forward the caller's title"
	)
	assert_true(
		type(state.items) == "table",
		shape.name .. ": state.items should be a table regardless of the call shape's key name"
	)
	assert_equals(#state.items, 2, shape.name .. ": state.items should hold both entries")

	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	assert_true(find_line(lines, "alpha") ~= nil, shape.name .. ": alpha row should render")
	assert_true(find_line(lines, "beta") ~= nil, shape.name .. ": beta row should render")

	-- Every shape supports the same navigation/search/close keymaps.
	local keymaps = vim.api.nvim_buf_get_keymap(state.bufnr, "n")
	local have = {}
	for _, m in ipairs(keymaps) do
		have[m.lhs] = true
	end
	for _, lhs in ipairs({ "j", "k", "/", "q", "<Esc>", "<CR>", " " }) do
		assert_true(have[lhs], ("%s: missing keymap %s"):format(shape.name, lhs))
	end

	-- The active-line accent lives in the shape's OWN namespace, so two
	-- pickers open back to back never bleed extmarks into each other.
	local accent_marks = vim.api.nvim_buf_get_extmarks(
		state.bufnr, shape.namespace_active, 0, -1, { details = true }
	)
	local has_accent = false
	for _, mark in ipairs(accent_marks) do
		if mark[4] and mark[4].hl_group == "GitflowFormActiveField" then
			has_accent = true
		end
	end
	assert_true(has_accent, shape.name .. ": active-line accent should be in this shape's own namespace")

	pcall(vim.api.nvim_win_close, state.winid, true)
	pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
	assert_true(true, shape.name .. ": open/render/keymap contract holds")
end

-- ── 1b. opts.selected preselects the matching row, per shape. Already
-- guarded outside this spec by test_stage10_pickers/test_stage10_forms, but
-- this is the contract file a future picker change is read against.
for _, shape in ipairs(shapes) do
	local entries = { { name = "alpha" }, { name = "beta" } }
	local pre_state = shape.open(entries, {
		selected = { "alpha" },
		on_submit = function() end,
	})

	local pre_lines = vim.api.nvim_buf_get_lines(pre_state.bufnr, 0, -1, false)
	local selected_marker = pre_state.multi_select and "[x] alpha" or "> alpha"
	assert_true(
		find_line(pre_lines, selected_marker) ~= nil,
		shape.name .. ": opts.selected should preselect the matching row"
	)
	if pre_state.multi_select then
		assert_true(
			find_line(pre_lines, "[ ] beta") ~= nil,
			shape.name .. ": non-preselected rows should stay unselected"
		)
	end

	pcall(vim.api.nvim_win_close, pre_state.winid, true)
	pcall(vim.api.nvim_buf_delete, pre_state.bufnr, { force = true })
end

-- ── 2. Live search narrows results identically across shapes ────────

for _, shape in ipairs(shapes) do
	local entries = {
		{ name = "main" }, { name = "develop" }, { name = "feature/x" },
	}
	local state = shape.open(entries, { on_submit = function() end })

	-- "/" enters search mode (state.searching=true, the live-filter
	-- autocmd registered). A headless script has no main loop to carry
	-- startinsert's mode switch across a second feedkeys call, so the
	-- query is set the same way test_stage10_palette.lua drives its
	-- prompt: write the line, then fire the autocmd it listens for.
	press(state.winid, "/")
	vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, { "dev" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = state.bufnr })

	wait_until(function()
		local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
		return find_line(lines, "develop") ~= nil and find_line(lines, "main") == nil
	end, shape.name .. ": search should narrow to develop only", 1000)

	pcall(vim.api.nvim_win_close, state.winid, true)
	pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
end

-- ── 3. Cancel fires on_cancel exactly once, per shape ────────────────

for _, shape in ipairs(shapes) do
	local calls = 0
	local state = shape.open({ { name = "only" } }, {
		on_submit = function() end,
		on_cancel = function() calls = calls + 1 end,
	})
	press(state.winid, "q")
	vim.wait(50, function() return false end, 10)
	assert_equals(calls, 1, shape.name .. ": on_cancel should fire exactly once via q")
	assert_true(state.closed, shape.name .. ": state.closed should be true after cancel")
end

-- ── 4. A too-small terminal refuses cleanly, per shape ───────────────

local original_columns, original_lines = vim.o.columns, vim.o.lines
vim.o.columns, vim.o.lines = 10, 3
for _, shape in ipairs(shapes) do
	local state = shape.open({ { name = "x" } }, { on_submit = function() end })
	assert_true(state == nil, shape.name .. ": open should return nil on a too-small terminal")
end
vim.o.columns, vim.o.lines = original_columns, original_lines

-- ── 5. Shape-specific behavior each wrapper alone is responsible for ─

-- 5a. list_picker normalizes bare-string items (label_picker has no such
-- shape: every label is a table with an optional color).
local string_state = list_picker.open({
	items = { "gamma", "delta" },
	on_submit = function() end,
})
assert_equals(string_state.items[1].name, "gamma", "5a. list_picker normalizes a string item to {name=...}")
pcall(vim.api.nvim_win_close, string_state.winid, true)
pcall(vim.api.nvim_buf_delete, string_state.bufnr, { force = true })

-- 5a2. list_picker preserves item.description through M.open's own
-- normalization (not just through filter_items, which the matcher spec
-- exercises directly and which bypasses this normalization entirely).
-- Descriptions render AND are half the fuzzy haystack, so this goes through
-- the real M.open path end to end: render, then search by description alone.
local desc_state = list_picker.open({
	items = {
		{ name = "widget-one", description = "special-marker-zzz" },
		{ name = "widget-two", description = "other" },
	},
	on_submit = function() end,
})
local desc_lines = vim.api.nvim_buf_get_lines(desc_state.bufnr, 0, -1, false)
assert_true(
	find_line(desc_lines, "special-marker-zzz") ~= nil,
	"5a2. list_picker.open should render item.description"
)

press(desc_state.winid, "/")
vim.api.nvim_buf_set_lines(desc_state.bufnr, 0, 1, false, { "special-marker-zzz" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = desc_state.bufnr })
wait_until(function()
	local lines = vim.api.nvim_buf_get_lines(desc_state.bufnr, 0, -1, false)
	return find_line(lines, "widget-one") ~= nil and find_line(lines, "widget-two") == nil
end, "5a2. a query matching only the description should find its item and exclude others", 1000)

pcall(vim.api.nvim_win_close, desc_state.winid, true)
pcall(vim.api.nvim_buf_delete, desc_state.bufnr, { force = true })

-- 5b. list_picker single-select toggles-and-submits on <CR> without <Space>
-- accumulating a selection set; multi_select toggles then requires <CR>.
local single_submit
local single_state = list_picker.open({
	items = { { name = "one" }, { name = "two" } },
	multi_select = false,
	on_submit = function(sel) single_submit = sel end,
})
press(single_state.winid, "<CR>")
wait_until(function() return single_submit ~= nil end, "5b. single-select <CR> should submit immediately")
assert_equals(#single_submit, 1, "5b. single-select submits exactly one item")
assert_equals(single_submit[1], "one", "5b. single-select submits the active row, not every row")

-- 5d. Multi-select ACCUMULATES across several <Space> presses and only
-- commits on <CR> -- this, not the state.multi_select flag alone, is what
-- breaks if the engine's documented default (multi_select == nil -> true)
-- silently flips, or if toggle_current's accumulate-vs-submit-immediately
-- branch is neutered: either mutation makes the first <Space> submit early.
local multi_submitted
local multi_state = list_picker.open({
	items = { { name = "alpha" }, { name = "beta" }, { name = "gamma" } },
	on_submit = function(sel) multi_submitted = sel end,
})
press(multi_state.winid, "<Space>") -- toggle alpha (cursor starts on row 1)
assert_true(multi_submitted == nil, "5d. multi-select must not submit on the first <Space> (accumulate, don't commit)")
press(multi_state.winid, "j")
press(multi_state.winid, "j") -- skip beta, land on gamma
press(multi_state.winid, "<Space>") -- toggle gamma; beta stays untouched
assert_true(multi_submitted == nil, "5d. multi-select must not submit before <CR>")
press(multi_state.winid, "<CR>")
wait_until(
	function() return multi_submitted ~= nil end,
	"5d. multi-select <CR> should submit the accumulated set", 1000
)
assert_equals(
	#multi_submitted, 2, "5d. multi-select submits exactly the toggled items, not more or fewer"
)
assert_equals(multi_submitted[1], "alpha", "5d. multi-select submitted set includes alpha")
assert_equals(multi_submitted[2], "gamma", "5d. multi-select submitted set includes gamma, excludes untouched beta")

-- 5c. label_picker always multi-selects and colors the name chip per label.
local label_state = label_picker.open({
	labels = { { name = "bug", color = "d73a4a" } },
	on_submit = function() end,
})
assert_true(label_state.multi_select, "5c. label_picker is always multi-select")
local label_marks = vim.api.nvim_buf_get_extmarks(
	label_state.bufnr, shapes[3].namespace_hl, 0, -1, { details = true }
)
local has_color_chip = false
for _, mark in ipairs(label_marks) do
	local hl = mark[4] and mark[4].hl_group
	if hl and hl:find("GitflowLabel_", 1, true) then
		has_color_chip = true
	end
end
assert_true(has_color_chip, "5c. label_picker renders a color-derived highlight group on the name")
pcall(vim.api.nvim_win_close, label_state.winid, true)
pcall(vim.api.nvim_buf_delete, label_state.bufnr, { force = true })

-- ── 6. Empty-results row renders through the shared components.empty
-- grammar, per shape: an unhighlighted gutter, then the highlighted text --
-- the same shape every other empty state in the plugin uses, not a
-- hand-rolled one-off (coldstart review finding 4).
for _, shape in ipairs(shapes) do
	local state = shape.open({ { name = "only" } }, { on_submit = function() end })
	local empty_text = state.spec.empty_text

	press(state.winid, "/")
	vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, { "zzz-does-not-match-anything" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = state.bufnr })

	local empty_line
	wait_until(function()
		local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
		empty_line = find_line(lines, empty_text)
		return empty_line ~= nil
	end, shape.name .. ": empty-results row should render " .. empty_text, 1000)

	local marks = vim.api.nvim_buf_get_extmarks(
		state.bufnr, shape.namespace_hl, 0, -1, { details = true }
	)
	local text_span
	for _, mark in ipairs(marks) do
		if mark[2] == empty_line - 1 and mark[4] and mark[4].hl_group == "GitflowMeta" then
			text_span = mark
		end
	end
	assert_true(text_span ~= nil, shape.name .. ": empty row text should carry GitflowMeta")
	assert_equals(
		text_span[3], 2,
		shape.name .. ": empty row highlight should start after the 2-col gutter (components.empty's grammar)"
	)

	pcall(vim.api.nvim_win_close, state.winid, true)
	pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
end

print(("Picker-contract spec passed (%d assertions)"):format(passed))
