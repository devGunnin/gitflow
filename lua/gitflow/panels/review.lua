local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local ui_render = require("gitflow.ui.render")
local gh_prs = require("gitflow.gh.prs")
local icons = require("gitflow.icons")
local git_diff = require("gitflow.git.diff")
local config = require("gitflow.config")

---@class GitflowPrReviewDraftThread
---@field id integer
---@field path string|nil
---@field hunk string|nil
---@field line integer
---@field start_line integer|nil
---@field end_line integer|nil
---@field body string
---@field _anchor_new_line integer|nil
---@field _anchor_old_line integer|nil
---@field _anchor_start_new_line integer|nil
---@field _anchor_start_old_line integer|nil
---@field _anchor_end_new_line integer|nil
---@field _anchor_end_old_line integer|nil

---@class GitflowPrReviewExistingComment
---@field id integer
---@field path string
---@field line integer|nil
---@field original_line integer|nil
---@field diff_hunk string|nil
---@field body string
---@field user string
---@field in_reply_to_id integer|nil
---@field start_line integer|nil

---@class GitflowPrReviewCommentThread
---@field id integer
---@field path string
---@field line integer|nil
---@field comments GitflowPrReviewExistingComment[]
---@field collapsed boolean
---@field buf_line integer|nil

---@class GitflowPrReviewPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field prev_winid integer|nil
---@field cfg GitflowConfig|nil
---@field pr_number integer|nil
---@field file_markers GitflowDiffFileMarker[]
---@field hunk_markers GitflowDiffHunkMarker[]
---@field line_context table<integer, GitflowDiffLineContext>
---@field comment_threads GitflowPrReviewCommentThread[]
---@field thread_line_map table<integer, integer>
---@field pending_comments GitflowPrReviewDraftThread[]
---@field show_inline_comments boolean
---@field _cached_title string|nil
---@field _cached_diff_text string|nil
---@field _cached_files table[]|nil
---@field _cached_hunks table[]|nil

local M = {}
local REVIEW_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_review_hl")
local REVIEW_FLOAT_FOOTER =
	"]f/[f files  ]c/[c hunks  c comment  S submit"
	.. "  a approve  x changes  R reply"
	.. "  <leader>t toggle  <leader>i inline"
	.. "  <leader>b back  r refresh  q close"

---@param line string
---@return boolean
local function is_diff_file_header_line(line)
	return vim.startswith(line, "diff --git")
		or vim.startswith(line, "index ")
		or line:match("^%-%-%- [ab]/") ~= nil
		or line:match("^%-%-%- /dev/null$") ~= nil
		or line:match("^%+%+%+ [ab]/") ~= nil
		or line:match("^%+%+%+ /dev/null$") ~= nil
		or vim.startswith(line, "new file mode")
		or vim.startswith(line, "deleted file mode")
		or vim.startswith(line, "rename from")
		or vim.startswith(line, "rename to")
		or vim.startswith(line, "similarity index")
		or vim.startswith(line, "old mode")
		or vim.startswith(line, "new mode")
end

---@type GitflowPrReviewPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	prev_winid = nil,
	cfg = nil,
	pr_number = nil,
	file_markers = {},
	hunk_markers = {},
	line_context = {},
	comment_threads = {},
	thread_line_map = {},
	pending_comments = {},
	show_inline_comments = false,
	-- Cached data for local re-renders (avoids API round-trips)
	_cached_title = nil,
	_cached_diff_text = nil,
	_cached_files = nil,
	_cached_hunks = nil,
}

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("review", {
			filetype = "gitflow-diff",
			lines = { "Loading review..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value(
		"filetype", "gitflow-diff", { buf = bufnr }
	)
	vim.api.nvim_set_option_value(
		"syntax", "diff", { buf = bufnr }
	)
	vim.api.nvim_set_option_value(
		"modifiable", false, { buf = bufnr }
	)

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	-- B3: save current window so we can restore it on close
	M.state.prev_winid = vim.api.nvim_get_current_win()

	local title = "Gitflow PR Review"
	if M.state.pr_number then
		title = ("Gitflow PR Review #%d"):format(M.state.pr_number)
	end

	-- B3: fullscreen floating window that overlays the editor
	M.state.winid = ui.window.open_float({
		name = "review",
		bufnr = bufnr,
		width = 1.0,
		height = 1.0,
		row = 0,
		col = 0,
		border = cfg.ui.float.border,
		title = title,
		title_pos = cfg.ui.float.title_pos,
		footer = cfg.ui.float.footer and REVIEW_FLOAT_FOOTER or nil,
		footer_pos = cfg.ui.float.footer_pos,
		on_close = function()
			M.state.winid = nil
		end,
	})

	-- ]c/[c for hunk nav per spec
	local pk = function(action, default)
		return config.resolve_panel_key(
			cfg, "review", action, default
		)
	end

	vim.keymap.set("n", pk("next_file", "]f"), function()
		M.next_file()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("prev_file", "[f"), function()
		M.prev_file()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("next_hunk", "]c"), function()
		M.next_hunk()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("prev_hunk", "[c"), function()
		M.prev_hunk()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("approve", "a"), function()
		M.review_approve()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("request_changes", "x"), function()
		M.review_request_changes()
	end, { buffer = bufnr, silent = true, nowait = true })

	-- c = inline comment per spec, S = submit review
	vim.keymap.set(
		"n", pk("inline_comment", "c"), function()
			M.inline_comment()
		end, { buffer = bufnr, silent = true, nowait = true }
	)

	vim.keymap.set(
		"n", pk("submit_review", "S"), function()
			M.submit_pending_review()
		end, { buffer = bufnr, silent = true, nowait = true }
	)

	-- visual mode c for multi-line inline comments
	vim.keymap.set(
		"v", pk("inline_comment_visual", "c"), function()
			M.inline_comment_visual()
		end, { buffer = bufnr, silent = true, nowait = true }
	)

	vim.keymap.set("n", pk("reply", "R"), function()
		M.reply_to_thread()
	end, { buffer = bufnr, silent = true, nowait = true })

	-- F1: use <leader>t instead of t to avoid shadowing vim motion
	vim.keymap.set(
		"n", pk("toggle_thread", "<leader>t"), function()
			M.toggle_thread()
		end, { buffer = bufnr, silent = true, nowait = true }
	)

	vim.keymap.set(
		"n", pk("toggle_inline", "<leader>i"), function()
			M.toggle_inline_comments()
		end, { buffer = bufnr, silent = true, nowait = true }
	)

	vim.keymap.set("n", pk("refresh", "r"), function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	-- F1: use <leader>b instead of b to avoid shadowing vim motion
	vim.keymap.set(
		"n", pk("back_to_pr", "<leader>b"), function()
			M.back_to_pr()
		end, { buffer = bufnr, silent = true, nowait = true }
	)

	vim.keymap.set("n", pk("close", "q"), function()
		M.close_with_guard()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param text string|nil
---@return string[]
local function split_lines(text)
	local value = tostring(text or "")
	if value == "" then
		return { "(no diff output)" }
	end
	return vim.split(value, "\n", { plain = true, trimempty = false })
end

-- collect_markers / parse_hunk_header / detect_file_status are now
-- shared via git_diff.collect_markers / git_diff.parse_hunk_header

---@param number integer|string|nil
---@return string
local function format_number(number)
	return tostring(number or "?")
end

---@param status string|nil
---@return string
local function status_indicator(status)
	return icons.get("file_status", status or "M")
end

---@param status string|nil
---@return string
local function status_highlight_group(status)
	if status == "A" then
		return "GitflowAdded"
	end
	if status == "D" then
		return "GitflowRemoved"
	end
	return "GitflowModified"
end

---@param comments table[]
---@return GitflowPrReviewCommentThread[]
local function build_comment_threads(comments)
	local threads = {}
	local root_map = {}

	for _, c in ipairs(comments) do
		local user = ""
		if type(c.user) == "table" and c.user.login then
			user = c.user.login
		elseif type(c.user) == "string" then
			user = c.user
		end

		local comment = {
			id = tonumber(c.id) or 0,
			path = c.path or "",
			line = tonumber(c.line) or tonumber(c.original_line),
			original_line = tonumber(c.original_line),
			diff_hunk = c.diff_hunk,
			body = c.body or "",
			user = user,
			in_reply_to_id = tonumber(c.in_reply_to_id),
			start_line = tonumber(c.start_line),
		}

		if not comment.in_reply_to_id then
			local thread = {
				id = comment.id,
				path = comment.path,
				line = comment.line,
				comments = { comment },
				collapsed = false,
				buf_line = nil,
			}
			threads[#threads + 1] = thread
			root_map[comment.id] = thread
		else
			local parent = root_map[comment.in_reply_to_id]
			if parent then
				parent.comments[#parent.comments + 1] = comment
			else
				local thread = {
					id = comment.id,
					path = comment.path,
					line = comment.line,
					comments = { comment },
					collapsed = false,
					buf_line = nil,
				}
				threads[#threads + 1] = thread
				root_map[comment.id] = thread
			end
		end
	end

	return threads
end

---@param thread GitflowPrReviewCommentThread
---@return string[]
local function render_thread_lines(thread)
	local out = {}
	local header = ("  >> [%s] @%s on %s"):format(
		thread.collapsed and "+" or "-",
		thread.comments[1].user,
		thread.path
	)
	local line = tonumber(thread.comments[1].line)
	if line then
		header = header .. (":%d"):format(line)
	end
	out[#out + 1] = header

	if not thread.collapsed then
		for _, c in ipairs(thread.comments) do
			local body_lines = vim.split(c.body, "\n", {
				plain = true, trimempty = true,
			})
			for _, bl in ipairs(body_lines) do
				if #bl > 96 then
					bl = bl:sub(1, 93) .. "..."
				end
				out[#out + 1] = ("  |  @%s: %s"):format(c.user, bl)
			end
		end
	end
	return out
end

---@param title string
---@param diff_text string
---@param files GitflowPrReviewFileMarker[]
---@param hunks GitflowPrReviewHunkMarker[]
---@param comment_threads GitflowPrReviewCommentThread[]
local function render_review(
	title, diff_text, files, hunks, comment_threads
)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(title, render_opts)
	local header_line_count = #lines
	lines[#lines + 1] = ("Files: %d  Hunks: %d"):format(#files, #hunks)
	for _, f in ipairs(files) do
		lines[#lines + 1] = ui_render.entry(
			("%s %s"):format(status_indicator(f.status), f.path)
		)
	end
	if #M.state.pending_comments > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] =
			("Pending comments: %d (press S to submit)")
				:format(#M.state.pending_comments)
	end
	lines[#lines + 1] = ""

	-- B1: render existing review comment threads above the diff
	local thread_line_map = {}
	if #comment_threads > 0 then
		lines[#lines + 1] =
			("Review Comments (%d threads)"):format(#comment_threads)
		for idx, thread in ipairs(comment_threads) do
			thread.buf_line = #lines + 1
			local thread_lines = render_thread_lines(thread)
			for _, tl in ipairs(thread_lines) do
				lines[#lines + 1] = tl
				thread_line_map[#lines] = idx
			end
		end
		lines[#lines + 1] = ""
	end

	local diff_lines = split_lines(diff_text)
	local diff_start_line = #lines + 1

	-- N3: render diff with dual line numbers
	for _, line in ipairs(diff_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("review", lines)

	M.state.file_markers, M.state.hunk_markers, M.state.line_context =
		git_diff.collect_markers(diff_lines, diff_start_line)
	M.state.comment_threads = comment_threads
	M.state.thread_line_map = thread_line_map

	if M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) then
		ui_render.apply_panel_highlights(M.state.bufnr, REVIEW_HIGHLIGHT_NS, lines, {})
		local files_summary_idx = header_line_count
		local first_file_idx = files_summary_idx + 1
		vim.api.nvim_buf_add_highlight(
			M.state.bufnr,
			REVIEW_HIGHLIGHT_NS,
			"GitflowHeader",
			files_summary_idx,
			0,
			-1
		)

		for idx, file in ipairs(files) do
			vim.api.nvim_buf_add_highlight(
				M.state.bufnr,
				REVIEW_HIGHLIGHT_NS,
				status_highlight_group(file.status),
				first_file_idx + idx - 1,
				0,
				-1
			)
		end

		for line_no, line in ipairs(lines) do
			if vim.startswith(line, "Review Comments") then
				vim.api.nvim_buf_add_highlight(
					M.state.bufnr,
					REVIEW_HIGHLIGHT_NS,
					"GitflowHeader",
					line_no - 1,
					0,
					-1
				)
			elseif vim.startswith(line, "  >>") or vim.startswith(line, "  |") then
				vim.api.nvim_buf_add_highlight(
					M.state.bufnr,
					REVIEW_HIGHLIGHT_NS,
					"GitflowReviewComment",
					line_no - 1,
					0,
					-1
				)
			end
		end

		for idx, line in ipairs(diff_lines) do
			local group = nil
			if is_diff_file_header_line(line) then
				group = "GitflowDiffFileHeader"
			elseif vim.startswith(line, "@@") then
				group = "GitflowDiffHunkHeader"
			elseif vim.startswith(line, "+") then
				group = "GitflowAdded"
			elseif vim.startswith(line, "-") then
				group = "GitflowRemoved"
			elseif vim.startswith(line, " ") then
				group = "GitflowDiffContext"
			end
			if group then
				vim.api.nvim_buf_add_highlight(
					M.state.bufnr,
					REVIEW_HIGHLIGHT_NS,
					group,
					diff_start_line + idx - 2,
					0,
					-1
				)
			end
		end
	end

	-- N3: apply virtual text for dual line numbers via extmarks
	if M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) then
		local ns = vim.api.nvim_create_namespace("gitflow_review_lines")
		vim.api.nvim_buf_clear_namespace(M.state.bufnr, ns, 0, -1)
		for line_no, ctx in pairs(M.state.line_context) do
			if ctx.old_line or ctx.new_line then
				local old_str = ctx.old_line
					and tostring(ctx.old_line) or " "
				local new_str = ctx.new_line
					and tostring(ctx.new_line) or " "
				local label = ("%4s %4s"):format(old_str, new_str)
				pcall(
					vim.api.nvim_buf_set_extmark,
					M.state.bufnr, ns, line_no - 1, 0,
					{ virt_text = { { label, "GitflowDiffLineNr" } },
						virt_text_pos = "right_align" }
				)
			end
		end
	end

	-- B1: place inline comment indicators next to corresponding
	-- diff lines using extmarks
	if M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) then
		local ns_comments = vim.api.nvim_create_namespace(
			"gitflow_review_comments"
		)
		vim.api.nvim_buf_clear_namespace(
			M.state.bufnr, ns_comments, 0, -1
		)
		for _, thread in ipairs(comment_threads) do
			local target_line = nil
			local comment = thread.comments[1]
			if comment.path and comment.line then
				for buf_line, ctx in pairs(M.state.line_context) do
					if ctx.path == comment.path
						and ctx.new_line == comment.line then
						target_line = buf_line
						break
					end
				end
			end
			if target_line then
				local label = (" [%d comments]"):format(
					#thread.comments
				)
				local extmark_opts = {
					virt_text = {
						{
							label,
							"GitflowReviewChangesRequested",
						},
					},
					virt_text_pos = "eol",
				}
				if M.state.show_inline_comments then
					local virt_lines = {}
					for _, c in ipairs(thread.comments) do
						local body_lines = vim.split(
							c.body, "\n",
							{ plain = true, trimempty = true }
						)
						for bi, bl in ipairs(body_lines) do
							if #bl > 96 then
								bl = bl:sub(1, 93) .. "..."
							end
							local prefix = bi == 1
								and ("  @%s: "):format(c.user)
								or "        "
							virt_lines[#virt_lines + 1] = {
								{
									prefix .. bl,
									"GitflowReviewComment",
								},
							}
						end
					end
					extmark_opts.virt_lines = virt_lines
				end
				pcall(
					vim.api.nvim_buf_set_extmark,
					M.state.bufnr, ns_comments,
					target_line - 1, 0,
					extmark_opts
				)
			end
		end

		-- B2: show pending inline comment indicators
		for _, pc in ipairs(M.state.pending_comments) do
			if pc.line >= 1
				and pc.line <= vim.api.nvim_buf_line_count(
					M.state.bufnr
				) then
				local pending_label =
					(" [pending #%d]"):format(pc.id)
				pcall(
					vim.api.nvim_buf_set_extmark,
					M.state.bufnr, ns_comments,
					pc.line - 1, 0,
					{ virt_text = {
						{ pending_label, "GitflowReviewComment" },
					}, virt_text_pos = "eol" }
				)
			end
		end
	end
end

---@param message string
local function render_loading(message)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow PR Review", render_opts)
	lines[#lines + 1] = ui_render.entry(message)
	ui.buffer.update("review", lines)
	M.state.file_markers = {}
	M.state.hunk_markers = {}
	M.state.line_context = {}

	if M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) then
		ui_render.apply_panel_highlights(
			M.state.bufnr,
			REVIEW_HIGHLIGHT_NS,
			lines,
			{}
		)
	end
end

---@param markers table[]
---@param direction 1|-1
local function jump_to_marker(markers, direction)
	if not M.state.winid
		or not vim.api.nvim_win_is_valid(M.state.winid) then
		return
	end
	if #markers == 0 then
		utils.notify("No diff markers available", vim.log.levels.WARN)
		return
	end

	local cursor_line =
		vim.api.nvim_win_get_cursor(M.state.winid)[1]
	if direction > 0 then
		for _, marker in ipairs(markers) do
			if marker.line > cursor_line then
				vim.api.nvim_win_set_cursor(
					M.state.winid, { marker.line, 0 }
				)
				return
			end
		end
		vim.api.nvim_win_set_cursor(
			M.state.winid, { markers[1].line, 0 }
		)
		return
	end

	for i = #markers, 1, -1 do
		local marker = markers[i]
		if marker.line < cursor_line then
			vim.api.nvim_win_set_cursor(
				M.state.winid, { marker.line, 0 }
			)
			return
		end
	end
	vim.api.nvim_win_set_cursor(
		M.state.winid, { markers[#markers].line, 0 }
	)
end

---@return integer|nil
local function current_pr_number()
	return M.state.pr_number
end

---@param mode "approve"|"request_changes"|"comment"
---@param body string
---@param on_success_message string
local function submit_review(mode, body, on_success_message)
	local number = current_pr_number()
	if not number then
		utils.notify(
			"No pull request selected for review",
			vim.log.levels.WARN
		)
		return
	end

	gh_prs.review(number, mode, body, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(on_success_message, vim.log.levels.INFO)
		M.refresh()
	end)
end

---@return table[]|nil, string|nil
local function collect_api_comments()
	local api_comments = {}

	---@param path string|nil
	---@param anchor_new integer|nil
	---@param anchor_old integer|nil
	---@return integer|nil
	local function find_buffer_line_for_anchor(path, anchor_new, anchor_old)
		if not path or path == "" then
			return nil
		end
		for buf_line, ctx in pairs(M.state.line_context) do
			if ctx.path == path
				and anchor_new
				and ctx.new_line == anchor_new then
				return buf_line
			end
		end
		for buf_line, ctx in pairs(M.state.line_context) do
			if ctx.path == path
				and anchor_old
				and ctx.old_line == anchor_old then
				return buf_line
			end
		end
		return nil
	end

	---@param path string|nil
	---@param buf_line integer|nil
	---@param fallback_new integer|nil
	---@param fallback_old integer|nil
	---@return table|nil
	local function resolve_api_target(path, buf_line, fallback_new, fallback_old)
		if path and path ~= ""
			and buf_line
			and M.state.line_context[buf_line] then
			local ctx = M.state.line_context[buf_line]
			if ctx.path == path then
				if ctx.new_line then
					return { line = ctx.new_line, side = "RIGHT" }
				end
				if ctx.old_line then
					return { line = ctx.old_line, side = "LEFT" }
				end
			end
		end
		local anchored_buf = find_buffer_line_for_anchor(
			path, fallback_new, fallback_old
		)
		if anchored_buf and M.state.line_context[anchored_buf] then
			local anchored_ctx = M.state.line_context[anchored_buf]
			if anchored_ctx.new_line then
				return { line = anchored_ctx.new_line, side = "RIGHT" }
			end
			if anchored_ctx.old_line then
				return { line = anchored_ctx.old_line, side = "LEFT" }
			end
		end
		if fallback_new then
			return { line = fallback_new, side = "RIGHT" }
		end
		if fallback_old then
			return { line = fallback_old, side = "LEFT" }
		end
		return nil
	end

	local unresolved_ids = {}
	for _, pc in ipairs(M.state.pending_comments) do
		if pc.path and pc.path ~= "" then
			local entry = {
				path = pc.path,
				body = pc.body,
			}

			local primary = resolve_api_target(
				pc.path, pc.line,
				pc._anchor_new_line, pc._anchor_old_line
			)
			if not primary then
				unresolved_ids[#unresolved_ids + 1] =
					tostring(pc.id or "?")
				goto continue
			end
			entry.line = primary.line
			entry.side = primary.side

			if pc.start_line and pc.end_line then
				local start_target = resolve_api_target(
					pc.path,
					pc.start_line,
					pc._anchor_start_new_line or pc._anchor_new_line,
					pc._anchor_start_old_line or pc._anchor_old_line
				)
				local end_target = resolve_api_target(
					pc.path,
					pc.end_line,
					pc._anchor_end_new_line or pc._anchor_new_line,
					pc._anchor_end_old_line or pc._anchor_old_line
				)
				if start_target and end_target
					and start_target.side == end_target.side then
					entry.start_line = start_target.line
					entry.start_side = start_target.side
					entry.line = end_target.line
					entry.side = end_target.side
				end
			end

			api_comments[#api_comments + 1] = entry
		else
			unresolved_ids[#unresolved_ids + 1] = tostring(pc.id or "?")
		end
		::continue::
	end

	if #unresolved_ids > 0 then
		return nil, (
			"Cannot submit pending comment(s) with unresolved diff lines "
			.. "(ids: %s). Re-open those comments on valid diff lines and retry."
		):format(table.concat(unresolved_ids, ", "))
	end

	return api_comments, nil
end

---@param mode "approve"|"request_changes"|"comment"
---@param body string
---@param on_success_message string
local function submit_review_with_pending(mode, body, on_success_message)
	if #M.state.pending_comments == 0 then
		submit_review(mode, body, on_success_message)
		return
	end

	local number = current_pr_number()
	if not number then
		utils.notify(
			"No pull request selected for review",
			vim.log.levels.WARN
		)
		return
	end

	local api_comments, collect_err = collect_api_comments()
	if collect_err then
		utils.notify(collect_err, vim.log.levels.WARN)
		return
	end
	gh_prs.submit_review(
		number, mode, body, api_comments, {},
		function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			local count = #M.state.pending_comments
			M.state.pending_comments = {}
			utils.notify(
				("Review submitted (%s) with %d comment(s)")
					:format(mode, count),
				vim.log.levels.INFO
			)
			M.refresh()
		end
	)
end

---@param mode "approve"|"request_changes"|"comment"
---@param prompt string
---@param on_success_message string
local function prompt_and_submit(mode, prompt, on_success_message)
	input.prompt({ prompt = prompt }, function(body)
		submit_review_with_pending(
			mode,
			body or "",
			on_success_message
		)
	end)
end

---@param include_context boolean
---@return string
local function contextual_comment_prefix(include_context)
	if not include_context then
		return ""
	end
	if not M.state.winid
		or not vim.api.nvim_win_is_valid(M.state.winid) then
		return ""
	end

	local line = vim.api.nvim_win_get_cursor(M.state.winid)[1]
	local context = M.state.line_context[line]
	if not context then
		return ""
	end

	local details = {}
	if context.path and context.path ~= "" then
		details[#details + 1] = ("file=%s"):format(context.path)
	end
	if context.hunk and context.hunk ~= "" then
		details[#details + 1] = ("hunk=%s"):format(context.hunk)
	end
	if #details == 0 then
		return ""
	end
	return ("[%s] "):format(table.concat(details, " "))
end

function M.review_approve()
	prompt_and_submit(
		"approve",
		"Approval message (optional): ",
		"Review submitted (approved)"
	)
end

function M.review_request_changes()
	prompt_and_submit(
		"request_changes",
		"Request changes message: ",
		"Review submitted (changes requested)"
	)
end

function M.review_comment()
	prompt_and_submit(
		"comment",
		"Review comment (optional): ",
		"Review submitted (comment)"
	)
end

-- B2: submit all pending inline comments as a batched review
function M.submit_pending_review()
	local number = current_pr_number()
	if not number then
		utils.notify(
			"No pull request selected for review",
			vim.log.levels.WARN
		)
		return
	end

	if #M.state.pending_comments == 0 then
		-- No pending comments, fall back to general comment
		prompt_and_submit(
			"comment",
			"Review comment (optional): ",
			"Review submitted (comment)"
		)
		return
	end

	input.prompt({
		prompt = ("Submit %d pending comment(s)"
			.. " — mode (approve/request_changes/comment): "
			):format(#M.state.pending_comments),
	}, function(mode_input)
		local mode = vim.trim(mode_input or "comment")
		if mode == "" then
			mode = "comment"
		end
		if mode == "request-changes" then
			mode = "request_changes"
		end
		if mode ~= "approve"
			and mode ~= "request_changes"
			and mode ~= "comment" then
			utils.notify(
				"Invalid mode — use approve,"
					.. " request_changes, or comment",
				vim.log.levels.WARN
			)
			return
		end

		input.prompt({
			prompt = "Review body (optional): ",
		}, function(body_input)
			local body = vim.trim(body_input or "")
			submit_review_with_pending(
				mode, body,
				("Review submitted (%s)"):format(mode)
			)
		end)
	end)
end

function M.inline_comment()
	input.prompt({ prompt = "Inline comment: " }, function(comment)
		local body = vim.trim(comment or "")
		if body == "" then
			utils.notify(
				"Comment cannot be empty", vim.log.levels.WARN
			)
			return
		end

		local cursor_line = M.state.winid
			and vim.api.nvim_win_get_cursor(M.state.winid)[1]
			or 1
		local context = M.state.line_context[cursor_line] or {}
		if not context.path or context.path == ""
			or (not context.new_line and not context.old_line) then
			utils.notify(
				"Move cursor to a diff content line before adding a comment",
				vim.log.levels.WARN
			)
			return
		end
		local number = #M.state.pending_comments + 1
		M.state.pending_comments[#M.state.pending_comments + 1] = {
			id = number,
			path = context.path,
			hunk = context.hunk,
			line = cursor_line,
			body = body,
			_anchor_new_line = context.new_line,
			_anchor_old_line = context.old_line,
		}
		utils.notify(
			("Inline comment queued (#%d)"
				.. " — press S to submit review"):format(number),
			vim.log.levels.INFO
		)
		M.re_render()
	end)
end

-- visual mode multi-line inline comment
function M.inline_comment_visual()
	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")
	-- Exit visual mode
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
		"nx", false
	)

	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end

	input.prompt(
		{ prompt = "Inline comment (range): " },
		function(comment)
			local body = vim.trim(comment or "")
			if body == "" then
				utils.notify(
					"Comment cannot be empty",
					vim.log.levels.WARN
				)
				return
			end

			local start_ctx =
				M.state.line_context[start_line] or {}
			local end_ctx =
				M.state.line_context[end_line] or {}
			if not start_ctx.path
				or start_ctx.path == ""
				or start_ctx.path ~= end_ctx.path then
				utils.notify(
					"Range comments must stay within one diff file",
					vim.log.levels.WARN
				)
				return
			end
			if (not start_ctx.new_line and not start_ctx.old_line)
				or (not end_ctx.new_line and not end_ctx.old_line) then
				utils.notify(
					"Select diff content lines for range comments",
					vim.log.levels.WARN
				)
				return
			end
			local number = #M.state.pending_comments + 1
			M.state.pending_comments[
				#M.state.pending_comments + 1
			] = {
				id = number,
				path = start_ctx.path,
				hunk = start_ctx.hunk,
				line = end_line,
				start_line = start_line,
				end_line = end_line,
				body = body,
				_anchor_new_line = end_ctx.new_line,
				_anchor_old_line = end_ctx.old_line,
				_anchor_start_new_line = start_ctx.new_line,
				_anchor_start_old_line = start_ctx.old_line,
				_anchor_end_new_line = end_ctx.new_line,
				_anchor_end_old_line = end_ctx.old_line,
			}
			utils.notify(
				("Inline comment queued (#%d, lines %d-%d)"
					.. " — press S to submit review"):format(
					number, start_line, end_line
				),
				vim.log.levels.INFO
			)
			M.re_render()
		end
	)
end

function M.reply_to_thread()
	-- Check if cursor is on an existing remote thread first
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		local cursor = vim.api.nvim_win_get_cursor(M.state.winid)[1]
		local thread_idx = M.state.thread_line_map[cursor]
		if thread_idx then
			local thread = M.state.comment_threads[thread_idx]
			if thread then
				local prompt_text =
					("Reply to @%s's thread: "):format(
						thread.comments[1].user
					)
				input.prompt(
					{ prompt = prompt_text },
					function(reply)
						local body = vim.trim(reply or "")
						if body == "" then
							utils.notify(
								"Reply cannot be empty",
								vim.log.levels.WARN
							)
							return
						end
						local number = current_pr_number()
						if not number then
							utils.notify(
								"No PR selected",
								vim.log.levels.WARN
							)
							return
						end
						gh_prs.reply_to_review_comment(
							number, thread.id, body, {},
							function(err)
								if err then
									utils.notify(
										err,
										vim.log.levels.ERROR
									)
									return
								end
								utils.notify(
									"Reply posted",
									vim.log.levels.INFO
								)
								M.refresh()
							end
						)
					end
				)
				return
			end
		end
	end

	-- Fallback: reply to last local pending comment
	local pc = M.state.pending_comments[
		#M.state.pending_comments
	]
	if not pc then
		utils.notify(
			"No inline thread found to reply to",
			vim.log.levels.WARN
		)
		return
	end

	input.prompt(
		{ prompt = ("Reply to note #%d: "):format(pc.id) },
		function(reply)
			local body = vim.trim(reply or "")
			if body == "" then
				utils.notify(
					"Reply cannot be empty",
					vim.log.levels.WARN
				)
				return
			end

			local prefix = contextual_comment_prefix(false)
			local formatted =
				("Reply to inline note #%d: %s%s"):format(
					pc.id, prefix, body
				)
			submit_review(
				"comment",
				formatted,
				("Reply submitted for note #%d"):format(
					pc.id
				)
			)
		end
	)
end

-- B5: toggle collapse/expand for comment threads
function M.toggle_thread()
	if not M.state.winid
		or not vim.api.nvim_win_is_valid(M.state.winid) then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(M.state.winid)[1]
	local thread_idx = M.state.thread_line_map[cursor]
	if not thread_idx then
		utils.notify("No comment thread under cursor", vim.log.levels.WARN)
		return
	end
	local thread = M.state.comment_threads[thread_idx]
	if not thread then
		return
	end
	thread.collapsed = not thread.collapsed
	-- Re-render preserving state
	M.re_render()
end

function M.toggle_inline_comments()
	M.state.show_inline_comments = not M.state.show_inline_comments
	M.re_render()
end

function M.next_file()
	jump_to_marker(M.state.file_markers, 1)
end

function M.prev_file()
	jump_to_marker(M.state.file_markers, -1)
end

function M.next_hunk()
	jump_to_marker(M.state.hunk_markers, 1)
end

function M.prev_hunk()
	jump_to_marker(M.state.hunk_markers, -1)
end

--- Capture the cursor's diff-context anchor before a re-render so that
--- the cursor can be restored to the same logical diff line afterward.
---@return table|nil anchor  {path, new_line, old_line} or nil
local function capture_cursor_anchor()
	if not M.state.winid
		or not vim.api.nvim_win_is_valid(M.state.winid) then
		return nil
	end
	local cursor_line =
		vim.api.nvim_win_get_cursor(M.state.winid)[1]
	local ctx = M.state.line_context[cursor_line]
	if ctx then
		return {
			path = ctx.path,
			new_line = ctx.new_line,
			old_line = ctx.old_line,
			buf_line = cursor_line,
		}
	end
	-- Cursor is not on a diff line; save raw buffer line as fallback
	return { buf_line = cursor_line }
end

--- Restore the cursor to the buffer line matching a previously captured
--- diff-context anchor.  Falls back to the saved buffer line (clamped).
---@param anchor table|nil
local function restore_cursor_from_anchor(anchor)
	if not anchor then
		return
	end
	if not M.state.winid
		or not vim.api.nvim_win_is_valid(M.state.winid) then
		return
	end
	-- Try to find the same logical diff line in the new line_context
	if anchor.path then
		for buf_line, ctx in pairs(M.state.line_context) do
			local match = ctx.path == anchor.path
			if match and anchor.new_line and ctx.new_line then
				match = ctx.new_line == anchor.new_line
			elseif match and anchor.old_line and ctx.old_line then
				match = ctx.old_line == anchor.old_line
			else
				match = false
			end
			if match then
				pcall(vim.api.nvim_win_set_cursor,
					M.state.winid, { buf_line, 0 })
				return
			end
		end
	end
	-- Fallback: clamp original buffer line to new buffer length
	if anchor.buf_line and M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr) then
		local max_line =
			vim.api.nvim_buf_line_count(M.state.bufnr)
		local target = math.min(anchor.buf_line, max_line)
		pcall(vim.api.nvim_win_set_cursor,
			M.state.winid, { target, 0 })
	end
end

--- After a re-render, update pending_comments buffer-line references
--- so that extmark indicators land on the correct new buffer lines.
local function update_pending_comment_lines()
	---@param path string|nil
	---@param anchor_new integer|nil
	---@param anchor_old integer|nil
	---@return integer|nil
	local function find_buffer_line_for_anchor(path, anchor_new, anchor_old)
		if not path or path == "" then
			return nil
		end
		for buf_line, ctx in pairs(M.state.line_context) do
			if ctx.path == path
				and anchor_new
				and ctx.new_line == anchor_new then
				return buf_line
			end
		end
		for buf_line, ctx in pairs(M.state.line_context) do
			if ctx.path == path
				and anchor_old
				and ctx.old_line == anchor_old then
				return buf_line
			end
		end
		return nil
	end

	for _, pc in ipairs(M.state.pending_comments) do
		if pc.path then
			local remapped_line = find_buffer_line_for_anchor(
				pc.path, pc._anchor_new_line, pc._anchor_old_line
			)
			if remapped_line then
				pc.line = remapped_line
			end

			if pc.start_line then
				local remapped_start = find_buffer_line_for_anchor(
					pc.path,
					pc._anchor_start_new_line or pc._anchor_new_line,
					pc._anchor_start_old_line or pc._anchor_old_line
				)
				if remapped_start then
					pc.start_line = remapped_start
				end
			end

			if pc.end_line then
				local remapped_end = find_buffer_line_for_anchor(
					pc.path,
					pc._anchor_end_new_line or pc._anchor_new_line,
					pc._anchor_end_old_line or pc._anchor_old_line
				)
				if remapped_end then
					pc.end_line = remapped_end
				end
			end
		end
	end
end

function M.re_render()
	if not M.state.bufnr
		or not vim.api.nvim_buf_is_valid(M.state.bufnr) then
		return
	end
	-- Fast path: rebuild buffer from cached data without API calls
	if M.state._cached_title and M.state._cached_diff_text then
		local anchor = capture_cursor_anchor()
		render_review(
			M.state._cached_title,
			M.state._cached_diff_text,
			M.state._cached_files or {},
			M.state._cached_hunks or {},
			M.state.comment_threads
		)
		update_pending_comment_lines()
		restore_cursor_from_anchor(anchor)
		return
	end
	-- Fallback: no cached data yet, do a full refresh
	M.refresh()
end

function M.refresh()
	if not M.state.cfg or not M.state.pr_number then
		return
	end

	local number = M.state.pr_number
	-- Preserve collapsed state across refreshes
	local collapsed_map = {}
	for _, thread in ipairs(M.state.comment_threads) do
		if thread.collapsed then
			collapsed_map[thread.id] = true
		end
	end

	-- Capture cursor anchor before the buffer is rebuilt
	local anchor = capture_cursor_anchor()

	render_loading(
		("Loading review for PR #%s..."):format(format_number(number))
	)
	gh_prs.view(number, {}, function(view_err, pr)
		if view_err then
			render_loading("Failed to load pull request metadata")
			utils.notify(view_err, vim.log.levels.ERROR)
			return
		end

		gh_prs.diff(number, {}, function(diff_err, diff_text)
			if diff_err then
				render_loading("Failed to load pull request diff")
				utils.notify(diff_err, vim.log.levels.ERROR)
				return
			end

			-- B1: fetch existing review comments
			gh_prs.review_comments(
				number, {},
				function(rc_err, comments)
					local comment_threads = {}
					if not rc_err and comments then
						comment_threads =
							build_comment_threads(comments)
					end

					-- Restore collapsed state
					for _, thread in ipairs(comment_threads) do
						if collapsed_map[thread.id] then
							thread.collapsed = true
						end
					end

					local pr_title =
						vim.trim(tostring(pr and pr.title or ""))
					if pr_title == "" then
						pr_title = "(untitled)"
					end
					local title =
						("PR #%s Review: %s"):format(
							format_number(
								pr and pr.number or number
							),
							pr_title
						)

					local preview_lines = split_lines(diff_text)
					local files, hunks =
						git_diff.collect_markers(preview_lines, 1)

					-- Cache data for fast local re-renders
					M.state._cached_title = title
					M.state._cached_diff_text = diff_text or ""
					M.state._cached_files = files
					M.state._cached_hunks = hunks

					render_review(
						title, diff_text or "",
						files, hunks, comment_threads
					)

					-- Restore cursor to the same diff line
					update_pending_comment_lines()
					restore_cursor_from_anchor(anchor)
				end
			)
		end)
	end)
end

---@param cfg GitflowConfig
---@param pr_number integer|string
function M.open(cfg, pr_number)
	M.state.cfg = cfg
	M.state.pr_number = tonumber(pr_number)
	ensure_window(cfg)
	M.refresh()
end

function M.back_to_pr()
	local number = current_pr_number()
	if not number then
		return
	end

	local pr_panel = require("gitflow.panels.prs")
	if M.state.cfg then
		pr_panel.open_view(number, M.state.cfg)
	else
		pr_panel.open_view(number)
	end
end

function M.close_with_guard()
	local count = #M.state.pending_comments
	if count > 0 then
		local msg = (
			"Are you sure you want to discard the review?"
			.. " You have %d comment%s so far."
		):format(count, count == 1 and "" or "s")
		local confirmed = input.confirm(msg, {
			choices = { "&Yes", "&No" },
			default_choice = 2,
		})
		if not confirmed then
			return
		end
	end
	M.close()
end

function M.close()
	-- B3: remember prev window before closing overlay
	local prev = M.state.prev_winid

	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("review")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("review")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.prev_winid = nil
	M.state.cfg = nil
	M.state.pr_number = nil
	M.state.file_markers = {}
	M.state.hunk_markers = {}
	M.state.line_context = {}
	M.state.comment_threads = {}
	M.state.thread_line_map = {}
	M.state.pending_comments = {}
	M.state.show_inline_comments = false
	M.state._cached_title = nil
	M.state._cached_diff_text = nil
	M.state._cached_files = nil
	M.state._cached_hunks = nil

	-- B3: restore focus to previous window
	if prev and vim.api.nvim_win_is_valid(prev) then
		vim.api.nvim_set_current_win(prev)
	end
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

-- B4: submit-review callable from command line
---@param mode "approve"|"request_changes"|"comment"
---@param body string
function M.submit_review_direct(mode, body)
	submit_review_with_pending(
		mode,
		body,
		("Review submitted (%s)"):format(mode)
	)
end

-- B4: respond to an existing review - list reviews and let user pick
---@param number integer|string
function M.respond_to_review(number)
	local pr_num = tonumber(number)
	if not pr_num then
		utils.notify(
			"Invalid PR number for respond", vim.log.levels.ERROR
		)
		return
	end

	gh_prs.list_reviews(pr_num, {}, function(err, reviews)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		if not reviews or #reviews == 0 then
			utils.notify(
				"No reviews found on this PR", vim.log.levels.WARN
			)
			return
		end

		local latest = reviews[#reviews]
		local author = ""
		if type(latest.user) == "table" and latest.user.login then
			author = latest.user.login
		end
		local review_body = latest.body or "(no body)"
		if #review_body > 80 then
			review_body = review_body:sub(1, 77) .. "..."
		end

		utils.notify(
			("Latest review by @%s [%s]: %s"):format(
				author, latest.state or "?", review_body
			),
			vim.log.levels.INFO
		)

		input.prompt(
			{ prompt = ("Reply to @%s's review: "):format(author) },
			function(reply)
				local body = vim.trim(reply or "")
				if body == "" then
					utils.notify(
						"Reply cannot be empty",
						vim.log.levels.WARN
					)
					return
				end
				gh_prs.comment(pr_num, body, {}, function(cerr)
					if cerr then
						utils.notify(cerr, vim.log.levels.ERROR)
						return
					end
					utils.notify(
						("Response posted to PR #%d"):format(
							pr_num
						),
						vim.log.levels.INFO
					)
				end)
			end
		)
	end)
end

return M
