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

-- ── Test 11: Non-table panel_keybindings ────────────────────────────
io.write("\n[11] Validation: non-table panel_keybindings\n")

assert_error(function()
	gitflow.setup({
		panel_keybindings = "invalid",
	})
end, "must be a table",
	"should reject non-table panel_keybindings")

-- ── Test 12: Valid panel names accepted ─────────────────────────────
io.write("\n[12] All valid panel names accepted\n")

local valid_panels = {
	"status", "branch", "diff", "review", "conflict",
	"issues", "prs", "log", "stash", "reset",
	"revert", "cherry_pick",
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

-- ── Test 13: E2E — overridden key works on status buffer ────────────
io.write("\n[13] E2E: overridden status panel keybinding\n")

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
local ui = require("gitflow.ui")

-- Open the status panel
status_panel.open(e2e_cfg)
vim.wait(200, function() return false end)

local bufnr = status_panel.state.bufnr

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
utils.system = orig_system

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
