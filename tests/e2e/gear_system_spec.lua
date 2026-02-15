-- tests/e2e/gear_system_spec.lua — conflict resolution UI E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/gear_system_spec.lua
--
-- Verifies:
--   1. Conflict panel opens via :Gitflow conflicts
--   2. Conflicted file list renders from git stub
--   3. 3-way merge view opens on file selection
--   4. LOCAL / BASE / REMOTE panes exist
--   5. Hunk navigation with ]x / [x
--   6. Accept LOCAL (1), BASE (2), REMOTE (3) side
--   7. Resolve all hunks (a)
--   8. Manual edit mode (e)
--   9. Continue merge/rebase (C)
--  10. Abort operation (A)
--  11. Window layout cleanup after resolution

local T = _G.T
local cfg = _G.TestConfig

local ui = require("gitflow.ui")
local commands = require("gitflow.commands")
local conflict_panel = require("gitflow.panels.conflict")
local conflict_view = require("gitflow.ui.conflict")
local git_conflict = require("gitflow.git.conflict")

-- ── Helpers ────────────────────────────────────────────────────────────

---@param patches table[]
---@param fn fun()
local function with_temporary_patches(patches, fn)
	local originals = {}
	for index, patch in ipairs(patches) do
		originals[index] = patch.table[patch.key]
		patch.table[patch.key] = patch.value
	end

	local ok, err = xpcall(fn, debug.traceback)

	for index = #patches, 1, -1 do
		local patch = patches[index]
		patch.table[patch.key] = originals[index]
	end

	if not ok then
		error(err, 0)
	end
end

---@param fn fun()
---@return table[] notifications
local function capture_notifications(fn)
	local notifications = {}
	local orig_notify = vim.notify
	vim.notify = function(msg, level, ...)
		notifications[#notifications + 1] = {
			message = msg,
			level = level,
		}
		return orig_notify(msg, level, ...)
	end

	local ok, err = xpcall(fn, debug.traceback)
	vim.notify = orig_notify

	if not ok then
		error(err, 0)
	end
	return notifications
end

--- Close all panels and floating windows.
local function cleanup_panels()
	if conflict_view.is_open() then
		pcall(conflict_view.close)
	end
	for _, panel_name in ipairs({
		"status", "diff", "log", "stash", "branch",
		"conflict", "issues", "prs", "labels", "review",
		"palette",
	}) do
		local mod_ok, mod = pcall(require, "gitflow.panels." .. panel_name)
		if mod_ok and mod.close then
			pcall(mod.close)
		end
	end

	-- Close any remaining tabs (conflict view opens a tab)
	while vim.fn.tabpagenr("$") > 1 do
		pcall(vim.cmd, "tabclose!")
	end

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local win_cfg = vim.api.nvim_win_get_config(win)
		if win_cfg.relative and win_cfg.relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
end

--- Create a temporary file with conflict markers for testing.
---@return string path
local function create_conflict_file()
	local path = vim.fn.tempname()
	local lines = {
		"line one",
		"<<<<<<< HEAD",
		"local content",
		"|||||||",
		"base content",
		"=======",
		"remote content",
		">>>>>>> feature",
		"line four",
	}
	T.write_file(path, lines)
	return path
end

--- Create a conflict file with multiple hunks.
---@return string path
local function create_multi_hunk_conflict_file()
	local path = vim.fn.tempname()
	local lines = {
		"header",
		"<<<<<<< HEAD",
		"local hunk one",
		"|||||||",
		"base hunk one",
		"=======",
		"remote hunk one",
		">>>>>>> feature",
		"middle",
		"<<<<<<< HEAD",
		"local hunk two",
		"|||||||",
		"base hunk two",
		"=======",
		"remote hunk two",
		">>>>>>> feature",
		"footer",
	}
	T.write_file(path, lines)
	return path
end

---@param fail_target string
---@param fn fun()
local function with_git_fail(fail_target, fn)
	local previous = vim.env.GITFLOW_GIT_FAIL
	vim.env.GITFLOW_GIT_FAIL = fail_target

	local ok, err = xpcall(fn, debug.traceback)

	vim.env.GITFLOW_GIT_FAIL = previous or ""
	if previous == nil then
		vim.env.GITFLOW_GIT_FAIL = nil
	end

	if not ok then
		error(err, 0)
	end
end

--- Set conflicted file paths for the git diff --name-only stub.
---@param paths string
---@param fn fun()
local function with_conflicts(paths, fn)
	local previous = vim.env.GITFLOW_GIT_CONFLICTS
	vim.env.GITFLOW_GIT_CONFLICTS = paths

	local ok, err = xpcall(fn, debug.traceback)

	vim.env.GITFLOW_GIT_CONFLICTS = previous or ""
	if previous == nil then
		vim.env.GITFLOW_GIT_CONFLICTS = nil
	end

	if not ok then
		error(err, 0)
	end
end

---@param fn fun(log_path: string)
local function with_temp_git_log(fn)
	local log_path = vim.fn.tempname()
	local previous = vim.env.GITFLOW_GIT_LOG
	vim.env.GITFLOW_GIT_LOG = log_path

	local ok, err = xpcall(function()
		fn(log_path)
	end, debug.traceback)

	vim.env.GITFLOW_GIT_LOG = previous
	pcall(vim.fn.delete, log_path)

	if not ok then
		error(err, 0)
	end
end

T.run_suite("E2E: Conflict Resolution UI", {

	-- ── Conflict panel opens via :Gitflow conflicts ──────────────────

	["conflict panel opens via :Gitflow conflicts"] = function()
		T.exec_command("Gitflow conflicts")
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("conflict")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"conflict buffer should exist after :Gitflow conflicts"
		)
		T.assert_true(
			conflict_panel.is_open(),
			"conflict panel should report as open"
		)

		cleanup_panels()
	end,

	-- ── Conflicted file list renders from git stub ───────────────────

	["conflicted file list renders from stub"] = function()
		with_conflicts("file.txt", function()
			conflict_panel.open(cfg)
			T.drain_jobs(3000)

			local bufnr = ui.buffer.get("conflict")
			T.assert_true(bufnr ~= nil, "conflict buffer should exist")
			local lines = T.buf_lines(bufnr)

			T.assert_true(
				T.find_line(lines, "file.txt") ~= nil,
				"conflict panel should show conflicted file.txt"
			)
			T.assert_true(
				T.find_line(lines, "Unresolved files: 1") ~= nil,
				"should show 1 unresolved file"
			)
		end)

		cleanup_panels()
	end,

	-- ── Conflict panel keymaps ───────────────────────────────────────

	["conflict panel has expected keymaps"] = function()
		conflict_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("conflict")
		T.assert_true(bufnr ~= nil, "conflict buffer should exist")
		T.assert_keymaps(bufnr, { "<CR>", "r", "R", "C", "A", "q" })

		cleanup_panels()
	end,

	-- ── Active operation label renders ───────────────────────────────

	["active operation label renders"] = function()
		conflict_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("conflict")
		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Active operation:") ~= nil,
			"should show active operation line"
		)

		cleanup_panels()
	end,

	-- ── Empty conflict list shows empty state ────────────────────────

	["empty conflict list shows no conflicts state"] = function()
		cleanup_panels()
		conflict_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("conflict")
		T.assert_true(bufnr ~= nil, "conflict buffer should exist")
		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "Unresolved files: 0") ~= nil,
			"should show 0 unresolved files when no conflicts"
		)

		cleanup_panels()
	end,

	-- ── parse_markers correctly parses conflict hunks ─────────────────

	["parse_markers extracts hunks from conflict content"] = function()
		local lines = {
			"line one",
			"<<<<<<< HEAD",
			"local content",
			"|||||||",
			"base content",
			"=======",
			"remote content",
			">>>>>>> feature",
			"line four",
		}
		local hunks = git_conflict.parse_markers(lines)
		T.assert_equals(#hunks, 1, "should find 1 conflict hunk")
		T.assert_equals(
			hunks[1].start_line, 2,
			"hunk should start at line 2"
		)
		T.assert_equals(
			hunks[1].end_line, 8,
			"hunk should end at line 8"
		)
		T.assert_deep_equals(
			hunks[1].local_lines, { "local content" },
			"local lines should be extracted"
		)
		T.assert_deep_equals(
			hunks[1].base_lines, { "base content" },
			"base lines should be extracted"
		)
		T.assert_deep_equals(
			hunks[1].remote_lines, { "remote content" },
			"remote lines should be extracted"
		)
	end,

	["parse_markers handles multiple hunks"] = function()
		local lines = {
			"header",
			"<<<<<<< HEAD",
			"local one",
			"=======",
			"remote one",
			">>>>>>> feature",
			"middle",
			"<<<<<<< HEAD",
			"local two",
			"=======",
			"remote two",
			">>>>>>> feature",
			"footer",
		}
		local hunks = git_conflict.parse_markers(lines)
		T.assert_equals(#hunks, 2, "should find 2 conflict hunks")
		T.assert_equals(hunks[1].start_line, 2, "first hunk start")
		T.assert_equals(hunks[2].start_line, 8, "second hunk start")
	end,

	-- ── 3-way merge view opens ──────────────────────────────────────

	["3-way merge view opens with LOCAL/BASE/REMOTE panes"] = function()
		local path = create_conflict_file()

		-- Stub get_version so the UI gets clean content
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					if stage == "local" or stage == 2 then
						cb(nil, { "local content" })
					elseif stage == "base" or stage == 1 then
						cb(nil, { "base content" })
					elseif stage == "remote" or stage == 3 then
						cb(nil, { "remote content" })
					end
				end,
			},
		}, function()
			with_conflicts(path, function()
				conflict_panel.open(cfg)
				T.drain_jobs(3000)

				local bufnr = ui.buffer.get("conflict")
				T.assert_true(bufnr ~= nil, "conflict buffer should exist")

				local line_no = T.buf_find_line(bufnr, path)
				T.assert_true(
					line_no ~= nil,
					"conflict panel should render selected conflicted file"
				)

				local winid = conflict_panel.state.winid
				T.assert_true(
					winid ~= nil and vim.api.nvim_win_is_valid(winid),
					"conflict panel window should be valid"
				)
				vim.api.nvim_set_current_win(winid)
				vim.api.nvim_win_set_cursor(winid, { line_no, 0 })
				T.feedkeys("<CR>")
				T.drain_jobs(3000)
			end)
		end)

		T.assert_true(
			conflict_view.is_open(),
			"3-way conflict view should open from conflict panel <CR>"
		)
		T.assert_true(
			conflict_view.state.active,
			"conflict view state should be active"
		)

		-- Verify 4 pane buffers exist
		T.assert_true(
			conflict_view.state.local_bufnr ~= nil
				and vim.api.nvim_buf_is_valid(
					conflict_view.state.local_bufnr
				),
			"local buffer should exist"
		)
		T.assert_true(
			conflict_view.state.base_bufnr ~= nil
				and vim.api.nvim_buf_is_valid(
					conflict_view.state.base_bufnr
				),
			"base buffer should exist"
		)
		T.assert_true(
			conflict_view.state.remote_bufnr ~= nil
				and vim.api.nvim_buf_is_valid(
					conflict_view.state.remote_bufnr
				),
			"remote buffer should exist"
		)
		T.assert_true(
			conflict_view.state.merged_bufnr ~= nil
				and vim.api.nvim_buf_is_valid(
					conflict_view.state.merged_bufnr
				),
			"merged buffer should exist"
		)

		-- Verify windows exist
		T.assert_true(
			conflict_view.state.local_winid ~= nil
				and vim.api.nvim_win_is_valid(
					conflict_view.state.local_winid
				),
			"local window should exist"
		)
		T.assert_true(
			conflict_view.state.base_winid ~= nil
				and vim.api.nvim_win_is_valid(
					conflict_view.state.base_winid
				),
			"base window should exist"
		)
		T.assert_true(
			conflict_view.state.remote_winid ~= nil
				and vim.api.nvim_win_is_valid(
					conflict_view.state.remote_winid
				),
			"remote window should exist"
		)
		T.assert_true(
			conflict_view.state.merged_winid ~= nil
				and vim.api.nvim_win_is_valid(
					conflict_view.state.merged_winid
				),
			"merged window should exist"
		)

		-- Tab should have been created
		T.assert_true(
			conflict_view.state.tabid ~= nil
				and vim.api.nvim_tabpage_is_valid(
					conflict_view.state.tabid
				),
			"conflict view should open in a new tab"
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Merged buffer keymaps ────────────────────────────────────────

	["merged buffer has all expected keymaps"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					if stage == "local" or stage == 2 then
						cb(nil, { "local content" })
					elseif stage == "base" or stage == 1 then
						cb(nil, { "base content" })
					elseif stage == "remote" or stage == 3 then
						cb(nil, { "remote content" })
					end
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		local bufnr = conflict_view.state.merged_bufnr
		T.assert_true(bufnr ~= nil, "merged buffer should exist")
		T.assert_keymaps(
			bufnr,
			{ "1", "2", "3", "a", "e", "]x", "[x", "r", "q" }
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Top buffers are read-only ────────────────────────────────────

	["LOCAL/BASE/REMOTE buffers are read-only"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					if stage == "local" or stage == 2 then
						cb(nil, { "local content" })
					elseif stage == "base" or stage == 1 then
						cb(nil, { "base content" })
					elseif stage == "remote" or stage == 3 then
						cb(nil, { "remote content" })
					end
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		for _, key in ipairs({ "local_bufnr", "base_bufnr", "remote_bufnr" }) do
			local bufnr = conflict_view.state[key]
			T.assert_true(bufnr ~= nil, key .. " should exist")
			local readonly = vim.api.nvim_get_option_value(
				"readonly", { buf = bufnr }
			)
			T.assert_true(
				readonly,
				key .. " should be read-only"
			)
		end

		-- Merged buffer should be modifiable
		local merged = conflict_view.state.merged_bufnr
		local modifiable = vim.api.nvim_get_option_value(
			"modifiable", { buf = merged }
		)
		T.assert_true(modifiable, "merged buffer should be modifiable")

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Hunk navigation ]x / [x ──────────────────────────────────────

	["hunk navigation ]x and [x move between hunks"] = function()
		local path = create_multi_hunk_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		T.assert_true(
			#conflict_view.state.hunks >= 2,
			"should have at least 2 hunks"
		)

		local merged_win = conflict_view.state.merged_winid

		-- Start at line 1
		vim.api.nvim_set_current_win(merged_win)
		vim.api.nvim_win_set_cursor(merged_win, { 1, 0 })

		-- Jump forward to first hunk
		conflict_view.jump(1)
		local pos1 = vim.api.nvim_win_get_cursor(merged_win)[1]
		T.assert_equals(
			pos1, conflict_view.state.hunks[1].start_line,
			"]x should jump to first hunk start"
		)

		-- Jump forward to second hunk
		conflict_view.jump(1)
		local pos2 = vim.api.nvim_win_get_cursor(merged_win)[1]
		T.assert_equals(
			pos2, conflict_view.state.hunks[2].start_line,
			"]x should jump to second hunk start"
		)

		-- Jump backward to first hunk
		conflict_view.jump(-1)
		local pos3 = vim.api.nvim_win_get_cursor(merged_win)[1]
		T.assert_equals(
			pos3, conflict_view.state.hunks[1].start_line,
			"[x should jump back to first hunk"
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Hunk navigation wraps around ─────────────────────────────────

	["hunk navigation wraps around at boundaries"] = function()
		local path = create_multi_hunk_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		local merged_win = conflict_view.state.merged_winid
		vim.api.nvim_set_current_win(merged_win)

		-- Position after last hunk and jump forward
		local last_hunk = conflict_view.state.hunks[#conflict_view.state.hunks]
		vim.api.nvim_win_set_cursor(
			merged_win, { last_hunk.start_line, 0 }
		)
		conflict_view.jump(1)
		local pos = vim.api.nvim_win_get_cursor(merged_win)[1]
		T.assert_equals(
			pos, conflict_view.state.hunks[1].start_line,
			"]x past last hunk should wrap to first"
		)

		-- Jump backward from first hunk
		vim.api.nvim_win_set_cursor(
			merged_win,
			{ conflict_view.state.hunks[1].start_line, 0 }
		)
		conflict_view.jump(-1)
		local pos2 = vim.api.nvim_win_get_cursor(merged_win)[1]
		T.assert_equals(
			pos2, last_hunk.start_line,
			"[x before first hunk should wrap to last"
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Accept LOCAL side (1) ────────────────────────────────────────

	["resolve current hunk accepts LOCAL side"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
			-- Stub mark_resolved to avoid git add call
			{
				table = git_conflict,
				key = "mark_resolved",
				value = function(p, opts, cb)
					cb(nil, { code = 0, stdout = "resolved", stderr = "" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)

			-- Confirm hunks parsed
			T.assert_true(
				#conflict_view.state.hunks > 0,
				"should have hunks before resolve"
			)

			-- Position cursor in hunk range
			local win = conflict_view.state.merged_winid
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(
				win,
				{ conflict_view.state.hunks[1].start_line, 0 }
			)

			-- Resolve with local side
			conflict_view.resolve_current("local")
			T.drain_jobs(3000)

			-- Read the file back — should have local content
			local result = T.read_file(path)
			T.assert_true(
				T.find_line(result, "local content") ~= nil,
				"file should contain local content after resolve"
			)
			-- Conflict markers should be gone
			T.assert_true(
				T.find_line(result, "<<<<<<<") == nil,
				"conflict markers should be removed"
			)
		end)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Accept BASE side (2) ─────────────────────────────────────────

	["resolve current hunk accepts BASE side"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
			{
				table = git_conflict,
				key = "mark_resolved",
				value = function(p, opts, cb)
					cb(nil, { code = 0, stdout = "resolved", stderr = "" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)

			local win = conflict_view.state.merged_winid
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(
				win,
				{ conflict_view.state.hunks[1].start_line, 0 }
			)

			conflict_view.resolve_current("base")
			T.drain_jobs(3000)

			local result = T.read_file(path)
			T.assert_true(
				T.find_line(result, "base content") ~= nil,
				"file should contain base content after resolve"
			)
			T.assert_true(
				T.find_line(result, "<<<<<<<") == nil,
				"conflict markers should be removed"
			)
		end)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Accept REMOTE side (3) ───────────────────────────────────────

	["resolve current hunk accepts REMOTE side"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
			{
				table = git_conflict,
				key = "mark_resolved",
				value = function(p, opts, cb)
					cb(nil, { code = 0, stdout = "resolved", stderr = "" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)

			local win = conflict_view.state.merged_winid
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(
				win,
				{ conflict_view.state.hunks[1].start_line, 0 }
			)

			conflict_view.resolve_current("remote")
			T.drain_jobs(3000)

			local result = T.read_file(path)
			T.assert_true(
				T.find_line(result, "remote content") ~= nil,
				"file should contain remote content after resolve"
			)
			T.assert_true(
				T.find_line(result, "<<<<<<<") == nil,
				"conflict markers should be removed"
			)
		end)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Resolve all hunks (a) ────────────────────────────────────────

	["resolve_all_from_prompt resolves all hunks"] = function()
		local path = create_multi_hunk_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
			{
				table = git_conflict,
				key = "mark_resolved",
				value = function(p, opts, cb)
					cb(nil, { code = 0, stdout = "resolved", stderr = "" })
				end,
			},
			-- Stub vim.fn.confirm to select "Local" (choice 1)
			{
				table = vim.fn,
				key = "confirm",
				value = function()
					return 1
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)

			T.assert_true(
				#conflict_view.state.hunks >= 2,
				"should have >= 2 hunks before resolve_all"
			)

			conflict_view.resolve_all_from_prompt()
			T.drain_jobs(3000)

			local result = T.read_file(path)
			T.assert_true(
				T.find_line(result, "<<<<<<<") == nil,
				"all conflict markers should be removed"
			)
			T.assert_true(
				T.find_line(result, "local hunk one") ~= nil,
				"should contain local hunk one content"
			)
			T.assert_true(
				T.find_line(result, "local hunk two") ~= nil,
				"should contain local hunk two content"
			)
		end)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Manual edit mode (e) ─────────────────────────────────────────

	["edit_current_hunk enters insert mode on merged buffer"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		local merged_win = conflict_view.state.merged_winid
		vim.api.nvim_set_current_win(merged_win)
		vim.api.nvim_win_set_cursor(
			merged_win,
			{ conflict_view.state.hunks[1].start_line, 0 }
		)

		-- edit_current_hunk should position cursor and enter insert mode
		conflict_view.edit_current_hunk()

		-- Cursor should be at hunk start
		local cursor = vim.api.nvim_win_get_cursor(merged_win)
		T.assert_equals(
			cursor[1], conflict_view.state.hunks[1].start_line,
			"cursor should be at hunk start after edit"
		)

		-- Leave insert mode for cleanup
		vim.cmd("stopinsert")

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Continue merge/rebase (C) ────────────────────────────────────

	["continue_operation dispatches merge --continue"] = function()
		with_temp_git_log(function(log_path)
			with_temporary_patches({
				{
					table = ui.input,
					key = "confirm",
					value = function()
						return true
					end,
				},
				-- Stub active_operation to return "merge"
				{
					table = git_conflict,
					key = "active_operation",
					value = function(opts, cb)
						cb(nil, "merge", { code = 0 })
					end,
				},
			}, function()
				conflict_panel.open(cfg)
				T.drain_jobs(3000)
				conflict_panel.state.active_operation = "merge"
				conflict_panel.state.files = {}

				conflict_panel.continue_operation()
				T.drain_jobs(3000)

				local lines = T.read_file(log_path)
				T.assert_true(
					T.find_line(lines, "merge --continue") ~= nil,
					"should invoke git merge --continue"
				)
			end)
		end)

		cleanup_panels()
	end,

	-- ── Abort operation (A) ──────────────────────────────────────────

	["abort_operation dispatches merge --abort"] = function()
		with_temp_git_log(function(log_path)
			with_temporary_patches({
				{
					table = ui.input,
					key = "confirm",
					value = function()
						return true
					end,
				},
				{
					table = git_conflict,
					key = "active_operation",
					value = function(opts, cb)
						cb(nil, "merge", { code = 0 })
					end,
				},
			}, function()
				conflict_panel.open(cfg)
				T.drain_jobs(3000)
				conflict_panel.state.active_operation = "merge"

				conflict_panel.abort_operation()
				T.drain_jobs(3000)

				local lines = T.read_file(log_path)
				T.assert_true(
					T.find_line(lines, "merge --abort") ~= nil,
					"should invoke git merge --abort"
				)
			end)
		end)

		cleanup_panels()
	end,

	-- ── Window layout cleanup after close ────────────────────────────

	["conflict view close cleans up all windows and tab"] = function()
		local path = create_conflict_file()
		local before = T.window_layout()
		local tab_before = vim.fn.tabpagenr("$")

		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
			{
				table = git_conflict,
				key = "mark_resolved",
				value = function(p, opts, cb)
					cb(nil, { code = 0, stdout = "resolved", stderr = "" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)

			T.assert_true(
				vim.fn.tabpagenr("$") > tab_before,
				"opening conflict view should create a new tab"
			)
			T.assert_true(
				conflict_view.state.active,
				"conflict view should be active"
			)

			conflict_view.close()
		end)

		-- After close, state should be reset
		T.assert_false(
			conflict_view.state.active,
			"conflict view state should be inactive after close"
		)
		T.assert_true(
			conflict_view.state.path == nil,
			"conflict view path should be nil after close"
		)
		T.assert_true(
			conflict_view.state.merged_bufnr == nil,
			"merged buffer should be nil after close"
		)

		-- Tab count should return to baseline
		T.assert_equals(
			vim.fn.tabpagenr("$"), tab_before,
			"tab count should return to baseline after close"
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Conflict panel close also closes conflict view ───────────────

	["conflict panel close also closes open conflict view"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		T.assert_true(
			conflict_view.is_open(),
			"conflict view should be open before panel close"
		)

		-- Open conflict panel then close it — should also close view
		conflict_panel.open(cfg)
		T.drain_jobs(3000)
		conflict_panel.close()

		T.assert_false(
			conflict_view.is_open(),
			"conflict view should be closed after panel close"
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Top panes scrollbind ─────────────────────────────────────────

	["LOCAL/BASE/REMOTE windows have scrollbind enabled"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		for _, key in ipairs({ "local_winid", "base_winid", "remote_winid" }) do
			local winid = conflict_view.state[key]
			T.assert_true(
				winid ~= nil and vim.api.nvim_win_is_valid(winid),
				key .. " should be valid"
			)
			local scrollbind = vim.api.nvim_get_option_value(
				"scrollbind", { win = winid }
			)
			T.assert_true(scrollbind, key .. " should have scrollbind")
		end

		-- Merged window should NOT have scrollbind
		local merged_sb = vim.api.nvim_get_option_value(
			"scrollbind",
			{ win = conflict_view.state.merged_winid }
		)
		T.assert_false(merged_sb, "merged window should not have scrollbind")

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Highlights applied to hunks ──────────────────────────────────

	["conflict view applies hunk highlights"] = function()
		local path = create_conflict_file()
		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			conflict_view.open(path, { cfg = cfg })
			T.drain_jobs(3000)
		end)

		-- Check that highlights are applied to merged buffer
		local ns_id = vim.api.nvim_get_namespaces()["gitflow_conflict_view"]
		T.assert_true(ns_id ~= nil, "conflict view namespace should exist")

		local bufnr = conflict_view.state.merged_bufnr
		local extmarks = vim.api.nvim_buf_get_extmarks(
			bufnr, ns_id, 0, -1, { details = true }
		)
		T.assert_true(
			#extmarks > 0,
			"should have highlight extmarks on merged buffer"
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,

	-- ── Callbacks fire on resolve / close ─────────────────────────────

	["on_closed callback fires when conflict view closes"] = function()
		local path = create_conflict_file()
		local closed_path = nil

		with_temporary_patches({
			{
				table = git_conflict,
				key = "get_version",
				value = function(p, stage, opts, cb)
					cb(nil, { "stub" })
				end,
			},
		}, function()
			conflict_view.open(path, {
				cfg = cfg,
				on_closed = function(p)
					closed_path = p
				end,
			})
			T.drain_jobs(3000)
			conflict_view.close()
		end)

		T.assert_equals(
			closed_path, path,
			"on_closed callback should receive the file path"
		)

		pcall(vim.fn.delete, path)
		cleanup_panels()
	end,
})

print("E2E conflict resolution tests passed")
