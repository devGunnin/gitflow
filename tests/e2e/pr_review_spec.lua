-- tests/e2e/pr_review_spec.lua — PR review tabpage mode E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/pr_review_spec.lua
--
-- The PR review system now opens a dedicated tabpage with a persistent
-- file list on the left and a normal editing area on the right; files
-- opened from the list display the actual working-tree file with inline
-- PR diff annotations.  This spec exercises that behaviour.

local T = _G.T
local cfg = _G.TestConfig

local gh_prs = require("gitflow.gh.prs")
local input = require("gitflow.ui.input")
local utils = require("gitflow.utils")
local review_panel = require("gitflow.panels.review")
local cache = require("gitflow.review.cache")
local inline = require("gitflow.review.inline")
local list_picker = require("gitflow.ui.list_picker")

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

---@param fn fun(log_path: string)
local function with_temp_gh_log(fn)
	local log_path = vim.fn.tempname()
	local previous = vim.env.GITFLOW_GH_LOG
	vim.env.GITFLOW_GH_LOG = log_path

	local ok, err = xpcall(function()
		fn(log_path)
	end, debug.traceback)

	vim.env.GITFLOW_GH_LOG = previous
	pcall(vim.fn.delete, log_path)

	if not ok then
		error(err, 0)
	end
end

---@param lines string[]
---@return table|nil
local function decode_logged_stdin_payload(lines)
	for i = #lines, 1, -1 do
		local line = lines[i]
		if line:sub(1, 6) == "stdin " then
			local ok, decoded = pcall(vim.json.decode, line:sub(7))
			if ok then
				return decoded
			end
			return nil
		end
	end
	return nil
end

local function cleanup_panels()
	review_panel.close()
	T.cleanup_panels()
end

T.run_suite("E2E: PR Review Mode (tabpage)", {

	-- ── Layout: tabpage + file-list + diff pane ────────────────────────

	["open creates a new tabpage with file list and diff pane"] = function()
		local initial_tabs = #vim.api.nvim_list_tabpages()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_true(review_panel.is_open(),
			"review panel should be open after opening PR")
		T.assert_equals(review_panel.state.pr_number, 42,
			"pr_number should be 42")
		T.assert_true(
			vim.api.nvim_tabpage_is_valid(review_panel.state.tabpage),
			"a new tabpage should be created")
		T.assert_true(
			vim.api.nvim_win_is_valid(review_panel.state.file_list_winid),
			"file list window should exist")
		T.assert_true(
			vim.api.nvim_win_is_valid(review_panel.state.diff_winid),
			"diff window should exist")
		T.assert_true(
			vim.api.nvim_buf_is_valid(review_panel.state.file_list_bufnr),
			"file list buffer should exist")
		T.assert_true(#vim.api.nvim_list_tabpages() > initial_tabs,
			"opening review mode should add a tabpage")

		cleanup_panels()
	end,

	["file list buffer lists the PR's changed files"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local bufnr = review_panel.state.file_list_bufnr
		local lines = T.buf_lines(bufnr)
		local combined = table.concat(lines, "\n")

		T.assert_contains(combined, "PR REVIEW",
			"file list should show a banner")
		T.assert_contains(combined, "highlights.lua",
			"file list should show highlights.lua from the diff fixture")
		T.assert_contains(combined, "config.lua",
			"file list should show config.lua from the diff fixture")

		cleanup_panels()
	end,

	["file list has the expected keybindings"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local bufnr = review_panel.state.file_list_bufnr
		T.assert_keymaps(bufnr, {
			"<CR>", "o", "S", "r", "q", "]f", "[f",
			"<Tab>", "za", "zM", "zR",
		})

		cleanup_panels()
	end,

	-- ── File tree: folders, folding, leaf rendering ────────────────────

	["file list renders changed files as a collapsible folder tree"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local bufnr = review_panel.state.file_list_bufnr
		local combined = table.concat(T.buf_lines(bufnr), "\n")

		-- A directory row is shown (compacted) with a fold arrow + trailing /.
		T.assert_contains(combined, "lua/gitflow/",
			"tree should show the compacted lua/gitflow folder row")
		T.assert_true(
			combined:find("▾", 1, true) ~= nil,
			"an expanded folder should show a ▾ fold arrow")

		-- Leaves are basenames, and a dir line map exists for folding.
		T.assert_contains(combined, "highlights.lua",
			"leaf file basename should be shown")
		T.assert_true(
			review_panel.state._dir_line_map ~= nil
				and next(review_panel.state._dir_line_map) ~= nil,
			"a directory line map should be populated for folding")

		cleanup_panels()
	end,

	["collapse_all hides leaves and expand_all restores them"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local bufnr = review_panel.state.file_list_bufnr

		-- Inject a draft so the collapsed folder should advertise it. Anchor
		-- it to config.lua so the Drafts section (which lists the draft's
		-- file) doesn't reintroduce the "highlights.lua" basename we assert
		-- is hidden by folding.
		review_panel.state.pending_comments[#review_panel.state.pending_comments + 1] = {
			id = 1, path = "lua/gitflow/config.lua",
			body = "draft", new_line = 1,
		}

		review_panel.collapse_all_dirs()
		local collapsed = table.concat(T.buf_lines(bufnr), "\n")
		T.assert_true(
			not collapsed:find("highlights.lua", 1, true),
			"collapse_all should hide leaf basenames")
		T.assert_true(
			collapsed:find("▸", 1, true) ~= nil,
			"collapsed folders should show a ▸ arrow")
		T.assert_true(
			collapsed:find("●", 1, true) ~= nil,
			"a collapsed folder should aggregate hidden draft counts (●n)")

		review_panel.expand_all_dirs()
		local expanded = table.concat(T.buf_lines(bufnr), "\n")
		T.assert_contains(expanded, "highlights.lua",
			"expand_all should restore leaf basenames")

		cleanup_panels()
	end,

	["state.files is populated and is keyed by path"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local paths = {}
		for _, f in ipairs(review_panel.state.files) do
			paths[#paths + 1] = f.path
		end
		T.assert_true(T.contains(paths, "lua/gitflow/highlights.lua"),
			"files should include highlights.lua")
		T.assert_true(T.contains(paths, "lua/gitflow/config.lua"),
			"files should include config.lua")

		cleanup_panels()
	end,

	-- ── File diff parsing: inline annotation contract ──────────────────

	["state.file_diffs parses hunks from the PR diff"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return next(review_panel.state.file_diffs) ~= nil
		end, "file_diffs should be populated after open")

		local fd = review_panel.state.file_diffs["lua/gitflow/highlights.lua"]
		T.assert_true(fd ~= nil, "highlights.lua diff should be parsed")
		T.assert_true(fd.hunks and #fd.hunks > 0,
			"highlights.lua diff should have at least one hunk")

		local has_add, has_del = false, false
		for _, h in ipairs(fd.hunks) do
			for _, line in ipairs(h.lines) do
				if line.kind == "add" then
					has_add = true
				end
				if line.kind == "del" then
					has_del = true
				end
			end
		end
		T.assert_true(has_add,
			"highlights.lua hunk should include an added line")
		T.assert_true(has_del,
			"highlights.lua hunk should include a removed line")

		cleanup_panels()
	end,

	-- ── Open file from list applies annotations ────────────────────────

	["open_file shows file in the diff pane with inline annotations"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		-- Use a path that we know exists in the working tree.
		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		T.assert_equals(review_panel.state.active_path,
			"lua/gitflow/highlights.lua",
			"active_path should be set after open_file")
		T.assert_true(review_panel.state.active_bufnr ~= nil
			and vim.api.nvim_buf_is_valid(review_panel.state.active_bufnr),
			"active_bufnr should be a valid buffer")

		local marks = vim.api.nvim_buf_get_extmarks(
			review_panel.state.active_bufnr,
			inline.DIFF_NS, 0, -1, { details = true }
		)
		T.assert_true(#marks > 0,
			"diff annotations should be applied as extmarks")

		-- Removed lines are rendered as virt_lines.  With a treesitter
		-- parser available for the buffer's filetype, each removed line
		-- should be split into a "- " prefix chunk plus syntax-highlighted
		-- chunks (more than one chunk total), rather than a single plain
		-- DiffDelete chunk.
		local found_del_virt = false
		local found_ts_chunks = false
		for _, m in ipairs(marks) do
			local details = m[4]
			if details and details.virt_lines then
				for _, vline in ipairs(details.virt_lines) do
					if vline[1] and vline[1][1] == "- " then
						found_del_virt = true
						if #vline > 1 then
							found_ts_chunks = true
						end
					end
				end
			end
		end
		T.assert_true(found_del_virt,
			"removed lines should render as '- ' prefixed virt_lines")
		T.assert_true(found_ts_chunks,
			"removed-line virt_lines should be syntax-highlighted into "
				.. "multiple chunks via treesitter")

		cleanup_panels()
	end,

	["opening a diff file via :edit (e.g. Telescope) shows annotations"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		-- Simulate Telescope find_files / a plain :edit: open the file
		-- WITHOUT going through review_panel.open_file. The BufWinEnter
		-- autocmd should still decorate it with the inline diff overlay.
		local full = vim.fn.fnamemodify("lua/gitflow/highlights.lua", ":p")
		vim.api.nvim_set_current_win(review_panel.state.diff_winid)
		vim.cmd("silent edit " .. vim.fn.fnameescape(full))
		T.drain_jobs(1000)

		T.assert_equals(review_panel.state.active_path,
			"lua/gitflow/highlights.lua",
			"active_path should be set by the autocmd, not just open_file")

		local bufnr = vim.api.nvim_get_current_buf()
		local marks = vim.api.nvim_buf_get_extmarks(
			bufnr, inline.DIFF_NS, 0, -1, { details = true }
		)
		T.assert_true(#marks > 0,
			"a file opened via :edit should receive diff annotations")

		-- And the review keymaps should be attached to that buffer.
		T.assert_keymaps(bufnr, { "c", "S", "<CR>", "]c", "[c" })

		cleanup_panels()
	end,

	["opening a non-diff file via :edit leaves it untouched"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		-- This file is NOT part of PR #42's diff, so the autocmd must skip it.
		local full = vim.fn.fnamemodify("README.md", ":p")
		if vim.fn.filereadable(full) == 1 then
			vim.api.nvim_set_current_win(review_panel.state.diff_winid)
			vim.cmd("silent edit " .. vim.fn.fnameescape(full))
			T.drain_jobs(500)

			local bufnr = vim.api.nvim_get_current_buf()
			local marks = vim.api.nvim_buf_get_extmarks(
				bufnr, inline.DIFF_NS, 0, -1, {}
			)
			T.assert_equals(#marks, 0,
				"a file outside the PR diff should not be annotated")
		end

		cleanup_panels()
	end,

	-- ── Thread discussion popup ────────────────────────────────────────

	["<CR> on a comment line opens the full discussion popup"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		-- Seed a remote thread (root + one reply) anchored to line 1.
		review_panel.state.comment_threads = {
			{
				id = 100,
				path = "lua/gitflow/highlights.lua",
				line = 1,
				comments = {
					{ id = 100, user = "alice", body = "root comment here" },
					{ id = 101, user = "bob",
						body = "this is the reply body",
						in_reply_to_id = 100 },
				},
			},
		}
		pcall(vim.api.nvim_win_set_cursor,
			review_panel.state.diff_winid, { 1, 0 })

		review_panel.view_thread_at_cursor()

		local win = require("gitflow.ui.window").get("gitflow_review_thread")
		T.assert_true(win ~= nil and vim.api.nvim_win_is_valid(win),
			"a thread popup window should open")
		local combined = table.concat(
			T.buf_lines(vim.api.nvim_win_get_buf(win)), "\n")
		T.assert_contains(combined, "root comment here",
			"popup should show the root comment")
		T.assert_contains(combined, "this is the reply body",
			"popup should show the reply body")
		T.assert_contains(combined, "@bob",
			"popup should attribute the reply author")

		pcall(vim.api.nvim_win_close, win, true)
		cleanup_panels()
	end,

	["<CR> on a line with no comment opens no popup"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		review_panel.state.comment_threads = {}
		pcall(vim.api.nvim_win_set_cursor,
			review_panel.state.diff_winid, { 1, 0 })

		review_panel.view_thread_at_cursor()

		local win = require("gitflow.ui.window").get("gitflow_review_thread")
		T.assert_true(win == nil,
			"no popup should open when the line has no comment")

		cleanup_panels()
	end,

	-- ── Comment workflow + persistence ─────────────────────────────────

	["inline_comment queues a draft and persists to cache"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		T.assert_equals(#review_panel.state.pending_comments, 0,
			"should start with no pending comments")

		-- Comments are only accepted on lines that are part of the PR diff,
		-- so anchor the cursor to a real new-side line from the parsed hunks.
		local fd = review_panel.state.file_diffs["lua/gitflow/highlights.lua"]
		local diff_line
		for _, h in ipairs(fd.hunks or {}) do
			for _, l in ipairs(h.lines or {}) do
				if l.new_line then
					diff_line = l.new_line
					break
				end
			end
			if diff_line then
				break
			end
		end
		T.assert_true(diff_line ~= nil,
			"fixture PR diff should expose a new-side line to comment on")

		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, on_confirm)
					on_confirm("First draft note")
				end,
			},
		}, function()
			-- Cursor must be in the diff pane for the helper to find the
			-- active line.
			vim.api.nvim_set_current_win(review_panel.state.diff_winid)
			vim.api.nvim_win_set_cursor(
				review_panel.state.diff_winid, { diff_line, 0 })

			review_panel.inline_comment()
			T.drain_jobs(2000)
		end)

		T.assert_equals(#review_panel.state.pending_comments, 1,
			"should have 1 pending comment after inline_comment")
		T.assert_equals(review_panel.state.pending_comments[1].body,
			"First draft note", "pending body should match input")

		local pr_number = review_panel.state.pr_number
		local repo_slug = review_panel.state.repo_slug
		local cached = cache.load(pr_number, repo_slug)
		T.assert_true(cached and type(cached.comments) == "table"
			and #cached.comments == 1,
			"cache should hold one comment after inline_comment")

		cache.clear(pr_number, repo_slug)
		cleanup_panels()
	end,

	["reopening a PR rehydrates pending comments from disk"] = function()
		-- Seed the cache directly, then open the PR and verify recovery.
		local repo_slug = cache.repo_slug()
		cache.save(99, {
			pr_number = 99,
			comments = {
				{
					id = 1,
					path = "lua/gitflow/highlights.lua",
					body = "Resumed after crash",
					new_line = 13,
					created_at = "2026-01-01T00:00:00Z",
				},
			},
		}, repo_slug)

		review_panel.open(cfg, 99)
		T.drain_jobs(5000)

		T.assert_equals(#review_panel.state.pending_comments, 1,
			"opening a PR should restore cached pending comments")
		T.assert_equals(review_panel.state.pending_comments[1].body,
			"Resumed after crash",
			"restored comment body should match cache")

		cache.clear(99, repo_slug)
		cleanup_panels()
	end,

	-- ── Approve / request-changes wiring ───────────────────────────────

	["review_approve calls gh pr review --approve with no pending"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		with_temp_gh_log(function(log_path)
			with_temporary_patches({
				{
					table = input,
					key = "prompt",
					value = function(_, on_confirm)
						on_confirm("LGTM")
					end,
				},
			}, function()
				review_panel.review_approve()
				T.drain_jobs(3000)
			end)

			local lines = T.read_file(log_path)
			local found_review, found_approve, found_body = false, false, false
			for _, line in ipairs(lines) do
				if line:find("pr review 42", 1, true) then
					found_review = true
				end
				if line:find("--approve", 1, true) then
					found_approve = true
				end
				if line:find("--body LGTM", 1, true) then
					found_body = true
				end
			end
			T.assert_true(found_review, "should call `pr review 42`")
			T.assert_true(found_approve, "should pass --approve")
			T.assert_true(found_body, "should include body LGTM")
		end)

		cleanup_panels()
	end,

	["approve with a pending comment batches via reviews API"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.state.pending_comments = {
			{
				id = 1,
				path = "lua/gitflow/highlights.lua",
				body = "Please refactor this",
				new_line = 13,
			},
		}

		with_temp_gh_log(function(log_path)
			with_temporary_patches({
				{
					table = input,
					key = "prompt",
					value = function(_, on_confirm)
						on_confirm("LGTM pending")
					end,
				},
			}, function()
				review_panel.review_approve()
				T.drain_jobs(3000)
			end)

			local lines = T.read_file(log_path)
			local found_reviews_api = false
			for _, line in ipairs(lines) do
				if line:find(
					"api repos/{owner}/{repo}/pulls/42/reviews",
					1, true
				) then
					found_reviews_api = true
				end
			end

			local payload = decode_logged_stdin_payload(lines)
			T.assert_true(found_reviews_api,
				"approve with pending should call reviews API")
			T.assert_true(payload ~= nil,
				"approve with pending should log JSON payload")
			T.assert_equals(payload.event, "APPROVE",
				"approve should map to APPROVE event")
			T.assert_true(
				type(payload.comments) == "table"
					and #payload.comments == 1,
				"payload should include one inline comment")
			T.assert_equals(payload.comments[1].path,
				"lua/gitflow/highlights.lua",
				"comment path should be preserved")
			T.assert_equals(payload.comments[1].line, 13,
				"comment line should be the new-side line")
			T.assert_equals(payload.comments[1].side, "RIGHT",
				"new-side comment should be RIGHT")
		end)

		T.assert_equals(#review_panel.state.pending_comments, 0,
			"successful submit should clear pending comments")

		cleanup_panels()
	end,

	-- ── Off-diff comment guard (prevents the 422 "Line could not be
	--    resolved" error) ────────────────────────────────────────────────

	["inline_comment on a non-diff line is rejected, not queued"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		-- Find a buffer line that is NOT part of the PR diff.
		local fd = review_panel.state.file_diffs["lua/gitflow/highlights.lua"]
		local in_diff = {}
		for _, h in ipairs(fd.hunks or {}) do
			for _, l in ipairs(h.lines or {}) do
				if l.new_line then
					in_diff[l.new_line] = true
				end
			end
		end
		local bufnr = review_panel.state.active_bufnr
		local n = vim.api.nvim_buf_line_count(bufnr)
		local off_line
		for i = 1, n do
			if not in_diff[i] then
				off_line = i
				break
			end
		end
		T.assert_true(off_line ~= nil, "should find an off-diff line")

		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, on_confirm)
					on_confirm("comment off the diff")
				end,
			},
		}, function()
			vim.api.nvim_set_current_win(review_panel.state.diff_winid)
			vim.api.nvim_win_set_cursor(
				review_panel.state.diff_winid, { off_line, 0 })
			review_panel.inline_comment()
			T.drain_jobs(1000)
		end)

		T.assert_equals(#review_panel.state.pending_comments, 0,
			"a comment on a non-diff line must not be queued")

		cleanup_panels()
	end,

	["submitting an out-of-diff comment is blocked, not sent to GitHub"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		-- A stale/bogus pending comment whose line is not in the diff.
		review_panel.state.pending_comments = {
			{
				id = 1,
				path = "lua/gitflow/highlights.lua",
				body = "stale comment",
				new_line = 999999,
			},
		}

		with_temp_gh_log(function(log_path)
			with_temporary_patches({
				{
					table = input,
					key = "prompt",
					value = function(_, on_confirm)
						on_confirm("LGTM")
					end,
				},
			}, function()
				review_panel.review_approve()
				T.drain_jobs(3000)
			end)

			local lines = T.read_file(log_path)
			local called_reviews_api = false
			for _, line in ipairs(lines) do
				if line:find(
					"api repos/{owner}/{repo}/pulls/42/reviews", 1, true
				) then
					called_reviews_api = true
				end
			end
			T.assert_false(called_reviews_api,
				"an unresolvable comment must block the API call")
		end)

		T.assert_equals(#review_panel.state.pending_comments, 1,
			"blocked submit should keep the pending comment for fixing")

		cleanup_panels()
	end,

	-- ── Drafts section in the file-list pane ───────────────────────────

	["file-list pane lists drafts and flags off-diff ones"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		-- One in-scope draft (line 13 is in the fixture diff) and one off-diff.
		review_panel.state.pending_comments = {
			{ id = 1, path = "lua/gitflow/highlights.lua",
				body = "valid draft", new_line = 13 },
			{ id = 2, path = "lua/gitflow/highlights.lua",
				body = "stale draft", new_line = 999999 },
		}
		-- Re-render the file list now that drafts exist.
		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		local lines = T.buf_lines(review_panel.state.file_list_bufnr)
		local combined = table.concat(lines, "\n")
		T.assert_contains(combined, "Drafts (2)",
			"file-list should show a Drafts section with the count")
		T.assert_contains(combined, "✗1 off-diff",
			"header should report the off-diff draft count")
		T.assert_true(
			review_panel.state._draft_line_map ~= nil
				and next(review_panel.state._draft_line_map) ~= nil,
			"a draft line map should be populated")

		cleanup_panels()
	end,

	["delete_off_diff_drafts removes only out-of-scope drafts"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")
		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		review_panel.state.pending_comments = {
			{ id = 1, path = "lua/gitflow/highlights.lua",
				body = "valid", new_line = 13 },
			{ id = 2, path = "lua/gitflow/highlights.lua",
				body = "stale", new_line = 999999 },
		}

		with_temporary_patches({
			{ table = input, key = "confirm",
				value = function() return true, 1 end },
		}, function()
			review_panel.delete_off_diff_drafts()
		end)

		T.assert_equals(#review_panel.state.pending_comments, 1,
			"only the off-diff draft should be removed")
		T.assert_equals(review_panel.state.pending_comments[1].new_line, 13,
			"the in-scope draft should remain")

		-- delete_off_diff_drafts persists the survivor to disk; clear it so
		-- later tests that open PR #42 don't rehydrate a stray draft.
		cache.clear(review_panel.state.pr_number, review_panel.state.repo_slug)
		cleanup_panels()
	end,

	["inline_comment anchors to the diff-window file, not stale active_path"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		-- Open file A, remember its buffer, then open file B (active_path = B).
		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)
		local hl_buf = review_panel.state.active_bufnr
		review_panel.open_file("lua/gitflow/config.lua")
		T.drain_jobs(1000)
		T.assert_equals(review_panel.state.active_path,
			"lua/gitflow/config.lua", "active_path should be B after open")

		-- Simulate switching the diff window back to A WITHOUT open_file
		-- (e.g. Telescope/:bnext): the bug saved the comment against B.
		vim.api.nvim_win_set_buf(review_panel.state.diff_winid, hl_buf)

		with_temporary_patches({
			{ table = input, key = "prompt",
				value = function(_, on_confirm) on_confirm("note on A") end },
		}, function()
			vim.api.nvim_set_current_win(review_panel.state.diff_winid)
			vim.api.nvim_win_set_cursor(
				review_panel.state.diff_winid, { 13, 0 })
			review_panel.inline_comment()
			T.drain_jobs(1000)
		end)

		T.assert_equals(#review_panel.state.pending_comments, 1,
			"comment should be queued")
		T.assert_equals(review_panel.state.pending_comments[1].path,
			"lua/gitflow/highlights.lua",
			"comment must anchor to the file shown in the diff window (A), "
				.. "not the stale active_path (B)")
		T.assert_equals(review_panel.state.pending_comments[1].new_line, 13,
			"line should come from the same file")

		cache.clear(review_panel.state.pr_number, review_panel.state.repo_slug)
		cleanup_panels()
	end,

	["request changes submits with --request-changes flag"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		with_temp_gh_log(function(log_path)
			with_temporary_patches({
				{
					table = input,
					key = "prompt",
					value = function(_, on_confirm)
						on_confirm("Please fix this")
					end,
				},
			}, function()
				review_panel.review_request_changes()
				T.drain_jobs(3000)
			end)

			local lines = T.read_file(log_path)
			local found_request = false
			for _, line in ipairs(lines) do
				if line:find("--request-changes", 1, true) then
					found_request = true
				end
			end
			T.assert_true(found_request,
				"request_changes should pass --request-changes")
		end)

		cleanup_panels()
	end,

	-- ── Close cleans up tabpage and clears state ───────────────────────

	["close removes the tabpage and resets state"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local tab = review_panel.state.tabpage
		T.assert_true(vim.api.nvim_tabpage_is_valid(tab),
			"tab should be valid before close")

		review_panel.close()

		T.assert_false(review_panel.is_open(),
			"review panel should be closed")
		T.assert_true(review_panel.state.pr_number == nil,
			"pr_number should be nil after close")
		T.assert_true(review_panel.state.tabpage == nil,
			"tabpage should be nil after close")
		T.assert_deep_equals(review_panel.state.pending_comments, {},
			"pending_comments should be empty after close")

		T.cleanup_panels()
	end,

	["close_with_guard prompts when pending comments exist"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		review_panel.state.pending_comments = {
			{
				id = 1,
				path = "lua/gitflow/highlights.lua",
				body = "Draft",
				new_line = 13,
			},
		}

		local confirm_message = nil
		with_temporary_patches({
			{
				table = input,
				key = "confirm",
				value = function(msg, _)
					confirm_message = msg
					return true, 1
				end,
			},
		}, function()
			review_panel.close_with_guard()
		end)

		T.assert_true(confirm_message ~= nil,
			"close_with_guard should prompt when drafts exist")
		T.assert_contains(confirm_message, "1 pending",
			"confirm should mention pending count")
		T.assert_false(review_panel.is_open(),
			"review should be closed after confirm")

		cleanup_panels()
	end,

	["close_with_guard does NOT close on cancel"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		review_panel.state.pending_comments = {
			{
				id = 1,
				path = "lua/gitflow/highlights.lua",
				body = "Draft",
				new_line = 13,
			},
		}

		with_temporary_patches({
			{
				table = input,
				key = "confirm",
				value = function(_, _) return false, 2 end,
			},
		}, function()
			review_panel.close_with_guard()
		end)

		T.assert_true(review_panel.is_open(),
			"review should stay open after user cancels")

		cleanup_panels()
	end,

	-- ── Toggle command path ────────────────────────────────────────────

	["toggle on an open review closes it"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.assert_true(review_panel.is_open(),
			"review should be open before toggle")

		review_panel.toggle(cfg)
		T.drain_jobs(500)

		T.assert_false(review_panel.is_open(),
			"toggle on an open review should close it")

		T.cleanup_panels()
	end,

	-- ── #359: next/prev file keybinds in the diff pane ─────────────────

	["diff pane has ]f/[f next/prev file keybinds"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		-- The diff-pane buffer should let you jump files without going back
		-- to the file list (issue #359).
		T.assert_keymaps(review_panel.state.active_bufnr, { "]f", "[f" })

		cleanup_panels()
	end,

	["next_file and prev_file walk the file list and wrap"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 1
		end, "at least two files should be populated after open")

		local files = review_panel.state.files
		review_panel.open_file(files[1].path)
		T.drain_jobs(1000)
		T.assert_equals(review_panel.state.active_file_idx, 1,
			"opening the first file should make it active")

		review_panel.next_file()
		T.drain_jobs(1000)
		T.assert_equals(review_panel.state.active_path, files[2].path,
			"]f should open the next file in the list")

		review_panel.prev_file()
		T.drain_jobs(1000)
		T.assert_equals(review_panel.state.active_path, files[1].path,
			"[f should go back to the previous file")

		review_panel.prev_file()
		T.drain_jobs(1000)
		T.assert_equals(review_panel.state.active_path, files[#files].path,
			"[f on the first file should wrap to the last")

		cleanup_panels()
	end,

	-- ── #357: toggle the diff overlay on/off ───────────────────────────

	["toggle_diff_view hides and restores diff annotations"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)
		local bufnr = review_panel.state.active_bufnr

		local function diff_mark_count()
			return #vim.api.nvim_buf_get_extmarks(
				bufnr, inline.DIFF_NS, 0, -1, {})
		end

		T.assert_true(diff_mark_count() > 0,
			"diff annotations should be present initially")

		review_panel.toggle_diff_view()
		T.drain_jobs(1000)
		T.assert_false(review_panel.state.show_diff,
			"show_diff should be false after toggling off")
		T.assert_equals(diff_mark_count(), 0,
			"diff annotations should be cleared when the diff view is hidden")

		review_panel.toggle_diff_view()
		T.drain_jobs(1000)
		T.assert_true(review_panel.state.show_diff,
			"show_diff should be true after toggling back on")
		T.assert_true(diff_mark_count() > 0,
			"diff annotations should be restored when toggled back on")

		cleanup_panels()
	end,

	["file list names the active view layer while the diff is hidden"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		local function file_list_text()
			return table.concat(
				T.buf_lines(review_panel.state.file_list_bufnr), "\n")
		end

		T.assert_false(file_list_text():find("view: full file", 1, true) ~= nil,
			"the diff view is the default and needs no marker")

		review_panel.toggle_diff_view()
		T.drain_jobs(1000)
		T.assert_contains(file_list_text(), "view: full file",
			"the file list should name the full-file layer while it is active")

		review_panel.toggle_diff_view()
		T.drain_jobs(1000)
		T.assert_false(file_list_text():find("view: full file", 1, true) ~= nil,
			"the marker should disappear when the diff view comes back")

		cleanup_panels()
	end,

	-- ── #366: review mode tears itself down completely ─────────────────

	["close restores the winbar it replaced and drops review keymaps"] = function()
		local outside_win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_option_value("winbar", "USER BAR",
			{ win = outside_win })

		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		local diff_winid = review_panel.state.diff_winid
		local bufnr = review_panel.state.active_bufnr
		T.assert_contains(
			vim.api.nvim_get_option_value("winbar", { win = diff_winid }),
			"PR REVIEW", "the diff pane should carry the review banner")
		T.assert_keymaps(bufnr, { "c", "]f", "]C" })

		review_panel.close()
		T.drain_jobs(500)

		T.assert_false(vim.api.nvim_win_is_valid(diff_winid),
			"the review windows should be gone after close")
		T.assert_equals(#vim.api.nvim_buf_get_keymap(bufnr, "n"), 0,
			"review keymaps must not outlive review mode")
		T.assert_equals(
			vim.api.nvim_get_option_value("winbar", { win = outside_win }),
			"USER BAR",
			"review mode must not clobber the user's own winbar")

		vim.api.nvim_set_option_value("winbar", "", { win = outside_win })
		T.cleanup_panels()
	end,

	["closing the file list window directly ends review mode"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		local diff_winid = review_panel.state.diff_winid
		local bufnr = review_panel.state.active_bufnr

		-- Abnormal exit: the user closes a review window by hand (:q) instead
		-- of pressing q in the file list.
		pcall(vim.api.nvim_win_close, review_panel.state.file_list_winid, true)
		T.wait_until(function()
			return not review_panel.is_open()
		end, "review mode should end when its layout is dismantled")

		T.assert_equals(
			vim.api.nvim_get_option_value("winbar", { win = diff_winid }), "",
			"the review title bar must not survive review mode (#366)")
		T.assert_equals(#vim.api.nvim_buf_get_keymap(bufnr, "n"), 0,
			"review keymaps must not survive an abnormal close")
		T.assert_equals(review_panel.state.pr_number, nil,
			"review state should be reset after an abnormal close")

		pcall(vim.api.nvim_win_close, diff_winid, true)
		T.cleanup_panels()
	end,

	-- ── Stale-response and retry safety ────────────────────────────────

	["a superseded PR load never writes into the current review"] = function()
		local deferred = {}
		local ok_result =
			{ code = 0, signal = 0, stdout = "", stderr = "", cmd = {} }

		with_temporary_patches({
			{ table = gh_prs, key = "view",
				value = function(number, _, cb)
					deferred[#deferred + 1] = function()
						cb(nil, {
							title = "PR " .. number,
							author = { login = "octocat" },
							headRefName = "head", baseRefName = "main",
						}, ok_result)
					end
				end },
			{ table = gh_prs, key = "list_files",
				value = function(number, _, cb)
					deferred[#deferred + 1] = function()
						cb(nil, { {
							filename = ("pr_%s.lua"):format(number),
							status = "modified", additions = 1, deletions = 0,
							patch = "@@ -1 +1 @@\n-a\n+b",
						} }, ok_result)
					end
				end },
			{ table = gh_prs, key = "review_comments",
				value = function(number, _, cb)
					deferred[#deferred + 1] = function()
						cb(nil, { {
							id = number, path = ("pr_%s.lua"):format(number),
							line = 1, body = ("comment from PR %s"):format(number),
							user = { login = "someone" },
						} }, ok_result)
					end
				end },
		}, function()
			local function run_next()
				local fn = table.remove(deferred, 1)
				T.assert_true(fn ~= nil, "a deferred gh response should exist")
				fn()
			end

			-- PR 42's metadata and files land, its comments are still in flight.
			review_panel.open(cfg, 42)
			run_next()
			run_next()
			local stale_comments = table.remove(deferred, 1)
			T.assert_true(stale_comments ~= nil,
				"PR 42's comment request should be in flight")

			-- The user switches to PR 99 before PR 42 finishes loading.
			review_panel.open(cfg, 99)
			while #deferred > 0 do
				run_next()
			end
			T.assert_equals(review_panel.state.pr_number, 99,
				"the review should now be showing PR 99")
			T.assert_equals(#review_panel.state.comment_threads, 1,
				"PR 99's own comments should have loaded")

			-- PR 42's response finally arrives; it must be discarded.
			stale_comments()

			T.assert_equals(
				review_panel.state.comment_threads[1].comments[1].body,
				"comment from PR 99",
				"a superseded PR's comments must not be spliced into the view")
		end)

		cleanup_panels()
	end,

	["retrying a failed submit does not repost file comments"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local path = "lua/gitflow/highlights.lua"
		review_panel.state.pr_head_sha = "deadbeef"
		review_panel.state.pending_comments = {
			{ id = 1, path = path, body = "file note A", file_level = true },
			{ id = 2, path = path, body = "file note B", file_level = true },
		}

		local posted = {}
		local submit_fails = true
		local function failing_submit(...)
			local cb = select(select("#", ...), ...)
			cb(submit_fails and "submit failed" or nil)
		end

		with_temporary_patches({
			{ table = gh_prs, key = "create_file_comment",
				value = function(_, _, _, body, _, cb)
					posted[#posted + 1] = body
					cb(nil, { code = 0 })
				end },
			{ table = gh_prs, key = "review", value = failing_submit },
			{ table = gh_prs, key = "submit_review", value = failing_submit },
		}, function()
			review_panel.submit_review_direct("comment", "please look")
			T.drain_jobs(1000)

			T.assert_equals(#posted, 2,
				"both file comments should reach GitHub before the failure")
			T.assert_equals(#review_panel.state.pending_comments, 2,
				"a failed submit must not discard the drafts")

			-- The user retries once the cause is fixed.
			submit_fails = false
			review_panel.submit_review_direct("comment", "please look")
			T.drain_jobs(1000)

			T.assert_equals(#posted, 2,
				"a retry must not post the file comments a second time")
		end)

		cleanup_panels()
	end,

	-- ── #360: whole comment threads, not just the first comment ────────

	["review comment replies are grouped into a single thread"] = function()
		with_temporary_patches({
			{ table = gh_prs, key = "review_comments",
				value = function(_, _, cb)
					cb(nil, {
						{ id = 1, path = "lua/gitflow/highlights.lua", line = 13,
							body = "root", user = { login = "alice" } },
						{ id = 2, path = "lua/gitflow/highlights.lua", line = 13,
							body = "reply to root", in_reply_to_id = 1,
							user = { login = "bob" } },
						-- GitHub can point a reply at another reply; it still
						-- belongs to the same discussion.
						{ id = 3, path = "lua/gitflow/highlights.lua", line = 13,
							body = "reply to reply", in_reply_to_id = 2,
							user = { login = "carol" } },
					}, { code = 0, signal = 0, stdout = "", stderr = "", cmd = {} })
				end },
		}, function()
			review_panel.open(cfg, 42)
			T.drain_jobs(5000)
			T.wait_until(function()
				return #review_panel.state.comment_threads > 0
			end, "comment threads should be built from the review comments")
		end)

		T.assert_equals(#review_panel.state.comment_threads, 1,
			"chained replies should not spawn extra threads")
		T.assert_equals(#review_panel.state.comment_threads[1].comments, 3,
			"the thread should hold the root comment and both replies")

		cleanup_panels()
	end,

	["toggle_thread folds the replies out under the first comment"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local path = "lua/gitflow/highlights.lua"
		review_panel.state.comment_threads = {
			{ id = 7, path = path, line = 13, collapsed = false, comments = {
				{ id = 7, path = path, line = 13,
					body = "root comment", user = "alice" },
				{ id = 8, path = path, line = 13,
					body = "a follow up reply", user = "bob" },
			} },
		}
		review_panel.open_file(path)
		T.drain_jobs(1000)

		local bufnr = review_panel.state.active_bufnr
		local function comment_box_text()
			local marks = vim.api.nvim_buf_get_extmarks(
				bufnr, inline.COMMENT_NS, 0, -1, { details = true })
			local out = {}
			for _, mark in ipairs(marks) do
				for _, virt_line in ipairs(mark[4].virt_lines or {}) do
					for _, chunk in ipairs(virt_line) do
						out[#out + 1] = chunk[1]
					end
				end
			end
			return table.concat(out, "")
		end

		T.assert_contains(comment_box_text(), "root comment",
			"the first comment should render inline")
		T.assert_false(
			comment_box_text():find("a follow up reply", 1, true) ~= nil,
			"replies stay hidden until the thread is folded out")

		vim.api.nvim_win_set_cursor(review_panel.state.diff_winid, { 13, 0 })
		review_panel.toggle_thread()
		T.drain_jobs(500)

		T.assert_true(review_panel.state.expanded_threads[7] == true,
			"toggle_thread should mark the thread expanded")
		T.assert_contains(comment_box_text(), "a follow up reply",
			"the reply should render inline once the thread is folded out")
		T.assert_contains(comment_box_text(), "@bob",
			"each folded-out reply should be attributed to its author")

		review_panel.toggle_thread()
		T.drain_jobs(500)
		T.assert_false(
			comment_box_text():find("a follow up reply", 1, true) ~= nil,
			"toggling again should fold the thread back up")

		cleanup_panels()
	end,

	-- ── #382: jump to next comment + overview of all comments ──────────

	["diff pane has ]C/[C and the comments overview keybind"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		-- Keymaps are recorded with <leader> already expanded.
		local overview = (vim.g.mapleader or "\\") .. "c"
		T.assert_keymaps(review_panel.state.active_bufnr,
			{ "]C", "[C", overview })
		T.assert_keymaps(review_panel.state.file_list_bufnr,
			{ "]C", "[C", overview })

		cleanup_panels()
	end,

	["comments_overview lists every comment and jumps to the chosen one"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local path = "lua/gitflow/highlights.lua"
		review_panel.state.comment_threads = {
			{ id = 7, path = path, line = 13, collapsed = false, comments = {
				{ id = 7, path = path, line = 13,
					body = "please rename this", user = "alice" },
			} },
		}
		review_panel.state.pending_comments = {
			{ id = 1, path = path, body = "my own note", new_line = 14 },
		}

		local opened
		with_temporary_patches({
			{ table = list_picker, key = "open",
				value = function(opts)
					opened = opts
					return {}
				end },
		}, function()
			review_panel.comments_overview()
		end)

		T.assert_true(opened ~= nil, "the overview should open a picker")
		T.assert_equals(#opened.items, 2,
			"the overview should list the remote thread and the draft")
		T.assert_contains(opened.items[1].description, "please rename this",
			"each row should preview its comment")
		T.assert_false(opened.multi_select,
			"the overview picks a single comment to jump to")

		-- Selecting a row jumps the diff pane to that comment.
		opened.on_submit({ opened.items[2].name })
		T.drain_jobs(1000)
		T.assert_equals(review_panel.state.active_path, path,
			"selecting a comment should open its file")
		T.assert_equals(
			vim.api.nvim_win_get_cursor(review_panel.state.diff_winid)[1], 14,
			"selecting a comment should put the cursor on its line")

		cleanup_panels()
	end,

	-- ── #358: edit a draft comment ─────────────────────────────────────

	["edit_draft updates the body and persists to cache"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.state.pending_comments = {
			{ id = 1, path = "lua/gitflow/highlights.lua",
				body = "original body", new_line = 13 },
		}

		with_temporary_patches({
			{ table = input, key = "prompt",
				value = function(opts, on_confirm)
					-- The edit prompt should pre-fill the existing body.
					T.assert_equals(opts.default, "original body",
						"edit prompt should default to the current body")
					on_confirm("corrected body")
				end },
		}, function()
			review_panel.edit_draft(review_panel.state.pending_comments[1])
			T.drain_jobs(1000)
		end)

		T.assert_equals(review_panel.state.pending_comments[1].body,
			"corrected body", "edit_draft should update the draft body")

		local cached = cache.load(review_panel.state.pr_number,
			review_panel.state.repo_slug)
		T.assert_true(cached and cached.comments
			and cached.comments[1]
			and cached.comments[1].body == "corrected body",
			"edited body should be persisted to the cache")

		cache.clear(review_panel.state.pr_number, review_panel.state.repo_slug)
		cleanup_panels()
	end,

	-- ── #361: file-level comments (incl. deleted files) ────────────────

	["file_comment queues a file-level draft with no line"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		with_temporary_patches({
			{ table = input, key = "prompt",
				value = function(_, on_confirm)
					on_confirm("comment about the whole file")
				end },
		}, function()
			review_panel.file_comment("lua/gitflow/config.lua")
			T.drain_jobs(1000)
		end)

		T.assert_equals(#review_panel.state.pending_comments, 1,
			"a file-level comment should be queued")
		local pc = review_panel.state.pending_comments[1]
		T.assert_true(pc.file_level == true,
			"queued comment should be marked file_level")
		T.assert_true(pc.new_line == nil and pc.old_line == nil,
			"a file-level comment should carry no line anchor")

		cache.clear(review_panel.state.pr_number, review_panel.state.repo_slug)
		cleanup_panels()
	end,

	["edit_draft_under_cursor edits a file comment from the file row"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		-- A line comment (not file-level) — editing from the file row should
		-- still work, picking the file's single draft.
		review_panel.state.pending_comments = {
			{ id = 1, path = "lua/gitflow/config.lua",
				body = "file note v1", new_line = 13 },
		}
		-- Repaint so the file tree + file_line_map exist.
		review_panel.open_file("lua/gitflow/config.lua")
		T.drain_jobs(1000)

		-- Put the cursor on the config.lua *file* row (not the Drafts row).
		local file_row
		for line, idx in pairs(review_panel.state._file_line_map or {}) do
			if review_panel.state.files[idx]
				and review_panel.state.files[idx].path == "lua/gitflow/config.lua" then
				file_row = line
			end
		end
		T.assert_true(file_row ~= nil, "config.lua file row should be mapped")
		vim.api.nvim_set_current_win(review_panel.state.file_list_winid)
		vim.api.nvim_win_set_cursor(
			review_panel.state.file_list_winid, { file_row, 0 })

		with_temporary_patches({
			{ table = input, key = "prompt",
				value = function(opts, on_confirm)
					T.assert_equals(opts.default, "file note v1",
						"edit should pre-fill the existing file-comment body")
					on_confirm("file note v2")
				end },
		}, function()
			review_panel.edit_draft_under_cursor()
			T.drain_jobs(1000)
		end)

		T.assert_equals(review_panel.state.pending_comments[1].body,
			"file note v2",
			"a file comment should be editable from its file row")

		cache.clear(review_panel.state.pr_number, review_panel.state.repo_slug)
		cleanup_panels()
	end,

	["file-level comment posts via comments API with subject_type=file"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")
		-- headRefOid from the PR view fixture supplies the commit_id.
		T.wait_until(function()
			return review_panel.state.pr_head_sha ~= nil
		end, "pr_head_sha should be populated from headRefOid")

		review_panel.state.pending_comments = {
			{ id = 1, path = "lua/gitflow/config.lua",
				body = "whole-file note", file_level = true },
		}

		with_temp_gh_log(function(log_path)
			with_temporary_patches({
				{ table = input, key = "prompt",
					value = function(_, on_confirm) on_confirm("LGTM") end },
			}, function()
				review_panel.review_approve()
				T.drain_jobs(3000)
			end)

			local lines = T.read_file(log_path)
			-- File comment must go to the review-comments endpoint (NOT the
			-- reviews batch API, which would 422 on a comment with no line).
			local posted_file_comment, has_subject_type, has_commit_id = false, false, false
			for _, line in ipairs(lines) do
				if line:find("api repos/{owner}/{repo}/pulls/42/comments", 1, true)
					and line:find("--method POST", 1, true) then
					posted_file_comment = true
					if line:find("subject_type=file", 1, true) then
						has_subject_type = true
					end
					if line:find("commit_id=", 1, true) then
						has_commit_id = true
					end
				end
			end
			T.assert_true(posted_file_comment,
				"file comment should POST to the review-comments API")
			T.assert_true(has_subject_type,
				"file comment should pass subject_type=file")
			T.assert_true(has_commit_id,
				"file comment should pass a commit_id")

			-- And it must NOT appear in the reviews-batch payload.
			local payload = decode_logged_stdin_payload(lines)
			if payload and type(payload.comments) == "table" then
				T.assert_equals(#payload.comments, 0,
					"file comment must not be sent in the reviews batch payload")
			end
		end)

		cleanup_panels()
	end,

	-- ── #355: comment on a deleted (LEFT-side) line ────────────────────

	["comment on a deleted line anchors to old_line (LEFT side)"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		review_panel.open_file("lua/gitflow/highlights.lua")
		T.drain_jobs(1000)

		-- After opening, deleted lines are indexed by the buffer row they
		-- render next to (#355).  Pick one and place the cursor there.
		local anchor = next(review_panel.state.deleted_anchors)
		T.assert_true(anchor ~= nil,
			"the fixture diff should expose at least one deleted-line anchor")

		with_temporary_patches({
			{ table = input, key = "prompt",
				value = function(_, on_confirm)
					on_confirm("note on a removed line")
				end },
			{ table = vim.ui, key = "select",
				value = function(items, _, on_choice)
					-- Choose the deleted-line target when offered a choice.
					for _, it in ipairs(items) do
						if it.target and it.target.old_line
							and not it.target.new_line then
							on_choice(it)
							return
						end
					end
					on_choice(items[1])
				end },
		}, function()
			vim.api.nvim_set_current_win(review_panel.state.diff_winid)
			vim.api.nvim_win_set_cursor(
				review_panel.state.diff_winid, { anchor, 0 })
			review_panel.inline_comment()
			T.drain_jobs(1000)
		end)

		local found_del = false
		for _, pc in ipairs(review_panel.state.pending_comments) do
			if pc.old_line and not pc.new_line then
				found_del = true
			end
		end
		T.assert_true(found_del,
			"commenting on a deleted line should queue an old_line/LEFT draft")

		cache.clear(review_panel.state.pr_number, review_panel.state.repo_slug)
		cleanup_panels()
	end,

	-- ── #363: scope review to a commit range via a local git diff ───────

	["apply_commit_scope builds files from a local git diff"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)
		T.wait_until(function()
			return #review_panel.state.files > 0
		end, "files should be populated after open")

		local git = require("gitflow.git")
		local canned = table.concat({
			"diff --git a/foo.lua b/foo.lua",
			"index 1111111..2222222 100644",
			"--- a/foo.lua",
			"+++ b/foo.lua",
			"@@ -1,3 +1,3 @@",
			" local a = 1",
			"-local b = 2",
			"+local b = 3",
			" local c = 4",
		}, "\n")

		with_temporary_patches({
			{ table = git, key = "git",
				value = function(args, _, cb)
					cb({
						code = 0, signal = 0,
						stdout = canned, stderr = "",
						cmd = args,
					})
				end },
		}, function()
			review_panel.apply_commit_scope("abc123^", "def456", "abc123..def456")
			T.drain_jobs(1000)
		end)

		T.assert_true(review_panel.state.commit_scope ~= nil
			and review_panel.state.commit_scope.label == "abc123..def456",
			"commit_scope should be recorded with its label")
		T.assert_equals(#review_panel.state.files, 1,
			"the scoped file list should come from the local git diff")
		T.assert_equals(review_panel.state.files[1].path, "foo.lua",
			"scoped file path should match the diff")
		local fd = review_panel.state.file_diffs["foo.lua"]
		T.assert_true(fd ~= nil and fd.hunks and #fd.hunks > 0,
			"scoped file should have parsed hunks")

		review_panel.state.commit_scope = nil
		cleanup_panels()
	end,
})

print("E2E PR review mode tests passed")
