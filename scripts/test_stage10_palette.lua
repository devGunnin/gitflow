local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local pass_count = 0

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
	pass_count = pass_count + 1
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
	pass_count = pass_count + 1
end

local function contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

local function wait_until(predicate, message, timeout_ms)
	local ok = vim.wait(timeout_ms or 5000, predicate, 20)
	assert_true(ok, message)
end

-- ─── 1. Subcommand registration ─────────────────────────────
local gh = require("gitflow.gh")
local original_check = gh.check_prerequisites
gh.check_prerequisites = function(_)
	gh.state.checked = true
	gh.state.available = true
	gh.state.authenticated = true
	return true
end

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = { default_layout = "float" },
})

local commands = require("gitflow.commands")
local completion = commands.complete("")
assert_true(
	contains(completion, "palette"),
	"1. palette subcommand should be registered"
)

-- ─── 2. Keybinding wiring ────────────────────────────────────
local mapping = vim.fn.maparg(
	cfg.keybindings.palette, "n", false, true
)
assert_true(
	type(mapping) == "table"
		and mapping.rhs == "<Plug>(GitflowPalette)",
	"2. palette keybinding should map to plug"
)

-- ─── 3. Highlight groups exist ───────────────────────────────
local highlights = require("gitflow.highlights")
local expected_groups = {
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
for _, group in ipairs(expected_groups) do
	assert_true(
		highlights.DEFAULT_GROUPS[group] ~= nil,
		("3. highlight group %s should be defined"):format(group)
	)
end

-- ─── 4. Icon fallback (ASCII mode) ──────────────────────────
local icons = require("gitflow.icons")
icons.setup({ icons = { enable = false } })
local git_icon = icons.get("palette", "git")
assert_true(
	git_icon ~= "" and git_icon ~= nil,
	"4a. palette git icon ascii fallback should be non-empty"
)
local github_icon = icons.get("palette", "github")
assert_true(
	github_icon ~= "" and github_icon ~= nil,
	"4b. palette github icon ascii fallback should be non-empty"
)
local ui_icon = icons.get("palette", "ui")
assert_true(
	ui_icon ~= "" and ui_icon ~= nil,
	"4c. palette ui icon ascii fallback should be non-empty"
)

-- ─── 5. Config validation ────────────────────────────────────
local config = require("gitflow.config")
local defaults = config.defaults()
assert_true(
	type(defaults.highlights) == "table",
	"5a. config defaults should include highlights table"
)
assert_true(
	type(defaults.icons) == "table"
		and type(defaults.icons.enable) == "boolean",
	"5b. config defaults should include icons.enable boolean"
)

-- ─── 6. Open palette and verify structure ────────────────────
local palette_panel = require("gitflow.panels.palette")
local test_entries = {
	{
		name = "status",
		description = "Open git status panel",
		category = "Git",
		keybinding = "gs",
	},
	{
		name = "branch",
		description = "Open branch list panel",
		category = "Git",
		keybinding = "<leader>gb",
	},
	{
		name = "issue",
		description = "GitHub issues list",
		category = "GitHub",
		keybinding = "<leader>gi",
	},
	{
		name = "pr",
		description = "GitHub PRs list",
		category = "GitHub",
		keybinding = "<leader>gr",
	},
	{
		name = "palette",
		description = "Open command palette",
		category = "UI",
		keybinding = "<leader>go",
	},
	{
		name = "help",
		description = "Show Gitflow usage",
		category = "UI",
		keybinding = nil,
	},
}

local picked = nil
palette_panel.open(cfg, test_entries, function(entry)
	picked = entry.name
end)

local prompt_bufnr = palette_panel.state.prompt_bufnr
local list_bufnr = palette_panel.state.list_bufnr
local list_winid = palette_panel.state.list_winid
local highlight_ns = palette_panel.state.highlight_ns
local render_ns = palette_panel.state.render_ns
assert_true(prompt_bufnr ~= nil, "6a. prompt buffer should exist")
assert_true(list_bufnr ~= nil, "6b. list buffer should exist")
assert_true(highlight_ns ~= nil, "6c. selection namespace should exist")
assert_true(render_ns ~= nil, "6d. render namespace should exist")

-- ─── 7. Section headers appear ───────────────────────────────
local list_lines = vim.api.nvim_buf_get_lines(
	list_bufnr, 0, -1, false
)
local found_git_header = false
local found_github_header = false
local found_ui_header = false
for _, line in ipairs(list_lines) do
	if line:find("Git", 1, true)
		and not line:find("GitHub", 1, true)
		and not line:find("Gitflow", 1, true)
		and not line:find("status", 1, true)
	then
		found_git_header = true
	end
	if line:find("GitHub", 1, true)
		and not line:find("issue", 1, true)
	then
		found_github_header = true
	end
	if line:find("UI", 1, true)
		and not line:find("palette", 1, true)
		and not line:find("help", 1, true)
	then
		found_ui_header = true
	end
end
assert_true(found_git_header, "7a. Git section header should appear")
assert_true(
	found_github_header, "7b. GitHub section header should appear"
)
assert_true(found_ui_header, "7c. UI section header should appear")

-- ─── 8. Keybind hints in rendered lines ──────────────────────
local found_keybind_hint = false
for _, line in ipairs(list_lines) do
	if line:find("%[gs%]") then
		found_keybind_hint = true
		break
	end
end
assert_true(
	found_keybind_hint,
	"8. rendered lines should contain [gs] keybind hint"
)

-- ─── 9. Numbered prefixes in rendered lines ──────────────────
local found_numbered = false
for _, line in ipairs(list_lines) do
	if line:find("%[1%]") then
		found_numbered = true
		break
	end
end
assert_true(
	found_numbered,
	"9. rendered lines should contain [1] numbered prefix"
)

-- ─── 10. Selectable lines filter out headers ────────────────
local selectable_count = 0
for _, _ in pairs(palette_panel.state.line_entries) do
	selectable_count = selectable_count + 1
end
assert_equals(
	selectable_count, 6,
	"10. selectable lines should equal number of entries"
)

-- ─── 11. Prompt keymaps exist ────────────────────────────────
local prompt_maps = vim.api.nvim_buf_get_keymap(
	prompt_bufnr, "i"
)
local has_cr = false
local has_esc = false
for _, m in ipairs(prompt_maps) do
	local lhs = vim.api.nvim_replace_termcodes(
		m.lhs, true, false, true
	)
	local cr = vim.api.nvim_replace_termcodes(
		"<CR>", true, false, true
	)
	local esc = vim.api.nvim_replace_termcodes(
		"<Esc>", true, false, true
	)
	if lhs == cr then
		has_cr = true
	end
	if lhs == esc then
		has_esc = true
	end
end
local has_1_insert = false
for _, m in ipairs(prompt_maps) do
	if m.lhs == "1" then
		has_1_insert = true
	end
end
assert_true(has_cr, "11a. prompt should have <CR> insert keymap")
assert_true(has_esc, "11b. prompt should have <Esc> insert keymap")
assert_true(
	has_1_insert,
	"11c. prompt should have insert-mode 1 quick-access keymap"
)

-- ─── 12. List keymaps exist ──────────────────────────────────
local list_maps = vim.api.nvim_buf_get_keymap(
	list_bufnr, "n"
)
local has_j = false
local has_k = false
local has_q = false
local has_1 = false
for _, m in ipairs(list_maps) do
	if m.lhs == "j" then
		has_j = true
	end
	if m.lhs == "k" then
		has_k = true
	end
	if m.lhs == "q" then
		has_q = true
	end
	if m.lhs == "1" then
		has_1 = true
	end
end
assert_true(has_j, "12a. list should have j keymap")
assert_true(has_k, "12b. list should have k keymap")
assert_true(has_q, "12c. list should have q keymap")
assert_true(has_1, "12d. list should have 1 quick-access keymap")

-- ─── 13. Numbered entries mapping ────────────────────────────
assert_true(
	palette_panel.state.numbered_entries[1] ~= nil,
	"13a. numbered_entries[1] should exist"
)
assert_equals(
	palette_panel.state.numbered_entries[1].name, "issue",
	"13b. numbered_entries[1] should be issue (priority order)"
)

-- ─── 14. Fuzzy search filters correctly ──────────────────────
vim.api.nvim_buf_set_lines(prompt_bufnr, 0, 1, false, { "iss" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = prompt_bufnr })
wait_until(function()
	for _, entry in pairs(palette_panel.state.line_entries) do
		if entry.name == "issue" then
			return true
		end
	end
	return false
end, "14. fuzzy search should filter to issue entry")

-- ─── 15. Clear query restores all entries ────────────────────
vim.api.nvim_buf_set_lines(prompt_bufnr, 0, 1, false, { "" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = prompt_bufnr })
wait_until(function()
	local count = 0
	for _, _ in pairs(palette_panel.state.line_entries) do
		count = count + 1
	end
	return count == 6
end, "15. clearing query should restore all entries")

-- ─── 16. Selection highlight present ─────────────────────────
local marks = vim.api.nvim_buf_get_extmarks(
	list_bufnr, highlight_ns, 0, -1, {}
)
assert_true(
	#marks == 1,
	"16. exactly one selection highlight extmark should exist"
)

-- ─── 17. Render highlights applied ───────────────────────────
local render_marks = vim.api.nvim_buf_get_extmarks(
	list_bufnr, render_ns, 0, -1, { details = true }
)
assert_true(
	#render_marks > 0,
	"17. render namespace should contain highlight extmarks"
)

-- ─── 18. Close and cleanup ───────────────────────────────────
palette_panel.close()
assert_true(
	not palette_panel.is_open(),
	"18a. palette should be closed after close()"
)
assert_true(
	palette_panel.state.prompt_bufnr == nil,
	"18b. prompt buffer state should be nil after close"
)
assert_true(
	palette_panel.state.render_ns == nil,
	"18c. render namespace state should be nil after close"
)
assert_true(
	vim.tbl_isempty(palette_panel.state.numbered_entries),
	"18d. numbered_entries should be empty after close"
)
assert_true(
	palette_panel.state.backdrop_winid == nil,
	"18e. backdrop_winid should be nil after close"
)
assert_true(
	palette_panel.state.backdrop_bufnr == nil,
	"18f. backdrop_bufnr should be nil after close"
)

-- ─── 19. Nerd font icon toggle ───────────────────────────────
icons.setup({ icons = { enable = true } })
local nerd_icon = icons.get("palette", "git")
assert_true(
	nerd_icon ~= "#",
	"19. nerd font mode should return non-ascii icon"
)
icons.setup(cfg)

-- ─── 20. Footer content ─────────────────────────────────────
-- Re-open palette to verify footer through window config
palette_panel.open(cfg, test_entries, function() end)
local prompt_winid = palette_panel.state.prompt_winid
if vim.fn.has("nvim-0.10") == 1 and cfg.ui.float.footer then
	local win_cfg = vim.api.nvim_win_get_config(prompt_winid)
	local footer_text = ""
	if type(win_cfg.footer) == "string" then
		footer_text = win_cfg.footer
	elseif type(win_cfg.footer) == "table" then
		for _, part in ipairs(win_cfg.footer) do
			if type(part) == "string" then
				footer_text = footer_text .. part
			elseif type(part) == "table" and part[1] then
				footer_text = footer_text .. part[1]
			end
		end
	end
	assert_true(
		footer_text:find("quick select", 1, true) ~= nil,
		"20. footer should contain quick select hint"
	)
else
	pass_count = pass_count + 1
end
palette_panel.close()

gh.check_prerequisites = original_check

print(
	("Stage 10 palette tests passed (%d assertions)"):format(
		pass_count
	)
)
