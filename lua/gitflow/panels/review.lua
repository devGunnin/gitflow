--- PR review mode: a dedicated tabpage with a persistent file list on the left
--- and a regular neovim editing area on the right. Files opened from the list
--- are displayed with inline diff annotations from the PR (added lines
--- highlighted, removed lines as virt_lines, hunk markers). Single + multi-line
--- comments are queued locally and persisted to disk under
--- stdpath('data')/gitflow/review/ so a crashed editor can resume.
---
--- This module is the surface: the tabpage layout, the open/close lifecycle,
--- and the public entry points the `:Gitflow` commands and the PR panel call.
--- The work itself lives in `gitflow.review.*`:
---
---   state      the shared model, draft persistence, path resolution
---   tree       the file list's directory tree (pure)
---   keymaps    every review key, declared once for both key surfaces
---   file_list  the left pane — the review's `ui/panel.lua` panel
---   overlay    the right pane — annotations, banner, navigation
---   threads    remote threads, and moving between comments
---   comments   drafting, editing and deleting comments
---   submit     turning drafts into a submitted review
---   load       the network round-trips that fill the model

local rstate = require("gitflow.review.state")
local file_list = require("gitflow.review.file_list")
local overlay = require("gitflow.review.overlay")
local threads = require("gitflow.review.threads")
local comments = require("gitflow.review.comments")
local submit = require("gitflow.review.submit")
local load = require("gitflow.review.load")

local M = {}

---@type GitflowPrReviewState
M.state = rstate.state

local AUGROUP = vim.api.nvim_create_augroup("GitflowReview", { clear = true })

--- Suppresses our own WinClosed hook while `close` dismantles the layout.
local closing = false

-- ── layout ─────────────────────────────────────────────────────────────

--- The file list is a fixed-width pane inside the review's own tabpage, which
--- is not a shape `ui/panel.lua` places, so the buffer and window are built
--- here and handed to the panel with `attach`.
---@return integer bufnr
local function create_file_list_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr,
		("gitflow://review-files/%s"):format(
			rstate.fmt_number(M.state.pr_number)))
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("buflisted", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "gitflow-review-files",
		{ buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	return bufnr
end

---@param winid integer
local function tighten_file_list_window(winid)
	local options = {
		number = false, relativenumber = false, signcolumn = "no",
		wrap = false, winfixwidth = true, cursorline = true,
	}
	for option, value in pairs(options) do
		pcall(vim.api.nvim_set_option_value, option, value, { win = winid })
	end
end

local function build_tabpage()
	-- Open a new tabpage that takes over the screen visually.
	vim.cmd("tabnew")
	M.state.tabpage = vim.api.nvim_get_current_tabpage()

	local bufnr = create_file_list_buffer()

	-- The starting window of the new tab becomes the diff pane on the right.
	-- We open a vertical split to the left for the file list.
	vim.cmd("topleft vsplit")
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.api.nvim_win_set_width(winid, file_list.WIDTH)
	tighten_file_list_window(winid)
	file_list.attach(bufnr, winid)

	-- Right pane is whatever window is left over (the "diff" pane).
	vim.cmd("wincmd l")
	M.state.diff_winid = vim.api.nvim_get_current_win()

	-- Placeholder buffer in the right pane until the user picks a file.
	local placeholder = overlay.placeholder_buffer("",
		"PR review — select a file on the left with <CR>.\n\n"
		.. "Press q in the file list to exit review mode.")
	vim.api.nvim_win_set_buf(M.state.diff_winid, placeholder)
	overlay.track(placeholder)

	overlay.set_banner_winbar(M.state.diff_winid)

	-- Focus the file list so the user can immediately navigate.
	vim.api.nvim_set_current_win(winid)
end

local function install_autocmds()
	vim.api.nvim_clear_autocmds({ group = AUGROUP })

	-- Decorate files opened outside the file list (Telescope, :edit, quickfix)
	-- with the inline diff overlay when they belong to this PR.
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = AUGROUP,
		callback = function(ev)
			overlay.maybe_annotate_buffer(ev.buf)
		end,
	})

	-- Catch the user closing a review window/tab directly instead of pressing
	-- q, so the banner and overlays don't outlive the mode (#366). WinClosed
	-- fires before the window is gone, hence the deferred check.
	vim.api.nvim_create_autocmd({ "WinClosed", "TabClosed" }, {
		group = AUGROUP,
		callback = function()
			vim.schedule(M._on_layout_changed)
		end,
	})
end

-- ── lifecycle ──────────────────────────────────────────────────────────

---@param cfg GitflowConfig|nil
---@param pr_number integer|string
function M.open(cfg, pr_number)
	local number = rstate.as_integer(pr_number)
	if not number then
		rstate.notify_error("Invalid PR number: " .. tostring(pr_number))
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

	rstate.reset()
	M.state.cfg = cfg
	M.state.pr_number = number

	build_tabpage()
	install_autocmds()
	file_list.render()

	-- Which cache file this review's drafts live in is resolved off the main
	-- loop, so the tabpage is on screen before any `gh` call; the first load
	-- starts once the answer lands.
	load.start(number)
end

---@param cfg GitflowConfig
function M.toggle(cfg)
	if M.is_open() then
		M.close_with_guard()
		return
	end
	-- Open the PR picker
	require("gitflow.panels.prs").open(cfg, { state = "open" })
end

local function drop_file_list_buffer()
	local bufnr = M.state.bufnr
	file_list.detach()
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

--- Undo every editor-visible thing review mode installed, and forget the PR.
--- Idempotent, so both the normal and the abnormal close path can call it.
---@param close_windows boolean  also tear the tabpage down. False on the
---                              abnormal path: the user dismantled the layout
---                              themselves and may be mid-edit in what is
---                              left (#366).
local function dismantle(close_windows)
	pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })
	overlay.teardown_decorations()

	if close_windows and M.state.tabpage
		and vim.api.nvim_tabpage_is_valid(M.state.tabpage) then
		for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(M.state.tabpage)) do
			pcall(vim.api.nvim_win_close, winid, true)
		end
	end

	drop_file_list_buffer()
	rstate.reset()
end

function M.close()
	closing = true
	dismantle(true)
	closing = false
end

--- Review mode only exists while its tabpage, file list and diff pane all do.
---@return boolean
local function layout_intact()
	return M.state.tabpage ~= nil
		and vim.api.nvim_tabpage_is_valid(M.state.tabpage)
		and M.state.winid ~= nil
		and vim.api.nvim_win_is_valid(M.state.winid)
		and M.state.diff_winid ~= nil
		and vim.api.nvim_win_is_valid(M.state.diff_winid)
end

--- The user dismantled the layout by hand (:q, :tabclose, closing the file
--- list). End review mode and clean up, but leave the windows they still have
--- alone — they may be mid-edit in the file that was under review (#366).
function M._on_layout_changed()
	if closing or not M.state.tabpage or layout_intact() then
		return
	end
	dismantle(false)
	rstate.notify_info("Review mode closed")
end

--- Unsent comments are the one thing review mode can lose, so closing says
--- what is actually at stake — including the two cases a plain count hides:
--- the disk copy failed to write, and it has not been read back yet.
---@return string|nil
local function close_warning()
	local count = #M.state.pending_comments
	if count > 0 and M.state.draft_save_error then
		return ("You have %d pending comment(s) and saving them to disk FAILED:\n"
			.. "%s\n"
			.. "Closing loses them. Close the review anyway?")
			:format(count, M.state.draft_save_error)
	end
	if count > 0 then
		return ("You have %d pending comment(s). Cached drafts are kept on disk.\n"
			.. "Discard the in-memory drafts and close the review?"):format(count)
	end
	if M.state.pr_number and not M.state.drafts_hydrated then
		return "Drafts saved for this PR have not been read back from disk yet, "
			.. "so whether there are any is still unknown.\n"
			.. "Close the review anyway?"
	end
	return nil
end

function M.close_with_guard()
	local warning = close_warning()
	if warning then
		local confirmed = require("gitflow.ui.input").confirm(warning,
			{ choices = { "&Yes", "&No" }, default_choice = 2 })
		if not confirmed then
			return
		end
	end
	M.close()
end

function M.is_open()
	return M.state.tabpage ~= nil
		and vim.api.nvim_tabpage_is_valid(M.state.tabpage)
		and M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

-- ── public entry points ────────────────────────────────────────────────
-- The `:Gitflow` commands, the PR panel and the specs drive review mode
-- through this table; the split modules are internal.

M.refresh = load.refresh
M.scope_to_commits = load.scope_to_commits
M.apply_commit_scope = load.apply_commit_scope
M.clear_commit_scope = load.clear_commit_scope

M.open_file = overlay.open_file
M.next_file = overlay.next_file
M.prev_file = overlay.prev_file
M.next_hunk = overlay.next_hunk
M.prev_hunk = overlay.prev_hunk
M.toggle_diff_view = overlay.toggle_diff_view
M.toggle_inline_comments = overlay.toggle_inline_comments
M._maybe_annotate_buffer = overlay.maybe_annotate_buffer

M.open_file_under_cursor = file_list.open_under_cursor
M.toggle_dir_under_cursor = file_list.toggle_dir_under_cursor
M.collapse_all_dirs = file_list.collapse_all_dirs
M.expand_all_dirs = file_list.expand_all_dirs

M.next_comment = threads.next_comment
M.prev_comment = threads.prev_comment
M.comments_overview = threads.comments_overview
M.view_thread_at_cursor = threads.view_thread_at_cursor
M.toggle_thread = threads.toggle_thread
M.reply_to_thread = threads.reply_to_thread

M.inline_comment = comments.inline_comment
M.inline_comment_visual = comments.inline_comment_visual
M.inline_suggestion = comments.inline_suggestion
M.inline_suggestion_visual = comments.inline_suggestion_visual
M.file_comment = comments.file_comment
M.file_comment_under_cursor = comments.file_comment_under_cursor
M.jump_to_draft = comments.jump_to_draft
M.edit_draft = comments.edit_draft
M.edit_draft_under_cursor = comments.edit_draft_under_cursor
M.edit_comment_at_cursor = comments.edit_comment_at_cursor
M.delete_draft_under_cursor = comments.delete_draft_under_cursor
M.delete_off_diff_drafts = comments.delete_off_diff_drafts
M.delete_comment_at_cursor = comments.delete_comment_at_cursor

M.submit_pending_review = submit.submit_pending_review
M.submit_review_direct = submit.submit_review_direct
M.review_approve = submit.review_approve
M.review_request_changes = submit.review_request_changes
M.review_comment = submit.review_comment
M.respond_to_review = submit.respond_to_review

--- Back to the PR detail view the review was opened from.
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

return M
