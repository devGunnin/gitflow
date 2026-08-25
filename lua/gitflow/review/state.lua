--- The PR review's data model.
---
--- One state table, shared by every `gitflow.review.*` module and re-exported
--- as `panels/review.M.state` for the `:Gitflow` commands and the specs. The
--- file-list pane is the review's panel, so `ui/panel.lua` owns its `bufnr`
--- and `winid`; `diff_winid` is the editing pane beside it in the tabpage.
---
--- Also here: the value helpers and the draft persistence that belong to the
--- model rather than to any one surface.

local utils = require("gitflow.utils")
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
---@field file_level boolean|nil
---@field posted boolean|nil
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
---@field draft_save_error string|nil  set while the last cache write failed
---@field drafts_hydrated boolean  the on-disk drafts have been read back
---@field tabpage integer|nil
---@field bufnr integer|nil  file-list buffer (owned by ui/panel.lua)
---@field winid integer|nil  file-list window (owned by ui/panel.lua)
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
---@field file_line_map table<integer, integer>
---@field dir_line_map table<integer, string>
---@field draft_line_map table<integer, integer>
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
	pr_head_sha = nil,
	pr_base = nil,
	repo_slug = nil,
	-- Set to the reason while the last draft write failed, cleared by the
	-- next write that lands. Read by the close prompt.
	draft_save_error = nil,
	drafts_hydrated = false,
	tabpage = nil,
	diff_winid = nil,
	files = {},
	files_loaded = false,
	files_error = nil,
	file_diffs = {},
	comment_threads = {},
	pending_comments = {},
	annotated_buffers = {},
	active_path = nil,
	active_bufnr = nil,
	active_file_idx = nil,
	hunk_anchors = {},
	show_inline_comments = true,
	show_diff = true,
	-- Thread id → true while its replies are folded out inline (#360).
	expanded_threads = {},
	-- winid → the window-local winbar the review banner replaced, so close()
	-- can put it back instead of blanking the user's own winbar (#366).
	banner_wins = {},
	collapsed_dirs = {},
	repo_toplevel = nil,
	-- Deleted (LEFT-side) lines keyed by the buffer line they render next to,
	-- so `c` can offer commenting on a removed line that has no real row.
	deleted_anchors = {},
	-- When set, the review is scoped to a git commit range instead of the
	-- whole PR diff: { base = <rev>, head = <rev>, label = <string> }.
	commit_scope = nil,
	-- Rendered file-list line → what it points at. `file_list.render` empties
	-- all three before each paint, so no collapsed row can still resolve.
	file_line_map = {},
	dir_line_map = {},
	draft_line_map = {},
	all_dirs = {},
	-- Legacy compat shape (kept so :Gitflow pr submit-review / external
	-- callers that read state.* don't crash).
	file_markers = {},
	hunk_markers = {},
	line_context = {},
}

--- Put the model back to "no review open". The panel base owns `bufnr`,
--- `winid` and `request_id`, so they are cleared by `Panel:close`, not here —
--- `request_id` in particular must keep counting up so a response from the
--- review we just closed can never match the next one.
function M.reset()
	local s = M.state
	s.cfg = nil
	s.pr_number = nil
	s.pr_title = nil
	s.pr_author = nil
	s.pr_head = nil
	s.pr_head_sha = nil
	s.pr_base = nil
	s.repo_slug = nil
	s.draft_save_error = nil
	s.drafts_hydrated = false
	s.tabpage = nil
	s.diff_winid = nil
	s.files = {}
	s.files_loaded = false
	s.files_error = nil
	s.file_diffs = {}
	s.comment_threads = {}
	s.pending_comments = {}
	s.annotated_buffers = {}
	s.active_path = nil
	s.active_bufnr = nil
	s.active_file_idx = nil
	s.hunk_anchors = {}
	s.show_inline_comments = true
	s.show_diff = true
	s.expanded_threads = {}
	s.banner_wins = {}
	s.deleted_anchors = {}
	s.commit_scope = nil
	s.collapsed_dirs = {}
	s.repo_toplevel = nil
	s._checkout_prompted = false
	s.file_line_map = {}
	s.dir_line_map = {}
	s.draft_line_map = {}
	s.all_dirs = {}
	s.file_markers = {}
	s.hunk_markers = {}
	s.line_context = {}
end

-- ── notifications ──────────────────────────────────────────────────────

---@param msg string
function M.notify_info(msg)
	utils.notify(msg, vim.log.levels.INFO)
end

---@param msg string
function M.notify_warn(msg)
	utils.notify(msg, vim.log.levels.WARN)
end

---@param msg string
function M.notify_error(msg)
	utils.notify(msg, vim.log.levels.ERROR)
end

-- ── value helpers ──────────────────────────────────────────────────────

---@param value string|nil
---@return string
function M.fmt_number(value)
	return tostring(value or "?")
end

---@param value any
---@return integer|nil
function M.as_integer(value)
	local n = tonumber(value)
	if not n then
		return nil
	end
	return math.floor(n)
end

-- ── drafts ─────────────────────────────────────────────────────────────

---@return integer
function M.next_pending_id()
	local max = 0
	for _, pc in ipairs(M.state.pending_comments) do
		if pc.id and pc.id > max then
			max = pc.id
		end
	end
	return max + 1
end

--- Write the in-memory drafts to the on-disk cache. Every mutation of
--- `pending_comments` goes through here: the cache is the only thing that
--- survives a crashed editor, so a draft that never reaches it is lost work.
---
--- A write that fails (read-only data dir, full disk) is therefore reported —
--- once per run of failures, since this runs on every keystroke-sized edit —
--- and recorded in `draft_save_error` so the close prompt stops telling the
--- reviewer their drafts are safely on disk.
function M.persist_pending()
	if not M.state.pr_number then
		return
	end
	local ok, err = cache.save(M.state.pr_number, {
		pr_number = M.state.pr_number,
		comments = M.state.pending_comments,
	}, M.state.repo_slug)
	if ok then
		M.state.draft_save_error = nil
		return
	end

	local reason = err or "unknown error"
	if not M.state.draft_save_error then
		M.notify_error(("Could not save review drafts: %s\n"
			.. "They exist only in this editor session until a save succeeds.")
			:format(reason))
	end
	M.state.draft_save_error = reason
end

--- Does the PR diff for `path` contain `line` on the given side?
--- GitHub can only resolve a review comment whose line/side matches a line
--- that actually appears in the diff (RIGHT = new-side, LEFT = old-side).
---@param path string
---@param line integer|nil
---@param side "RIGHT"|"LEFT"
---@return boolean
function M.diff_has_line(path, line, side)
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

--- Is a pending draft anchored to a line that's actually in the PR diff?
--- Out-of-scope drafts will be rejected on submit, so we flag them.
---@param pc table
---@return boolean
function M.draft_in_scope(pc)
	-- File-level comments (#361) have no line to resolve; always in scope.
	if pc.file_level then
		return true
	end
	if pc.new_line then
		return M.diff_has_line(pc.path, pc.new_line, "RIGHT")
	elseif pc.old_line then
		return M.diff_has_line(pc.path, pc.old_line, "LEFT")
	end
	return false
end

-- ── paths ──────────────────────────────────────────────────────────────

---@param path string
---@return string|nil
function M.repo_relative_path(path)
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
--- in state.file_diffs (whose keys are PR filenames, i.e. repo-relative).
--- Returns nil for scratch/unnamed buffers or files outside the repo.
---@param bufnr integer
---@return string|nil
function M.buf_repo_relative(bufnr)
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

return M
