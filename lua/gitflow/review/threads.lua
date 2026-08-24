--- Remote review threads, and moving between comments.
---
--- Owns the shape GitHub's flat comment list is folded into (a thread per root
--- comment, replies attached), the projection of threads + local drafts onto
--- the inline renderer, and the ]C / [C / overview navigation that crosses
--- file boundaries.
---
--- Calls that cross back into the diff pane or restart a PR load are made with
--- a require inside the function body: this module is required by those, and a
--- load-time require would close the cycle.

local ui = require("gitflow.ui")
local input = require("gitflow.ui.input")
local inline = require("gitflow.review.inline")
local list_picker = require("gitflow.ui.list_picker")
local gh_prs = require("gitflow.gh.prs")
local rstate = require("gitflow.review.state")

local M = {}
local state = rstate.state

--- Fold GitHub's flat review-comment list into threads.
---@param comments table[]|nil
---@return GitflowPrReviewThread[]
function M.build(comments)
	local threads = {}
	-- Every comment id → the thread it belongs to, so a reply that points at
	-- another reply (not the thread root) still lands in the same thread.
	local thread_of = {}

	for _, c in ipairs(comments or {}) do
		local user = ""
		if type(c.user) == "table" and c.user.login then
			user = c.user.login
		elseif type(c.user) == "string" then
			user = c.user
		end

		local comment = {
			id = rstate.as_integer(c.id) or 0,
			path = c.path or "",
			line = rstate.as_integer(c.line) or rstate.as_integer(c.original_line),
			original_line = rstate.as_integer(c.original_line),
			body = c.body or "",
			user = user,
			in_reply_to_id = rstate.as_integer(c.in_reply_to_id),
			start_line = rstate.as_integer(c.start_line),
		}

		local parent = comment.in_reply_to_id
			and thread_of[comment.in_reply_to_id] or nil
		if parent then
			parent.comments[#parent.comments + 1] = comment
			thread_of[comment.id] = parent
		else
			-- A root comment, or a reply whose parent we never saw: either way
			-- it starts a thread of its own rather than being dropped.
			local thread = {
				id = comment.id,
				path = comment.path,
				line = comment.line,
				comments = { comment },
				collapsed = false,
			}
			threads[#threads + 1] = thread
			thread_of[comment.id] = thread
		end
	end

	return threads
end

--- Every comment to draw on `path`: remote threads plus local drafts.
---@param path string
---@return GitflowReviewInlineComment[]
function M.comments_for_path(path)
	local out = {}
	for _, thread in ipairs(state.comment_threads) do
		if thread.path == path and #thread.comments > 0 then
			local first = thread.comments[1]
			-- Replies are only handed to the renderer while the thread is
			-- folded out, so a long discussion can't swamp the diff (#360).
			local expanded = state.expanded_threads[thread.id] == true
			local replies = {}
			if expanded then
				for i = 2, #thread.comments do
					replies[#replies + 1] = {
						author = thread.comments[i].user,
						body = thread.comments[i].body,
					}
				end
			end
			out[#out + 1] = {
				author = first.user,
				body = first.body,
				new_line = thread.line,
				old_line = nil,
				pending = false,
				count = #thread.comments,
				expanded = expanded,
				replies = replies,
			}
		end
	end
	for _, pc in ipairs(state.pending_comments) do
		if pc.path == path then
			out[#out + 1] = {
				author = "you (draft)",
				body = pc.body,
				new_line = pc.new_line,
				old_line = pc.old_line,
				pending = true,
				count = 1,
			}
		end
	end
	return out
end

--- Redraw the comment boxes on the file currently in the diff pane.
function M.refresh_for_active()
	if not state.active_bufnr
		or not vim.api.nvim_buf_is_valid(state.active_bufnr)
		or not state.active_path then
		return
	end
	inline.apply_comments(
		state.active_bufnr,
		M.comments_for_path(state.active_path),
		{ show_body = state.show_inline_comments }
	)
end

-- ── navigation ─────────────────────────────────────────────────────────

--- Ordered list of every comment anchor across the whole PR: remote review
--- threads (from any author) plus local unsubmitted drafts, sorted by the
--- file-list order then line. Powers ]C / [C comment navigation.
---@return { path: string, line: integer, file_idx: integer, kind: string, summary: string }[]
function M.collect_anchors()
	local file_order = {}
	for i, f in ipairs(state.files) do
		file_order[f.path] = i
	end

	local anchors = {}
	local function add(path, line, kind, author, body)
		if not path or not line then
			return
		end
		local preview = vim.trim((body or ""):gsub("%s+", " "))
		anchors[#anchors + 1] = {
			path = path,
			line = line,
			file_idx = file_order[path] or math.huge,
			kind = kind,
			summary = ("@%s  %s"):format(author,
				vim.fn.strcharpart(preview, 0, 70)),
		}
	end

	for _, t in ipairs(state.comment_threads) do
		local comments = t.comments or {}
		local first = comments[1]
		local author = (first and first.user ~= "") and first.user or "unknown"
		local body = first and first.body or ""
		if #comments > 1 then
			body = ("(+%d repl%s) %s"):format(#comments - 1,
				(#comments - 1) == 1 and "y" or "ies", body)
		end
		add(t.path, t.line, "thread", author, body)
	end
	for _, pc in ipairs(state.pending_comments) do
		-- File-level drafts (#361) carry no line; list them at the file's top
		-- so they're still reachable when working through the comments.
		local line = pc.new_line or pc.old_line or (pc.file_level and 1 or nil)
		add(pc.path, line, "draft", "you (draft)", pc.body)
	end

	table.sort(anchors, function(a, b)
		if a.file_idx ~= b.file_idx then
			return a.file_idx < b.file_idx
		end
		return a.line < b.line
	end)
	return anchors
end

---@param anchor { path: string, line: integer }
local function goto_anchor(anchor)
	local overlay = require("gitflow.review.overlay")
	if state.active_path ~= anchor.path then
		overlay.open_file(anchor.path)
	end
	if state.diff_winid and vim.api.nvim_win_is_valid(state.diff_winid) then
		local buf = vim.api.nvim_win_get_buf(state.diff_winid)
		local total = vim.api.nvim_buf_line_count(buf)
		pcall(vim.api.nvim_win_set_cursor, state.diff_winid,
			{ math.min(anchor.line, total), 0 })
		vim.api.nvim_set_current_win(state.diff_winid)
	end
end

--- Jump to the next comment thread/draft in the PR, opening its file and
--- crossing file boundaries as needed. Wraps at the end.
function M.next_comment()
	local anchors = M.collect_anchors()
	if #anchors == 0 then
		rstate.notify_info("No comments in this review")
		return
	end
	local cur_idx = state.active_file_idx or 0
	local cur_line = 0
	if state.diff_winid and vim.api.nvim_win_is_valid(state.diff_winid) then
		cur_line = vim.api.nvim_win_get_cursor(state.diff_winid)[1]
	end
	for _, a in ipairs(anchors) do
		if a.file_idx > cur_idx
			or (a.file_idx == cur_idx and a.line > cur_line) then
			goto_anchor(a)
			return
		end
	end
	goto_anchor(anchors[1])
end

--- Jump to the previous comment thread/draft in the PR. Wraps at the start.
function M.prev_comment()
	local anchors = M.collect_anchors()
	if #anchors == 0 then
		rstate.notify_info("No comments in this review")
		return
	end
	local cur_idx = state.active_file_idx or math.huge
	local cur_line = math.huge
	if state.diff_winid and vim.api.nvim_win_is_valid(state.diff_winid) then
		cur_line = vim.api.nvim_win_get_cursor(state.diff_winid)[1]
	end
	for i = #anchors, 1, -1 do
		local a = anchors[i]
		if a.file_idx < cur_idx
			or (a.file_idx == cur_idx and a.line < cur_line) then
			goto_anchor(a)
			return
		end
	end
	goto_anchor(anchors[#anchors])
end

--- Overview of every comment on the PR — remote threads and local drafts, in
--- file-list then line order — as a picker that jumps to the one chosen (#382).
function M.comments_overview()
	local anchors = M.collect_anchors()
	if #anchors == 0 then
		rstate.notify_info("No comments in this review")
		return
	end

	local items, by_name = {}, {}
	for i, anchor in ipairs(anchors) do
		-- The picker sorts unfiltered items by name, so the index prefix is
		-- what keeps the list in review order.
		local name = ("%03d. %s:%d"):format(i, anchor.path, anchor.line)
		items[#items + 1] = { name = name, description = anchor.summary }
		by_name[name] = anchor
	end

	list_picker.open({
		items = items,
		multi_select = false,
		title = ("Comments · PR #%s"):format(rstate.fmt_number(state.pr_number)),
		on_submit = function(selected)
			local anchor = by_name[(selected or {})[1] or ""]
			if anchor then
				goto_anchor(anchor)
			end
		end,
	})
end

-- ── the thread surface ─────────────────────────────────────────────────

---The thread anchored at the diff-pane cursor, or nil.
---@return GitflowPrReviewThread|nil, integer|nil  thread, cursor line
local function thread_at_cursor()
	if not state.active_path or not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		return nil, nil
	end
	local cur = vim.api.nvim_win_get_cursor(state.diff_winid)[1]
	for _, t in ipairs(state.comment_threads) do
		if t.path == state.active_path and t.line == cur then
			return t, cur
		end
	end
	return nil, cur
end

--- Fold the replies of the thread under the diff-pane cursor in or out, so a
--- discussion is readable in place instead of only its first comment (#360).
--- <CR> still opens the same thread full-size in a float.
function M.toggle_thread()
	if not state.active_path or not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		rstate.notify_warn("Open a file from the PR file list first")
		return
	end
	local thread = thread_at_cursor()
	if not thread then
		rstate.notify_warn("No comment thread on this line")
		return
	end
	if #thread.comments < 2 then
		rstate.notify_info("This thread has no replies")
		return
	end

	state.expanded_threads[thread.id] =
		not state.expanded_threads[thread.id] or nil
	if not state.show_inline_comments then
		-- Bodies are collapsed to end-of-line badges; nothing would change.
		rstate.notify_info("Press <leader>i to show comment bodies inline")
	end
	M.refresh_for_active()
end

--- Render the discussion at `path:cur` as a markdown document. Comment bodies
--- are markdown on GitHub, so the float gets real formatting rather than a
--- flattened wall of text.
---@param path string
---@param cur integer
---@param threads GitflowPrReviewThread[]
---@param drafts table[]
---@return string[]
local function discussion_lines(path, cur, threads, drafts)
	local lines = {}
	local function add(s)
		lines[#lines + 1] = s
	end
	local function add_body(body)
		for _, bl in ipairs(vim.split(body or "", "\n", { plain = true })) do
			add(bl)
		end
	end

	add(("# Discussion · %s:%d"):format(path, cur))
	add("")
	for _, t in ipairs(threads) do
		for i, c in ipairs(t.comments) do
			local who = (c.user and c.user ~= "")
				and ("@" .. c.user) or "@unknown"
			if i == 1 then
				add(("**%s**"):format(who))
			else
				add(("**%s** _(reply)_"):format(who))
			end
			add("")
			add_body(c.body)
			add("")
			add("---")
			add("")
		end
	end
	if #drafts > 0 then
		add("## Drafts (unsubmitted)")
		add("")
		for _, d in ipairs(drafts) do
			add("**you** _(draft)_")
			add("")
			add_body(d.body)
			add("")
			add("---")
			add("")
		end
	end
	return lines
end

--- Open a floating window showing the full discussion (all remote replies +
--- any unsubmitted drafts) anchored to the current diff line. When there is no
--- comment on the line, fall through to the default <CR> behaviour (move to
--- the first non-blank of the next line).
function M.view_thread_at_cursor()
	if not state.active_path or not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(state.diff_winid)[1]
	local path = state.active_path

	local threads = {}
	for _, t in ipairs(state.comment_threads) do
		if t.path == path and t.line == cur then
			threads[#threads + 1] = t
		end
	end
	local drafts = {}
	for _, pc in ipairs(state.pending_comments) do
		if pc.path == path and (pc.new_line == cur or pc.old_line == cur) then
			drafts[#drafts + 1] = pc
		end
	end

	if #threads == 0 and #drafts == 0 then
		-- Nothing here — preserve the native <CR> motion.
		pcall(vim.cmd, "normal! +")
		return
	end

	local lines = discussion_lines(path, cur, threads, drafts)

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })

	local screen_lines = vim.o.lines - vim.o.cmdheight
	local width = math.min(84, math.max(48, vim.o.columns - 8))
	local height = math.min(#lines + 1,
		math.max(8, math.floor(screen_lines * 0.6)))

	-- Replace any previous thread popup before opening a fresh one.
	ui.window.close("gitflow_review_thread")
	local has_replies = false
	for _, t in ipairs(threads) do
		if #t.comments > 1 then
			has_replies = true
		end
	end
	local footer = has_replies
		and " R reply · q/<Esc> close "
		or " q/<Esc> close "
	local winid = ui.window.open_float({
		bufnr = bufnr,
		width = width,
		height = height,
		title = " Thread ",
		footer = footer,
		enter = true,
		name = "gitflow_review_thread",
	})
	pcall(vim.api.nvim_set_option_value, "wrap", true, { win = winid })
	pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = winid })
	pcall(vim.api.nvim_set_option_value, "cursorline", false, { win = winid })

	local function close()
		if vim.api.nvim_win_is_valid(winid) then
			pcall(vim.api.nvim_win_close, winid, true)
		end
	end
	local kopts = { buffer = bufnr, silent = true, nowait = true }
	vim.keymap.set("n", "q", close, kopts)
	vim.keymap.set("n", "<Esc>", close, kopts)
	if #threads > 0 then
		vim.keymap.set("n", "R", function()
			close()
			M.reply_to_thread()
		end, kopts)
	end
end

--- Reply to the remote thread on the current diff-pane line.
function M.reply_to_thread()
	local number = state.pr_number
	if not number then
		rstate.notify_warn("No pull request selected")
		return
	end
	if not state.active_path or not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		rstate.notify_warn("Open a file with an existing thread first")
		return
	end
	local thread = thread_at_cursor()
	if not thread then
		rstate.notify_warn("No existing thread on the current line")
		return
	end

	input.prompt({
		multiline = true,
		title = ("Reply to @%s"):format(thread.comments[1].user),
		draft_key = ("review:%s:reply:%s"):format(tostring(number), tostring(thread.id)),
	}, function(text)
		local body = vim.trim(text or "")
		if body == "" then
			rstate.notify_warn("Reply cannot be empty")
			return
		end
		gh_prs.reply_to_review_comment(number, thread.id, body, {}, function(err)
			if err then
				rstate.notify_error(err)
				return
			end
			rstate.notify_info("Reply posted")
			require("gitflow.review.load").refresh()
		end)
	end)
end

return M
