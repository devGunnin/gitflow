-- scripts/test_panel_base.lua — the panel-base contract, over every panel
-- that adopts ui/panel.lua.
--
-- One lifecycle means one set of guarantees, so they are asserted once here
-- for all of them rather than per panel:
--   * open -> refresh -> close leaves no buffer, window or registry entry;
--   * a callback from a superseded request is dropped, never painted;
--   * the split hint bar advertises exactly the keys the panel bound, and the
--     float footer advertises the same set (elided to fit, essentials kept);
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
	"notifications",
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
		end
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

	test(("%s: a superseded callback is dropped"):format(name), function()
		local mod = require(modname)
		local P = panel_object(modname)

		mod.open(cfg, {})
		local stale = P:next_request()
		P:next_request()
		assert_true(
			not P:is_active(stale),
			"a request superseded by a newer one must not be active"
		)
		mod.close()
	end)

	test(("%s: a request outliving the panel is dropped"):format(name), function()
		local mod = require(modname)
		local P = panel_object(modname)

		mod.open(cfg, {})
		local in_flight = P:next_request()
		mod.close()
		assert_true(
			not P:is_active(in_flight),
			"close must invalidate in-flight requests"
		)
	end)
end

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

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
