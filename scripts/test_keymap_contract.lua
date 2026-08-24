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
--   * `panel_keybindings` moves and unbinds keys, hints included, on EVERY
--     registered surface — including the three that are not `Panel`s;
--   * every key the migration table says can be put back, can be put back.

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

-- Load every key surface. Discovered across the whole tree by source, and
-- REGISTRATION is what is verified — see scripts/lib/key_surfaces.lua for the
-- escapes a `panels/*.lua` glob left open.
local key_surfaces = dofile(project_root .. "/scripts/lib/key_surfaces.lua")
local load_problems = key_surfaces.load(project_root)

local surfaces = panel.surfaces()

test("every module that binds keys registers a key surface", function()
	assert_equals(
		#load_problems, 0,
		"unregistered key surfaces:\n    " .. table.concat(load_problems, "\n    ")
	)
end)

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

-- Two surfaces are text-entry, not browsing: `?` there is a character the
-- user is typing or searching for, not a request for documentation. Both
-- carry their keys some other way — the resolver on `c?`, the palette in the
-- footers of its two panes.
local NO_HELP_KEY = { palette = true }

test("every panel surface binds ? to help", function()
	for _, surface in ipairs(surfaces) do
		-- The merge resolver is a modifiable editor pane, so `?` stays vim's
		-- reverse search there and the overlay is on the c-prefixed `c?`.
		local expected = surface.name == "conflict_resolver" and "c?" or "?"
		if NO_HELP_KEY[surface.name] then
			expected = nil
		end
		local found = expected == nil
		for _, entry in ipairs(surface.keymaps) do
			if expected and entry.key == expected then
				found = true
				assert_equals(
					entry.desc, "help",
					("%s: %s should be the help key"):format(surface.name, expected)
				)
			end
		end
		assert_true(
			found,
			("%s should bind %s"):format(surface.name, tostring(expected))
		)
	end
end)

-- ── what a surface REALLY bound ───────────────────────────────────────
-- Discovery is a source scan, and a source scan only decides who is ASKED to
-- register. This is the part that does not take the source's word for it:
-- open the surface and diff the keys on the real buffer against the keys its
-- registry declares. A key bound by an aliased or metatable-dispatched binder
-- shows up here as an undeclared key, whatever it spelled.

---Surfaces that can be brought up headlessly, and the buffers they bind on.
---@type table[]
local OPENABLE = {
	{ surface = "status" }, { surface = "branch" }, { surface = "log" },
	{ surface = "blame" }, { surface = "stash" }, { surface = "tag" },
	{ surface = "reflog" }, { surface = "reset" }, { surface = "revert" },
	{ surface = "cherry_pick" }, { surface = "rebase" }, { surface = "conflict" },
	{ surface = "worktree" }, { surface = "labels" }, { surface = "notifications" },
	{ surface = "diff" }, { surface = "prs" }, { surface = "issues" },
}

test("every openable surface binds exactly the keys its registry declares", function()
	local problems = {}
	vim.list_extend(problems, key_surfaces.watch_rebinds(function()
		for _, case in ipairs(OPENABLE) do
			local mod = require("gitflow.panels." .. case.surface)
			mod.open(cfg)
			local bufnr = require("gitflow.ui.buffer").get(case.surface)
			assert_true(bufnr ~= nil, ("%s should have opened"):format(case.surface))
			vim.list_extend(problems, key_surfaces.compare(
				case.surface, bufnr, panel.surface_keymaps(case.surface, cfg)
			))
			mod.close()
		end
	end))
	table.sort(problems)
	assert_equals(
		#problems, 0,
		"buffer/registry mismatches:\n    " .. table.concat(problems, "\n    ")
	)
end)

test("the actions panel binds exactly its current view's keys", function()
	local actions = require("gitflow.panels.actions")
	actions.open(cfg)
	local bufnr = actions.state.bufnr
	assert_true(bufnr ~= nil, "the actions panel should have opened")
	local problems = key_surfaces.compare(
		"actions", bufnr, panel.surface_keymaps("actions", cfg),
		{ view = actions.state.view }
	)
	actions.close()
	assert_equals(
		#problems, 0,
		"buffer/registry mismatches:\n    " .. table.concat(problems, "\n    ")
	)
end)

test("the palette's two panes bind exactly their own keys", function()
	local palette = require("gitflow.panels.palette")
	palette.open(cfg)
	local entries = panel.surface_keymaps("palette", cfg)
	local problems = {}
	for _, pane in ipairs({
		{ view = "prompt", bufnr = palette.state.prompt_bufnr },
		{ view = "list", bufnr = palette.state.list_bufnr },
	}) do
		assert_true(pane.bufnr ~= nil, ("the palette should have a %s pane"):format(pane.view))
		vim.list_extend(problems, key_surfaces.compare(
			"palette:" .. pane.view, pane.bufnr, entries, { view = pane.view }
		))
	end
	palette.close()
	table.sort(problems)
	assert_equals(
		#problems, 0,
		"buffer/registry mismatches:\n    " .. table.concat(problems, "\n    ")
	)
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


-- ── the migration promise, proved by pressing the key ─────────────────
-- KEYBINDINGS.md tells users every key this change moved can be put back
-- through `panel_keybindings`. These PRESS the restored key on the real panel
-- buffer and assert WHAT THE PRESS DID.
--
-- Pressing is the whole point. Re-keying moves the BINDING; until this round
-- it did not move the DISPATCH, so `rebase = { ["p/w/e/s/f"] = "p/r/e/s/f" }`
-- bound `r` and then wrote a nil action into the commit plan. A spec that
-- compares the hint label passes against exactly that, which is how the
-- flagship row shipped broken twice.

---Buffer-local normal-mode lhs set.
---@param bufnr integer
---@return table<string, boolean>
local function bound_keys(bufnr)
	local out = {}
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		out[map.lhs] = true
	end
	return out
end

---The desc a resolved surface advertises for a key, or nil.
---@param surface_name string
---@param cfg_used GitflowConfig
---@param key string
---@return string|nil
local function desc_for_key(surface_name, cfg_used, key)
	for _, entry in ipairs(panel.surface_keymaps(surface_name, cfg_used)) do
		for _, bound in ipairs(panel.bound_keys(entry)) do
			if bound == key then
				return entry.desc
			end
		end
	end
	return nil
end


---Press `key` in the current window and let its mapping run to completion.
---@param key string
local function press(key)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes(key, true, false, true), "x", false
	)
end

---Swap every entry of a surface's DEFAULT registry for a recorder, so a press
---reports which entry fired and which key it dispatched on. Must be installed
---BEFORE the surface binds: the resolved copy it binds is `vim.tbl_extend`ed
---from these entries, and copies the `run` value as it stands then.
---@param surface_name string
---@return table dispatches, fun() restore
local function recording(surface_name)
	local dispatches = {}
	local entries = panel.surface(surface_name).keymaps
	local originals = {}
	for index, entry in ipairs(entries) do
		originals[index] = entry.run
		entry.run = function(key)
			dispatches[#dispatches + 1] =
				{ label = entry.key, desc = entry.desc, key = key }
		end
	end
	return dispatches, function()
		for index, entry in ipairs(entries) do
			entry.run = originals[index]
		end
	end
end

---Open a panel with `overrides` applied, press `key` on its buffer, and
---return the single dispatch it produced.
---@param modname string
---@param surface_name string
---@param overrides table
---@param key string
---@return table  { label, desc, key }  the entry that ran and the key it meant
local function press_on_panel(modname, surface_name, overrides, key)
	local dispatches, restore = recording(surface_name)
	local mod = require("gitflow.panels." .. modname)
	local ok, err = pcall(function()
		mod.open(gitflow.setup({ panel_keybindings = overrides }))
		local bufnr = require("gitflow.ui.buffer").get(surface_name)
		assert_true(bufnr ~= nil, ("%s should have opened"):format(surface_name))
		assert_true(
			bound_keys(bufnr)[key],
			("%s should bind %q again"):format(surface_name, key)
		)
		press(key)
	end)
	restore()
	mod.close()
	gitflow.setup({})
	if not ok then
		error(err, 0)
	end
	assert_equals(
		#dispatches, 1,
		("pressing %q on %s should run exactly one entry"):format(key, surface_name)
	)
	return dispatches[1]
end

---@param dispatch table
---@param desc string  the verb the migration row promises is back
---@param means string  the DEFAULT key that verb dispatches on
---@param what string
local function assert_did(dispatch, desc, means, what)
	assert_equals(dispatch.desc, desc, what .. ": wrong verb ran")
	assert_equals(dispatch.key, means, what .. ": wrong action within the verb")
end

-- One row per line of KEYBINDINGS.md's "Panel keys" table that names a key a
-- user can put back. `press` is the old key; `desc`/`means` are what it has to
-- do again — `means` being the DEFAULT key whose behaviour must follow it.
local PANEL_ROWS = {
	{ row = "Branch List: r rename", mod = "branch", surface = "branch",
		overrides = { branch = { e = "r", r = "R" } },
		press = "r", desc = "rename", means = "e" },
	{ row = "Branch List: R refresh", mod = "branch", surface = "branch",
		overrides = { branch = { e = "r", r = "R" } },
		press = "R", desc = "refresh", means = "r" },
	{ row = "Conflict List: A abort", mod = "conflict", surface = "conflict",
		overrides = { conflict = { X = "A" } },
		press = "A", desc = "abort", means = "X" },
	{ row = "Reflog: R reset", mod = "reflog", surface = "reflog",
		overrides = { reflog = { H = "R" } },
		press = "R", desc = "reset", means = "H" },
	{ row = "Issue List: X clear filters", mod = "issues", surface = "issues",
		overrides = { issues = { F = "X" } },
		press = "X", desc = "clear filters", means = "F" },
	-- The flagship: `r` has to reword, and re-keying must not cost the other
	-- four actions their meanings.
	{ row = "Rebase editor: r reword", mod = "rebase", surface = "rebase",
		overrides = { rebase = { ["p/w/e/s/f"] = "p/r/e/s/f", r = "R" } },
		press = "r", desc = "action", means = "w" },
	{ row = "Rebase editor: p still picks", mod = "rebase", surface = "rebase",
		overrides = { rebase = { ["p/w/e/s/f"] = "p/r/e/s/f", r = "R" } },
		press = "p", desc = "action", means = "p" },
	{ row = "Rebase editor: e still edits", mod = "rebase", surface = "rebase",
		overrides = { rebase = { ["p/w/e/s/f"] = "p/r/e/s/f", r = "R" } },
		press = "e", desc = "action", means = "e" },
	{ row = "Rebase editor: s still squashes", mod = "rebase", surface = "rebase",
		overrides = { rebase = { ["p/w/e/s/f"] = "p/r/e/s/f", r = "R" } },
		press = "s", desc = "action", means = "s" },
	{ row = "Rebase editor: f still fixups", mod = "rebase", surface = "rebase",
		overrides = { rebase = { ["p/w/e/s/f"] = "p/r/e/s/f", r = "R" } },
		press = "f", desc = "action", means = "f" },
	{ row = "Rebase editor: refresh moved to R", mod = "rebase", surface = "rebase",
		overrides = { rebase = { ["p/w/e/s/f"] = "p/r/e/s/f", r = "R" } },
		press = "R", desc = "refresh", means = "r" },
	-- Not migration rows, but the same defect: a `/` re-key on any multi-key
	-- entry used to make every one of its keys mean the first key's action.
	{ row = "status s/u re-keyed: S stages", mod = "status", surface = "status",
		overrides = { status = { ["s/u"] = "S/U" } },
		press = "S", desc = "stage/unstage", means = "s" },
	{ row = "status s/u re-keyed: U unstages", mod = "status", surface = "status",
		overrides = { status = { ["s/u"] = "S/U" } },
		press = "U", desc = "stage/unstage", means = "u" },
	{ row = "worktree d/D re-keyed: x removes", mod = "worktree", surface = "worktree",
		overrides = { worktree = { ["d/D"] = "x/X" } },
		press = "x", desc = "remove", means = "d" },
	{ row = "worktree d/D re-keyed: X force-removes", mod = "worktree", surface = "worktree",
		overrides = { worktree = { ["d/D"] = "x/X" } },
		press = "X", desc = "remove", means = "D" },
}

for _, case in ipairs(PANEL_ROWS) do
	test(("pressing the restored key does the verb — %s"):format(case.row), function()
		assert_did(
			press_on_panel(case.mod, case.surface, case.overrides, case.press),
			case.desc, case.means, case.row
		)
	end)
end

test("the rebase editor's restored r writes reword, not nil, into the plan", function()
	-- The observed effect the label comparison could not see: the todo entry
	-- the plan carries. `set_action(nil)` used to render `● nil abc1234 …`.
	local restored = gitflow.setup({
		panel_keybindings = {
			rebase = { ["p/w/e/s/f"] = "p/r/e/s/f", ["r"] = "R" },
		},
	})
	local rebase = require("gitflow.panels.rebase")
	rebase.open(restored)
	rebase.state.current_branch = "feature"
	rebase.state.base_ref = "main"
	rebase.state.stage = "normal"
	rebase.state.entries = {
		{ sha = "abc1234", subject = "a commit", action = "pick" },
	}
	rebase.switch_to_interactive()

	-- Reword prompts for the new message; decline it, so the only thing this
	-- asserts is the action the keypress set.
	local ui_input = require("gitflow.ui.input")
	local real_input = ui_input.prompt
	ui_input.prompt = function() end

	local line
	for candidate, entry in pairs(rebase.state.line_entries) do
		if entry == rebase.state.entries[1] and (not line or candidate < line) then
			line = candidate
		end
	end
	local ok, err = pcall(function()
		assert_true(line ~= nil, "the todo view should have a commit row")
		vim.api.nvim_win_set_cursor(0, { line, 0 })
		press("r")
	end)

	ui_input.prompt = real_input
	local action = rebase.state.entries[1] and rebase.state.entries[1].action
	rebase.close()
	gitflow.setup({})
	if not ok then
		error(err, 0)
	end
	assert_equals(action, "reword", "pressing the restored r should reword")
end)

test("the merge resolver's cx reset can be put back, pressed", function()
	local restored = gitflow.setup({
		panel_keybindings = { conflict_resolver = { cD = "cx" } },
	})
	local conflict = require("gitflow.ui.conflict")
	local path = vim.fn.tempname()
	vim.fn.writefile({
		"a", "<<<<<<< HEAD", "mine", "=======", "theirs", ">>>>>>> other", "b",
	}, path)

	local dispatches, restore = recording("conflict_resolver")
	local ok, err = pcall(function()
		conflict.open(path, { cfg = restored })
		local bufnr = conflict.state.merged_bufnr
		assert_true(bufnr ~= nil, "the resolver should have opened a merged buffer")
		local bound = bound_keys(bufnr)
		assert_true(bound["cx"], "cx should be bound again on the resolver buffer")
		assert_true(bound["cD"] == nil, "the new key should be free once remapped")
		vim.api.nvim_set_current_buf(bufnr)
		press("cx")
	end)
	restore()
	conflict.close()
	vim.fn.delete(path)
	gitflow.setup({})
	if not ok then
		error(err, 0)
	end
	assert_equals(#dispatches, 1, "cx should run exactly one entry")
	assert_did(dispatches[1], "reset", "cD", "Merge Resolver: cx reset")
end)

test("the review file list's dd delete-draft can be put back, pressed", function()
	-- Review mode needs a PR; the pane is the same `Panel` either way, so
	-- this attaches it to a scratch buffer exactly as `panels/review.lua` does.
	local restored = gitflow.setup({
		panel_keybindings = { review_files = { x = "dd" } },
	})
	local file_list = require("gitflow.review.file_list")
	local bufnr = vim.api.nvim_create_buf(false, true)
	local winid = vim.api.nvim_get_current_win()
	local previous = vim.api.nvim_win_get_buf(winid)
	vim.api.nvim_win_set_buf(winid, bufnr)

	local dispatches, restore = recording("review_files")
	local ok, err = pcall(function()
		file_list.attach(bufnr, winid, restored)
		assert_true(
			bound_keys(bufnr)["dd"],
			"dd should be bound again on the review file list"
		)
		press("dd")
	end)
	restore()
	file_list.detach()
	pcall(vim.api.nvim_win_set_buf, winid, previous)
	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	gitflow.setup({})
	if not ok then
		error(err, 0)
	end
	assert_equals(#dispatches, 1, "dd should run exactly one entry")
	assert_did(dispatches[1], "delete", "x", "PR Review file list: dd delete draft")
end)

test("? goes back to reverse search when the row says so", function()
	local without = gitflow.setup({ panel_keybindings = { status = { ["?"] = false } } })
	local status = require("gitflow.panels.status")
	status.open(without)
	local bufnr = require("gitflow.ui.buffer").get("status")
	assert_true(
		bound_keys(bufnr)["?"] == nil,
		"? must be unbound, or vim's reverse search never comes back"
	)
	status.close()
	gitflow.setup({})
end)

-- ── the global migration rows ─────────────────────────────────────────
-- The other ten rows are ordinary global mappings. Pressing them has to reach
-- the subcommand the table names, so the old key does the old thing.

test("every global row's old key runs its old action when put back", function()
	local commands = require("gitflow.commands")
	local rows = {
		{ action = "refresh", old = "gr", subcommand = "refresh" },
		{ action = "status", old = "gs", subcommand = "status" },
		{ action = "commit", old = "gc", subcommand = "commit" },
		{ action = "diff", old = "gD", subcommand = "diff" },
		{ action = "palette", old = "gP", subcommand = "palette" },
		{ action = "revert", old = "gV", subcommand = "revert" },
		{ action = "tag", old = "gT", subcommand = "tag" },
		{ action = "reflog", old = "gF", subcommand = "reflog" },
		{ action = "rebase_interactive", old = "gI", subcommand = "rebase-interactive" },
		{ action = "notifications", old = "gN", subcommand = "notifications" },
	}
	local real_dispatch = commands.dispatch
	local seen
	commands.dispatch = function(args)
		seen = args[1]
	end
	local ok, err = pcall(function()
		for _, row in ipairs(rows) do
			gitflow.setup({ keybindings = { [row.action] = row.old } })
			seen = nil
			press(row.old)
			assert_equals(
				seen, row.subcommand,
				("%s put back on %q should run :Gitflow %s"):format(
					row.action, row.old, row.subcommand
				)
			)
		end
	end)
	commands.dispatch = real_dispatch
	gitflow.setup({})
	if not ok then
		error(err, 0)
	end
end)


test("an override that would shadow an existing key is refused, loudly", function()
	local warnings = {}
	local utils = require("gitflow.utils")
	local real_notify = utils.notify
	utils.notify = function(message)
		warnings[#warnings + 1] = message
	end

	-- tag already binds D (delete); moving push onto it would silently drop
	-- the destructive verb while the hints still advertised both.
	local shadowed = gitflow.setup({ panel_keybindings = { tag = { P = "D" } } })
	local tag = require("gitflow.panels.tag")
	tag.open(shadowed)

	local bound = bound_keys(require("gitflow.ui.buffer").get("tag"))
	assert_true(bound["P"], "the refused override must leave P where it was")
	assert_equals(
		desc_for_key("tag", shadowed, "D"), "delete",
		"D must still be the destructive verb it was"
	)

	local reported = false
	for _, message in ipairs(warnings) do
		if message:find("panel_keybindings.tag ignored", 1, true) then
			reported = true
		end
	end
	assert_true(
		reported,
		"a refused override must say so: " .. vim.inspect(warnings)
	)

	utils.notify = real_notify
	tag.close()
	gitflow.setup({})
end)

test("a replacement naming more keys than the entry binds is refused", function()
	-- Without this the extra key binds with no meaning behind it: `run` gets
	-- a key its action table has no entry for.
	local warnings = {}
	local utils = require("gitflow.utils")
	local real_notify = utils.notify
	utils.notify = function(message)
		warnings[#warnings + 1] = message
	end

	local overreach = gitflow.setup({
		panel_keybindings = { worktree = { ["d/D"] = "x/X/Y" } },
	})
	local worktree = require("gitflow.panels.worktree")
	worktree.open(overreach)
	local bound = bound_keys(require("gitflow.ui.buffer").get("worktree"))

	local reported = false
	for _, message in ipairs(warnings) do
		if message:find("names 3 keys but d/D binds 2", 1, true) then
			reported = true
		end
	end

	utils.notify = real_notify
	worktree.close()
	gitflow.setup({})

	assert_true(bound["d"] and bound["D"], "the refused override must leave d/D alone")
	assert_true(bound["Y"] == nil, "a key with no meaning must not be bound")
	assert_true(reported, "the refusal must say so: " .. vim.inspect(warnings))
end)

test("panel_keybindings reaches the actions panel and the review diff pane", function()
	local moved = gitflow.setup({
		panel_keybindings = {
			actions = { W = "<leader>aw" },
			review_diff = { s = "<leader>rs" },
		},
	})
	assert_equals(
		desc_for_key("actions", moved, "<leader>aw"), "workflows",
		"the actions panel should resolve its overrides"
	)
	assert_true(
		desc_for_key("actions", moved, "W") == nil,
		"the actions panel's default key should be free once remapped"
	)
	assert_equals(
		desc_for_key("review_diff", moved, "<leader>rs"), "suggest",
		"the review diff pane should resolve its overrides"
	)
	gitflow.setup({})
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
