-- scripts/test_keymap_contract.lua — the cross-panel keybinding contract.
--
-- Panel keys are buffer-local, so nothing in Neovim stops one panel binding a
-- destructive verb to a key another panel uses for something benign. Muscle
-- memory does not know which buffer it is in: `A` used to be "edit assignees"
-- in the two panels a user visits most and "abort the in-progress merge" in
-- the panel they land in under stress. This spec is what stops that class of
-- key coming back.
--
-- It asserts, over EVERY registered key surface:
--   * no key means both a destructive and a benign thing;
--   * `r` is refresh everywhere it is bound;
--   * `?` opens a help buffer generated from the surface's own registry;
--   * `panel_keybindings` moves and unbinds keys, hints included.

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

print("Keymap contract tests")
print("=====================")

local gitflow = require("gitflow")
local cfg = gitflow.setup({})
local panel = require("gitflow.ui.panel")
local help = require("gitflow.ui.help")

-- Load every key surface. Globbed, not listed: a hardcoded list lets a new
-- panel opt out of this contract by simply not being added to it.
for _, path in ipairs(vim.fn.glob(project_root .. "/lua/gitflow/panels/*.lua", false, true)) do
	local modname = vim.fn.fnamemodify(path, ":t:r")
	local ok, err = pcall(require, "gitflow.panels." .. modname)
	assert(ok, ("could not load panel %s: %s"):format(modname, tostring(err)))
end
-- Surfaces that are not panel modules: review's diff pane and the merge
-- resolver register themselves from these.
require("gitflow.review.overlay")
require("gitflow.ui.conflict")

local surfaces = panel.surfaces()

---Every advertised key on every surface: key -> list of { surface, desc,
---destructive }. Only advertised entries count — an entry with no `desc` is a
---no-op or an alias with no meaning of its own to collide.
---@return table<string, table[]>
local function meanings_by_key()
	local by_key = {}
	for _, surface in ipairs(surfaces) do
		for _, entry in ipairs(surface.keymaps) do
			if entry.desc then
				for _, key in ipairs(panel.bound_keys(entry)) do
					by_key[key] = by_key[key] or {}
					table.insert(by_key[key], {
						surface = surface.name,
						desc = entry.desc,
						destructive = entry.destructive == true,
					})
				end
			end
		end
	end
	return by_key
end

test("every panel registers a key surface", function()
	assert_true(#surfaces >= 20, ("expected every panel to register, got %d"):format(#surfaces))
	local names = {}
	for _, surface in ipairs(surfaces) do
		names[surface.name] = true
	end
	for _, expected in ipairs({
		"status", "branch", "prs", "issues", "actions", "conflict",
		"conflict_resolver", "review_files", "review_diff", "rebase",
	}) do
		assert_true(names[expected], ("surface %q should be registered"):format(expected))
	end
end)

-- THE invariant. Read the failure message as: one of these two meanings has
-- to move to a different key, or the destructive one is not actually
-- destructive and its flag is wrong.
test("no key means both a destructive and a benign action", function()
	local offences = {}
	for key, meanings in pairs(meanings_by_key()) do
		local destructive, benign = nil, nil
		for _, meaning in ipairs(meanings) do
			if meaning.destructive then
				destructive = meaning
			else
				benign = meaning
			end
		end
		if destructive and benign then
			offences[#offences + 1] = ("%q is %s:%s (destructive) and %s:%s (benign)"):format(
				key, destructive.surface, destructive.desc, benign.surface, benign.desc
			)
		end
	end
	table.sort(offences)
	assert_equals(
		#offences, 0,
		"destructive/benign key collisions:\n    " .. table.concat(offences, "\n    ")
	)
end)

test("r is refresh in every surface that binds it", function()
	for _, meaning in ipairs(meanings_by_key()["r"] or {}) do
		assert_equals(
			meaning.desc, "refresh",
			("%s binds r to %q"):format(meaning.surface, meaning.desc)
		)
	end
end)

test("every panel surface binds ? to help", function()
	for _, surface in ipairs(surfaces) do
		-- The merge resolver is a modifiable editor pane, so `?` stays vim's
		-- reverse search there and the overlay is on the c-prefixed `c?`.
		local expected = surface.name == "conflict_resolver" and "c?" or "?"
		local found = false
		for _, entry in ipairs(surface.keymaps) do
			if entry.key == expected then
				found = true
				assert_equals(
					entry.desc, "help",
					("%s: %s should be the help key"):format(surface.name, expected)
				)
			end
		end
		assert_true(found, ("%s should bind %s"):format(surface.name, expected))
	end
end)

test("a destructive entry is never also essential", function()
	for _, surface in ipairs(surfaces) do
		for _, entry in ipairs(surface.keymaps) do
			assert_true(
				not (entry.essential and entry.destructive),
				("%s: %s is both essential and destructive"):format(surface.name, entry.key)
			)
		end
	end
end)

-- ── the ? overlay is generated, not written ───────────────────────────

---Open a panel's `?` overlay and return the help buffer's lines.
---@param modname string
---@param panel_name string
---@return string[]
local function help_lines_for(modname, panel_name)
	local mod = require("gitflow.panels." .. modname)
	mod.open(cfg)
	local surface = panel.surface(panel_name)
	for _, entry in ipairs(surface.keymaps) do
		if entry.key == "?" then
			entry.run("?")
		end
	end
	assert_true(help.is_open(), ("? should have opened a help buffer for %s"):format(panel_name))
	local lines = vim.api.nvim_buf_get_lines(help.state.bufnr, 0, -1, false)
	help.close()
	mod.close()
	return lines
end

test("the ? overlay lists exactly the panel's registry", function()
	for _, case in ipairs({
		{ "status", "status" }, { "branch", "branch" }, { "tag", "tag" },
	}) do
		local lines = help_lines_for(case[1], case[2])
		local body = table.concat(lines, "\n")
		local advertised = 0
		for _, entry in ipairs(panel.surface(case[2]).keymaps) do
			if entry.desc then
				advertised = advertised + 1
				local row = vim.pesc(entry.key) .. "%s+" .. vim.pesc(entry.desc)
				assert_true(
					body:find(row) ~= nil,
					("%s overlay should list %q %s"):format(case[2], entry.key, entry.desc)
				)
			end
		end
		assert_true(advertised > 0, "the fixture panel should advertise keys")

		-- And nothing the registry does not declare: every key row in the
		-- buffer has to resolve back to an entry, so the overlay cannot grow
		-- a hand-written line.
		local declared = {}
		for _, entry in ipairs(panel.surface(case[2]).keymaps) do
			if entry.desc then
				declared[entry.key .. "\0" .. entry.desc] = true
			end
		end
		for _, line in ipairs(lines) do
			-- Key column is padded then separated by at least two spaces; a
			-- key label can itself contain one ("V then s/u").
			local key, desc = line:match("^    (.-)%s%s+(%S.*)$")
			if key then
				assert_true(
					declared[key .. "\0" .. desc] == true,
					("%s overlay shows %q %q, which no registry entry declares")
						:format(case[2], key, desc)
				)
			end
		end
	end
end)

test(":Gitflow help opens the same buffer, not a notification", function()
	local commands = require("gitflow.commands")
	commands.dispatch({ "help" }, cfg)
	assert_true(help.is_open(), ":Gitflow help should open a help buffer")
	local body = table.concat(
		vim.api.nvim_buf_get_lines(help.state.bufnr, 0, -1, false), "\n"
	)
	assert_true(body:find(":GITFLOW", 1, true) ~= nil, "should list the subcommands")
	assert_true(body:find("status", 1, true) ~= nil, "should list the status subcommand")
	assert_true(
		body:find(cfg.keybindings.status, 1, true) ~= nil,
		"should list the global mappings the config installs"
	)
	help.close()
end)

-- ── panel_keybindings ─────────────────────────────────────────────────

test("panel_keybindings moves a key, hints included", function()
	local moved = gitflow.setup({
		panel_keybindings = { tag = { ["X"] = "<leader>tx" } },
	})
	local tag = require("gitflow.panels.tag")
	tag.open(moved)

	local bufnr = require("gitflow.ui.buffer").get("tag")
	local bound = {}
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		bound[map.lhs] = true
	end
	assert_true(bound["X"] == nil, "the default key should be free once remapped")

	local resolved = panel.resolve_keymaps(panel.surface("tag").keymaps, moved, "tag")
	local labels = {}
	for _, entry in ipairs(resolved) do
		labels[entry.key] = entry.desc
	end
	assert_equals(labels["<leader>tx"], "remote del", "the hint should follow the key")
	assert_true(labels["X"] == nil, "the old label should be gone")

	tag.close()
	gitflow.setup({})
end)

test("panel_keybindings false unbinds a key entirely", function()
	local without = gitflow.setup({
		panel_keybindings = { tag = { ["D"] = false } },
	})
	local tag = require("gitflow.panels.tag")
	tag.open(without)

	local bufnr = require("gitflow.ui.buffer").get("tag")
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		assert_true(map.lhs ~= "D", "an unbound key must not be mapped")
	end
	for _, entry in ipairs(panel.resolve_keymaps(panel.surface("tag").keymaps, without, "tag")) do
		assert_true(entry.key ~= "D", "an unbound key must not be advertised")
	end

	tag.close()
	gitflow.setup({})
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
