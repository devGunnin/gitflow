--- Drafting review comments: what a keypress in the diff pane anchors to, and
--- the local draft it queues, edits or deletes.
---
--- Every anchor is resolved against the PR diff rather than the buffer, so a
--- locally modified working tree can neither misplace a comment nor leak into
--- a suggestion. Drafts live in `state.pending_comments` and reach disk
--- through `state.persist_pending` — every mutation here calls it, because the
--- cache is the only thing that survives a crashed editor.

local input = require("gitflow.ui.input")
local gh = require("gitflow.gh")
local gh_prs = require("gitflow.gh.prs")
local inline = require("gitflow.review.inline")
local rstate = require("gitflow.review.state")
local threads = require("gitflow.review.threads")
local file_list = require("gitflow.review.file_list")
local overlay = require("gitflow.review.overlay")

local M = {}
local state = rstate.state

local OFF_DIFF_HINT =
	"You can only comment on lines that are part of the PR diff "
	.. "(changed or context lines within a hunk). If line numbers look "
	.. "off, check out the PR branch first (gh pr checkout)."

local SUGGESTION_SIDE_HINT =
	"A suggestion replaces lines in the PR's new file, so it can only be "
	.. "started on added or context lines of the diff (not removed lines)."

---Redraw both surfaces after a draft changed.
local function redraw()
	file_list.render()
	threads.refresh_for_active()
end

-- ── anchors ────────────────────────────────────────────────────────────

---@param path string
---@param line integer
---@return GitflowReviewHunkLine|nil, string|nil
local function find_hunk_line_for(path, line)
	local fd = state.file_diffs[path]
	if not fd then
		return nil, nil
	end
	for _, h in ipairs(fd.hunks) do
		-- A line is "in" the hunk's new range if any of its lines hit it.
		for _, l in ipairs(h.lines) do
			if l.new_line == line then
				return l, h.header
			end
		end
	end
	return nil, nil
end

---@param path string
---@param old_line integer
---@return GitflowReviewHunkLine|nil, string|nil
local function find_hunk_del_line_for(path, old_line)
	local fd = state.file_diffs[path]
	if not fd then
		return nil, nil
	end
	for _, h in ipairs(fd.hunks) do
		for _, l in ipairs(h.lines) do
			if l.kind == "del" and l.old_line == old_line then
				return l, h.header
			end
		end
	end
	return nil, nil
end

--- Resolve the file + line a comment should anchor to. The path is taken
--- from the buffer actually displayed in the diff window (not the tracked
--- active_path, which can lag behind file switches), so path and line are
--- always read from the same file the cursor is in.
---@return { path: string, line: integer }|nil
local function require_active_diff_line()
	if not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		rstate.notify_warn("Open a file from the PR file list first")
		return nil
	end
	local buf = vim.api.nvim_win_get_buf(state.diff_winid)
	local path = rstate.buf_repo_relative(buf)
	if not path or not state.file_diffs[path] then
		-- Non-file buffer (e.g. a deleted-file placeholder): fall back to
		-- the tracked active path.
		path = state.active_path
	end
	if not path then
		rstate.notify_warn("Open a file from the PR file list first")
		return nil
	end
	-- Keep the tracked pointers consistent with what we're commenting on.
	state.active_path = path
	state.active_bufnr = buf
	return { path = path, line = vim.api.nvim_win_get_cursor(state.diff_winid)[1] }
end

--- Resolve the file + ordered line range of the current visual selection and
--- leave visual mode. The path comes from the buffer the selection is in, so
--- the comment can't be misattributed to a previously-active file.
---@return { path: string, start_line: integer, end_line: integer }|nil
local function require_visual_diff_range()
	if not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		return nil
	end
	local buf = vim.api.nvim_get_current_buf()
	local path = rstate.buf_repo_relative(buf)
	if not path or not state.file_diffs[path] then
		path = state.active_path
	end

	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
		"nx", false
	)

	if not path then
		rstate.notify_warn("Open a file from the PR file list first")
		return nil
	end
	state.active_path = path
	state.active_bufnr = buf

	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end
	return { path = path, start_line = start_line, end_line = end_line }
end

-- ── queueing a draft ───────────────────────────────────────────────────

--- Prompt for a body and queue a draft against the chosen anchor target.
---@param path string
---@param target table  { hunk, new_line, old_line, start_new_line, start_old_line, desc }
---@param opts table|nil  { kind, title, noun, default }  compose overrides
local function queue_target_comment(path, target, opts)
	opts = opts or {}
	local kind = opts.kind or "inline"
	input.prompt({
		multiline = true,
		title = opts.title or "Inline comment",
		default = opts.default,
		draft_key = ("review:%s:%s:%s:%s:%s"):format(
			tostring(state.pr_number), kind, path,
			tostring(target.new_line), tostring(target.old_line)
		),
	}, function(text)
		local body = vim.trim(text or "")
		if body == "" then
			rstate.notify_warn("Comment cannot be empty")
			return
		end
		local pending = {
			id = rstate.next_pending_id(),
			path = path,
			body = body,
			hunk = target.hunk,
			-- Anchor to the diff's own line numbers, not the raw cursor.
			new_line = target.new_line,
			old_line = target.old_line,
			start_new_line = target.start_new_line,
			start_old_line = target.start_old_line,
			created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		}
		state.pending_comments[#state.pending_comments + 1] = pending
		rstate.persist_pending()
		rstate.notify_info(
			("%s queued on %s (#%d) — press S to submit"):
				format(opts.noun or "Comment", target.desc, pending.id))
		redraw()
	end)
end

function M.inline_comment()
	local ctx = require_active_diff_line()
	if not ctx then
		return
	end

	-- Collect every line the cursor row can anchor a comment to: the new-side
	-- (RIGHT) line if it is part of the diff, plus any deleted (LEFT) lines
	-- rendered next to this row. Deleted lines have no real buffer row, so
	-- this is the only way to comment on them (#355).
	local targets = {}
	local hunk_line, hunk_header = find_hunk_line_for(ctx.path, ctx.line)
	if hunk_line then
		targets[#targets + 1] = {
			hunk = hunk_header,
			new_line = hunk_line.new_line,
			old_line = hunk_line.old_line,
			desc = ("line %d"):format(hunk_line.new_line or ctx.line),
		}
	end
	for _, d in ipairs(state.deleted_anchors[ctx.line] or {}) do
		local _, del_header = find_hunk_del_line_for(ctx.path, d.old_line)
		targets[#targets + 1] = {
			hunk = del_header,
			new_line = nil,
			old_line = d.old_line,
			desc = ("deleted line %d"):format(d.old_line or 0),
			preview = vim.trim((d.text or ""):gsub("%s+", " ")):sub(1, 40),
		}
	end

	if #targets == 0 then
		rstate.notify_warn(OFF_DIFF_HINT)
		return
	end
	if #targets == 1 then
		queue_target_comment(ctx.path, targets[1])
		return
	end

	-- An added/context line that also has deleted lines beside it: let the
	-- user choose which one to comment on.
	local items = {}
	for _, t in ipairs(targets) do
		local label
		if t.old_line and not t.new_line then
			label = ("\u{2013} %s: %s"):format(t.desc, t.preview or "")
		else
			label = ("\u{25cf} %s (added/context)"):format(t.desc)
		end
		items[#items + 1] = { target = t, label = label }
	end
	vim.ui.select(items, {
		prompt = "Comment on which line?",
		format_item = function(it) return it.label end,
	}, function(choice)
		if not choice then
			return
		end
		queue_target_comment(ctx.path, choice.target)
	end)
end

function M.inline_comment_visual()
	local sel = require_visual_diff_range()
	if not sel then
		return
	end

	-- Both ends of the range must be diff lines, or GitHub can't resolve it.
	local end_hunk, hunk_header = find_hunk_line_for(sel.path, sel.end_line)
	local start_hunk = find_hunk_line_for(sel.path, sel.start_line)
	if not end_hunk or not start_hunk then
		rstate.notify_warn(OFF_DIFF_HINT)
		return
	end

	queue_target_comment(sel.path, {
		hunk = hunk_header,
		new_line = end_hunk.new_line,
		old_line = end_hunk.old_line,
		start_new_line = start_hunk.new_line,
		start_old_line = start_hunk.old_line,
		desc = ("lines %d-%d"):format(sel.start_line, sel.end_line),
	}, { kind = "range", title = "Inline range comment" })
end

--- Queue a file-level comment (no line) for `path` (#361). Works for any
--- file in the PR including deleted files, which have no commentable lines.
---@param path string
function M.file_comment(path)
	if not path or path == "" then
		rstate.notify_warn("No file selected")
		return
	end
	input.prompt({
		multiline = true,
		title = ("Comment on %s"):format(vim.fn.fnamemodify(path, ":t")),
		draft_key = ("review:%s:file:%s"):format(tostring(state.pr_number), path),
	}, function(text)
		local body = vim.trim(text or "")
		if body == "" then
			rstate.notify_warn("Comment cannot be empty")
			return
		end
		local pending = {
			id = rstate.next_pending_id(),
			path = path,
			body = body,
			file_level = true,
			created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		}
		state.pending_comments[#state.pending_comments + 1] = pending
		rstate.persist_pending()
		rstate.notify_info(
			("File comment queued on %s (#%d) — press S to submit"):
				format(vim.fn.fnamemodify(path, ":t"), pending.id))
		redraw()
	end)
end

--- Comment on the whole file on the file-list row under the cursor (#361).
function M.file_comment_under_cursor()
	local idx = file_list.file_idx_under_cursor()
	if not idx then
		rstate.notify_warn(
			"Put the cursor on a file row to comment on the whole file")
		return
	end
	local file = state.files[idx]
	if file then
		M.file_comment(file.path)
	end
end

-- ── suggestions (#367) ─────────────────────────────────────────────────

--- Resolve what a suggestion anchored on buffer rows `start_row`..`end_row`
--- would replace: the new-side line numbers, and those lines' exact text from
--- the PR diff. The diff is the source of truth, not the buffer, so a locally
--- modified working tree can never leak into the proposal.
---@param path string
---@param start_row integer
---@param end_row integer
---@return table|nil, string|nil  { hunk, start_new, end_new, lines }
local function resolve_suggestion_range(path, start_row, end_row)
	local start_hunk, hunk_header = find_hunk_line_for(path, start_row)
	local end_hunk = find_hunk_line_for(path, end_row)
	if not start_hunk or not end_hunk
		or not start_hunk.new_line or not end_hunk.new_line then
		return nil, SUGGESTION_SIDE_HINT
	end

	local lines, err = inline.new_side_lines(
		state.file_diffs[path], start_hunk.new_line, end_hunk.new_line)
	if not lines then
		return nil, ("Cannot suggest here: %s"):format(err or "unknown reason")
	end
	return {
		hunk = hunk_header,
		start_new = start_hunk.new_line,
		end_new = end_hunk.new_line,
		lines = lines,
	}, nil
end

--- Queue a draft prefilled with a ```suggestion block holding the anchored
--- lines verbatim, so the reviewer edits the proposal instead of retyping it.
---@param path string
---@param start_row integer
---@param end_row integer
local function queue_suggestion(path, start_row, end_row)
	local range, err = resolve_suggestion_range(path, start_row, end_row)
	if not range then
		rstate.notify_warn(err)
		return
	end

	local multi = range.start_new ~= range.end_new
	queue_target_comment(path, {
		hunk = range.hunk,
		-- The comment anchors at the range end; GitHub replaces start..end.
		new_line = range.end_new,
		start_new_line = multi and range.start_new or nil,
		desc = multi
			and ("lines %d-%d"):format(range.start_new, range.end_new)
			or ("line %d"):format(range.end_new),
	}, {
		kind = "suggest",
		title = "Suggested change",
		noun = "Suggestion",
		default = inline.suggestion_block(range.lines),
	})
end

--- Propose an edit to the line under the cursor (#367).
function M.inline_suggestion()
	local ctx = require_active_diff_line()
	if ctx then
		queue_suggestion(ctx.path, ctx.line, ctx.line)
	end
end

--- Propose an edit spanning the visual selection (#367).
function M.inline_suggestion_visual()
	local sel = require_visual_diff_range()
	if sel then
		queue_suggestion(sel.path, sel.start_line, sel.end_line)
	end
end

-- ── editing and deleting drafts ────────────────────────────────────────

--- Open the draft's file and place the diff-pane cursor on its line.
---@param pc table  a pending comment
function M.jump_to_draft(pc)
	if not pc or not pc.path then
		return
	end
	overlay.open_file(pc.path)
	local line = pc.new_line or pc.old_line
	if line and state.diff_winid
		and vim.api.nvim_win_is_valid(state.diff_winid) then
		local total = vim.api.nvim_buf_line_count(
			vim.api.nvim_win_get_buf(state.diff_winid))
		pcall(vim.api.nvim_win_set_cursor, state.diff_winid,
			{ math.min(line, total), 0 })
		vim.api.nvim_set_current_win(state.diff_winid)
	end
end

--- Edit the body of a pending (unsubmitted) draft comment in place (#358).
--- Pre-fills the prompt with the existing body so corrections / additions
--- are quick. Only drafts can be edited here; submitted remote comments
--- are immutable through this path (reply with R instead).
---@param pc table  a pending comment
function M.edit_draft(pc)
	if not pc then
		return
	end
	input.prompt({
		multiline = true,
		title = "Edit draft comment",
		default = pc.body or "",
		draft_key = ("review:%s:draft:%s"):format(
			tostring(state.pr_number), tostring(pc.id)),
	}, function(text)
		local body = vim.trim(text or "")
		if body == "" then
			rstate.notify_warn("Comment cannot be empty (use dd to delete)")
			return
		end
		pc.body = body
		rstate.persist_pending()
		rstate.notify_info("Draft comment updated")
		redraw()
	end)
end

--- Edit the draft comment under the cursor in the file-list "Drafts" section.
function M.edit_draft_under_cursor()
	local idx = file_list.draft_idx_under_cursor()
	if idx then
		M.edit_draft(state.pending_comments[idx])
		return
	end

	-- On a file row, edit any draft on that file — file-level OR line
	-- comments (#358/#361). It's natural to edit a file's comments by
	-- hovering its row rather than hunting through the Drafts section.
	local file_idx = file_list.file_idx_under_cursor()
	if not file_idx then
		rstate.notify_warn("No draft comment under the cursor")
		return
	end

	local file = state.files[file_idx]
	local matches = {}
	for _, pc in ipairs(state.pending_comments) do
		if file and pc.path == file.path then
			matches[#matches + 1] = pc
		end
	end
	if #matches == 1 then
		M.edit_draft(matches[1])
		return
	end
	if #matches == 0 then
		rstate.notify_warn("No draft comment on this file")
		return
	end
	vim.ui.select(matches, {
		prompt = "Edit which comment?",
		format_item = function(pc)
			local loc = pc.file_level and "(file)"
				or ("L%d"):format(pc.new_line or pc.old_line or 0)
			local preview = vim.trim((pc.body or ""):gsub("%s+", " ")):sub(1, 50)
			return ("%-7s %s"):format(loc, preview)
		end,
	}, function(choice)
		if choice then
			M.edit_draft(choice)
		end
	end)
end

--- Edit the draft anchored to the current diff-pane line. Mirrors the draft
--- lookup in delete_comment_at_cursor (matches new_line OR old_line so
--- deleted-line drafts are editable too).
function M.edit_comment_at_cursor()
	if not state.active_path or not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		rstate.notify_warn("Open a file from the PR file list first")
		return
	end
	local cur = vim.api.nvim_win_get_cursor(state.diff_winid)[1]
	for _, pc in ipairs(state.pending_comments) do
		if pc.path == state.active_path
			and (pc.new_line == cur or pc.old_line == cur) then
			M.edit_draft(pc)
			return
		end
	end
	rstate.notify_warn("No draft comment under cursor")
end

--- Delete the draft comment under the cursor in the file-list pane.
function M.delete_draft_under_cursor()
	local idx = file_list.draft_idx_under_cursor()
	if not idx then
		rstate.notify_warn("No draft comment under the cursor")
		return
	end
	local pc = state.pending_comments[idx]
	if not pc then
		return
	end
	local preview = vim.trim((pc.body or ""):gsub("%s+", " ")):sub(1, 60)
	local confirmed = input.confirm(
		("Delete draft comment?\n\n  %s"):format(preview),
		{ choices = { "&Yes", "&No" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end
	table.remove(state.pending_comments, idx)
	rstate.persist_pending()
	rstate.notify_info("Draft comment deleted")
	redraw()
end

--- Delete every draft whose line no longer maps to the PR diff (the ones
--- that would be rejected on submit).
function M.delete_off_diff_drafts()
	local victims = {}
	for idx = #state.pending_comments, 1, -1 do
		if not rstate.draft_in_scope(state.pending_comments[idx]) then
			victims[#victims + 1] = idx
		end
	end
	if #victims == 0 then
		rstate.notify_info("No off-diff drafts to delete")
		return
	end
	local confirmed = input.confirm(
		("Delete %d off-diff draft comment(s)?"):format(#victims),
		{ choices = { "&Yes", "&No" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end
	for _, idx in ipairs(victims) do
		table.remove(state.pending_comments, idx)
	end
	rstate.persist_pending()
	rstate.notify_info(("Deleted %d off-diff draft(s)"):format(#victims))
	redraw()
end

--- Confirm and delete an already-submitted review comment.
---@param thread GitflowPrReviewThread
---@param login string  the current GitHub user, "" when it could not be read
local function delete_remote_comment(thread, login)
	-- Prefer a comment owned by the current GitHub user; fall back to the
	-- thread's first comment. GitHub rejects the DELETE with 403 if the
	-- comment isn't ours, and we surface that error to the user.
	local target = thread.comments[1]
	if login ~= "" then
		for _, c in ipairs(thread.comments) do
			if c.user == login then
				target = c
				break
			end
		end
	end
	if not target or not target.id then
		rstate.notify_warn("No deletable comment under cursor")
		return
	end

	local label = ("@%s: %s"):format(
		target.user or "?", (target.body or ""):sub(1, 60))
	local confirmed = input.confirm(
		("Delete submitted review comment?\n\n  %s\n\n"
		.. "(This permanently removes it from the PR.)"):format(label),
		{ choices = { "&Yes", "&No" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	gh_prs.delete_review_comment(state.pr_number, target.id, {}, function(err)
		if err then
			rstate.notify_error(err)
			return
		end
		rstate.notify_info("Review comment deleted")
		require("gitflow.review.load").refresh()
	end)
end

--- Delete a review comment anchored to the current diff-pane line.
---
--- Drafts (pending, never submitted) are removed in-memory + from the
--- on-disk cache. Already-submitted remote comments are deleted via the
--- GitHub API. Drafts take priority when both exist on the same line —
--- they're cheaper to undo by accident.
function M.delete_comment_at_cursor()
	if not state.active_path or not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		rstate.notify_warn("Open a file from the PR file list first")
		return
	end
	local cur = vim.api.nvim_win_get_cursor(state.diff_winid)[1]
	local path = state.active_path

	-- 1) Prefer deleting a pending draft on this line.
	for idx = #state.pending_comments, 1, -1 do
		local pc = state.pending_comments[idx]
		if pc.path == path
			and (pc.new_line == cur or pc.old_line == cur) then
			local confirmed = input.confirm(
				("Delete draft comment? \n\n  %s"):format(
					(pc.body or ""):sub(1, 60)),
				{ choices = { "&Yes", "&No" }, default_choice = 2 }
			)
			if not confirmed then
				return
			end
			table.remove(state.pending_comments, idx)
			rstate.persist_pending()
			rstate.notify_info("Draft comment deleted")
			redraw()
			return
		end
	end

	-- 2) Otherwise look for a remote thread anchored at this line.
	local thread
	for _, t in ipairs(state.comment_threads) do
		if t.path == path and t.line == cur then
			thread = t
			break
		end
	end
	if not thread then
		rstate.notify_warn("No comment under cursor")
		return
	end

	-- Which of the thread's comments is ours decides which one D deletes, and
	-- reading that from `gh` must not freeze the editor: ask asynchronously
	-- and confirm from the callback. The review the answer belongs to is
	-- captured, so a PR switch in between drops it rather than deleting a
	-- comment on the wrong review.
	local number = state.pr_number
	gh.run({ "api", "user", "-q", ".login" }, {}, function(result)
		if state.pr_number ~= number then
			return
		end
		local login = ""
		if result.code == 0 then
			login = vim.trim((result.stdout or ""):gsub("\n.*", ""))
		end
		delete_remote_comment(thread, login)
	end)
end

return M
