-- scripts/test_keybinding_optout.lua — the global map set is opt-out.
--
-- gitflow's global keybindings are ordinary normal-mode mappings installed in
-- every buffer, so a user whose config already owns a key needs a way to say
-- so. Before this, `config.setup()` validated against `defaults()` as the
-- schema and rejected anything else, which made `keybindings = false` an
-- error and left "override all of them individually" as the only escape.
--
-- Asserts: the whole set can be declined, one action can be declined, the
-- `<Plug>` targets survive both (so a user can still map their own key), and
-- no default shadows a built-in Neovim command.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, failed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " — " .. tostring(err))
	end
end

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

print("Keybinding opt-out tests")
print("========================")

local gitflow = require("gitflow")
local config = require("gitflow.config")

---Drop every gitflow global mapping, so one setup() cannot be read through
---the mappings a previous one installed.
local function clear_gitflow_maps()
	for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
		if type(map.rhs) == "string" and map.rhs:find("Gitflow", 1, true) then
			pcall(vim.keymap.del, "n", map.lhs)
		end
	end
end

---@param lhs string  a key as written in config (may carry `<leader>`)
---@return string|nil  the mapping's rhs, or nil when the key is unmapped
local function rhs_for(lhs)
	local resolved = lhs:gsub("<leader>", vim.g.mapleader or "\\")
	local mapping = vim.fn.maparg(resolved, "n", false, true)
	if type(mapping) ~= "table" or mapping.rhs == nil or mapping.rhs == "" then
		return nil
	end
	return mapping.rhs
end

test("keybindings = false installs no global mappings", function()
	clear_gitflow_maps()
	local cfg = gitflow.setup({ keybindings = false })
	assert_equals(cfg.keybindings, false, "the opt-out should survive the merge")

	for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
		local rhs = type(map.rhs) == "string" and map.rhs or ""
		assert_true(
			not rhs:find("<Plug>(Gitflow", 1, true),
			("%q should not be mapped when keybindings = false"):format(map.lhs)
		)
	end

	-- The <Plug> targets stay, so a user can still bind their own key to them.
	assert_true(
		rhs_for("<Plug>(GitflowStatus)") ~= nil,
		"<Plug>(GitflowStatus) should still be defined"
	)
end)

test("a single action set to false installs only that one nowhere", function()
	clear_gitflow_maps()
	local cfg = gitflow.setup({ keybindings = { commit = false } })
	assert_equals(cfg.keybindings.commit, false, "the disabled action should stay false")

	assert_true(rhs_for(config.defaults().keybindings.commit) == nil, "commit should be unmapped")
	assert_equals(
		rhs_for(cfg.keybindings.status),
		"<Plug>(GitflowStatus)",
		"the other defaults should be untouched"
	)
end)

test("a disabled action cannot collide with another action's key", function()
	clear_gitflow_maps()
	-- status keeps its default; commit is disabled, so it claims nothing and
	-- the collision check has nothing to report.
	local ok = pcall(gitflow.setup, { keybindings = { commit = false } })
	assert_true(ok, "disabling an action should not trip the collision check")
end)

test("a non-string, non-false mapping is still rejected", function()
	local ok, err = pcall(config.setup, { keybindings = { commit = 42 } })
	assert_true(not ok, "a numeric mapping should be rejected")
	assert_true(
		tostring(err):find("false to disable it", 1, true) ~= nil,
		"the error should point at the opt-out: " .. tostring(err)
	)
end)

test("no default shadows a built-in Neovim command", function()
	clear_gitflow_maps()
	local defaults = gitflow.setup({}).keybindings

	-- Bare `g<x>` sequences Neovim itself defines (or, for gc/gr, defines as
	-- of 0.10/0.11). Claiming one of these makes a core editor verb wait on
	-- gitflow's timeout or stop working altogether.
	local builtin = {
		gc = "comment operator", gr = "LSP prefix", gs = "sleep",
		gD = "goto declaration", gP = "paste before", gV = "reselect",
		gT = "previous tab", gF = "edit file at line", gI = "insert at col 1",
		gN = "search-match text object", gd = "goto definition",
		gf = "edit file", gg = "first line", gi = "resume insert",
		gv = "reselect last", gp = "paste", gq = "format", gu = "lowercase",
		gU = "uppercase", ga = "show character", ge = "backward to end",
		gj = "display line down", gk = "display line up", gm = "middle of line",
		gn = "search-match text object", go = "goto byte", gt = "next tab",
		gw = "format in place", gx = "open under cursor", gJ = "join",
		gE = "backward to end", gH = "select-line mode", gR = "virtual replace",
		gQ = "Ex mode",
	}
	for action, mapping in pairs(defaults) do
		local reason = builtin[mapping]
		assert_true(
			reason == nil,
			("default for %s is %q, which shadows Neovim's %s"):format(
				action, mapping, tostring(reason)
			)
		)
	end
end)

test("panel_keybindings rejects two verbs on one key", function()
	local ok, err = pcall(config.setup, {
		panel_keybindings = { tag = { D = "<leader>k", X = "<leader>k" } },
	})
	assert_true(not ok, "an intra-panel collision should be rejected")
	assert_true(
		tostring(err):find("panel_keybindings.tag", 1, true) ~= nil,
		"the error should name the panel: " .. tostring(err)
	)
end)

test("panel_keybindings rejects a non-string, non-false replacement", function()
	local ok = pcall(config.setup, { panel_keybindings = { tag = { D = 7 } } })
	assert_true(not ok, "a numeric replacement should be rejected")
end)

gitflow.setup({})

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
