-- tests/e2e/window_lifecycle_spec.lua — float sizing + close-hook lifecycle
--
-- Run:
--   nvim --headless -u tests/minimal_init.lua \
--     -l tests/e2e/window_lifecycle_spec.lua
--
-- Verifies:
--   1. Float geometry accounts for tabline/statusline/cmdheight and clamps to
--      what fits; a terminal too small to hold a usable float is refused with
--      a message instead of a crash or a sliver window
--   2. `on_close` fires exactly once on every close route (:q, <C-w>c, :bd,
--      layout change, ui.window.close)
--   3. Manual conflict-buffer edits reach disk when the view is closed with a
--      plain :q, not only via the plugin's own `q` bind

local T = _G.T

local window = require("gitflow.ui.window")
local buffer = require("gitflow.ui.buffer")
local conflict = require("gitflow.ui.conflict")

---@param name string
---@return boolean
local function augroup_exists(name)
	return (pcall(vim.api.nvim_get_autocmds, { group = name }))
end

---@param fn fun()
---@return string[] messages
local function capture_notifications(fn)
	local messages = {}
	local original = vim.notify
	vim.notify = function(msg, ...)
		messages[#messages + 1] = tostring(msg)
		return original(msg, ...)
	end
	local ok, err = pcall(fn)
	vim.notify = original
	if not ok then
		error(err, 0)
	end
	return messages
end

---@param columns integer
---@param lines integer
---@param fn fun()
local function with_screen(columns, lines, fn)
	local saved_columns, saved_lines = vim.o.columns, vim.o.lines
	vim.o.columns, vim.o.lines = columns, lines
	local ok, err = pcall(fn)
	vim.o.columns, vim.o.lines = saved_columns, saved_lines
	if not ok then
		error(err, 0)
	end
end

--- Open a counted float and return its winid plus a counter table.
---@param name string|nil
---@return integer winid, { count: integer }
local function open_counted_float(name)
	local bufnr = vim.api.nvim_create_buf(false, true)
	local calls = { count = 0 }
	local winid = window.open_float({
		bufnr = bufnr,
		name = name,
		width = 0.4,
		height = 0.4,
		on_close = function()
			calls.count = calls.count + 1
		end,
	})
	T.assert_true(
		winid ~= nil and vim.api.nvim_win_is_valid(winid),
		"counted float should open"
	)
	return winid, calls
end

---@param lines string[]
---@return string path
local function write_conflicted_file(lines)
	local path = vim.fn.tempname()
	vim.fn.writefile(lines, path)
	return path
end

local CONFLICT_LINES = {
	"context above",
	"<<<<<<< HEAD",
	"ours line",
	"=======",
	"theirs line",
	">>>>>>> feature",
	"context below",
}

T.run_suite("E2E: Window Lifecycle (sizing + close hooks)", {
	-- ── 1. sizing ────────────────────────────────────────────────────

	["float area excludes statusline, tabline and cmdheight"] = function()
		local area = window.float_area()
		local chrome = vim.o.lines - area.lines - area.first_row
		T.assert_true(
			chrome >= vim.o.cmdheight,
			"usable area must reserve at least the command line"
		)
		if vim.o.laststatus > 0 then
			T.assert_true(
				chrome >= vim.o.cmdheight + 1,
				"usable area must also reserve the statusline row"
			)
		end
		T.assert_equals(
			area.columns, vim.o.columns, "usable columns should be the full width"
		)
	end,

	["float geometry keeps the bordered window inside the usable area"] = function()
		local area = { columns = 40, lines = 12, first_row = 1, scale_lines = 13 }
		local geometry, err = window.float_geometry({ width = 1.0, height = 1.0 }, area)
		T.assert_true(geometry ~= nil, "full-size request should still fit: " .. tostring(err))
		T.assert_true(
			geometry.width + 2 <= area.columns,
			"content + border must fit the columns"
		)
		T.assert_true(
			geometry.height + 2 <= area.lines,
			"content + border must fit the usable rows"
		)
		T.assert_true(
			geometry.row >= area.first_row,
			"float must start below the tabline"
		)
		T.assert_true(
			geometry.row + geometry.height + 2 <= area.first_row + area.lines,
			"float must not extend past the usable area"
		)
	end,

	["float geometry never returns a non-positive dimension"] = function()
		for columns = 1, 30 do
			for lines = 1, 12 do
				local geometry = window.float_geometry(
					{ width = 0.8, height = 0.7 },
					{ columns = columns, lines = lines, first_row = 0, scale_lines = lines }
				)
				if geometry then
					T.assert_true(
						geometry.width >= window.MIN_FLOAT_WIDTH,
						("width %d below the usable minimum"):format(geometry.width)
					)
					T.assert_true(
						geometry.height >= window.MIN_FLOAT_HEIGHT,
						("height %d below the usable minimum"):format(geometry.height)
					)
					T.assert_true(
						geometry.width + 2 <= columns and geometry.height + 2 <= lines,
						("geometry overflows a %dx%d area"):format(columns, lines)
					)
				end
			end
		end
	end,

	["float geometry refuses a terminal too small to be usable"] = function()
		local geometry, err = window.float_geometry(
			{ width = 0.8, height = 0.7 },
			{ columns = 10, lines = 4, first_row = 0, scale_lines = 4 }
		)
		T.assert_true(geometry == nil, "a 10x4 terminal should be refused")
		T.assert_contains(
			tostring(err), "too small", "refusal should say the terminal is too small"
		)
	end,

	["open_float degrades with a message instead of crashing"] = function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		local winid
		local messages = capture_notifications(function()
			with_screen(12, 4, function()
				winid = window.open_float({ bufnr = bufnr, width = 0.8, height = 0.7 })
			end)
		end)
		T.assert_true(winid == nil, "open_float should not open on a tiny terminal")
		T.assert_true(#messages > 0, "open_float should explain why it refused")
		T.assert_contains(
			table.concat(messages, "\n"), "too small", "message should name the cause"
		)
	end,

	-- ── 2. close hooks ───────────────────────────────────────────────

	["on_close fires once on plain :q"] = function()
		local winid, calls = open_counted_float(nil)
		vim.api.nvim_win_call(winid, function()
			vim.cmd("quit")
		end)
		T.assert_equals(calls.count, 1, "on_close should fire exactly once for :q")
	end,

	["on_close fires once on <C-w>c"] = function()
		local winid, calls = open_counted_float(nil)
		vim.api.nvim_win_call(winid, function()
			vim.cmd("close")
		end)
		T.assert_equals(calls.count, 1, "on_close should fire exactly once for :close")
	end,

	["on_close fires once when the buffer is deleted"] = function()
		local winid, calls = open_counted_float(nil)
		local bufnr = vim.api.nvim_win_get_buf(winid)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		T.assert_equals(calls.count, 1, "on_close should fire exactly once for :bd")
	end,

	["on_close fires once on a layout change"] = function()
		local winid, calls = open_counted_float(nil)
		vim.api.nvim_win_close(winid, true)
		T.assert_equals(
			calls.count, 1, "on_close should fire exactly once when the layout drops the window"
		)
	end,

	["on_close does not fire twice via the plugin's own close"] = function()
		local _, calls = open_counted_float("lifecycle_probe")
		T.assert_true(
			window.close("lifecycle_probe"), "named close should find the window"
		)
		T.assert_equals(
			calls.count, 1, "plugin close plus WinClosed must still fire on_close once"
		)
		T.assert_true(
			window.get("lifecycle_probe") == nil, "registry entry should be dropped"
		)
	end,

	-- ── 3. augroups have a bounded lifecycle ─────────────────────────

	["gitflow buffers share one cleanup augroup"] = function()
		local before = #vim.api.nvim_get_autocmds({ group = "GitflowBufferCleanup" })
		for index = 1, 5 do
			local name = ("lifecycle probe buf %d"):format(index)
			local bufnr = buffer.create(name, { lines = { "x" } })
			vim.api.nvim_buf_delete(bufnr, { force = true })
			T.assert_false(
				augroup_exists(("GitflowBuffer_%s"):format(name:gsub("[^%w_]", "_"))),
				"no per-name augroup should be created"
			)
			T.assert_true(buffer.get(name) == nil, "registry entry should be cleared")
		end
		T.assert_equals(
			#vim.api.nvim_get_autocmds({ group = "GitflowBufferCleanup" }),
			before,
			"cleanup autocmds must not accumulate once the buffers are gone"
		)
	end,

	["a closed window drops its watch augroup"] = function()
		local winid, calls = open_counted_float(nil)
		local group = ("GitflowWindow_%d"):format(winid)
		T.assert_true(augroup_exists(group), "an open window should be watched")
		vim.api.nvim_win_close(winid, true)
		T.assert_equals(calls.count, 1, "on_close should have fired")
		T.assert_false(augroup_exists(group), "the watch augroup must be removed on close")
	end,

	-- ── 4. conflict edits survive a plain :q ─────────────────────────

	["manual conflict edits are written to disk on plain :q"] = function()
		local path = write_conflicted_file(CONFLICT_LINES)
		conflict.open(path)
		T.assert_true(conflict.is_open(), "conflict view should be open")

		local bufnr = conflict.state.merged_bufnr
		local winid = conflict.state.merged_winid
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "hand edited above" })

		vim.api.nvim_win_call(winid, function()
			vim.cmd("quit")
		end)

		local on_disk = vim.fn.readfile(path)
		T.assert_equals(
			on_disk[1], "hand edited above", "the manual edit must reach disk on :q"
		)

		vim.wait(200, function()
			return not conflict.state.active and conflict.state.path == nil
		end, 10)
		T.assert_true(
			conflict.state.path == nil, "conflict state should be torn down after :q"
		)
		vim.fn.delete(path)
	end,

	["closing via the q bind still writes and does not double-fire"] = function()
		local path = write_conflicted_file(CONFLICT_LINES)
		local closed = 0
		conflict.open(path, {
			on_closed = function()
				closed = closed + 1
			end,
		})
		local bufnr = conflict.state.merged_bufnr
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "edited then q" })

		conflict.close()

		local on_disk = vim.fn.readfile(path)
		T.assert_equals(
			on_disk[1], "edited then q", "the manual edit must reach disk on the q bind"
		)
		vim.wait(200, function()
			return false
		end, 10)
		T.assert_equals(closed, 1, "on_closed must fire exactly once")
		T.assert_false(conflict.state.active, "conflict view should be closed")
		vim.fn.delete(path)
	end,
})

print("E2E window lifecycle tests passed")
