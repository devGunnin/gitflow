-- tests/e2e/pr_review_spec.lua — PR review flow E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/pr_review_spec.lua
--
-- Verifies:
--   1. Review panel opens and renders diff content
--   2. File navigation with ]f/[f
--   3. Hunk navigation with ]c/[c
--   4. Inline comment addition (c key)
--   5. Review submission as approve (a key)
--   6. Review submission as request-changes (x key)
--   7. Review stub invoked with correct body and event
--   8. UI reflects success/failure states
--   9. Thread reply (R key)
--  10. Thread collapse toggle (<leader>t)

local T = _G.T
local cfg = _G.TestConfig

local ui = require("gitflow.ui")
local gh_prs = require("gitflow.gh.prs")
local input = require("gitflow.ui.input")
local utils = require("gitflow.utils")
local review_panel = require("gitflow.panels.review")

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

-- Compatibility helper for merge-ref runs where newer base-only tests may
-- still call cleanup_panels() in this file.
local function cleanup_panels()
	T.cleanup_panels()
end

T.run_suite("E2E: PR Review Flow", {

	-- ── Review panel opens and loads diff ─────────────────────────────

	["review panel opens via :Gitflow pr review"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_true(
			review_panel.is_open(),
			"review panel should be open"
		)
		T.assert_equals(
			review_panel.state.pr_number,
			42,
			"review panel should track PR number 42"
		)

		local bufnr = ui.buffer.get("review")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"review buffer should exist"
		)

		T.cleanup_panels()
	end,

	-- ── Review panel renders diff content ─────────────────────────────

	["review panel renders diff content from stub"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local bufnr = ui.buffer.get("review")
		T.assert_true(
			bufnr ~= nil,
			"review buffer should exist"
		)

		local lines = T.buf_lines(bufnr)
		local combined = table.concat(lines, "\n")

		T.assert_true(
			combined:find("diff %-%-git", 1, false) ~= nil,
			"review buffer should contain diff header"
		)
		T.assert_true(
			combined:find("highlights.lua", 1, true) ~= nil,
			"review buffer should contain filename from diff"
		)

		T.cleanup_panels()
	end,

	-- ── Review panel renders file/hunk summary ────────────────────────

	["review panel shows files and hunks summary"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local bufnr = ui.buffer.get("review")
		local lines = T.buf_lines(bufnr)

		T.assert_true(
			T.find_line(lines, "Files:") ~= nil,
			"review panel should show Files count"
		)
		T.assert_true(
			T.find_line(lines, "Hunks:") ~= nil,
			"review panel should show Hunks count"
		)

		T.cleanup_panels()
	end,

	-- ── File markers populated ────────────────────────────────────────

	["review panel populates file markers"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_true(
			#review_panel.state.file_markers >= 2,
			("expected >= 2 file markers, got %d"):format(
				#review_panel.state.file_markers
			)
		)

		-- Verify marker paths match fixture diff
		local paths = {}
		for _, m in ipairs(review_panel.state.file_markers) do
			paths[#paths + 1] = m.path
		end
		T.assert_true(
			T.contains(paths, "lua/gitflow/highlights.lua"),
			"file markers should include highlights.lua"
		)
		T.assert_true(
			T.contains(paths, "lua/gitflow/config.lua"),
			"file markers should include config.lua"
		)

		T.cleanup_panels()
	end,

	-- ── Hunk markers populated ────────────────────────────────────────

	["review panel populates hunk markers"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_true(
			#review_panel.state.hunk_markers >= 2,
			("expected >= 2 hunk markers, got %d"):format(
				#review_panel.state.hunk_markers
			)
		)

		T.cleanup_panels()
	end,

	-- ── Review panel keymaps are set ──────────────────────────────────

	["review panel has expected keymaps"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local bufnr = ui.buffer.get("review")
		T.assert_true(
			bufnr ~= nil,
			"review buffer should exist"
		)

		T.assert_keymaps(bufnr, {
			"]f", "[f", "]c", "[c",
			"c", "S", "a", "x",
			"R", "r", "q",
		})

		local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
		local leader_toggle = vim.api.nvim_replace_termcodes(
			"<leader>t", true, false, true
		)
		local has_leader_toggle = false
		for _, map in ipairs(keymaps) do
			if map.lhs == leader_toggle then
				has_leader_toggle = true
				break
			end
		end
		T.assert_true(
			has_leader_toggle,
			"review panel should map <leader>t for thread toggle"
		)

		T.cleanup_panels()
	end,

	-- ── File navigation with ]f/[f ────────────────────────────────────

	["file navigation ]f jumps to next file marker"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local winid = review_panel.state.winid
		T.assert_true(
			winid ~= nil and vim.api.nvim_win_is_valid(winid),
			"review window should be valid"
		)

		-- Start at line 1
		vim.api.nvim_win_set_cursor(winid, { 1, 0 })

		-- Jump forward
		review_panel.next_file()

		local cursor = vim.api.nvim_win_get_cursor(winid)
		T.assert_true(
			cursor[1] > 1,
			"cursor should have moved forward on ]f"
		)

		-- Should be on a file marker line
		local on_marker = false
		for _, m in ipairs(review_panel.state.file_markers) do
			if m.line == cursor[1] then
				on_marker = true
				break
			end
		end
		T.assert_true(
			on_marker,
			"cursor should be on a file marker line after ]f"
		)

		T.cleanup_panels()
	end,

	["file navigation [f jumps to previous file marker"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local winid = review_panel.state.winid
		T.assert_true(
			winid ~= nil and vim.api.nvim_win_is_valid(winid),
			"review window should be valid"
		)

		-- Go to the last file marker first
		local last_marker = review_panel.state.file_markers[
			#review_panel.state.file_markers
		]
		T.assert_true(
			last_marker ~= nil,
			"should have file markers"
		)
		vim.api.nvim_win_set_cursor(winid, { last_marker.line, 0 })

		-- Jump backward
		review_panel.prev_file()

		local cursor = vim.api.nvim_win_get_cursor(winid)
		T.assert_true(
			cursor[1] < last_marker.line,
			"cursor should move backward on [f"
		)

		T.cleanup_panels()
	end,

	-- ── Hunk navigation with ]c/[c ────────────────────────────────────

	["hunk navigation ]c jumps to next hunk marker"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local winid = review_panel.state.winid
		vim.api.nvim_win_set_cursor(winid, { 1, 0 })

		review_panel.next_hunk()

		local cursor = vim.api.nvim_win_get_cursor(winid)
		local on_hunk = false
		for _, h in ipairs(review_panel.state.hunk_markers) do
			if h.line == cursor[1] then
				on_hunk = true
				break
			end
		end
		T.assert_true(
			on_hunk,
			"cursor should be on a hunk marker line after ]c"
		)

		T.cleanup_panels()
	end,

	["hunk navigation [c wraps to last hunk from first"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_true(
			#review_panel.state.hunk_markers >= 2,
			"need at least 2 hunk markers for wrap test"
		)

		local winid = review_panel.state.winid
		local first_hunk = review_panel.state.hunk_markers[1]
		vim.api.nvim_win_set_cursor(winid, { first_hunk.line, 0 })

		-- Navigate backward from first hunk - should wrap to last
		review_panel.prev_hunk()

		local cursor = vim.api.nvim_win_get_cursor(winid)
		local last_hunk = review_panel.state.hunk_markers[
			#review_panel.state.hunk_markers
		]
		T.assert_equals(
			cursor[1],
			last_hunk.line,
			"[c from first hunk should wrap to last hunk"
		)

		T.cleanup_panels()
	end,

	-- ── Inline comment (c key) ────────────────────────────────────────

	["inline comment c adds pending comment"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_equals(
			#review_panel.state.pending_comments,
			0,
			"should start with no pending comments"
		)

		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, on_confirm)
					on_confirm("Test inline comment")
				end,
			},
		}, function()
			-- Move cursor to a diff line with context
			local first_hunk = review_panel.state.hunk_markers[1]
			if first_hunk then
				vim.api.nvim_win_set_cursor(
					review_panel.state.winid,
					{ first_hunk.line + 1, 0 }
				)
			end

			review_panel.inline_comment()
			T.drain_jobs(3000)
		end)

		T.assert_equals(
			#review_panel.state.pending_comments,
			1,
			"should have 1 pending comment after c"
		)
		T.assert_equals(
			review_panel.state.pending_comments[1].body,
			"Test inline comment",
			"pending comment body should match input"
		)

		T.cleanup_panels()
	end,

	-- ── Submit review as approve (a key) ──────────────────────────────

	["approve review a invokes gh pr review --approve"] = function()
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
			local found_review = false
			local found_approve = false
			local found_body = false
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

			T.assert_true(
				found_review,
				"gh log should contain `pr review 42`"
			)
			T.assert_true(
				found_approve,
				"gh log should contain --approve"
			)
			T.assert_true(
				found_body,
				"gh log should contain approve review body"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Submit review as request-changes (x key) ──────────────────────

	["request changes x invokes gh pr review --request-changes"] = function()
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
			local found_review = false
			local found_request_changes = false
			local found_body = false
			for _, line in ipairs(lines) do
				if line:find("pr review 42", 1, true) then
					found_review = true
				end
				if line:find("--request-changes", 1, true) then
					found_request_changes = true
				end
				if line:find("--body Please fix this", 1, true) then
					found_body = true
				end
			end

			T.assert_true(
				found_review,
				"gh log should contain `pr review 42`"
			)
			T.assert_true(
				found_request_changes,
				"gh log should contain --request-changes"
			)
			T.assert_true(
				found_body,
				"gh log should contain request changes review body"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Review success shows notification ─────────────────────────────

	["review approve success shows notification"] = function()
		local notified_message = nil

		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, on_confirm)
					on_confirm("Approved")
				end,
			},
			{
				table = gh_prs,
				key = "review",
				value = function(_, _, _, _, cb)
					cb(nil)
				end,
			},
			{
				table = utils,
				key = "notify",
				value = function(msg)
					if msg and msg:find("approved", 1, true) then
						notified_message = msg
					end
				end,
			},
		}, function()
			review_panel.review_approve()
			T.drain_jobs(3000)
		end)

		T.assert_true(
			notified_message ~= nil,
			"should notify on successful approve review"
		)
		T.assert_contains(
			notified_message,
			"approved",
			"notification should mention 'approved'"
		)

		T.cleanup_panels()
	end,

	-- ── Review failure shows error ────────────────────────────────────

	["review failure shows error notification"] = function()
		local error_msg = nil
		local error_level = nil

		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, on_confirm)
					on_confirm("test")
				end,
			},
			{
				table = gh_prs,
				key = "review",
				value = function(_, _, _, _, cb)
					cb("review submission failed: 403 forbidden")
				end,
			},
			{
				table = utils,
				key = "notify",
				value = function(msg, level)
					error_msg = msg
					error_level = level
				end,
			},
		}, function()
			review_panel.review_approve()
			T.drain_jobs(3000)
		end)

		T.assert_true(
			error_msg ~= nil,
			"should notify on review failure"
		)
		T.assert_contains(
			error_msg,
			"403 forbidden",
			"error should contain failure details"
		)
		T.assert_equals(
			error_level,
			vim.log.levels.ERROR,
			"error should be at ERROR level"
		)

		T.cleanup_panels()
	end,

	-- ── Comment threads rendered ──────────────────────────────────────

	["review panel renders existing comment threads"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local bufnr = ui.buffer.get("review")
		local lines = T.buf_lines(bufnr)

		-- The stub returns review comments with reviewer1
		T.assert_true(
			T.find_line(lines, "reviewer1") ~= nil,
			"review buffer should show reviewer1 comment author"
		)
		T.assert_true(
			T.find_line(lines, "Consider renaming") ~= nil,
			"review buffer should show comment body"
		)

		T.cleanup_panels()
	end,

	-- ── Thread collapse toggle (<leader>t) ────────────────────────────

	["thread toggle via <leader>t keymap collapses thread"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		-- Should have at least one thread
		T.assert_true(
			#review_panel.state.comment_threads > 0,
			"should have at least one comment thread"
		)

		-- Find the first thread header line
		local thread = review_panel.state.comment_threads[1]
		T.assert_false(
			thread.collapsed,
			"thread should start expanded"
		)

		-- Move cursor to a thread line and toggle
		local winid = review_panel.state.winid
		local bufnr = ui.buffer.get("review")
		local lines = T.buf_lines(bufnr)
		local thread_line = nil
		for i, line in ipairs(lines) do
			if line:find(">>", 1, true) then
				thread_line = i
				break
			end
		end
		T.assert_true(
			thread_line ~= nil,
			"should find a thread header line (>>)"
		)

		-- Set cursor to thread line
		vim.api.nvim_win_set_cursor(winid, { thread_line, 0 })
		vim.api.nvim_set_current_win(winid)

		-- Need to check thread_line_map is populated at this line
		local thread_idx = review_panel.state.thread_line_map[thread_line]
		T.assert_true(
			thread_idx ~= nil,
			"thread_line_map should contain entry for thread line"
		)

		-- Toggle collapse through the keymap path.
		T.feedkeys("<leader>t")
		T.drain_jobs(3000)

		-- After toggle + re-render, thread should be collapsed
		local toggled_thread = review_panel.state.comment_threads[1]
		T.assert_true(
			toggled_thread ~= nil
				and toggled_thread.collapsed == true,
			"thread should be collapsed after toggle"
		)

		T.cleanup_panels()
	end,

	-- ── Thread reply (R key) ──────────────────────────────────────────

	["reply to thread R invokes reply API"] = function()
		local reply_called = false
		local reply_body = nil

		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		-- Position cursor on a thread line
		local bufnr = ui.buffer.get("review")
		local lines = T.buf_lines(bufnr)
		local thread_line = nil
		for i, line in ipairs(lines) do
			if line:find(">>", 1, true) then
				thread_line = i
				break
			end
		end

		if not thread_line then
			-- If no rendered threads, skip gracefully
			T.cleanup_panels()
			return
		end

		vim.api.nvim_win_set_cursor(
			review_panel.state.winid,
			{ thread_line, 0 }
		)

		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, on_confirm)
					on_confirm("Thanks for the feedback")
				end,
			},
			{
				table = gh_prs,
				key = "reply_to_review_comment",
				value = function(_, _, body, _, cb)
					reply_called = true
					reply_body = body
					cb(nil)
				end,
			},
		}, function()
			review_panel.reply_to_thread()
			T.drain_jobs(3000)
		end)

		T.assert_true(
			reply_called,
			"reply_to_review_comment should be called"
		)
		T.assert_equals(
			reply_body,
			"Thanks for the feedback",
			"reply body should match user input"
		)

		T.cleanup_panels()
	end,

	-- ── Submit pending review with inline comments ────────────────────

	["submit pending review batches inline comments"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		-- Add a pending comment
		review_panel.state.pending_comments = {
			{
				id = 1,
				path = "lua/gitflow/highlights.lua",
				hunk = "@@ -10,7 +10,9 @@",
				line = review_panel.state.hunk_markers[1]
					and review_panel.state.hunk_markers[1].line + 1
					or 1,
				body = "Please refactor this",
			},
		}

		with_temp_gh_log(function(log_path)
			with_temporary_patches({
				{
					table = input,
					key = "prompt",
					value = function(opts, on_confirm)
						-- First prompt: mode selection
						if opts.prompt:find("mode", 1, true) then
							on_confirm("approve")
						else
							-- Second prompt: body
							on_confirm("Good overall")
						end
					end,
				},
			}, function()
				review_panel.submit_pending_review()
				T.drain_jobs(3000)
			end)

			local lines = T.read_file(log_path)
			local found_review_api = false
			local found_event = false
			local found_body = false
			local found_comments = false
			for _, line in ipairs(lines) do
				if line:find("api repos/{owner}/{repo}/pulls/42/reviews", 1, true) then
					found_review_api = true
				end
				if line:find("event=APPROVE", 1, true) then
					found_event = true
				end
				if line:find("body=Good overall", 1, true) then
					found_body = true
				end
				if line:find("comments=", 1, true)
					and line:find("lua/gitflow/highlights.lua", 1, true) then
					found_comments = true
				end
			end

			T.assert_true(
				found_review_api,
				"submit review should call reviews API endpoint"
			)
			T.assert_true(
				found_event,
				"submit review should map approve mode to event=APPROVE"
			)
			T.assert_true(
				found_body,
				"submit review should include provided body"
			)
			T.assert_true(
				found_comments,
				"submit review should include inline comments payload"
			)
		end)

		T.cleanup_panels()
	end,

	["submit review API maps request_changes to REQUEST_CHANGES"] = function()
		with_temp_gh_log(function(log_path)
			gh_prs.submit_review(
				42,
				"request_changes",
				"Need another pass",
				{},
				{},
				function(err)
					T.assert_true(
						err == nil,
						"submit_review should succeed: " .. tostring(err)
					)
				end
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			local found_event = false
			local found_body = false
			for _, line in ipairs(lines) do
				if line:find("event=REQUEST_CHANGES", 1, true) then
					found_event = true
				end
				if line:find("body=Need another pass", 1, true) then
					found_body = true
				end
			end

			T.assert_true(
				found_event,
				"submit_review should map request_changes to REQUEST_CHANGES"
			)
			T.assert_true(
				found_body,
				"submit_review should include request changes body"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Review panel close restores previous window ───────────────────

	["review panel close restores previous window"] = function()
		local prev_win = vim.api.nvim_get_current_win()

		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_true(
			review_panel.is_open(),
			"review panel should be open"
		)

		review_panel.close()

		T.assert_false(
			review_panel.is_open(),
			"review panel should be closed"
		)

		-- Previous window should be restored (if still valid)
		if vim.api.nvim_win_is_valid(prev_win) then
			T.assert_equals(
				vim.api.nvim_get_current_win(),
				prev_win,
				"previous window should be restored after close"
			)
		end

		T.cleanup_panels()
	end,

	-- ── Review panel state reset on close ─────────────────────────────

	["review panel state is reset on close"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		review_panel.close()

		T.assert_true(
			review_panel.state.bufnr == nil,
			"bufnr should be nil after close"
		)
		T.assert_true(
			review_panel.state.winid == nil,
			"winid should be nil after close"
		)
		T.assert_true(
			review_panel.state.pr_number == nil,
			"pr_number should be nil after close"
		)
		T.assert_deep_equals(
			review_panel.state.file_markers,
			{},
			"file_markers should be empty after close"
		)
		T.assert_deep_equals(
			review_panel.state.pending_comments,
			{},
			"pending_comments should be empty after close"
		)

		T.cleanup_panels()
	end,

	-- ── Line context tracks old/new line numbers ──────────────────────

	["line context provides old/new line numbers"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local has_old_line = false
		local has_new_line = false
		for _, ctx in pairs(review_panel.state.line_context) do
			if ctx.old_line then
				has_old_line = true
			end
			if ctx.new_line then
				has_new_line = true
			end
		end

		T.assert_true(
			has_old_line,
			"line context should contain old_line entries"
		)
		T.assert_true(
			has_new_line,
			"line context should contain new_line entries"
		)

		T.cleanup_panels()
	end,

	-- ── Review via command dispatch ───────────────────────────────────

	-- ── Cursor restoration after inline comment ─────────────────────

	["cursor returns to same diff line after inline comment"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local winid = review_panel.state.winid
		T.assert_true(
			winid ~= nil and vim.api.nvim_win_is_valid(winid),
			"review window should be valid"
		)

		-- Find a diff line with line_context (has path + new_line)
		local target_line = nil
		local target_ctx = nil
		for buf_line, ctx in pairs(review_panel.state.line_context) do
			if ctx.path and ctx.new_line then
				target_line = buf_line
				target_ctx = ctx
				break
			end
		end
		T.assert_true(
			target_line ~= nil,
			"should find a diff line with path and new_line context"
		)

		-- Move cursor to the target diff line
		vim.api.nvim_win_set_cursor(winid, { target_line, 0 })

		-- Add an inline comment (patches input to auto-confirm)
		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, on_confirm)
					on_confirm("Cursor restore test comment")
				end,
			},
		}, function()
			review_panel.inline_comment()
			T.drain_jobs(5000)
		end)

		-- After re-render, cursor should be on a line with the
		-- same path and new_line as before
		local cursor_after =
			vim.api.nvim_win_get_cursor(winid)[1]
		local ctx_after =
			review_panel.state.line_context[cursor_after] or {}
		T.assert_equals(
			ctx_after.path,
			target_ctx.path,
			"cursor should return to same file path after comment"
		)
		T.assert_equals(
			ctx_after.new_line,
			target_ctx.new_line,
			"cursor should return to same new_line after comment"
		)

		T.cleanup_panels()
	end,

	-- ── Review via command dispatch ───────────────────────────────────

	["pr review 42 approve via command dispatch"] = function()
		local review_mode = nil

		with_temporary_patches({
			{
				table = gh_prs,
				key = "review",
				value = function(_, mode, _, _, cb)
					review_mode = mode
					cb(nil)
				end,
			},
		}, function()
			local commands = require("gitflow.commands")
			commands.dispatch(
				{ "pr", "review", "42", "approve", "LGTM" },
				cfg
			)
			T.drain_jobs(3000)
		end)

		T.assert_equals(
			review_mode,
			"approve",
			"command dispatch should invoke approve review"
		)

		T.cleanup_panels()
	end,

	-- ── Close guard: q with no pending comments closes ───────────

	["q with no pending comments closes immediately"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		T.assert_true(
			review_panel.is_open(),
			"review panel should be open"
		)
		T.assert_equals(
			#review_panel.state.pending_comments,
			0,
			"should start with no pending comments"
		)

		review_panel.close_with_guard()

		T.assert_false(
			review_panel.is_open(),
			"review panel should close without confirmation"
		)

		T.cleanup_panels()
	end,

	-- ── Close guard: q with pending comments shows confirm ──────

	["q with pending comments shows confirmation"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		-- Add a pending comment manually
		review_panel.state.pending_comments = {
			{
				id = 1,
				path = "lua/gitflow/highlights.lua",
				hunk = "@@ -10,7 +10,9 @@",
				line = 5,
				body = "Draft comment",
			},
		}

		-- Stub confirm to return true (user confirms discard)
		with_temporary_patches({
			{
				table = input,
				key = "confirm",
				value = function(msg, _)
					T.assert_contains(
						msg,
						"1 comment",
						"confirm message should mention count"
					)
					return true, 1
				end,
			},
		}, function()
			review_panel.close_with_guard()
		end)

		T.assert_false(
			review_panel.is_open(),
			"review panel should close after user confirms"
		)

		T.cleanup_panels()
	end,

	-- ── Close guard: cancel keeps panel open ────────────────────

	["q with pending comments cancelled keeps panel"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		-- Add two pending comments
		review_panel.state.pending_comments = {
			{
				id = 1,
				path = "lua/gitflow/highlights.lua",
				hunk = "@@ -10,7 +10,9 @@",
				line = 5,
				body = "First draft",
			},
			{
				id = 2,
				path = "lua/gitflow/config.lua",
				hunk = "@@ -1,3 +1,4 @@",
				line = 10,
				body = "Second draft",
			},
		}

		-- Stub confirm to return false (user cancels)
		with_temporary_patches({
			{
				table = input,
				key = "confirm",
				value = function(msg, _)
					T.assert_contains(
						msg,
						"2 comments",
						"confirm should mention 2 comments"
					)
					return false, 2
				end,
			},
		}, function()
			review_panel.close_with_guard()
		end)

		T.assert_true(
			review_panel.is_open(),
			"review panel should stay open after cancel"
		)
		T.assert_equals(
			#review_panel.state.pending_comments,
			2,
			"pending comments should be preserved"
		)

		T.cleanup_panels()
	end,

	-- ── Treesitter not attached to review buffer ─────────
	["review buffer uses gitflow-diff filetype"] = function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		local bufnr = ui.buffer.get("review")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"review buffer should exist"
		)

		local ft = vim.api.nvim_get_option_value(
			"filetype", { buf = bufnr }
		)
		T.assert_equals(
			ft,
			"gitflow-diff",
			"review buffer filetype should be gitflow-diff"
		)

		local syn = vim.api.nvim_get_option_value(
			"syntax", { buf = bufnr }
		)
		T.assert_equals(
			syn,
			"diff",
			"review buffer syntax should be diff"
		)

		-- Treesitter should not be attached
		local has_ts_parser = pcall(
			vim.treesitter.get_parser, bufnr
		)
		T.assert_false(
			has_ts_parser,
			"treesitter should not attach to gitflow-diff"
		)

		cleanup_panels()
	end,

	-- ── Re-render does not cause treesitter error ────────
	["re-render after comment has no treesitter error"]
		= function()
		review_panel.open(cfg, 42)
		T.drain_jobs(5000)

		-- Add a pending comment to trigger re-render path
		with_temporary_patches({
			{
				table = input,
				key = "prompt",
				value = function(_, cb) cb("test comment") end,
			},
		}, function()
			review_panel.inline_comment()
		end)
		T.drain_jobs(5000)

		T.assert_equals(
			#review_panel.state.pending_comments,
			1,
			"should have 1 pending comment after re-render"
		)

		local bufnr = ui.buffer.get("review")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"review buffer should still be valid"
		)

		-- No treesitter parser should be present
		local has_ts = pcall(
			vim.treesitter.get_parser, bufnr
		)
		T.assert_false(
			has_ts,
			"treesitter should not attach after re-render"
		)

		cleanup_panels()
	end,
})

print("E2E PR review flow tests passed")
