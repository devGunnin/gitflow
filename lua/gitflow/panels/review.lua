--- lua/gitflow/panels/review.lua
---
--- PR review mode: a dedicated tabpage with a persistent file list on
--- the left and a regular neovim editing area on the right. Files opened
--- from the list are displayed with inline diff annotations from the PR
--- (added lines highlighted, removed lines as virt_lines, hunk markers).
--- Single + multi-line comments are queued locally and persisted to disk
--- under stdpath('data')/gitflow/review/ so a crashed editor can resume.

local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local gh_prs = require("gitflow.gh.prs")
local git_branch = require("gitflow.git.branch")
local inline = require("gitflow.review.inline")
local cache = require("gitflow.review.cache")

---@class GitflowPrReviewFile
---@field path string
---@field status "A"|"D"|"M"|"R"
---@field additions integer|nil
---@field deletions integer|nil

---@class GitflowPrReviewPending
---@field id integer
---@field path string
---@field hunk string|nil
---@field body string
---@field new_line integer|nil
---@field old_line integer|nil
---@field start_new_line integer|nil
---@field start_old_line integer|nil
---@field created_at string

---@class GitflowPrReviewRemoteComment
---@field id integer
---@field path string
---@field line integer|nil
---@field original_line integer|nil
---@field body string
---@field user string
---@field in_reply_to_id integer|nil
---@field start_line integer|nil

---@class GitflowPrReviewThread
---@field id integer
---@field path string
---@field line integer|nil
---@field comments GitflowPrReviewRemoteComment[]
---@field collapsed boolean

---@class GitflowPrReviewState
---@field cfg GitflowConfig|nil
---@field pr_number integer|nil
---@field pr_title string|nil
---@field pr_author string|nil
---@field pr_head string|nil
---@field pr_base string|nil
---@field repo_slug string|nil
---@field tabpage integer|nil
---@field file_list_winid integer|nil
---@field file_list_bufnr integer|nil
---@field diff_winid integer|nil
---@field files GitflowPrReviewFile[]
---@field file_diffs table<string, GitflowReviewFileDiff>
---@field comment_threads GitflowPrReviewThread[]
---@field pending_comments GitflowPrReviewPending[]
---@field annotated_buffers integer[]
---@field active_path string|nil
---@field active_bufnr integer|nil
---@field active_file_idx integer|nil
---@field hunk_anchors integer[]
---@field show_inline_comments boolean
---@field collapsed_dirs table<string, boolean>
---@field file_markers table[]
---@field hunk_markers table[]
---@field line_context table

local M = {}

---@type GitflowPrReviewState
M.state = {
	cfg = nil,
	pr_number = nil,
	pr_title = nil,
	pr_author = nil,
	pr_head = nil,
	pr_base = nil,
	repo_slug = nil,
	tabpage = nil,
	file_list_winid = nil,
	file_list_bufnr = nil,
	diff_winid = nil,
	files = {},
	file_diffs = {},
	comment_threads = {},
	pending_comments = {},
	annotated_buffers = {},
	active_path = nil,
	active_bufnr = nil,
	active_file_idx = nil,
	hunk_anchors = {},
	show_inline_comments = true,
	collapsed_dirs = {},
	repo_toplevel = nil,
	-- Legacy compat shape (kept so :Gitflow pr submit-review / external
	-- callers that read state.* don't crash).
	file_markers = {},
	hunk_markers = {},
	line_context = {},
}

local FILE_LIST_HL_NS = vim.api.nvim_create_namespace("gitflow_review_file_list")
local AUGROUP = vim.api.nvim_create_augroup("GitflowReview", { clear = true })

local FILE_LIST_WIDTH = 44
local TREE_INDENT = "  "

local function notify_info(msg)
	utils.notify(msg, vim.log.levels.INFO)
end

local function notify_warn(msg)
	utils.notify(msg, vim.log.levels.WARN)
end

local function notify_error(msg)
	utils.notify(msg, vim.log.levels.ERROR)
end

---@param value string|nil
---@return string
local function fmt_number(value)
	return tostring(value or "?")
end

---@param value any
---@return integer|nil
local function as_integer(value)
	local n = tonumber(value)
	if not n then
		return nil
	end
	return math.floor(n)
end

---@param status string|nil
---@return string
local function status_indicator(status)
	if status == "A" then
		return "+"
	elseif status == "D" then
		return "-"
	elseif status == "R" then
		return ">"
	end
	return "~"
end

---@param status string|nil
---@return string
local function status_hl(status)
	if status == "A" then
		return "GitflowAdded"
	elseif status == "D" then
		return "GitflowRemoved"
	elseif status == "R" then
		return "GitflowModified"
	end
	return "GitflowModified"
end

---@return string
local function banner_text()
	local n = M.state.pr_number and tostring(M.state.pr_number) or "?"
	local title = M.state.pr_title or "(loading)"
	local pending = #M.state.pending_comments
	local pending_label = ""
	if pending > 0 then
		pending_label = (" • %d draft%s"):format(
			pending, pending == 1 and "" or "s"
		)
	end
	local author = M.state.pr_author and ("@" .. M.state.pr_author) or ""
	return ("  PR REVIEW #%s  %s  %s%s "):format(n, title, author, pending_label)
end

local function set_banner_winbar(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end
	local ok = pcall(
		vim.api.nvim_set_option_value,
		"winbar", "%#GitflowTitle#" .. banner_text(),
		{ win = winid }
	)
	if not ok then
		-- winbar requires nvim 0.8+; ignore older versions
	end
end

---@return integer
local function next_pending_id()
	local max = 0
	for _, pc in ipairs(M.state.pending_comments) do
		if pc.id and pc.id > max then
			max = pc.id
		end
	end
	return max + 1
end

local function persist_pending()
	if not M.state.pr_number then
		return
	end
	cache.save(M.state.pr_number, {
		pr_number = M.state.pr_number,
		comments = M.state.pending_comments,
	}, M.state.repo_slug)
end

---@param threads table[]
---@return GitflowPrReviewThread[]
local function build_comment_threads(comments)
	local threads = {}
	local root_map = {}

	for _, c in ipairs(comments or {}) do
		local user = ""
		if type(c.user) == "table" and c.user.login then
			user = c.user.login
		elseif type(c.user) == "string" then
			user = c.user
		end

		local comment = {
			id = as_integer(c.id) or 0,
			path = c.path or "",
			line = as_integer(c.line) or as_integer(c.original_line),
			original_line = as_integer(c.original_line),
			body = c.body or "",
			user = user,
			in_reply_to_id = as_integer(c.in_reply_to_id),
			start_line = as_integer(c.start_line),
		}

		if not comment.in_reply_to_id then
			local thread = {
				id = comment.id,
				path = comment.path,
				line = comment.line,
				comments = { comment },
				collapsed = false,
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
				}
				threads[#threads + 1] = thread
				root_map[comment.id] = thread
			end
		end
	end

	return threads
end

local function track_annotated(bufnr)
	if not bufnr then
		return
	end
	for _, existing in ipairs(M.state.annotated_buffers) do
		if existing == bufnr then
			return
		end
	end
	M.state.annotated_buffers[#M.state.annotated_buffers + 1] = bufnr
end

local function clear_all_annotations()
	for _, bufnr in ipairs(M.state.annotated_buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			inline.clear_annotations(bufnr)
			inline.clear_comments(bufnr)
			pcall(vim.api.nvim_buf_clear_namespace, bufnr,
				vim.api.nvim_create_namespace("gitflow_review_file_list"), 0, -1)
			-- also clear winbar on any windows that show this buffer
			for _, winid in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_is_valid(winid)
					and vim.api.nvim_win_get_buf(winid) == bufnr then
					pcall(vim.api.nvim_set_option_value,
						"winbar", "", { win = winid })
				end
			end
		end
	end
	M.state.annotated_buffers = {}
end

---@param path string
---@return GitflowReviewInlineComment[]
local function comments_for_path(path)
	local out = {}
	for _, thread in ipairs(M.state.comment_threads) do
		if thread.path == path and #thread.comments > 0 then
			local first = thread.comments[1]
			out[#out + 1] = {
				author = first.user,
				body = first.body,
				new_line = thread.line,
				old_line = nil,
				pending = false,
				count = #thread.comments,
			}
		end
	end
	for _, pc in ipairs(M.state.pending_comments) do
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

local function refresh_comments_for_active()
	if not M.state.active_bufnr
		or not vim.api.nvim_buf_is_valid(M.state.active_bufnr)
		or not M.state.active_path then
		return
	end
	inline.apply_comments(
		M.state.active_bufnr,
		comments_for_path(M.state.active_path),
		{ show_body = M.state.show_inline_comments }
	)
end

--- Per-path counts of pending drafts and remote threads.
---@return table<string, integer>, table<string, integer>
local function comment_counts_by_path()
	local pending, threads = {}, {}
	for _, pc in ipairs(M.state.pending_comments) do
		if pc.path then
			pending[pc.path] = (pending[pc.path] or 0) + 1
		end
	end
	for _, t in ipairs(M.state.comment_threads) do
		if t.path then
			threads[t.path] = (threads[t.path] or 0) + 1
		end
	end
	return pending, threads
end

--- Build a nested directory tree from the flat file list.  Each node
--- has `dirs` (name → child), `dir_order` (insertion order) and `files`
--- (leaf entries carrying the original 1-based index into state.files).
---@param files GitflowPrReviewFile[]
local function build_file_tree(files)
	local root = { dirs = {}, dir_order = {}, files = {} }
	for idx, f in ipairs(files) do
		local parts = vim.split(f.path, "/", { plain = true })
		local node = root
		for i = 1, #parts - 1 do
			local part = parts[i]
			local child = node.dirs[part]
			if not child then
				child = { dirs = {}, dir_order = {}, files = {} }
				node.dirs[part] = child
				node.dir_order[#node.dir_order + 1] = part
			end
			node = child
		end
		node.files[#node.files + 1] = {
			idx = idx, name = parts[#parts], file = f,
		}
	end
	return root
end

---@return integer
local function dir_leaf_count(node)
	local n = #node.files
	for _, d in ipairs(node.dir_order) do
		n = n + dir_leaf_count(node.dirs[d])
	end
	return n
end

--- Sum remote threads and pending drafts across every file under `node`.
---@param node table
---@param threads table<string, integer>
---@param pending table<string, integer>
---@return integer, integer  total threads, total drafts
local function dir_comment_totals(node, threads, pending)
	local t, p = 0, 0
	for _, e in ipairs(node.files) do
		t = t + (threads[e.file.path] or 0)
		p = p + (pending[e.file.path] or 0)
	end
	for _, d in ipairs(node.dir_order) do
		local ct, cp = dir_comment_totals(node.dirs[d], threads, pending)
		t, p = t + ct, p + cp
	end
	return t, p
end

--- Turn a list of `{ text, hl|nil }` chunks into a single string plus a
--- list of `{ col_start, col_end, hl }` byte-range highlight spans.
---@param chunks table[]
---@return string, table[]
local function join_chunks(chunks)
	local s, spans, col = "", {}, 0
	for _, ch in ipairs(chunks) do
		local text = ch[1] or ""
		if ch[2] and text ~= "" then
			spans[#spans + 1] = {
				col_start = col, col_end = col + #text, hl = ch[2],
			}
		end
		s = s .. text
		col = col + #text
	end
	return s, spans
end

--- Recursively emit tree lines into `ctx`.
---@param node table
---@param depth integer
---@param prefix string  parent dir path (for collapse keys)
---@param ctx table
local function render_tree_node(node, depth, prefix, ctx)
	local dnames = vim.deepcopy(node.dir_order)
	table.sort(dnames)
	for _, dname in ipairs(dnames) do
		local child = node.dirs[dname]
		local label = dname
		local full = prefix == "" and dname or (prefix .. "/" .. dname)
		-- Compact single-child directory chains: foo/bar/baz on one row.
		while #child.dir_order == 1 and #child.files == 0 do
			local only = child.dir_order[1]
			label = label .. "/" .. only
			full = full .. "/" .. only
			child = child.dirs[only]
		end
		ctx.all_dirs[full] = true
		local collapsed = M.state.collapsed_dirs[full] == true
		local arrow = collapsed and "▸" or "▾"
		local indent = string.rep(TREE_INDENT, depth)
		local dir_chunks = {
			{ " " .. indent, nil },
			{ arrow .. " ", "GitflowReviewTreeGuide" },
			{ label .. "/", "GitflowReviewTreeDir" },
			{ ("  (%d)"):format(dir_leaf_count(child)),
				"GitflowReviewHint" },
		}
		-- When folded, surface hidden threads/drafts so the user doesn't
		-- have to expand every folder to find unresolved comments.
		if collapsed then
			local ct, cp = dir_comment_totals(child, ctx.threads, ctx.pending)
			if ct > 0 then
				dir_chunks[#dir_chunks + 1] = {
					(" [%d]"):format(ct), "GitflowReviewComment",
				}
			end
			if cp > 0 then
				dir_chunks[#dir_chunks + 1] = {
					(" ●%d"):format(cp), "GitflowReviewChangesRequested",
				}
			end
		end
		local line, spans = join_chunks(dir_chunks)
		ctx.lines[#ctx.lines + 1] = line
		local lineno = #ctx.lines
		ctx.dir_line_map[lineno] = full
		for _, sp in ipairs(spans) do
			sp.line = lineno - 1
			ctx.highlights[#ctx.highlights + 1] = sp
		end
		if not collapsed then
			render_tree_node(child, depth + 1, full, ctx)
		end
	end

	local files = vim.deepcopy(node.files)
	table.sort(files, function(a, b) return a.name < b.name end)
	for _, entry in ipairs(files) do
		local f = entry.file
		local indent = string.rep(TREE_INDENT, depth)
		local is_active = M.state.active_path == f.path
		local chunks = {
			{ " " .. indent, nil },
			{ status_indicator(f.status) .. " ", status_hl(f.status) },
			{ entry.name, is_active and "GitflowTitle" or nil },
		}
		local addn, deln = f.additions or 0, f.deletions or 0
		if addn > 0 or deln > 0 then
			chunks[#chunks + 1] = { "  ", nil }
			chunks[#chunks + 1] = { "+" .. addn, "GitflowReviewCountAdd" }
			chunks[#chunks + 1] = { " ", nil }
			chunks[#chunks + 1] = { "-" .. deln, "GitflowReviewCountDel" }
		end
		local threads = ctx.threads[f.path] or 0
		if threads > 0 then
			chunks[#chunks + 1] = {
				(" [%d]"):format(threads), "GitflowReviewComment",
			}
		end
		local pending = ctx.pending[f.path] or 0
		if pending > 0 then
			chunks[#chunks + 1] = {
				(" ●%d"):format(pending), "GitflowReviewChangesRequested",
			}
		end
		local fd = M.state.file_diffs[f.path]
		if fd and fd.truncated then
			chunks[#chunks + 1] = {
				" ⚠", "GitflowReviewChangesRequested",
			}
		end
		local line, spans = join_chunks(chunks)
		ctx.lines[#ctx.lines + 1] = line
		local lineno = #ctx.lines
		ctx.file_line_map[lineno] = entry.idx
		for _, sp in ipairs(spans) do
			sp.line = lineno - 1
			ctx.highlights[#ctx.highlights + 1] = sp
		end
	end
end

local function render_file_list()
	local bufnr = M.state.file_list_bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local sep = string.rep("─", FILE_LIST_WIDTH - 2)
	local n = M.state.pr_number and tostring(M.state.pr_number) or "?"
	local title = M.state.pr_title or "(loading)"

	local lines = { (" PR REVIEW · #%s"):format(n), (" %s"):format(title) }
	local header_lines = 2
	if M.state.pr_author then
		lines[#lines + 1] = ("  by @%s"):format(M.state.pr_author)
	end
	if M.state.pr_head and M.state.pr_base then
		lines[#lines + 1] = ("  %s ← %s"):format(
			M.state.pr_base, M.state.pr_head
		)
	end
	lines[#lines + 1] = sep

	-- Files header with an aggregate +/- summary.
	local total_add, total_del = 0, 0
	for _, f in ipairs(M.state.files) do
		total_add = total_add + (f.additions or 0)
		total_del = total_del + (f.deletions or 0)
	end
	local files_header, files_header_spans = join_chunks({
		{ (" Files (%d)"):format(#M.state.files), nil },
		{ ("  +%d"):format(total_add), "GitflowReviewCountAdd" },
		{ (" -%d"):format(total_del), "GitflowReviewCountDel" },
	})
	lines[#lines + 1] = files_header
	local files_header_line = #lines
	lines[#lines + 1] = sep

	local pending_map, threads_map = comment_counts_by_path()
	local ctx = {
		lines = lines,
		highlights = {},
		file_line_map = {},
		dir_line_map = {},
		all_dirs = {},
		pending = pending_map,
		threads = threads_map,
	}

	local file_lines_start = #lines + 1
	if #M.state.files == 0 then
		lines[#lines + 1] = "  (no files)"
	else
		render_tree_node(build_file_tree(M.state.files), 0, "", ctx)
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = sep
	local hints = {
		" ~ mod  + add  - del  > ren",
		" [n] threads  ●n drafts",
		" <CR>/o open · <Tab> fold",
		" zR/zM  unfold/fold all",
		" c comment · S submit",
		" R reply · <leader>x delete",
		" ]f/[f file · ]c/[c hunk",
		" r refresh · q close",
	}
	local hint_start = #lines + 1
	for _, h in ipairs(hints) do
		lines[#lines + 1] = h
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	vim.api.nvim_buf_clear_namespace(bufnr, FILE_LIST_HL_NS, 0, -1)
	local function hl(line, cs, ce, group)
		pcall(vim.api.nvim_buf_add_highlight,
			bufnr, FILE_LIST_HL_NS, group, line, cs, ce)
	end
	-- Header chrome.
	hl(0, 0, -1, "GitflowTitle")
	hl(1, 0, -1, "GitflowHeader")
	for line = header_lines, files_header_line - 2 do
		hl(line, 0, -1, "GitflowReviewHint")
	end
	for _, sp in ipairs(files_header_spans) do
		hl(files_header_line - 1, sp.col_start, sp.col_end, sp.hl)
	end
	-- Tree spans.
	for _, sp in ipairs(ctx.highlights) do
		hl(sp.line, sp.col_start, sp.col_end, sp.hl)
	end
	-- Footer hints.
	for i = 0, #hints - 1 do
		hl(hint_start - 1 + i, 0, -1, "GitflowReviewHint")
	end

	M.state._file_line_map = ctx.file_line_map
	M.state._dir_line_map = ctx.dir_line_map
	M.state._all_dirs = ctx.all_dirs
	M.state._file_lines_start = file_lines_start
end

---@return integer|nil
local function file_idx_under_cursor()
	if not M.state.file_list_winid
		or not vim.api.nvim_win_is_valid(M.state.file_list_winid) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(M.state.file_list_winid)[1]
	return M.state._file_line_map and M.state._file_line_map[cursor] or nil
end

---@param path string
---@return string|nil
local function repo_relative_path(path)
	if not path or path == "" then
		return nil
	end
	-- Try git toplevel
	local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
	if vim.v.shell_error == 0 and out and out[1] then
		local toplevel = vim.trim(out[1])
		if toplevel ~= "" then
			return toplevel .. "/" .. path
		end
	end
	return path
end

--- Inverse of repo_relative_path: given a buffer backed by a real file on
--- disk, return its path relative to the git toplevel so it can be looked up
--- in M.state.file_diffs (whose keys are PR filenames, i.e. repo-relative).
--- Returns nil for scratch/unnamed buffers or files outside the repo.
---@param bufnr integer
---@return string|nil
local function buf_repo_relative(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	-- Only real files: scratch/nofile buffers (e.g. the file list or a
	-- deleted-file placeholder) have a non-empty buftype.
	if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if not name or name == "" then
		return nil
	end
	local full = vim.fn.fnamemodify(name, ":p")

	local top = M.state.repo_toplevel
	if not top then
		local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
		if vim.v.shell_error ~= 0 or not out or not out[1] then
			return nil
		end
		top = vim.trim(out[1])
		if top == "" then
			return nil
		end
		top = (vim.fn.fnamemodify(top, ":p"):gsub("/$", ""))
		M.state.repo_toplevel = top
	end

	if full:sub(1, #top + 1) == top .. "/" then
		return full:sub(#top + 2)
	end
	return nil
end

--- Build a scratch buffer that shows a message instead of a real file
--- (for deleted files or missing paths).
---@param path string
---@param message string
---@return integer
local function open_placeholder_buffer(path, message)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr,
		("gitflow://review/%s/%s"):format(
			tostring(M.state.pr_number or "?"), path
		))
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(message, "\n"))
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	return bufnr
end

--- Apply the full PR-review overlay to a buffer that displays the
--- working-tree file at repo-relative `path`: inline diff annotations,
--- comment boxes, the winbar banner, and the review keymaps.  `winid` is the
--- window currently showing the buffer (used for cursor jumps + winbar).
--- Shared by M.open_file (file-list navigation) and the BufWinEnter autocmd
--- that catches files opened by other means (e.g. Telescope find_files).
---@param bufnr integer
---@param path string
---@param winid integer|nil
---@param opts table|nil  { jump = boolean }  jump to first hunk (default true)
local function apply_review_overlay(bufnr, path, winid, opts)
	opts = opts or {}
	local file_diff = M.state.file_diffs[path]

	M.state.active_path = path
	M.state.active_bufnr = bufnr

	local result = inline.apply_annotations(bufnr, file_diff)
	M.state.hunk_anchors = result.hunk_anchors or {}
	track_annotated(bufnr)

	if file_diff and file_diff.truncated then
		notify_warn(
			("PR diff for %s exceeds the GitHub per-file size limit; "
			.. "inline annotations are not available for this file."):format(path)
		)
	end

	refresh_comments_for_active()
	set_banner_winbar(winid)

	-- Set up buffer-local keymaps for review actions in the diff pane.
	local kopts = { buffer = bufnr, silent = true, nowait = true }
	vim.keymap.set("n", "c", function() M.inline_comment() end, kopts)
	vim.keymap.set("v", "c", function() M.inline_comment_visual() end, kopts)
	vim.keymap.set("n", "S", function() M.submit_pending_review() end, kopts)
	vim.keymap.set("n", "R", function() M.reply_to_thread() end, kopts)
	vim.keymap.set("n", "<CR>", function() M.view_thread_at_cursor() end, kopts)
	vim.keymap.set("n", "]c", function() M.next_hunk() end, kopts)
	vim.keymap.set("n", "[c", function() M.prev_hunk() end, kopts)
	vim.keymap.set("n", "<leader>i", function() M.toggle_inline_comments() end, kopts)
	vim.keymap.set("n", "<leader>x", function() M.delete_comment_at_cursor() end, kopts)

	-- Jump to first hunk so the change is immediately on screen.
	if opts.jump ~= false
		and winid and vim.api.nvim_win_is_valid(winid)
		and #M.state.hunk_anchors > 0 then
		pcall(vim.api.nvim_win_set_cursor, winid,
			{ M.state.hunk_anchors[1], 0 })
	end

	-- Track which file index is now active (for next_file / prev_file)
	for i, f in ipairs(M.state.files) do
		if f.path == path then
			M.state.active_file_idx = i
			break
		end
	end

	-- Reveal the active file by expanding its ancestor folders.
	local parts = vim.split(path, "/", { plain = true })
	local acc = ""
	for i = 1, #parts - 1 do
		acc = acc == "" and parts[i] or (acc .. "/" .. parts[i])
		M.state.collapsed_dirs[acc] = nil
	end

	render_file_list()
end

--- Catch a file opened outside the file list (e.g. Telescope find_files,
--- :edit, a quickfix jump) that happens to be part of the PR diff, and
--- decorate it with the review overlay so the inline diff still shows.
---@param bufnr integer
function M._maybe_annotate_buffer(bufnr)
	-- Guard against the recursive BufWinEnter fired by open_file's own :edit.
	if M._applying then
		return
	end
	if not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid) then
		return
	end
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	-- Already decorated?
	for _, b in ipairs(M.state.annotated_buffers) do
		if b == bufnr then
			return
		end
	end
	-- Only act inside the review tabpage to avoid surprising the user when
	-- they open the same file in an unrelated tab/window.
	if M.state.tabpage
		and vim.api.nvim_get_current_tabpage() ~= M.state.tabpage then
		return
	end
	local rel = buf_repo_relative(bufnr)
	if not rel or not M.state.file_diffs[rel] then
		return
	end
	local winid = vim.fn.bufwinid(bufnr)
	if winid == -1 then
		winid = M.state.diff_winid
	end
	apply_review_overlay(bufnr, rel, winid)
end

---@param path string
function M.open_file(path)
	if not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid) then
		notify_warn("Review mode is not active")
		return
	end
	if not path or path == "" then
		return
	end

	local file_diff = M.state.file_diffs[path]
	local full_path = repo_relative_path(path)
	local readable = full_path and vim.fn.filereadable(full_path) == 1

	vim.api.nvim_set_current_win(M.state.diff_winid)

	local bufnr = nil
	if readable then
		-- Open the real file via :edit so filetype detection, treesitter,
		-- and LSP attach normally.  We deliberately do NOT use
		-- `noautocmd` here — suppressing autocmds skips FileType and
		-- BufRead* events, which breaks syntax highlighting.  The
		-- _applying guard stops the BufWinEnter autocmd from racing us.
		M._applying = true
		pcall(vim.cmd, "silent edit " .. vim.fn.fnameescape(full_path))
		bufnr = vim.api.nvim_get_current_buf()
		M._applying = false

		-- If for any reason filetype wasn't picked up (e.g. the buffer
		-- was already open via another path), re-run filetype detection.
		local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
		if ft == "" then
			pcall(vim.cmd, "filetype detect")
		end
	else
		local message = ("PR diff for %s\n\nThis file is not in the working tree.")
			:format(path)
		if file_diff and file_diff.status == "D" then
			message = ("PR #%s deletes %s\n\n(Showing diff only — no working tree file.)")
				:format(fmt_number(M.state.pr_number), path)
		end
		bufnr = open_placeholder_buffer(path, message)
		vim.api.nvim_win_set_buf(M.state.diff_winid, bufnr)
	end

	apply_review_overlay(bufnr, path, M.state.diff_winid)
end

--- Toggle the collapsed state of the directory on the cursor line.
---@return boolean  true if a directory line was toggled
function M.toggle_dir_under_cursor()
	if not M.state.file_list_winid
		or not vim.api.nvim_win_is_valid(M.state.file_list_winid) then
		return false
	end
	local cursor = vim.api.nvim_win_get_cursor(M.state.file_list_winid)[1]
	local full = M.state._dir_line_map and M.state._dir_line_map[cursor]
	if not full then
		return false
	end
	M.state.collapsed_dirs[full] = not M.state.collapsed_dirs[full]
	render_file_list()
	local total = vim.api.nvim_buf_line_count(M.state.file_list_bufnr)
	pcall(vim.api.nvim_win_set_cursor, M.state.file_list_winid,
		{ math.min(cursor, total), 0 })
	return true
end

function M.open_file_under_cursor()
	-- A folder row folds/unfolds; a file row opens.
	if M.toggle_dir_under_cursor() then
		return
	end
	local idx = file_idx_under_cursor()
	if not idx then
		return
	end
	local file = M.state.files[idx]
	if not file then
		return
	end
	M.open_file(file.path)
end

function M.collapse_all_dirs()
	for full in pairs(M.state._all_dirs or {}) do
		M.state.collapsed_dirs[full] = true
	end
	render_file_list()
end

function M.expand_all_dirs()
	M.state.collapsed_dirs = {}
	render_file_list()
end

local function set_up_file_list_keymaps(bufnr)
	local opts = { buffer = bufnr, silent = true, nowait = true }
	vim.keymap.set("n", "<CR>", M.open_file_under_cursor, opts)
	vim.keymap.set("n", "o", M.open_file_under_cursor, opts)
	vim.keymap.set("n", "<2-LeftMouse>", M.open_file_under_cursor, opts)
	vim.keymap.set("n", "<Tab>", M.open_file_under_cursor, opts)
	vim.keymap.set("n", "za", function() M.toggle_dir_under_cursor() end, opts)
	vim.keymap.set("n", "zM", function() M.collapse_all_dirs() end, opts)
	vim.keymap.set("n", "zR", function() M.expand_all_dirs() end, opts)
	vim.keymap.set("n", "r", function() M.refresh() end, opts)
	vim.keymap.set("n", "q", function() M.close_with_guard() end, opts)
	vim.keymap.set("n", "S", function() M.submit_pending_review() end, opts)
	vim.keymap.set("n", "]f", function() M.next_file() end, opts)
	vim.keymap.set("n", "[f", function() M.prev_file() end, opts)
end

local function ensure_file_list_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr,
		("gitflow://review-files/%s"):format(
			tostring(M.state.pr_number or "?")))
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("buflisted", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "gitflow-review-files",
		{ buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	M.state.file_list_bufnr = bufnr
	set_up_file_list_keymaps(bufnr)
end

local function build_tabpage()
	-- Open a new tabpage that takes over the screen visually.
	vim.cmd("tabnew")
	M.state.tabpage = vim.api.nvim_get_current_tabpage()

	ensure_file_list_buffer()

	-- The starting window of the new tab becomes the diff pane on the
	-- right. We open a vertical split to the left for the file list.
	vim.cmd("topleft vsplit")
	M.state.file_list_winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(M.state.file_list_winid, M.state.file_list_bufnr)
	vim.api.nvim_win_set_width(M.state.file_list_winid, FILE_LIST_WIDTH)

	-- Tighten up the file-list window: no numbers, no signcolumn drama.
	pcall(vim.api.nvim_set_option_value, "number", false,
		{ win = M.state.file_list_winid })
	pcall(vim.api.nvim_set_option_value, "relativenumber", false,
		{ win = M.state.file_list_winid })
	pcall(vim.api.nvim_set_option_value, "signcolumn", "no",
		{ win = M.state.file_list_winid })
	pcall(vim.api.nvim_set_option_value, "wrap", false,
		{ win = M.state.file_list_winid })
	pcall(vim.api.nvim_set_option_value, "winfixwidth", true,
		{ win = M.state.file_list_winid })
	pcall(vim.api.nvim_set_option_value, "cursorline", true,
		{ win = M.state.file_list_winid })

	-- Right pane is whatever window is left over (the "diff" pane).
	vim.cmd("wincmd l")
	M.state.diff_winid = vim.api.nvim_get_current_win()

	-- Placeholder buffer in the right pane until the user picks a file.
	local placeholder = open_placeholder_buffer("",
		"PR review — select a file on the left with <CR>.\n\n"
		.. "Press q in the file list to exit review mode.")
	vim.api.nvim_win_set_buf(M.state.diff_winid, placeholder)
	track_annotated(placeholder)

	set_banner_winbar(M.state.diff_winid)

	-- Focus the file list so the user can immediately navigate.
	vim.api.nvim_set_current_win(M.state.file_list_winid)
end

---@param view table|nil
local function pull_pr_metadata(view)
	if not view then
		return
	end
	M.state.pr_title = vim.trim(tostring(view.title or "")) ~= ""
		and view.title or M.state.pr_title or "(untitled)"
	if type(view.author) == "table" and view.author.login then
		M.state.pr_author = view.author.login
	elseif type(view.author) == "string" then
		M.state.pr_author = view.author
	end
	if view.headRefName and view.headRefName ~= vim.NIL then
		M.state.pr_head = tostring(view.headRefName)
	end
	if view.baseRefName and view.baseRefName ~= vim.NIL then
		M.state.pr_base = tostring(view.baseRefName)
	end

	-- Pull file list from view.files first; fall back to diff parsing.
	if type(view.files) == "table" then
		local files = {}
		for _, f in ipairs(view.files) do
			if type(f) == "table" and f.path then
				files[#files + 1] = {
					path = f.path,
					status = "M",
					additions = as_integer(f.additions),
					deletions = as_integer(f.deletions),
				}
			end
		end
		if #files > 0 then
			M.state.files = files
		end
	end
end

local PR_STATUS_MAP = {
	added = "A",
	removed = "D",
	modified = "M",
	renamed = "R",
	copied = "M",
	changed = "M",
}

--- Ingest the per-file patches returned by the GitHub pulls/.../files
--- API.  This handles huge PRs that would crash `gh pr diff`: each file
--- is processed independently, and files whose patch was omitted by
--- GitHub (because they exceed the per-file size limit) are still
--- listed but flagged as truncated.
---@param files_data table[]|nil
local function ingest_pr_files(files_data)
	local files = {}
	local file_diffs = {}
	local hunk_markers = {}
	local file_markers = {}

	for _, f in ipairs(files_data or {}) do
		if type(f) == "table" and f.filename then
			local status = PR_STATUS_MAP[tostring(f.status or "")] or "M"
			files[#files + 1] = {
				path = f.filename,
				status = status,
				additions = as_integer(f.additions),
				deletions = as_integer(f.deletions),
			}

			local patch = f.patch
			if patch == vim.NIL then
				patch = nil
			end

			local fd = {
				path = f.filename,
				status = status,
				hunks = {},
				truncated = (patch == nil) and (status ~= "A" and status ~= "D"),
			}
			if type(patch) == "string" and patch ~= "" then
				fd.hunks = inline.parse_hunks_from_patch(patch)
			end
			file_diffs[f.filename] = fd

			file_markers[#file_markers + 1] = {
				path = f.filename, status = status, line = 0,
			}
			for _, h in ipairs(fd.hunks) do
				hunk_markers[#hunk_markers + 1] = {
					path = f.filename, header = h.header, line = 0,
				}
			end
		end
	end

	M.state.files = files
	M.state.file_diffs = file_diffs
	M.state.file_markers = file_markers
	M.state.hunk_markers = hunk_markers
end

--- If the PR's head branch isn't the one currently checked out, comment
--- line numbers won't match the diff (the #1 cause of "Line could not be
--- resolved"). Offer to check the PR out. Prompts at most once per session.
local function maybe_prompt_pr_checkout()
	if M.state._checkout_prompted then
		return
	end
	local head = M.state.pr_head
	local number = M.state.pr_number
	if not head or head == "" or not number then
		return
	end

	git_branch.current({}, function(_, branch)
		if M.state._checkout_prompted then
			return
		end
		branch = branch and vim.trim(branch) or ""
		if branch == head then
			return -- already on the PR's branch; lines will resolve
		end
		M.state._checkout_prompted = true

		local confirmed = input.confirm(
			("PR #%s targets branch '%s', but you're on '%s'.\n"
			.. "Inline-comment line numbers may not resolve until the PR "
			.. "branch is checked out.\n\nCheck out '%s' now?"):format(
				tostring(number), head,
				branch ~= "" and branch or "(detached HEAD)", head
			),
			{ choices = { "&Checkout", "&Ignore" }, default_choice = 1 }
		)
		if not confirmed then
			return
		end

		gh_prs.checkout(number, {}, function(err)
			if err then
				notify_error(err)
				return
			end
			notify_info(("Checked out PR branch '%s'"):format(head))
			local active = M.state.active_path
			M.refresh()
			if active then
				vim.schedule(function()
					M.open_file(active)
				end)
			end
		end)
	end)
end

function M.refresh()
	if not M.state.cfg or not M.state.pr_number then
		return
	end
	local number = M.state.pr_number

	M.state.pr_title = M.state.pr_title or "(loading)"
	render_file_list()

	gh_prs.view(number, {}, function(view_err, pr)
		if view_err then
			notify_error(view_err)
		else
			pull_pr_metadata(pr)
			maybe_prompt_pr_checkout()
		end

		gh_prs.list_files(number, {}, function(files_err, files_data)
			if files_err then
				notify_error(
					"Could not load PR files list: " .. files_err
				)
				render_file_list()
				return
			end

			ingest_pr_files(files_data)

			gh_prs.review_comments(number, {}, function(rc_err, comments)
				if not rc_err and comments then
					M.state.comment_threads = build_comment_threads(comments)
				end

				-- Hydrate pending comments from cache (only if our in-memory
				-- list is empty — never clobber user's current drafts).
				if #M.state.pending_comments == 0 then
					local cached = cache.load(number, M.state.repo_slug)
					if cached and type(cached.comments) == "table" then
						M.state.pending_comments = cached.comments
					end
				end

				render_file_list()
				set_banner_winbar(M.state.diff_winid)

				if M.state.active_path then
					M.open_file(M.state.active_path)
				end
			end)
		end)
	end)
end

---@param cfg GitflowConfig|nil
---@param pr_number integer|string
function M.open(cfg, pr_number)
	local number = as_integer(pr_number)
	if not number then
		notify_error("Invalid PR number: " .. tostring(pr_number))
		return
	end

	-- If a review is already open for the same PR, just refocus it.
	if M.is_open() and M.state.pr_number == number then
		if M.state.tabpage
			and vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
			pcall(vim.api.nvim_set_current_tabpage, M.state.tabpage)
		end
		return
	end

	if M.is_open() then
		M.close()
	end

	M.state.cfg = cfg
	M.state.pr_number = number
	M.state.pr_title = nil
	M.state.pr_author = nil
	M.state.pr_head = nil
	M.state.pr_base = nil
	M.state.files = {}
	M.state.file_diffs = {}
	M.state.comment_threads = {}
	M.state.pending_comments = {}
	M.state.annotated_buffers = {}
	M.state.active_path = nil
	M.state.active_bufnr = nil
	M.state.active_file_idx = nil
	M.state.hunk_anchors = {}
	M.state.show_inline_comments = true
	M.state.collapsed_dirs = {}
	M.state.repo_toplevel = nil
	M.state._checkout_prompted = false
	M.state.repo_slug = cache.repo_slug()

	-- Restore any cached draft comments BEFORE building the tab so that
	-- counts in the file list are correct on first paint.
	local cached = cache.load(number, M.state.repo_slug)
	if cached and type(cached.comments) == "table" then
		M.state.pending_comments = cached.comments
		if #M.state.pending_comments > 0 then
			notify_info(
				("Restored %d pending comment(s) from disk for PR #%d"):
					format(#M.state.pending_comments, number)
			)
		end
	end

	build_tabpage()

	-- Decorate files opened outside the file list (Telescope, :edit, quickfix)
	-- with the inline diff overlay when they belong to this PR.
	vim.api.nvim_clear_autocmds({ group = AUGROUP })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = AUGROUP,
		callback = function(ev)
			M._maybe_annotate_buffer(ev.buf)
		end,
	})

	render_file_list()
	M.refresh()
end

---@param cfg GitflowConfig
function M.toggle(cfg)
	if M.is_open() then
		M.close_with_guard()
		return
	end
	-- Open the PR picker
	local pr_panel = require("gitflow.panels.prs")
	pr_panel.open(cfg, { state = "open" })
end

function M.close()
	pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })
	M._applying = false
	clear_all_annotations()

	-- Close the tabpage if it's still around.
	if M.state.tabpage and vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
		local wins = vim.api.nvim_tabpage_list_wins(M.state.tabpage)
		for _, winid in ipairs(wins) do
			pcall(vim.api.nvim_win_close, winid, true)
		end
	end

	if M.state.file_list_bufnr
		and vim.api.nvim_buf_is_valid(M.state.file_list_bufnr) then
		pcall(vim.api.nvim_buf_delete, M.state.file_list_bufnr,
			{ force = true })
	end

	M.state.cfg = nil
	M.state.pr_number = nil
	M.state.pr_title = nil
	M.state.pr_author = nil
	M.state.pr_head = nil
	M.state.pr_base = nil
	M.state.tabpage = nil
	M.state.file_list_winid = nil
	M.state.file_list_bufnr = nil
	M.state.diff_winid = nil
	M.state.files = {}
	M.state.file_diffs = {}
	M.state.comment_threads = {}
	M.state.pending_comments = {}
	M.state.annotated_buffers = {}
	M.state.active_path = nil
	M.state.active_bufnr = nil
	M.state.active_file_idx = nil
	M.state.hunk_anchors = {}
	M.state.show_inline_comments = true
	M.state.collapsed_dirs = {}
	M.state.repo_toplevel = nil
	M.state._checkout_prompted = false
	M.state.repo_slug = nil
	M.state.file_markers = {}
	M.state.hunk_markers = {}
	M.state.line_context = {}
end

function M.close_with_guard()
	local count = #M.state.pending_comments
	if count > 0 then
		local msg = (
			"You have %d pending comment(s). Cached drafts are kept on disk.\n"
			.. "Discard the in-memory drafts and close the review?"
		):format(count)
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

function M.is_open()
	return M.state.tabpage ~= nil
		and vim.api.nvim_tabpage_is_valid(M.state.tabpage)
		and M.state.file_list_bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.file_list_bufnr)
end

-- ── File / hunk navigation ──────────────────────────────────────────────

function M.next_file()
	if #M.state.files == 0 then
		return
	end
	local idx = (M.state.active_file_idx or 0) + 1
	if idx > #M.state.files then
		idx = 1
	end
	M.open_file(M.state.files[idx].path)
end

function M.prev_file()
	if #M.state.files == 0 then
		return
	end
	local idx = (M.state.active_file_idx or 2) - 1
	if idx < 1 then
		idx = #M.state.files
	end
	M.open_file(M.state.files[idx].path)
end

function M.next_hunk()
	if not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid)
		or #M.state.hunk_anchors == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(M.state.diff_winid)[1]
	for _, line in ipairs(M.state.hunk_anchors) do
		if line > cur then
			pcall(vim.api.nvim_win_set_cursor, M.state.diff_winid, { line, 0 })
			return
		end
	end
	pcall(vim.api.nvim_win_set_cursor, M.state.diff_winid,
		{ M.state.hunk_anchors[1], 0 })
end

function M.prev_hunk()
	if not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid)
		or #M.state.hunk_anchors == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(M.state.diff_winid)[1]
	for i = #M.state.hunk_anchors, 1, -1 do
		local line = M.state.hunk_anchors[i]
		if line < cur then
			pcall(vim.api.nvim_win_set_cursor, M.state.diff_winid, { line, 0 })
			return
		end
	end
	pcall(vim.api.nvim_win_set_cursor, M.state.diff_winid,
		{ M.state.hunk_anchors[#M.state.hunk_anchors], 0 })
end

-- ── Comments ────────────────────────────────────────────────────────────

---@param path string
---@param line integer
---@return GitflowReviewHunkLine|nil, string|nil
local function find_hunk_line_for(path, line)
	local fd = M.state.file_diffs[path]
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

--- Does the PR diff for `path` contain `line` on the given side?
--- GitHub can only resolve a review comment whose line/side matches a line
--- that actually appears in the diff (RIGHT = new-side, LEFT = old-side).
---@param path string
---@param line integer|nil
---@param side "RIGHT"|"LEFT"
---@return boolean
local function diff_has_line(path, line, side)
	if not line then
		return false
	end
	local fd = M.state.file_diffs[path]
	if not fd then
		return false
	end
	for _, h in ipairs(fd.hunks) do
		for _, l in ipairs(h.lines) do
			if side == "LEFT" then
				if l.old_line == line then
					return true
				end
			elseif l.new_line == line then
				return true
			end
		end
	end
	return false
end

local OFF_DIFF_HINT =
	"You can only comment on lines that are part of the PR diff "
	.. "(changed or context lines within a hunk). If line numbers look "
	.. "off, check out the PR branch first (gh pr checkout)."

local function require_active_diff_line()
	if not M.state.active_path or not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid) then
		notify_warn("Open a file from the PR file list first")
		return nil
	end
	local cur = vim.api.nvim_win_get_cursor(M.state.diff_winid)[1]
	return { path = M.state.active_path, line = cur }
end

function M.inline_comment()
	local ctx = require_active_diff_line()
	if not ctx then
		return
	end

	-- Validate up front: the line must be part of the PR diff or GitHub
	-- will reject the review with "Line could not be resolved".
	local hunk_line, hunk_header = find_hunk_line_for(ctx.path, ctx.line)
	if not hunk_line then
		notify_warn(OFF_DIFF_HINT)
		return
	end

	input.prompt({ prompt = "Inline comment: " }, function(text)
		local body = vim.trim(text or "")
		if body == "" then
			notify_warn("Comment cannot be empty")
			return
		end
		local pending = {
			id = next_pending_id(),
			path = ctx.path,
			body = body,
			hunk = hunk_header,
			-- Anchor to the diff's own line numbers, not the raw cursor.
			new_line = hunk_line.new_line,
			old_line = hunk_line.old_line,
			created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		}
		M.state.pending_comments[#M.state.pending_comments + 1] = pending
		persist_pending()
		notify_info(
			("Inline comment queued (#%d) — press S to submit"):
				format(pending.id))
		render_file_list()
		refresh_comments_for_active()
	end)
end

function M.inline_comment_visual()
	if not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid) then
		return
	end
	if not M.state.active_path then
		notify_warn("Open a file from the PR file list first")
		return
	end

	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
		"nx", false
	)
	if start_line > end_line then
		start_line, end_line = end_line, start_line
	end

	-- Both ends of the range must be diff lines, or GitHub can't resolve it.
	local end_hunk, hunk_header = find_hunk_line_for(M.state.active_path, end_line)
	local start_hunk = find_hunk_line_for(M.state.active_path, start_line)
	if not end_hunk or not start_hunk then
		notify_warn(OFF_DIFF_HINT)
		return
	end

	input.prompt(
		{ prompt = "Inline comment (range): " },
		function(text)
			local body = vim.trim(text or "")
			if body == "" then
				notify_warn("Comment cannot be empty")
				return
			end
			local pending = {
				id = next_pending_id(),
				path = M.state.active_path,
				body = body,
				hunk = hunk_header,
				new_line = end_hunk.new_line,
				old_line = end_hunk.old_line,
				start_new_line = start_hunk.new_line,
				start_old_line = start_hunk.old_line,
				created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			}
			M.state.pending_comments[#M.state.pending_comments + 1] = pending
			persist_pending()
			notify_info(
				("Range comment queued (#%d, lines %d-%d) — press S to submit"):
					format(pending.id, start_line, end_line))
			render_file_list()
			refresh_comments_for_active()
		end
	)
end

function M.toggle_inline_comments()
	M.state.show_inline_comments = not M.state.show_inline_comments
	refresh_comments_for_active()
end

function M.toggle_thread()
	-- Comment threads aren't rendered as a separate list in this mode;
	-- toggle is kept as a no-op so legacy keymaps don't error.
end

-- ── Review submission ──────────────────────────────────────────────────

---@return table[]|nil, string|nil
local function collect_api_comments()
	local api = {}
	local unresolved = {}
	for _, pc in ipairs(M.state.pending_comments) do
		local entry = { path = pc.path, body = pc.body }
		if pc.new_line then
			entry.line = pc.new_line
			entry.side = "RIGHT"
		elseif pc.old_line then
			entry.line = pc.old_line
			entry.side = "LEFT"
		end

		if pc.start_new_line then
			entry.start_line = pc.start_new_line
			entry.start_side = "RIGHT"
		elseif pc.start_old_line then
			entry.start_line = pc.start_old_line
			entry.start_side = "LEFT"
		end

		-- A multi-line comment needs start_line strictly above line on the
		-- same side; collapse degenerate/inverted ranges to a single line.
		if entry.start_line and entry.line
			and (entry.start_side ~= entry.side
				or entry.start_line >= entry.line) then
			entry.start_line = nil
			entry.start_side = nil
		end

		-- Final safety net against a 422: the anchor must be a line that is
		-- actually present in the PR diff on the chosen side.
		local resolvable = entry.path and entry.path ~= ""
			and diff_has_line(entry.path, entry.line, entry.side)
		if resolvable and entry.start_line then
			resolvable = diff_has_line(entry.path, entry.start_line, entry.start_side)
		end

		if resolvable then
			api[#api + 1] = entry
		else
			unresolved[#unresolved + 1] = tostring(pc.id or "?")
		end
	end
	if #unresolved > 0 then
		return nil, (
			"%d comment(s) don't map to a line in the PR diff (ids: %s). "
			.. "This usually means the PR branch isn't checked out — run "
			.. "`gh pr checkout <N>`, reopen the review, and re-add them."
		):format(#unresolved, table.concat(unresolved, ", "))
	end
	return api, nil
end

---@param mode "approve"|"request_changes"|"comment"
---@param body string
---@param on_success_message string
local function submit_review_with_pending(mode, body, on_success_message)
	local number = M.state.pr_number
	if not number then
		notify_warn("No pull request selected for review")
		return
	end

	if #M.state.pending_comments == 0 then
		gh_prs.review(number, mode, body, {}, function(err)
			if err then
				notify_error(err)
				return
			end
			notify_info(on_success_message)
			M.refresh()
		end)
		return
	end

	local api_comments, collect_err = collect_api_comments()
	if collect_err then
		notify_warn(collect_err)
		return
	end

	gh_prs.submit_review(number, mode, body, api_comments, {}, function(err)
		if err then
			notify_error(err)
			return
		end
		local count = #M.state.pending_comments
		M.state.pending_comments = {}
		cache.clear(number, M.state.repo_slug)
		notify_info(
			("Review submitted (%s) with %d comment(s)"):
				format(mode, count))
		M.refresh()
	end)
end

---@param mode "approve"|"request_changes"|"comment"
---@param prompt string
---@param success string
local function prompt_and_submit(mode, prompt, success)
	input.prompt({ prompt = prompt }, function(body)
		submit_review_with_pending(mode, body or "", success)
	end)
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

--- Single entry point for submitting a review.  Opens a dropdown to
--- pick mode (comment / request_changes / approve), then prompts for an
--- optional body, then submits — batching any pending inline comments
--- through the reviews API.
function M.submit_pending_review()
	local number = M.state.pr_number
	if not number then
		notify_warn("No pull request selected for review")
		return
	end

	local choices = {
		{ key = "comment", label = "Comment",
			detail = "Leave a review without approval" },
		{ key = "request_changes", label = "Request changes",
			detail = "Block merge until addressed" },
		{ key = "approve", label = "Approve",
			detail = "Approve this PR for merge" },
	}

	local pending = #M.state.pending_comments
	local prompt = pending > 0
		and ("Submit %d pending comment(s) as:"):format(pending)
		or "Submit review as:"

	vim.ui.select(choices, {
		prompt = prompt,
		format_item = function(item)
			return ("%-18s  %s"):format(item.label, item.detail)
		end,
	}, function(choice)
		if not choice then
			return
		end
		local mode = choice.key

		input.prompt({
			prompt = ("%s message (optional): "):format(choice.label),
		}, function(body_in)
			local body = vim.trim(body_in or "")
			submit_review_with_pending(
				mode, body,
				("Review submitted (%s)"):format(mode)
			)
		end)
	end)
end

---@param mode "approve"|"request_changes"|"comment"
---@param body string
function M.submit_review_direct(mode, body)
	submit_review_with_pending(mode, body,
		("Review submitted (%s)"):format(mode))
end

--- Delete a review comment anchored to the current diff-pane line.
---
--- Drafts (pending, never submitted) are removed in-memory + from the
--- on-disk cache.  Already-submitted remote comments are deleted via
--- the GitHub API.  Drafts take priority when both exist on the same
--- line — they're cheaper to undo by accident.
function M.delete_comment_at_cursor()
	if not M.state.active_path or not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid) then
		notify_warn("Open a file from the PR file list first")
		return
	end
	local cur = vim.api.nvim_win_get_cursor(M.state.diff_winid)[1]
	local path = M.state.active_path

	-- 1) Prefer deleting a pending draft on this line.
	for idx = #M.state.pending_comments, 1, -1 do
		local pc = M.state.pending_comments[idx]
		if pc.path == path
			and (pc.new_line == cur or pc.old_line == cur) then
			local preview = (pc.body or ""):sub(1, 60)
			local confirmed = input.confirm(
				("Delete draft comment? \n\n  %s"):format(preview),
				{ choices = { "&Yes", "&No" }, default_choice = 2 }
			)
			if not confirmed then
				return
			end
			table.remove(M.state.pending_comments, idx)
			persist_pending()
			notify_info("Draft comment deleted")
			render_file_list()
			refresh_comments_for_active()
			return
		end
	end

	-- 2) Otherwise look for a remote thread anchored at this line.
	local thread = nil
	for _, t in ipairs(M.state.comment_threads) do
		if t.path == path and t.line == cur then
			thread = t
			break
		end
	end
	if not thread then
		notify_warn("No comment under cursor")
		return
	end

	-- Find a comment owned by the current GitHub user; fall back to the
	-- thread's first comment.  GitHub will reject the DELETE with 403 if
	-- the comment isn't ours, and we surface that error to the user.
	local target_comment = thread.comments[1]
	local me = (vim.fn.systemlist({ "gh", "api", "user", "-q", ".login" }) or {})[1]
	if me and me ~= "" then
		me = vim.trim(me)
		for _, c in ipairs(thread.comments) do
			if c.user == me then
				target_comment = c
				break
			end
		end
	end

	if not target_comment or not target_comment.id then
		notify_warn("No deletable comment under cursor")
		return
	end

	local preview = (target_comment.body or ""):sub(1, 60)
	local label = ("@%s: %s"):format(
		target_comment.user or "?", preview)
	local confirmed = input.confirm(
		("Delete submitted review comment?\n\n  %s\n\n"
		.. "(This permanently removes it from the PR.)"):format(label),
		{ choices = { "&Yes", "&No" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	gh_prs.delete_review_comment(
		M.state.pr_number, target_comment.id, {},
		function(err)
			if err then
				notify_error(err)
				return
			end
			notify_info("Review comment deleted")
			M.refresh()
		end
	)
end

--- Open a floating window showing the full discussion (all remote
--- replies + any unsubmitted drafts) anchored to the current diff line.
--- When there is no comment on the line, fall through to the default
--- <CR> behaviour (move to the first non-blank of the next line).
function M.view_thread_at_cursor()
	if not M.state.active_path or not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid) then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(M.state.diff_winid)[1]
	local path = M.state.active_path

	local threads = {}
	for _, t in ipairs(M.state.comment_threads) do
		if t.path == path and t.line == cur then
			threads[#threads + 1] = t
		end
	end
	local drafts = {}
	for _, pc in ipairs(M.state.pending_comments) do
		if pc.path == path and (pc.new_line == cur or pc.old_line == cur) then
			drafts[#drafts + 1] = pc
		end
	end

	if #threads == 0 and #drafts == 0 then
		-- Nothing here — preserve the native <CR> motion.
		pcall(vim.cmd, "normal! +")
		return
	end

	-- Build a markdown document so comment bodies (which are markdown on
	-- GitHub) render naturally and authors/headers get highlighted.
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

function M.reply_to_thread()
	local number = M.state.pr_number
	if not number then
		notify_warn("No pull request selected")
		return
	end
	if not M.state.active_path or not M.state.diff_winid
		or not vim.api.nvim_win_is_valid(M.state.diff_winid) then
		notify_warn("Open a file with an existing thread first")
		return
	end
	local cur = vim.api.nvim_win_get_cursor(M.state.diff_winid)[1]
	local thread = nil
	for _, t in ipairs(M.state.comment_threads) do
		if t.path == M.state.active_path and t.line == cur then
			thread = t
			break
		end
	end
	if not thread then
		notify_warn("No existing thread on the current line")
		return
	end

	input.prompt({
		prompt = ("Reply to @%s: "):format(thread.comments[1].user),
	}, function(text)
		local body = vim.trim(text or "")
		if body == "" then
			notify_warn("Reply cannot be empty")
			return
		end
		gh_prs.reply_to_review_comment(number, thread.id, body, {}, function(err)
			if err then
				notify_error(err)
				return
			end
			notify_info("Reply posted")
			M.refresh()
		end)
	end)
end

-- ── Misc helpers kept for command-line backwards compat ────────────────

function M.back_to_pr()
	local number = M.state.pr_number
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

---@param number integer|string
function M.respond_to_review(number)
	local pr_num = as_integer(number)
	if not pr_num then
		notify_error("Invalid PR number for respond")
		return
	end
	gh_prs.list_reviews(pr_num, {}, function(err, reviews)
		if err then
			notify_error(err)
			return
		end
		if not reviews or #reviews == 0 then
			notify_warn("No reviews found on this PR")
			return
		end
		local latest = reviews[#reviews]
		local author = ""
		if type(latest.user) == "table" and latest.user.login then
			author = latest.user.login
		end
		input.prompt({
			prompt = ("Reply to @%s's review: "):format(author),
		}, function(reply)
			local body = vim.trim(reply or "")
			if body == "" then
				notify_warn("Reply cannot be empty")
				return
			end
			gh_prs.comment(pr_num, body, {}, function(cerr)
				if cerr then
					notify_error(cerr)
					return
				end
				notify_info(("Response posted to PR #%d"):format(pr_num))
			end)
		end)
	end)
end

return M
