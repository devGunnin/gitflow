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

		review_panel.collapse_all_dirs()
		local collapsed = table.concat(T.buf_lines(bufnr), "\n")
		T.assert_true(
			not collapsed:find("highlights.lua", 1, true),
			"collapse_all should hide leaf basenames")
		T.assert_true(
			collapsed:find("▸", 1, true) ~= nil,
			"collapsed folders should show a ▸ arrow")

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
				review_panel.state.diff_winid, { 1, 0 })

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
})

print("E2E PR review mode tests passed")
