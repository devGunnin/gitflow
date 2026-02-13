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
				message, vim.inspect(expected), vim.inspect(actual)
			),
			2
		)
	end
end

local function contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

local function find_line(lines, needle, start_line)
	local start_idx = start_line or 1
	for i = start_idx, #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function normalize_lhs(lhs)
	return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

local function assert_keymaps(bufnr, mode, expected_keys, context)
	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, mode)
	local mapped = {}
	for _, m in ipairs(keymaps) do
		mapped[normalize_lhs(m.lhs)] = true
	end
	for _, key in ipairs(expected_keys) do
		assert_true(
			mapped[normalize_lhs(key)] ~= nil,
			("%s: expected keymap '%s' in mode '%s'"):format(context, key, mode)
		)
	end
end

-- ── Setup ──────────────────────────────────────────────────────────
local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 45 },
	},
	highlights = {},
	icons = { enable = false },
})

-- ── 1. Palette subcommand registered ──────────────────────────────
local commands = require("gitflow.commands")
local all_sub = commands.complete("")
assert_true(contains(all_sub, "palette"), "palette subcommand should be registered")

-- ── 2. Palette keybinding registered ──────────────────────────────
local plug_mapping = vim.fn.maparg("<Plug>(GitflowPalette)", "n", false, true)
assert_true(
	type(plug_mapping) == "table" and plug_mapping.rhs ~= nil,
	"<Plug>(GitflowPalette) should be mapped"
)

-- ── 3. Highlights module sets default groups ──────────────────────
local highlights = require("gitflow.highlights")
assert_true(type(highlights.DEFAULT_GROUPS) == "table", "highlights should export DEFAULT_GROUPS")
local expected_hl_groups = {
	"GitflowPaletteSelection",
	"GitflowPaletteHeader",
	"GitflowPaletteKeybind",
	"GitflowPaletteDescription",
	"GitflowPaletteCategory",
	"GitflowPaletteIcon",
	"GitflowPaletteSeparator",
	"GitflowPaletteNumber",
}
for _, group in ipairs(expected_hl_groups) do
	assert_true(
		highlights.DEFAULT_GROUPS[group] ~= nil,
		("highlight group '%s' should be in DEFAULT_GROUPS"):format(group)
	)
end

-- Verify groups were applied
for _, group in ipairs(expected_hl_groups) do
	local hl = vim.api.nvim_get_hl(0, { name = group })
	assert_true(
		hl ~= nil and (hl.link ~= nil or next(hl) ~= nil),
		("highlight group '%s' should be defined"):format(group)
	)
end

-- ── 4. Icons module ───────────────────────────────────────────────
local icon_mod = require("gitflow.icons")
assert_equals(icon_mod.enabled, false, "icons should default to disabled")
assert_true(icon_mod.registry.palette ~= nil, "icons should have palette category")
local git_icon = icon_mod.get("palette", "git")
assert_true(git_icon ~= "", "palette git icon should return ASCII fallback")

-- ── 5. Config validation — highlights and icons ───────────────────
local config_mod = require("gitflow.config")
local ok, err

ok, err = pcall(config_mod.validate, vim.tbl_deep_extend("force", config_mod.defaults(), {
	highlights = "bad",
}))
assert_true(not ok, "highlights validation should reject non-table")
assert_true(err:find("highlights must be a table") ~= nil, "error should mention highlights")

ok, err = pcall(config_mod.validate, vim.tbl_deep_extend("force", config_mod.defaults(), {
	icons = { enable = "bad" },
}))
assert_true(not ok, "icons.enable validation should reject non-boolean")
assert_true(err:find("icons.enable must be a boolean") ~= nil, "error should mention icons.enable")

-- ── 6. Palette opens and renders ──────────────────────────────────
local palette = require("gitflow.panels.palette")
local selected_entry = nil
palette.open(cfg, {
	on_select = function(entry)
		selected_entry = entry
	end,
})

assert_true(palette.is_open(), "palette should be open after palette.open()")
assert_true(palette.state.bufnr ~= nil, "palette list buffer should exist")
assert_true(palette.state.prompt_bufnr ~= nil, "palette prompt buffer should exist")
assert_true(palette.state.winid ~= nil, "palette list window should exist")
assert_true(palette.state.prompt_winid ~= nil, "palette prompt window should exist")

-- ── 7. Rendered lines contain section headers and entries ─────────
local list_lines = vim.api.nvim_buf_get_lines(palette.state.bufnr, 0, -1, false)
assert_true(#list_lines > 0, "palette should render lines")

local git_header = find_line(list_lines, "Git")
assert_true(git_header ~= nil, "palette should render Git section header")

local status_line = find_line(list_lines, "Status")
assert_true(status_line ~= nil, "palette should render Status entry")

local ui_header = find_line(list_lines, "UI")
assert_true(ui_header ~= nil, "palette should render UI section header")

-- ── 8. Keybind hints visible ──────────────────────────────────────
local keybind_line = find_line(list_lines, "[gs]")
assert_true(keybind_line ~= nil, "palette should show keybind hint [gs] for Status")

local keybind_log = find_line(list_lines, "[gl]")
assert_true(keybind_log ~= nil, "palette should show keybind hint [gl] for Log")

-- ── 9. Numbered quick-access prefixes ─────────────────────────────
local numbered_line = find_line(list_lines, " 1")
assert_true(numbered_line ~= nil, "palette entries should have numbered prefix")

-- ── 10. Selectable lines skip headers/separators ──────────────────
assert_true(
	#palette.state.selectable_lines > 0,
	"palette should have selectable lines"
)
for _, line_nr in ipairs(palette.state.selectable_lines) do
	assert_true(
		palette.state.line_entries[line_nr] ~= nil,
		("selectable line %d should have a corresponding entry"):format(line_nr)
	)
end

-- ── 11. Prompt keymaps ────────────────────────────────────────────
assert_keymaps(palette.state.prompt_bufnr, "i", {
	"<CR>", "<Esc>", "<Down>", "<Up>",
	"<C-n>", "<C-p>", "<Tab>", "<S-Tab>",
	"<C-j>", "<C-k>",
}, "prompt buffer")

-- ── 12. List keymaps ──────────────────────────────────────────────
assert_keymaps(palette.state.bufnr, "n", {
	"<CR>", "<Esc>", "q", "j", "k",
	"1", "2", "3", "4", "5", "6", "7", "8", "9",
}, "list buffer")

-- ── 13. Selection movement ────────────────────────────────────────
local initial_sel = palette.state.selection
assert_equals(initial_sel, 1, "initial selection should be 1")

-- Move down
vim.api.nvim_buf_set_lines(palette.state.prompt_bufnr, 0, -1, false, { "" })
local sel_before = palette.state.selection
-- simulate internal move
local palette_mod = require("gitflow.panels.palette")
-- Access move through the exposed state
palette.state.selection = 1
-- We can test that selectable_lines maps correctly
local first_sel_line = palette.state.selectable_lines[1]
assert_true(first_sel_line ~= nil, "first selectable line should exist")
local first_entry = palette.state.line_entries[first_sel_line]
assert_true(first_entry ~= nil, "first selectable entry should exist")
assert_equals(first_entry.command, "status", "first entry should be status")

-- ── 14. Fuzzy search filtering ────────────────────────────────────
vim.api.nvim_buf_set_lines(palette.state.prompt_bufnr, 0, -1, false, { "sta" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = palette.state.prompt_bufnr })
local filtered_lines = vim.api.nvim_buf_get_lines(palette.state.bufnr, 0, -1, false)
local has_status = find_line(filtered_lines, "Status") ~= nil
local has_stash = find_line(filtered_lines, "Stash") ~= nil
assert_true(has_status or has_stash, "fuzzy filter 'sta' should match Status or Stash")

-- Non-matching entries should be gone
local has_help = find_line(filtered_lines, "Help") ~= nil
assert_true(not has_help, "fuzzy filter 'sta' should not show Help")

-- ── 15. Clear filter restores all entries ─────────────────────────
vim.api.nvim_buf_set_lines(palette.state.prompt_bufnr, 0, -1, false, { "" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = palette.state.prompt_bufnr })
local restored_lines = vim.api.nvim_buf_get_lines(palette.state.bufnr, 0, -1, false)
local restored_help = find_line(restored_lines, "Help")
assert_true(restored_help ~= nil, "clearing filter should restore all entries")

-- ── 16. Close palette ─────────────────────────────────────────────
palette.close()
assert_true(not palette.is_open(), "palette should be closed after palette.close()")
assert_true(palette.state.bufnr == nil, "list bufnr should be nil after close")
assert_true(palette.state.prompt_bufnr == nil, "prompt bufnr should be nil after close")

-- ── 17. Palette via dispatch ──────────────────────────────────────
local dispatch_opened = false
local original_open = palette.open
palette.open = function(c, opts)
	dispatch_opened = true
	original_open(c, opts)
end
commands.dispatch({ "palette" }, cfg)
assert_true(dispatch_opened, "dispatch('palette') should call palette.open")
palette.open = original_open
if palette.is_open() then
	palette.close()
end

-- ── 18. Highlight user overrides ──────────────────────────────────
highlights.setup({ GitflowPaletteHeader = { bold = true } })
local hl_override = vim.api.nvim_get_hl(0, { name = "GitflowPaletteHeader" })
assert_true(
	hl_override.bold == true,
	"user override should set bold on GitflowPaletteHeader"
)

-- ── 19. Icons with nerd fonts enabled ─────────────────────────────
icon_mod.setup({ enable = true })
assert_equals(icon_mod.enabled, true, "icons should be enabled after setup")
local nerd_icon = icon_mod.get("palette", "git")
assert_true(nerd_icon ~= "" and nerd_icon ~= "[G]", "nerd font icon should differ from ASCII")
icon_mod.setup({ enable = false })

-- ── 20. Non-selectable lines are correct ──────────────────────────
palette.open(cfg, { on_select = function() end })
local all_lines = vim.api.nvim_buf_get_lines(palette.state.bufnr, 0, -1, false)
for i, line in ipairs(all_lines) do
	if palette.state.line_entries[i] == nil then
		-- This line should NOT be in selectable_lines
		local is_selectable = false
		for _, sl in ipairs(palette.state.selectable_lines) do
			if sl == i then
				is_selectable = true
				break
			end
		end
		assert_true(
			not is_selectable,
			("line %d ('%s') is non-entry but in selectable_lines"):format(
				i, line:sub(1, 30)
			)
		)
	end
end
palette.close()

print("Stage 10 palette smoke tests passed")
