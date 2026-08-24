-- scripts/test_panel_base.lua — the panel-base contract, over every panel
-- that adopts ui/panel.lua.
--
-- One lifecycle means one set of guarantees, so they are asserted once here
-- for all of them rather than per panel:
--   * open -> refresh -> close leaves no buffer, window or registry entry;
--   * a callback from a superseded request is dropped, never painted;
--   * the split hint bar advertises exactly the keys the panel bound, and the
--     float footer advertises the same set (elided to fit: essentials kept,
--     destructive verbs dropped first);
--   * at the shipped default split width the bar still names what the panel
--     is FOR, not just how to leave it;
--   * open_float returning nil (terminal too small) leaves nothing half-open.

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

local gitflow = require("gitflow")
local panel = require("gitflow.ui.panel")
local ui_buffer = require("gitflow.ui.buffer")
local ui_window = require("gitflow.ui.window")
local render = require("gitflow.ui.render")
local utils = require("gitflow.utils")

-- Every panel that routes through the base, with the module-local `P` its
-- lifecycle lives on. The panel modules keep `P` private (it is not API), so
-- the harness reads it off the module's upvalues.
local PANEL_NAMES = {
	"status", "log", "branch", "blame", "stash", "tag", "reflog", "reset",
	"revert", "cherry_pick", "rebase", "conflict", "worktree", "labels",
	"notifications", "prs", "issues",
}

---Find the panel object a module built, by walking the upvalues of one of its
---functions. Keeps `P` out of the public module table.
---@param modname string
---@return table panel_object
local function panel_object(modname)
	local mod = require(modname)
	for _, fn in pairs(mod) do
		if type(fn) == "function" then
			local index = 1
			while true do
				local name, value = debug.getupvalue(fn, index)
				if not name then
					break
				end
				if name == "P" and type(value) == "table" and value.ns then
					return value
				end
				index = index + 1
			end
		end
	end
	error(("could not find the panel object of %s"):format(modname))
end

gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 40 },
	},
})
local cfg = require("gitflow.config").current

-- ── the registry is the single source of the hint chrome ──────────────

for _, name in ipairs(PANEL_NAMES) do
	local modname = "gitflow.panels." .. name
	local P = panel_object(modname)

	test(("%s: every advertised key is actually bound"):format(name), function()
		local advertised = {}
		for _, entry in ipairs(P.keymaps) do
			if entry.desc then
				advertised[entry.key] = entry
			end
		end
		assert_true(next(advertised) ~= nil, "panel should advertise some keys")

		local bound = {}
		for _, entry in ipairs(P.keymaps) do
			if entry.bind ~= false then
				for _, key in ipairs(panel.bound_keys(entry)) do
					bound[key] = true
				end
			end
		end
		for key, entry in pairs(advertised) do
			for _, real_key in ipairs(panel.bound_keys(entry)) do
				assert_true(
					bound[real_key],
					("%s advertises %s but never binds %s"):format(name, key, real_key)
				)
			end
		end
	end)

	test(("%s: the float footer carries the same keys as the hint bar"):format(name), function()
		local views = { nil }
		for _, entry in ipairs(P.keymaps) do
			for _, view in ipairs(entry.views or {}) do
				views[#views + 1] = view
			end
		end
		for _, view in ipairs(views) do
			local hints = P:hints(view)
			if #hints > 0 then
				-- Unbounded width: nothing elided, so the two must agree exactly.
				local footer = P:footer(view, nil)
				for _, hint in ipairs(hints) do
					assert_true(
						footer:find(hint[1] .. " " .. hint[2], 1, true) ~= nil,
						("%s footer is missing the %q hint"):format(name, hint[1])
					)
				end
			end
		end
	end)

	test(("%s: an overflowing footer elides but keeps essentials"):format(name), function()
		local hints = P:hints()
		if #hints == 0 then
			return
		end
		-- A tight-but-real float: 0.8 of an 80-column terminal, less the border.
		local width = 40
		local narrow = P:footer(nil, width)

		-- Essentials are never dropped, so the floor is the essentials-only
		-- footer; anything above that must have been elided away.
		local essential_only = {}
		for _, hint in ipairs(hints) do
			if hint.essential then
				essential_only[#essential_only + 1] = hint[1] .. " " .. hint[2]
			end
		end
		local floor_width = vim.fn.strdisplaywidth(
			" " .. table.concat(essential_only, " \u{b7} ") .. " "
		)
		assert_true(
			vim.fn.strdisplaywidth(narrow) <= width
				or #hints == 1
				or floor_width > width,
			("%s footer should fit the float it goes into"):format(name)
		)
		for _, hint in ipairs(hints) do
			if hint.essential then
				assert_true(
					narrow:find(hint[1] .. " " .. hint[2], 1, true) ~= nil,
					("%s dropped the essential key %q when eliding"):format(
						name, hint[1]
					)
				)
			end
			-- A cramped surface must not end up advertising mainly the key
			-- you least want fat-fingered.
			if hint.destructive and vim.fn.strdisplaywidth(narrow) > width then
				assert_true(
					narrow:find(hint[1] .. " " .. hint[2], 1, true) == nil,
					("%s kept the destructive key %q on an overflowing footer")
						:format(name, hint[1])
				)
			end
		end
	end)
end

-- ── the split bar at the width a split user actually gets ─────────────
-- The chrome this change exists to unify is read at `ui.split.size`, not at
-- an unlimited width. At that default the bar must fit, must still name the
-- panel's primary verbs, and must not have been reduced to its destructive
-- one plus the exit.

local default_split_size = require("gitflow.config").defaults().ui.split.size
local cfg_default_split = vim.tbl_deep_extend("force", vim.deepcopy(cfg), {
	ui = { split = { size = default_split_size } },
})

---@type { name: string, view: string|nil, keep: string[], drop: string[] }[]
local DEFAULT_SPLIT_BARS = {
	{
		name = "status",
		keep = { "s/u stage/unstage", "cc commit", "q close" },
		drop = { "X discard changes" },
	},
	{
		name = "worktree",
		keep = { "<CR> switch", "a add", "q close" },
		drop = { "d/D remove" },
	},
	{
		name = "branch",
		view = "list",
		keep = { "<CR> switch", "c create", "q close" },
		drop = { "D force delete" },
	},
}

for _, case in ipairs(DEFAULT_SPLIT_BARS) do
	test(("%s: the default-width split bar keeps the primary verbs"):format(
		case.name
	), function()
		local P = panel_object("gitflow.panels." .. case.name)
		assert_true(
			P:ensure_window(cfg_default_split),
			("%s should open in a split"):format(case.name)
		)
		local ok, err = pcall(function()
			assert_equals(
				P:split_width(), default_split_size,
				"the split should be the shipped default width"
			)
			local B = P:begin_render()
			P:push_hints(B, case.view)
			assert_true(P:paint(B), ("%s should paint"):format(case.name))

			local bar
			for _, line in ipairs(
				vim.api.nvim_buf_get_lines(P.state.bufnr, 0, -1, false)
			) do
				if line:find("q close", 1, true) then
					bar = line
				end
			end
			assert_true(bar ~= nil, ("%s should render a hint bar"):format(case.name))
			assert_true(
				vim.fn.strdisplaywidth(bar) <= default_split_size,
				("%s hint bar overflows its split (%d > %d): %q"):format(
					case.name, vim.fn.strdisplaywidth(bar),
					default_split_size, bar
				)
			)
			for _, hint in ipairs(case.keep) do
				assert_true(
					bar:find(hint, 1, true) ~= nil,
					("%s dropped %q from its default-width bar: %q"):format(
						case.name, hint, bar
					)
				)
			end
			for _, hint in ipairs(case.drop) do
				assert_true(
					bar:find(hint, 1, true) == nil,
					("%s kept the destructive %q on its default-width bar: %q")
						:format(case.name, hint, bar)
				)
			end
		end)
		P:close()
		assert_true(ok, tostring(err))
	end)
end

-- ── lifecycle: open, refresh, close ───────────────────────────────────
-- The GitHub-backed panels (labels) and the picker-first panels (cherry_pick,
-- rebase) open a picker or a network call rather than painting immediately,
-- so the lifecycle assertions run over the panels that paint from local git.

local LIFECYCLE_PANELS = {
	"status", "log", "branch", "blame", "stash", "tag", "reflog", "reset",
	"revert", "conflict", "worktree", "notifications",
}

for _, name in ipairs(LIFECYCLE_PANELS) do
	local modname = "gitflow.panels." .. name

	test(("%s: open then close leaves nothing behind"):format(name), function()
		local mod = require(modname)
		local P = panel_object(modname)

		mod.open(cfg, {})
		assert_true(P:is_open(), "panel buffer should exist after open")
		assert_true(
			ui_buffer.get(name) ~= nil,
			"panel buffer should be registered under its name"
		)

		mod.refresh()
		vim.wait(200, function()
			return false
		end)

		mod.close()
		assert_true(not P:is_open(), "panel buffer should be gone after close")
		assert_equals(P.state.winid, nil, "panel window should be cleared")
		assert_equals(
			ui_window.get(name), nil, "window registry should be empty after close"
		)
		assert_equals(
			ui_buffer.get(name), nil, "buffer registry should be empty after close"
		)
	end)
end

-- ── stale requests: drive each panel's own async path ─────────────────
-- Asserting on P:next_request()/P:is_active() alone proves the base's counter
-- works, not that a panel consults it: every guard could be deleted and such
-- a test would still pass. So each panel below is driven through its real
-- refresh chain with its git lister stubbed, and the superseded callback is
-- released by hand.
--
-- The callback is delivered as a failure, which is the one shape every panel
-- handles identically (notify + render_error) — so an unguarded panel paints
-- a marker we can see. The live callback is released the same way right
-- after, and its marker MUST appear: that is what keeps the stale assertion
-- from passing vacuously.

---A `prepare` for the picker-first panels: their `open` starts a branch
---picker that is not the chain under test, so drop its result rather than let
---it paint mid-assertion.
---@return fun()  teardown
local function drop_branch_picker()
	local git_branch = require("gitflow.git.branch")
	local real_list = git_branch.list
	git_branch.list = function() end
	return function()
		git_branch.list = real_list
	end
end

---@class GitflowStaleGuardCase
---@field name string  panel module name
---@field label string|nil  which guard, when a panel has more than one case
---@field module string  git module whose lister the refresh chain calls
---@field fn string  the lister; its last argument is the callback
---@field before integer|nil  earlier calls to answer before holding one, so a
---                          case can reach a guard deeper down the chain
---@field answer fun(cb: function)|nil  how those earlier calls are answered
---@field prepare fun(mod: table): (fun()|nil)  run before `open`; may return a teardown
---@field arm fun(mod: table)|nil  put the panel in the stage whose refresh
---                               reaches the lister (`open` starts a picker)

---@type GitflowStaleGuardCase[]
local STALE_GUARD_PANELS = {
	{ name = "status", label = "the fetch guard",
		module = "gitflow.git.status", fn = "fetch" },
	{
		-- status's decisive guard is the last one, not the first: the chain
		-- runs branch -> status -> upstream -> outgoing log -> incoming log,
		-- and only the innermost callback stands between a superseded chain
		-- and a full repaint. Answer the outgoing log, hold the incoming one.
		name = "status",
		label = "the paint-adjacent guard",
		module = "gitflow.git.log",
		fn = "list",
		before = 1,
		answer = function(cb)
			cb(nil, {})
		end,
		prepare = function()
			-- The chain only reaches the logs when HEAD has an upstream, and
			-- the checkout under test may not: answer rev-parse ourselves.
			local git = require("gitflow.git")
			local real_git = git.git
			git.git = function(args, opts, cb)
				if args and args[1] == "rev-parse" then
					cb({ code = 0, stdout = "origin/main\n", stderr = "" })
					return
				end
				return real_git(args, opts, cb)
			end
			return function()
				git.git = real_git
			end
		end,
	},
	{ name = "log", module = "gitflow.git.log", fn = "list" },
	{ name = "branch", module = "gitflow.git.branch", fn = "list" },
	{ name = "stash", module = "gitflow.git.stash", fn = "list" },
	{ name = "tag", module = "gitflow.git.tag", fn = "list" },
	{ name = "reflog", module = "gitflow.git.reflog", fn = "list" },
	{ name = "reset", module = "gitflow.git.reset", fn = "list_commits" },
	{ name = "revert", module = "gitflow.git.revert", fn = "list_commits" },
	{ name = "conflict", module = "gitflow.git.conflict", fn = "list" },
	{ name = "worktree", module = "gitflow.git.worktree", fn = "list" },
	{ name = "labels", module = "gitflow.gh.labels", fn = "list" },
	{ name = "prs", module = "gitflow.gh.prs", fn = "list" },
	{ name = "issues", module = "gitflow.gh.issues", fn = "list" },
	{
		name = "blame",
		module = "gitflow.git.blame",
		fn = "run",
		prepare = function(mod)
			mod.state.filepath = project_root .. "/README.md"
		end,
	},
	{
		name = "cherry_pick",
		module = "gitflow.git.cherry_pick",
		fn = "list_unique_commits",
		prepare = drop_branch_picker,
		arm = function(mod)
			mod.state.source_branch = "HEAD"
			mod.state.stage = "commits"
		end,
	},
	{
		name = "rebase",
		module = "gitflow.git.rebase",
		fn = "list_commits",
		prepare = drop_branch_picker,
		arm = function(mod)
			mod.state.base_ref = "HEAD"
			mod.state.stage = "normal"
		end,
	},
}

test("every guard-carrying panel has a stale-guard case", function()
	local covered = {}
	for _, case in ipairs(STALE_GUARD_PANELS) do
		covered[case.name] = true
	end
	for _, name in ipairs(PANEL_NAMES) do
		-- notifications reads memory synchronously: nothing to supersede.
		if name ~= "notifications" then
			assert_true(
				covered[name],
				("%s consults the stale guard but no case drives it"):format(name)
			)
		end
	end
end)

---@param P table
---@return string
local function buffer_text(P)
	local bufnr = P.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

for _, case in ipairs(STALE_GUARD_PANELS) do
	local title = ("%s: a superseded callback never paints%s"):format(
		case.name, case.label and (" (" .. case.label .. ")") or ""
	)
	test(title, function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local P = panel_object(modname)
		local git_mod = require(case.module)

		local held = {}
		local real_lister = git_mod[case.fn]
		local real_notify = utils.notify
		local notified = {}
		-- Calls the case wants answered rather than held, counted per chain
		-- so a deeper guard can be reached without racing the previous one.
		local answered = 0
		git_mod[case.fn] = function(...)
			local cb = (select(select("#", ...), ...))
			if answered < (case.before or 0) then
				answered = answered + 1
				case.answer(cb)
				return
			end
			held[#held + 1] = cb
		end
		utils.notify = function(message)
			notified[#notified + 1] = tostring(message)
		end

		---Run one refresh chain to its (stubbed) lister and return the
		---callback it held. Awaited one at a time so the order of `held` is
		---the order the refreshes were issued.
		---@return function
		local function refresh_and_hold()
			local before_count = #held
			answered = 0
			mod.refresh()
			assert_true(
				vim.wait(5000, function()
					return #held > before_count
				end, 10),
				("%s never reached %s.%s"):format(case.name, case.module, case.fn)
			)
			return held[#held]
		end

		local teardown_prepare
		local ok, err = pcall(function()
			if case.prepare then
				teardown_prepare = case.prepare(mod)
			end
			mod.open(cfg, {})
			if case.arm then
				case.arm(mod)
			else
				assert_true(
					vim.wait(5000, function()
						return #held >= 1
					end, 10),
					("%s never reached %s.%s on open"):format(
						case.name, case.module, case.fn
					)
				)
			end

			local stale_cb = refresh_and_hold()
			local live_cb = refresh_and_hold()

			local stale_marker = ("STALE-%s-marker"):format(case.name)
			local live_marker = ("LIVE-%s-marker"):format(case.name)
			local before = buffer_text(P)

			stale_cb(stale_marker)
			assert_equals(
				buffer_text(P), before,
				("%s repainted from a superseded callback"):format(case.name)
			)
			assert_true(
				not table.concat(notified, "\n"):find(stale_marker, 1, true),
				("%s reported a superseded failure to the user"):format(case.name)
			)

			live_cb(live_marker)
			assert_true(
				buffer_text(P):find(live_marker, 1, true) ~= nil,
				("%s never paints the live failure — the stale assertion above"
					.. " proves nothing"):format(case.name)
			)
			assert_true(
				not buffer_text(P):find(stale_marker, 1, true),
				("%s leaked the superseded failure into the buffer"):format(
					case.name
				)
			)
		end)

		git_mod[case.fn] = real_lister
		utils.notify = real_notify
		if teardown_prepare then
			teardown_prepare()
		end
		mod.close()
		assert_true(ok, tostring(err))
	end)
end

test("closing the window with :q invalidates the refresh chain", function()
	local mod = require("gitflow.panels.tag")
	local P = panel_object("gitflow.panels.tag")

	mod.open(cfg)
	local in_flight = P:next_request()
	assert_true(P:is_active(in_flight), "the panel should be live once open")

	-- `:q` closes the window and leaves the buffer; without the generation
	-- bump the whole refresh chain keeps running and painting into it.
	vim.api.nvim_win_close(P.state.winid, true)
	assert_true(
		not P:is_active(in_flight),
		"closing the window must invalidate in-flight requests"
	)
	-- The generation bump only reaches requests already in flight. Every git
	-- operation in the plugin refreshes the open panels, so a chain STARTED
	-- after `:q` must be dropped too — it would paint a buffer nobody can see,
	-- at the terminal's width rather than the split's.
	assert_true(
		not P:is_active(P:next_request()),
		"a request started after :q must not be live either"
	)
	mod.close()
end)

-- ── a state render drops the line→entry map ──────────────────────────
-- A loading or error render collapses the buffer. The map built for the
-- previous, longer content must not survive it: line 8 of a 57-line log is a
-- commit, line 8 of the 8-line error state is the hint bar — and on status
-- the same map is what `X discard changes` and `p push` act on.

local MAPPED_PANELS = {
	"status", "log", "branch", "blame", "stash", "tag", "reflog", "reset",
	"revert", "conflict", "worktree",
}

for _, name in ipairs(MAPPED_PANELS) do
	test(("%s: a state render invalidates the line→entry map"):format(name), function()
		local modname = "gitflow.panels." .. name
		local mod = require(modname)
		local P = panel_object(modname)

		mod.open(cfg, {})
		P.state.line_entries = { [1] = { sentinel = true } }
		P:render_loading("Reloading…")
		assert_equals(
			next(P.state.line_entries), nil,
			("%s kept its line→entry map across the loading state"):format(name)
		)

		P.state.line_entries = { [1] = { sentinel = true } }
		P:render_error("Boom", { hint = "r retries" })
		assert_equals(
			next(P.state.line_entries), nil,
			("%s kept its line→entry map across the error state"):format(name)
		)
		mod.close()
	end)
end

test("reopening the base picker drops the rows the last one left", function()
	-- `b` flips rebase into the base stage synchronously while the new rows
	-- load async, so <CR> on a commit row of the still-visible todo view used
	-- to select whatever branch last occupied that line.
	local mod = require("gitflow.panels.rebase")
	local P = panel_object("gitflow.panels.rebase")
	local git_branch = require("gitflow.git.branch")

	local real_list, real_notify = git_branch.list, utils.notify
	local notified = {}
	git_branch.list = function() end
	utils.notify = function(message)
		notified[#notified + 1] = tostring(message)
	end

	mod.open(cfg)
	local ok, err = pcall(function()
		mod.state.base_ref = nil
		mod.state.base_line_branches = { [1] = { name = "stale-branch" } }

		mod.show_base_picker()

		vim.api.nvim_set_current_win(P.state.winid)
		vim.api.nvim_win_set_cursor(P.state.winid, { 1, 0 })
		mod.select_base_branch()

		assert_equals(
			mod.state.base_ref, nil,
			"<CR> picked a base from the previous picker's rows"
		)
		assert_true(
			table.concat(notified, "\n"):find("Move cursor to a branch", 1, true)
				~= nil,
			"<CR> over an unloaded picker should say there is no branch there"
		)
	end)
	git_branch.list, utils.notify = real_list, real_notify
	mod.close()
	assert_true(ok, tostring(err))
end)

test("a second entry map is invalidated too once its panel declares it", function()
	-- rebase keeps the base picker's rows outside `line_entries`; the base
	-- clears whatever the panel registered, so it cannot be forgotten.
	local P = panel_object("gitflow.panels.rebase")

	assert_true(P:ensure_window(cfg), "rebase should open in a split")
	local ok, err = pcall(function()
		P.state.base_line_branches = { [1] = { name = "stale-branch" } }
		P:render_error("Boom", { hint = "b picks another base" })
		assert_equals(
			next(P.state.base_line_branches), nil,
			"rebase kept the base picker's rows across the error state"
		)
	end)
	P:close()
	assert_true(ok, tostring(err))
end)

test("a destructive key resolves to nothing once status drops to its error state", function()
	local mod = require("gitflow.panels.status")
	local P = panel_object("gitflow.panels.status")
	local ui = require("gitflow.ui")
	local git_status = require("gitflow.git.status")

	local real_confirm, real_revert = ui.input.confirm, git_status.revert_file
	local real_notify = utils.notify
	local confirmed, reverted, notified = {}, {}, {}
	ui.input.confirm = function(message)
		confirmed[#confirmed + 1] = tostring(message)
		return true
	end
	git_status.revert_file = function(path)
		reverted[#reverted + 1] = tostring(path)
	end
	utils.notify = function(message)
		notified[#notified + 1] = tostring(message)
	end

	local ok, err = pcall(function()
		mod.open(cfg, {})
		vim.wait(2000, function()
			return vim.api.nvim_buf_line_count(P.state.bufnr) > 3
		end, 10)

		-- Every line of the rendered list mapped to a file, as a full render
		-- leaves it. Seeded rather than harvested so the case does not need
		-- the test repo to have a dirty worktree.
		local seeded = {}
		for line = 1, vim.api.nvim_buf_line_count(P.state.bufnr) do
			seeded[line] = {
				kind = "file",
				entry = { path = "seeded-under-cursor.txt", untracked = false },
				diff_staged = false,
			}
		end
		P.state.line_entries = seeded

		P:render_error("Could not read repository status", { hint = "r retries" })

		local discard
		for _, entry in ipairs(P.keymaps) do
			if entry.key == "X" then
				discard = entry
			end
		end
		assert_true(discard ~= nil, "status should still bind X")

		vim.api.nvim_set_current_win(P.state.winid)
		local last_line = vim.api.nvim_buf_line_count(P.state.bufnr)
		assert_true(
			seeded[last_line] ~= nil,
			"the line the cursor lands on must have been mapped before the error"
		)
		vim.api.nvim_win_set_cursor(P.state.winid, { last_line, 0 })
		discard.run("X")

		assert_equals(#confirmed, 0, "X must not offer to discard a stale entry")
		assert_equals(#reverted, 0, "X must not revert a stale entry")
		assert_true(
			table.concat(notified, "\n"):find("No file selected", 1, true) ~= nil,
			"X on an error state should say there is no file selected"
		)
	end)

	ui.input.confirm, git_status.revert_file = real_confirm, real_revert
	utils.notify = real_notify
	mod.close()
	assert_true(ok, tostring(err))
end)

-- ── loading / empty / error states go through components ──────────────

test("render_loading and render_error paint into the panel buffer", function()
	local mod = require("gitflow.panels.tag")
	local P = panel_object("gitflow.panels.tag")

	mod.open(cfg)
	P:render_loading("Loading tags…")
	local lines = vim.api.nvim_buf_get_lines(P.state.bufnr, 0, -1, false)
	local found_loading = false
	for _, line in ipairs(lines) do
		if line:find("Loading tags", 1, true) then
			found_loading = true
		end
	end
	assert_true(found_loading, "loading state should be visible in the buffer")

	P:render_error("Boom", { detail = "the detail", hint = "r retries" })
	lines = vim.api.nvim_buf_get_lines(P.state.bufnr, 0, -1, false)
	local found_error, found_detail = false, false
	for _, line in ipairs(lines) do
		if line:find("Boom", 1, true) then
			found_error = true
		end
		if line:find("the detail", 1, true) then
			found_detail = true
		end
	end
	assert_true(found_error, "error message should be visible in the buffer")
	assert_true(found_detail, "error detail should be visible in the buffer")
	mod.close()
end)

-- ── small terminal: open_float returns nil, nothing is half-open ──────

test("a terminal too small for a float leaves no half-open panel", function()
	local float_cfg = vim.tbl_deep_extend("force", vim.deepcopy(cfg), {
		ui = { default_layout = "float" },
	})
	local mod = require("gitflow.panels.tag")
	local P = panel_object("gitflow.panels.tag")

	local saved_lines, saved_columns = vim.o.lines, vim.o.columns
	local notified = {}
	local saved_notify = vim.notify
	vim.notify = function(message)
		notified[#notified + 1] = tostring(message)
	end

	local ok, err = pcall(function()
		vim.o.lines = 4
		vim.o.columns = 10
		mod.open(float_cfg)
	end)

	vim.notify = saved_notify
	vim.o.lines, vim.o.columns = saved_lines, saved_columns
	assert_true(ok, "opening into a tiny terminal should not error: " .. tostring(err))

	assert_true(
		not P:is_open(),
		"a refused float must not leave the panel buffer behind"
	)
	assert_equals(P.state.winid, nil, "a refused float must not leave a window")
	assert_equals(
		ui_buffer.get("tag"), nil, "a refused float must not leave a buffer registered"
	)
	assert_true(
		table.concat(notified, "\n"):find("too small", 1, true) ~= nil,
		"the refusal should tell the user why"
	)
end)

-- ── the base's own units ──────────────────────────────────────────────

test("hints and footer honour per-view filtering", function()
	local P = panel.new({
		name = "test_panel_base_fixture",
		title = "Fixture",
		keymaps = {
			{ key = "a", desc = "always", run = function() end },
			{ key = "o", desc = "only one", views = { "one" }, run = function() end },
			{ key = "t", desc = "only two", views = { "two" }, run = function() end },
		},
	})

	assert_equals(#P:hints("one"), 2, "view one should see its own key plus the shared one")
	assert_equals(#P:hints("two"), 2, "view two should see its own key plus the shared one")
	assert_equals(#P:hints(), 1, "no view should see only the unrestricted key")
	assert_true(
		P:footer("one", nil):find("o only one", 1, true) ~= nil,
		"the footer should follow the same view filter"
	)
	assert_true(
		P:footer("one", nil):find("t only two", 1, true) == nil,
		"the footer should not leak another view's keys"
	)
end)

test("a range entry binds every key but advertises one label", function()
	local fired = {}
	local P = panel.new({
		name = "test_panel_base_range",
		title = "Range",
		keymaps = {
			{ key = "1-3", keys = { "1", "2", "3" }, desc = "jump",
				run = function(key)
					fired[#fired + 1] = key
				end },
		},
	})
	assert_equals(#P:hints(), 1, "a range advertises one entry")
	assert_equals(P:hints()[1][1], "1-3", "the label is the range, not a single key")

	local bufnr = vim.api.nvim_create_buf(false, true)
	P:bind_keymaps(bufnr)
	local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local bound = {}
	for _, map in ipairs(maps) do
		bound[map.lhs] = true
	end
	for _, key in ipairs({ "1", "2", "3" }) do
		assert_true(bound[key], ("range should bind %s"):format(key))
	end
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("the footer never drops below one entry", function()
	local P = panel.new({
		name = "test_panel_base_narrow",
		title = "Narrow",
		keymaps = {
			{ key = "a", desc = "a very long description indeed", run = function() end },
			{ key = "b", desc = "another long description here", run = function() end },
		},
	})
	local footer = P:footer(nil, 4)
	assert_true(footer:find("a ", 1, true) ~= nil, "the first entry always survives")
	assert_true(
		footer:find(render.glyphs.ellipsis, 1, true) ~= nil,
		"an elided footer says so instead of clipping silently"
	)
end)

test("the split hint bar elides to fit its window", function()
	local P = panel.new({
		name = "test_panel_base_split_bar",
		title = "Split bar",
		keymaps = {
			{ key = "a", desc = "a fairly long description", run = function() end },
			{ key = "b", desc = "another long description", run = function() end },
			{ key = "c", desc = "a third long description", run = function() end },
			{ key = "q", desc = "close", essential = true, run = function() end },
		},
	})

	assert_true(P:ensure_window(cfg), "the fixture panel should open in a split")
	local ok, err = pcall(function()
		local B = P:begin_render()
		P:push_hints(B)
		assert_true(P:paint(B), "the fixture panel should paint")

		local width = P:split_width()
		assert_equals(width, 40, "the fixture split should be 40 columns wide")

		local bar
		for _, line in ipairs(vim.api.nvim_buf_get_lines(P.state.bufnr, 0, -1, false)) do
			if line:find("q close", 1, true) then
				bar = line
			end
		end
		assert_true(bar ~= nil, "the essential key must stay on the bar")
		assert_true(
			vim.fn.strdisplaywidth(bar) <= width,
			("the hint bar overflows its split (%d > %d): %q"):format(
				vim.fn.strdisplaywidth(bar), width, bar
			)
		)
		assert_true(
			bar:find(render.glyphs.ellipsis, 1, true) ~= nil,
			"an elided hint bar says so instead of running off the window"
		)
	end)
	P:close()
	assert_true(ok, tostring(err))
end)

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
