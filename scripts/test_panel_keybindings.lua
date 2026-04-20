-- scripts/test_panel_keybindings.lua — panel-local keybinding customization
--
-- Run: nvim --headless -u NONE -l scripts/test_panel_keybindings.lua
--
-- Covers:
--   1. Config validation for panel_keybindings
--   2. Conflict detection within a panel
--   3. Fallback to defaults when no overrides
--   4. Override resolution via resolve_panel_key
--   5. E2E: overridden key works on a status panel buffer

vim.opt.runtimepath:append(".")

local pass_count = 0
local fail_count = 0
local test_names = {}

local function assert_true(condition, message)
	if not condition then
		fail_count = fail_count + 1
		table.insert(test_names, "FAIL: " .. message)
		io.write("  FAIL: " .. message .. "\n")
	else
		pass_count = pass_count + 1
		table.insert(test_names, "PASS: " .. message)
		io.write("  PASS: " .. message .. "\n")
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		fail_count = fail_count + 1
		local err = ("%s (expected=%s, actual=%s)"):format(
			message,
			vim.inspect(expected),
			vim.inspect(actual)
		)
		table.insert(test_names, "FAIL: " .. err)
		io.write("  FAIL: " .. err .. "\n")
	else
		pass_count = pass_count + 1
		table.insert(test_names, "PASS: " .. message)
		io.write("  PASS: " .. message .. "\n")
	end
end

local function assert_error(fn, pattern, message)
	local ok, err = pcall(fn)
	if ok then
		fail_count = fail_count + 1
		table.insert(test_names, "FAIL: " .. message .. " (no error)")
		io.write("  FAIL: " .. message .. " (no error thrown)\n")
	elseif pattern and not tostring(err):find(pattern, 1, true) then
		fail_count = fail_count + 1
		local detail = message
			.. " (error did not match pattern '"
			.. pattern .. "'): " .. tostring(err)
		table.insert(test_names, "FAIL: " .. detail)
		io.write("  FAIL: " .. detail .. "\n")
	else
		pass_count = pass_count + 1
		table.insert(test_names, "PASS: " .. message)
		io.write("  PASS: " .. message .. "\n")
	end
end

local function find_buf_map(buf, mode, lhs)
	local maps = vim.api.nvim_buf_get_keymap(buf, mode)
	local target = vim.api.nvim_replace_termcodes(lhs, true, true, true)
	for _, m in ipairs(maps) do
		local mlhs = vim.api.nvim_replace_termcodes(
			m.lhs, true, true, true
		)
		if mlhs == target then
			return m
		end
	end
	return nil
end

---@param bufnr integer
---@param needle string
---@return boolean
local function buffer_contains(bufnr, needle)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			return true
		end
	end
	return false
end

---@param winid integer|nil
---@return string
local function window_footer_text(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return ""
	end

	local ok, win_cfg = pcall(vim.api.nvim_win_get_config, winid)
	if not ok or type(win_cfg) ~= "table" then
		return ""
	end

	local footer = win_cfg.footer
	if type(footer) == "string" then
		return footer
	end

	if type(footer) ~= "table" then
		return ""
	end

	local parts = {}
	for _, chunk in ipairs(footer) do
		if type(chunk) == "string" then
			parts[#parts + 1] = chunk
		elseif type(chunk) == "table" and type(chunk[1]) == "string" then
			parts[#parts + 1] = chunk[1]
		end
	end
	return table.concat(parts, "")
end

-- ── Test 1: Default setup with empty panel_keybindings ──────────────
io.write("\n[1] Default panel_keybindings\n")

local gitflow = require("gitflow")
local cfg = gitflow.setup({})

assert_equals(
	type(cfg.panel_keybindings), "table",
	"panel_keybindings should default to a table"
)
assert_equals(
	next(cfg.panel_keybindings), nil,
	"panel_keybindings should default to empty"
)

-- ── Test 2: resolve_panel_key fallback ──────────────────────────────
io.write("\n[2] resolve_panel_key fallback to default\n")

local config = require("gitflow.config")

assert_equals(
	config.resolve_panel_key(cfg, "status", "stage", "s"),
	"s",
	"should return default when no override exists"
)
assert_equals(
	config.resolve_panel_key(cfg, "branch", "create", "c"),
	"c",
	"should return default for branch panel"
)

-- ── Test 3: resolve_panel_key with override ─────────────────────────
io.write("\n[3] resolve_panel_key with override\n")

local cfg_override = gitflow.setup({
	panel_keybindings = {
		status = {
			stage = "S",
			unstage = "U",
		},
	},
})

assert_equals(
	config.resolve_panel_key(cfg_override, "status", "stage", "s"),
	"S",
	"should return override key for stage"
)
assert_equals(
	config.resolve_panel_key(cfg_override, "status", "unstage", "u"),
	"U",
	"should return override key for unstage"
)
assert_equals(
	config.resolve_panel_key(cfg_override, "status", "close", "q"),
	"q",
	"should return default for non-overridden action"
)
assert_equals(
	config.resolve_panel_key(cfg_override, "branch", "create", "c"),
	"c",
	"should return default for non-overridden panel"
)

-- ── Test 4: Validation — invalid panel name ─────────────────────────
io.write("\n[4] Validation: invalid panel name\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			bogus_panel = { stage = "s" },
		},
	})
end, "not a valid panel name",
	"should reject unknown panel name")

-- ── Test 5: Validation — non-table panel value ──────────────────────
io.write("\n[5] Validation: non-table panel value\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			status = "not a table",
		},
	})
end, "must be a table",
	"should reject non-table panel override")

-- ── Test 6: Validation — non-string action name ─────────────────────
io.write("\n[6] Validation: non-string action name\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			status = { [123] = "x" },
		},
	})
end, "non-empty strings",
	"should reject non-string action key")

-- ── Test 7: Validation — non-string mapping value ───────────────────
io.write("\n[7] Validation: non-string mapping value\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			status = { stage = 42 },
		},
	})
end, "non-empty string",
	"should reject non-string mapping value")

-- ── Test 8: Validation — empty string action ────────────────────────
io.write("\n[8] Validation: empty string action\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			status = { [""] = "x" },
		},
	})
end, "non-empty strings",
	"should reject empty action key")

-- ── Test 9: Validation — empty string mapping ───────────────────────
io.write("\n[9] Validation: empty string mapping\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			status = { stage = "" },
		},
	})
end, "non-empty string",
	"should reject empty mapping value")

-- ── Test 10: Conflict detection ─────────────────────────────────────
io.write("\n[10] Conflict detection within a panel\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			status = {
				stage = "x",
				unstage = "x",
			},
		},
	})
end, "conflicting key",
	"should reject duplicate keys in same panel")

-- ── Test 11: Conflict detection with existing defaults ──────────────
io.write("\n[11] Conflict detection against default keymaps\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			status = {
				stage = "u",
			},
		},
	})
end, "conflicting key",
	"should reject override that collides with non-overridden default")

local ok_no_conflict = pcall(function()
	gitflow.setup({
		panel_keybindings = {
			status = {
				stage = "u",
				unstage = "U",
			},
		},
	})
end)
assert_true(
	ok_no_conflict,
	"should allow overrides when all resulting panel keys are unique"
)

-- ── Test 12: Palette context-aware conflict detection ────────────────
io.write("\n[12] Palette context-aware conflict detection\n")

local ok_palette_context = pcall(function()
	gitflow.setup({
		panel_keybindings = {
			palette = {
				prompt_submit = "X",
				list_submit = "X",
			},
		},
	})
end)
assert_true(
	ok_palette_context,
	"should allow same key for palette prompt/list contexts"
)

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			palette = {
				list_submit = "q",
			},
		},
	})
end, "conflicting key",
	"should reject palette duplicates within the same context")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			palette = {
				quick_select_1 = "q",
			},
		},
	})
end, "conflicting key",
	"should reject quick-select key collisions with list keys")

-- ── Test 12b: Reserve positional shortcuts for commit-select panels ──
io.write("\n[12b] Validation: reserved positional shortcuts\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			reset = {
				close = "1",
			},
		},
	})
end, "reserved positional key",
	"should reject reset overrides that collide with fixed 1-9 shortcuts")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			revert = {
				refresh = "2",
			},
		},
	})
end, "reserved positional key",
	"should reject revert overrides that collide with fixed 1-9 shortcuts")

assert_error(function()
	gitflow.setup({
		panel_keybindings = {
			cherry_pick = {
				close = "9",
			},
		},
	})
end, "reserved positional key",
	"should reject cherry-pick overrides that collide with fixed 1-9 shortcuts")

local ok_no_positional_conflict = pcall(function()
	gitflow.setup({
		panel_keybindings = {
			reset = {
				close = "Q",
			},
			revert = {
				refresh = "R",
			},
			cherry_pick = {
				close = "C",
			},
		},
	})
end)
assert_true(
	ok_no_positional_conflict,
	"should allow non-positional overrides for reset/revert/cherry_pick"
)

-- ── Test 13: Non-table panel_keybindings ────────────────────────────
io.write("\n[13] Validation: non-table panel_keybindings\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = "invalid",
	})
end, "must be a table",
	"should reject non-table panel_keybindings")

-- ── Test 14: Valid panel names accepted ─────────────────────────────
io.write("\n[14] All valid panel names accepted\n")

local valid_panels = {
	"status", "branch", "diff", "review", "conflict",
	"issues", "prs", "log", "stash", "reset",
	"revert", "cherry_pick", "labels", "palette",
}

for _, panel in ipairs(valid_panels) do
	local ok = pcall(function()
		gitflow.setup({
			panel_keybindings = {
				[panel] = { close = "Q" },
			},
		})
	end)
	assert_true(ok, "panel name '" .. panel .. "' should be valid")
end

-- ── Test 15: E2E — overridden key works on status buffer ────────────
io.write("\n[15] E2E: overridden status panel keybinding\n")

local e2e_cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 40 },
	},
	panel_keybindings = {
		status = {
			stage = "S",
			close = "Q",
		},
	},
})

-- Stub git/gh to prevent real calls
local utils = require("gitflow.utils")
local orig_system = utils.system
utils.system = function(cmd, opts)
	if type(cmd) == "table" then
		local sub = cmd[1] or ""
		if sub == "git" then
			local arg2 = cmd[2] or ""
			if arg2 == "status" then
				if opts and opts.on_exit then
					opts.on_exit("", 0)
				end
				return
			elseif arg2 == "rev-parse" then
				if opts and opts.on_exit then
					opts.on_exit(vim.fn.getcwd(), 0)
				end
				return
			elseif arg2 == "branch" then
				if opts and opts.on_exit then
					opts.on_exit("* main", 0)
				end
				return
			elseif arg2 == "log" then
				if opts and opts.on_exit then
					opts.on_exit("", 0)
				end
				return
			elseif arg2 == "diff" then
				if opts and opts.on_exit then
					opts.on_exit("", 0)
				end
				return
			end
		elseif sub == "gh" then
			if opts and opts.on_exit then
				opts.on_exit("", 0)
			end
			return
		end
	end
	if opts and opts.on_exit then
		opts.on_exit("", 0)
	end
end

local status_panel = require("gitflow.panels.status")

-- Open the status panel
status_panel.open(e2e_cfg)
vim.wait(200, function() return false end)

local bufnr = status_panel.state.bufnr

if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
	-- The overridden key "S" should be mapped (for stage)
	local s_map = find_buf_map(bufnr, "n", "S")
	assert_true(
		s_map ~= nil,
		"overridden key 'S' should be mapped on status buffer"
	)

	-- The default key "s" should NOT be mapped
	local old_s_map = find_buf_map(bufnr, "n", "s")
	assert_true(
		old_s_map == nil,
		"default key 's' should NOT be mapped when overridden"
	)

	-- The overridden close key "Q" should be mapped
	local q_map = find_buf_map(bufnr, "n", "Q")
	assert_true(
		q_map ~= nil,
		"overridden key 'Q' should be mapped for close"
	)

	-- The default close key "q" should NOT be mapped
	local old_q = find_buf_map(bufnr, "n", "q")
	assert_true(
		old_q == nil,
		"default key 'q' should NOT be mapped when overridden"
	)

	-- Non-overridden keys should still work
	local refresh_map = find_buf_map(bufnr, "n", "r")
	assert_true(
		refresh_map ~= nil,
		"non-overridden key 'r' (refresh) should still be mapped"
	)
else
	assert_true(false, "status panel buffer should be valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
end

-- Cleanup
status_panel.close()

-- ── Test 16: E2E — status float footer reflects overrides ───────────
io.write("\n[16] E2E: status float footer uses overridden keys\n")

local status_float_cfg = gitflow.setup({
	panel_keybindings = {
		status = {
			stage = "S",
			close = "Q",
		},
	},
})

status_panel.open(status_float_cfg)
vim.wait(200, function() return false end)

local status_footer = window_footer_text(status_panel.state.winid)
assert_true(
	status_footer:find("S stage", 1, true) ~= nil,
	"status footer should show overridden stage key"
)
assert_true(
	status_footer:find("Q close", 1, true) ~= nil,
	"status footer should show overridden close key"
)
assert_true(
	status_footer:find("s stage", 1, true) == nil,
	"status footer should not show default stage key after override"
)
assert_true(
	status_footer:find("q close", 1, true) == nil,
	"status footer should not show default close key after override"
)

status_panel.close()
utils.system = orig_system

-- ── Test 17: E2E — overridden key works on labels buffer ────────────
io.write("\n[17] E2E: overridden labels panel keybinding\n")

local labels_cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 40 },
	},
	panel_keybindings = {
		labels = {
			create = "n",
			close = "Q",
		},
	},
})

local labels_panel = require("gitflow.panels.labels")
local gh_labels = require("gitflow.gh.labels")
local orig_labels_list = gh_labels.list
gh_labels.list = function(_, cb)
	cb(nil, {})
end

labels_panel.open(labels_cfg)
vim.wait(200, function() return false end)

local labels_bufnr = labels_panel.state.bufnr
if labels_bufnr and vim.api.nvim_buf_is_valid(labels_bufnr) then
	assert_true(
		find_buf_map(labels_bufnr, "n", "n") ~= nil,
		"overridden labels key 'n' should be mapped for create"
	)
	assert_true(
		find_buf_map(labels_bufnr, "n", "c") == nil,
		"default labels key 'c' should not remain mapped"
	)
	assert_true(
		find_buf_map(labels_bufnr, "n", "Q") ~= nil,
		"overridden labels key 'Q' should be mapped for close"
	)
	assert_true(
		find_buf_map(labels_bufnr, "n", "q") == nil,
		"default labels key 'q' should not remain mapped"
	)
	assert_true(
		buffer_contains(labels_bufnr, "n create"),
		"labels footer hints should show overridden create key"
	)
	assert_true(
		buffer_contains(labels_bufnr, "Q close"),
		"labels footer hints should show overridden close key"
	)
	assert_true(
		not buffer_contains(labels_bufnr, "c create"),
		"labels footer hints should not show default create key"
	)
	assert_true(
		not buffer_contains(labels_bufnr, "q close"),
		"labels footer hints should not show default close key"
	)
else
	assert_true(false, "labels panel buffer should be valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
end

labels_panel.close()
gh_labels.list = orig_labels_list

-- ── Test 18: E2E — overridden key works on palette buffers ──────────
io.write("\n[18] E2E: overridden palette panel keybinding\n")

local palette_cfg = gitflow.setup({
	panel_keybindings = {
		palette = {
			prompt_close = "Z",
			prompt_submit = "X",
			prompt_next_down = "N",
			prompt_prev_up = "P",
			list_submit = "L",
			list_next_j = "J",
			list_prev_k = "K",
			list_close = "Q",
			list_close_esc = "E",
			quick_select_1 = "0",
		},
	},
})

local palette_panel = require("gitflow.panels.palette")
palette_panel.open(palette_cfg, {
	{
		name = "status",
		description = "Open status panel",
		category = "Git",
	},
}, function() end)
vim.wait(200, function() return false end)

local prompt_bufnr = palette_panel.state.prompt_bufnr
local list_bufnr = palette_panel.state.list_bufnr
if prompt_bufnr and list_bufnr
	and vim.api.nvim_buf_is_valid(prompt_bufnr)
	and vim.api.nvim_buf_is_valid(list_bufnr) then
	assert_true(
		find_buf_map(prompt_bufnr, "n", "X") ~= nil,
		"overridden palette prompt key 'X' should submit"
	)
	assert_true(
		find_buf_map(prompt_bufnr, "n", "<CR>") == nil,
		"default palette prompt '<CR>' should not remain mapped"
	)
	assert_true(
		find_buf_map(prompt_bufnr, "n", "Z") ~= nil,
		"overridden palette prompt key 'Z' should close"
	)
	assert_true(
		find_buf_map(prompt_bufnr, "n", "<Esc>") == nil,
		"default palette prompt '<Esc>' should not remain mapped"
	)
	assert_true(
		find_buf_map(prompt_bufnr, "n", "0") ~= nil,
		"overridden quick-select key '0' should be mapped"
	)
	assert_true(
		find_buf_map(prompt_bufnr, "n", "1") == nil,
		"default quick-select key '1' should not remain mapped"
	)
	assert_true(
		find_buf_map(list_bufnr, "n", "L") ~= nil,
		"overridden palette list key 'L' should submit"
	)
	assert_true(
		find_buf_map(list_bufnr, "n", "<CR>") == nil,
		"default palette list '<CR>' should not remain mapped"
	)
	assert_true(
		find_buf_map(list_bufnr, "n", "Q") ~= nil,
		"overridden palette list key 'Q' should close"
	)
	assert_true(
		find_buf_map(list_bufnr, "n", "q") == nil,
		"default palette list 'q' should not remain mapped"
	)
	assert_true(
		find_buf_map(list_bufnr, "n", "E") ~= nil,
		"overridden palette list key 'E' should close"
	)
	assert_true(
		find_buf_map(list_bufnr, "n", "<Esc>") == nil,
		"default palette list '<Esc>' should not remain mapped"
	)

	local prompt_footer = window_footer_text(palette_panel.state.prompt_winid)
	local list_footer = window_footer_text(palette_panel.state.list_winid)
	assert_true(
		prompt_footer:find("X confirm", 1, true) ~= nil,
		"palette prompt footer should show overridden submit key"
	)
	assert_true(
		prompt_footer:find("Z close", 1, true) ~= nil,
		"palette prompt footer should show overridden close key"
	)
	assert_true(
		prompt_footer:find("[0/2/3/4/5/6/7/8/9] quick select", 1, true) ~= nil,
		"palette prompt footer should show overridden quick-select key"
	)
	assert_true(
		prompt_footer:find("<CR> confirm", 1, true) == nil,
		"palette prompt footer should not show default submit key"
	)
	assert_true(
		prompt_footer:find("<Esc> close", 1, true) == nil,
		"palette prompt footer should not show default close key"
	)
	assert_true(
		list_footer:find("L select", 1, true) ~= nil,
		"palette list footer should show overridden submit key"
	)
	assert_true(
		list_footer:find("J/K move", 1, true) ~= nil,
		"palette list footer should show overridden move keys"
	)
	assert_true(
		list_footer:find("Q/E close", 1, true) ~= nil,
		"palette list footer should show overridden close keys"
	)
	assert_true(
		list_footer:find("<CR> select", 1, true) == nil,
		"palette list footer should not show default submit key"
	)
	assert_true(
		list_footer:find("j/k move", 1, true) == nil,
		"palette list footer should not show default move keys"
	)
	assert_true(
		list_footer:find("q/<Esc> close", 1, true) == nil,
		"palette list footer should not show default close keys"
	)
else
	assert_true(false, "palette prompt/list buffers should be valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
end

palette_panel.close()

-- ── Test 19: E2E — stash float footer reflects overrides ─────────────
io.write("\n[19] E2E: stash float footer uses overridden keys\n")

local stash_cfg = gitflow.setup({
	panel_keybindings = {
		stash = {
			pop = "X",
			close = "Q",
		},
	},
})

local stash_panel = require("gitflow.panels.stash")
local git_stash = require("gitflow.git.stash")
local git_branch = require("gitflow.git.branch")
local orig_stash_list = git_stash.list
local orig_branch_current = git_branch.current

git_stash.list = function(_, cb)
	cb(nil, {})
end
git_branch.current = function(_, cb)
	cb(nil, "main")
end

stash_panel.open(stash_cfg)
vim.wait(200, function() return false end)

local stash_footer = window_footer_text(stash_panel.state.winid)
assert_true(
	stash_footer:find("X pop", 1, true) ~= nil,
	"stash footer should show overridden pop key"
)
assert_true(
	stash_footer:find("Q close", 1, true) ~= nil,
	"stash footer should show overridden close key"
)
assert_true(
	stash_footer:find("P pop", 1, true) == nil,
	"stash footer should not show default pop key after override"
)
assert_true(
	stash_footer:find("q close", 1, true) == nil,
	"stash footer should not show default close key after override"
)

stash_panel.close()
git_stash.list = orig_stash_list
git_branch.current = orig_branch_current

-- ── Test 20: E2E — PR detail legends reflect overrides ───────────────
io.write("\n[20] E2E: PR detail legend uses overridden keys\n")

local prs_cfg = gitflow.setup({
	panel_keybindings = {
		prs = {
			back = "B",
			comment = "K",
			review = "V",
		},
	},
})

local prs_panel = require("gitflow.panels.prs")
local gh_prs = require("gitflow.gh.prs")
local orig_prs_view = gh_prs.view
gh_prs.view = function(number, _, cb)
	cb(nil, {
		number = tonumber(number),
		title = "Legend override smoke test",
		state = "OPEN",
		isDraft = false,
		author = { login = "octocat" },
		headRefName = "feature/prs-legend",
		baseRefName = "main",
		labels = {},
		assignees = {},
		body = "body",
		reviewRequests = {},
		reviews = {},
		comments = {},
		files = {},
	})
end

prs_panel.open_view(7, prs_cfg)
vim.wait(200, function() return false end)

local prs_bufnr = prs_panel.state.bufnr
if prs_bufnr and vim.api.nvim_buf_is_valid(prs_bufnr) then
	assert_true(
		buffer_contains(prs_bufnr, "B back"),
		"PR detail legend should show overridden back key"
	)
	assert_true(
		buffer_contains(prs_bufnr, "K comment"),
		"PR detail legend should show overridden comment key"
	)
	assert_true(
		buffer_contains(prs_bufnr, "V review"),
		"PR detail legend should show overridden review key"
	)
	assert_true(
		not buffer_contains(prs_bufnr, "b back"),
		"PR detail legend should not show default back key after override"
	)
	assert_true(
		not buffer_contains(prs_bufnr, "C comment"),
		"PR detail legend should not show default comment key after override"
	)
	assert_true(
		not buffer_contains(prs_bufnr, "v review"),
		"PR detail legend should not show default review key after override"
	)
else
	assert_true(false, "PR panel buffer should be valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
	assert_true(false, "skip: buffer not valid")
end

prs_panel.close()
gh_prs.view = orig_prs_view

-- ── Test 21: E2E — review submit hints reflect overrides ─────────────
io.write("\n[21] E2E: review submit hints use overridden key\n")

local review_cfg = gitflow.setup({
	panel_keybindings = {
		review = {
			submit_review = "Z",
		},
	},
})

local review_panel = require("gitflow.panels.review")
local input = require("gitflow.ui.input")
local utils_mod = require("gitflow.utils")
local orig_review_view = gh_prs.view
local orig_review_diff = gh_prs.diff
local orig_review_comments = gh_prs.review_comments
local orig_input_prompt = input.prompt
local orig_notify = utils_mod.notify
local orig_vim_fn_line = vim.fn.line

gh_prs.view = function(number, _, cb)
	cb(nil, {
		number = tonumber(number),
		title = "Review hints smoke test",
	})
end

gh_prs.diff = function(_, _, cb)
	cb(nil, table.concat({
		"diff --git a/lua/gitflow/commands.lua b/lua/gitflow/commands.lua",
		"index 1111111..2222222 100644",
		"--- a/lua/gitflow/commands.lua",
		"+++ b/lua/gitflow/commands.lua",
		"@@ -1,1 +1,1 @@",
		"-old line",
		"+new line",
	}, "\n"))
end

gh_prs.review_comments = function(_, _, cb)
	cb(nil, {})
end

review_panel.open(review_cfg, 7)
vim.wait(200, function() return false end)

local function find_first_diff_content_line()
	local bufnr = review_panel.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	for line = 1, vim.api.nvim_buf_line_count(bufnr) do
		local ctx = review_panel.state.line_context[line]
		if ctx and ctx.path and (ctx.new_line or ctx.old_line) then
			return line
		end
	end
	return nil
end

local review_line = find_first_diff_content_line()
assert_true(
	type(review_line) == "number",
	"review panel should expose a diff content line"
)

if review_line then
	review_panel.state.pending_comments = {
		{
			id = 1,
			path = "lua/gitflow/commands.lua",
			line = review_line,
			body = "queued",
		},
	}
	review_panel.re_render()

	local review_bufnr = review_panel.state.bufnr
	if review_bufnr and vim.api.nvim_buf_is_valid(review_bufnr) then
		assert_true(
			buffer_contains(
				review_bufnr,
				"Pending comments: 1 (press Z to submit)"
			),
			"review pending summary should show overridden submit key"
		)
		assert_true(
			not buffer_contains(
				review_bufnr,
				"Pending comments: 1 (press S to submit)"
			),
			"review pending summary should not show default submit key"
		)
	end

	local notified = {}
	utils_mod.notify = function(message, _)
		notified[#notified + 1] = tostring(message)
	end
	input.prompt = function(_, cb)
		cb("looks good")
	end

	review_panel.state.pending_comments = {}
	review_panel.re_render()
	review_line = find_first_diff_content_line()
	assert_true(
		type(review_line) == "number",
		"review panel should keep a diff content line after re-render"
	)
	if review_panel.state.winid
		and vim.api.nvim_win_is_valid(review_panel.state.winid) then
		vim.api.nvim_win_set_cursor(review_panel.state.winid, { review_line, 0 })
	end
	review_panel.inline_comment()

	local inline_msg = notified[#notified] or ""
	assert_true(
		inline_msg:find("press Z to submit review", 1, true) ~= nil,
		"inline comment notice should show overridden submit key"
	)
	assert_true(
		inline_msg:find("press S to submit review", 1, true) == nil,
		"inline comment notice should not show default submit key"
	)

	review_line = find_first_diff_content_line()
	assert_true(
		type(review_line) == "number",
		"review panel should keep a diff content line after inline comment"
	)

	vim.fn.line = function(mark)
		if mark == "v" or mark == "." then
			return review_line
		end
		return orig_vim_fn_line(mark)
	end
	review_panel.inline_comment_visual()

	local visual_msg = notified[#notified] or ""
	assert_true(
		visual_msg:find("press Z to submit review", 1, true) ~= nil,
		"range comment notice should show overridden submit key"
	)
	assert_true(
		visual_msg:find("press S to submit review", 1, true) == nil,
		"range comment notice should not show default submit key"
	)
end

review_panel.close()
gh_prs.view = orig_review_view
gh_prs.diff = orig_review_diff
gh_prs.review_comments = orig_review_comments
input.prompt = orig_input_prompt
utils_mod.notify = orig_notify
vim.fn.line = orig_vim_fn_line

-- ── Summary ─────────────────────────────────────────────────────────
io.write(("\n%d passed, %d failed\n"):format(pass_count, fail_count))
if fail_count > 0 then
	io.write("\nFailed tests:\n")
	for _, name in ipairs(test_names) do
		if name:find("^FAIL") then
			io.write("  " .. name .. "\n")
		end
	end
	vim.cmd("cquit! 1")
else
	vim.cmd("quit!")
end
