--- The review's diff pane: the right half of the review tabpage.
---
--- Owns everything review mode paints onto a *file* buffer — the inline diff
--- annotations, the comment boxes, the winbar banner and the review keys — and
--- the navigation that moves between files and hunks inside it. Every one of
--- those is installed and removed from the same declarations, so a file the
--- user keeps editing after review mode behaves normally again (#366).

local panel = require("gitflow.ui.panel")
local inline = require("gitflow.review.inline")
local rstate = require("gitflow.review.state")
local threads = require("gitflow.review.threads")
local file_list = require("gitflow.review.file_list")
local keymaps = require("gitflow.review.keymaps")

local M = {}
local state = rstate.state

--- Review actions bound buffer-locally on every file opened in the diff pane.
--- One list for both directions: a key added here is also a key removed on
--- close, so setup and teardown can never drift (#366).
local DIFF_KEYMAPS = keymaps.for_surface("diff")

-- The diff pane is a key surface in its own right (the file list is a Panel
-- and registers itself), so `?` and the cross-panel collision spec can see it.
panel.register_surface({
	name = "review_diff",
	title = "Gitflow Review — diff pane",
	keymaps = DIFF_KEYMAPS,
})

--- The keys currently bound in the diff pane, with `panel_keybindings`
--- applied. Held rather than re-resolved so teardown removes exactly what
--- setup installed, even if the config changes mid-review (#366).
---@type GitflowPanelKeymap[]
local bound_keymaps = {}

--- Guards the recursive BufWinEnter fired by open_file's own `:edit`.
local applying = false

-- ── the banner ─────────────────────────────────────────────────────────

---@return string
local function banner_text()
	local pending = #state.pending_comments
	local pending_label = ""
	if pending > 0 then
		pending_label = (" \u{2022} %d draft%s"):format(
			pending, pending == 1 and "" or "s"
		)
	end
	local author = state.pr_author and ("@" .. state.pr_author) or ""
	local extra = ""
	if state.commit_scope and state.commit_scope.label then
		extra = extra .. (" \u{2022} scope: %s"):format(state.commit_scope.label)
	end
	if not state.show_diff then
		extra = extra .. " \u{2022} view: full file"
	end
	return ("  PR REVIEW #%s  %s  %s%s%s "):format(
		rstate.fmt_number(state.pr_number), state.pr_title or "(loading)",
		author, pending_label, extra)
end

--- Paint the review banner on `winid`, remembering the winbar it replaced so
--- teardown can restore it (#366). Windows outside the review tabpage are
--- never touched — the banner must not leak into the user's other windows.
---@param winid integer|nil
function M.set_banner_winbar(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end
	if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage)
		and vim.api.nvim_win_get_tabpage(winid) ~= state.tabpage then
		return
	end
	if state.banner_wins[winid] == nil then
		-- winbar requires nvim 0.8+; on older versions leave the window alone.
		local ok, previous = pcall(vim.api.nvim_get_option_value, "winbar",
			{ win = winid })
		if not ok then
			return
		end
		state.banner_wins[winid] = previous or ""
	end
	pcall(
		vim.api.nvim_set_option_value,
		"winbar", "%#GitflowTitle#" .. banner_text(),
		{ win = winid }
	)
end

--- Put every winbar the banner overwrote back the way we found it (#366).
local function restore_banner_winbars()
	for winid, previous in pairs(state.banner_wins) do
		if vim.api.nvim_win_is_valid(winid) then
			pcall(vim.api.nvim_set_option_value, "winbar", previous,
				{ win = winid })
		end
	end
	state.banner_wins = {}
end

-- ── decorated buffers ──────────────────────────────────────────────────

---@param bufnr integer|nil
local function track_annotated(bufnr)
	if not bufnr then
		return
	end
	for _, existing in ipairs(state.annotated_buffers) do
		if existing == bufnr then
			return
		end
	end
	state.annotated_buffers[#state.annotated_buffers + 1] = bufnr
end

---@param bufnr integer
local function bind_review_keys(bufnr)
	local opts = { buffer = bufnr, silent = true, nowait = true }
	if #bound_keymaps == 0 then
		local cfg = state.cfg or require("gitflow.config").get()
		panel.warn_overrides("review_diff", cfg)
		bound_keymaps = panel.surface_keymaps("review_diff", cfg)
	end
	for _, entry in ipairs(bound_keymaps) do
		for _, binding in ipairs(panel.bindings(entry)) do
			vim.keymap.set(entry.mode or "n", binding.key, function()
				entry.run(binding.run_key)
			end, opts)
		end
	end
end

--- Drop the review keymaps from every buffer the overlay decorated.
local function clear_review_keymaps()
	for _, bufnr in ipairs(state.annotated_buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			for _, entry in ipairs(bound_keymaps) do
				for _, key in ipairs(panel.bound_keys(entry)) do
					pcall(vim.keymap.del, entry.mode or "n", key,
						{ buffer = bufnr })
				end
			end
		end
	end
	bound_keymaps = {}
end

local function clear_all_annotations()
	for _, bufnr in ipairs(state.annotated_buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			inline.clear_annotations(bufnr)
			inline.clear_comments(bufnr)
		end
	end
	state.annotated_buffers = {}
end

--- Undo every editor-visible thing review mode installed on a file buffer:
--- the banner winbars, the inline annotations and the buffer-local keymaps.
--- Idempotent, so both the normal and the abnormal close path can call it.
function M.teardown_decorations()
	applying = false
	restore_banner_winbars()
	-- Keymaps first: clear_all_annotations empties annotated_buffers.
	clear_review_keymaps()
	clear_all_annotations()
end

-- ── opening a file ─────────────────────────────────────────────────────

--- Build a scratch buffer that shows a message instead of a real file
--- (for deleted files or missing paths).
---@param path string
---@param message string
---@return integer
function M.placeholder_buffer(path, message)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr,
		("gitflow://review/%s/%s"):format(
			rstate.fmt_number(state.pr_number), path
		))
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(message, "\n"))
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	return bufnr
end

--- Track the placeholder the tabpage starts on, so teardown reaches it too.
---@param bufnr integer
function M.track(bufnr)
	track_annotated(bufnr)
end

--- Apply the full PR-review overlay to a buffer that displays the
--- working-tree file at repo-relative `path`: inline diff annotations,
--- comment boxes, the winbar banner, and the review keymaps. `winid` is the
--- window currently showing the buffer (used for cursor jumps + winbar).
--- Shared by open_file (file-list navigation) and the BufWinEnter autocmd
--- that catches files opened by other means (e.g. Telescope find_files).
---@param bufnr integer
---@param path string
---@param winid integer|nil
---@param opts table|nil  { jump = boolean }  jump to first hunk (default true)
local function apply_review_overlay(bufnr, path, winid, opts)
	opts = opts or {}
	local file_diff = state.file_diffs[path]

	state.active_path = path
	state.active_bufnr = bufnr

	-- When the diff overlay is hidden (#357) we show the plain working-tree
	-- file with no added/removed annotations; comments are still applied.
	local result
	if state.show_diff then
		result = inline.apply_annotations(bufnr, file_diff)
	else
		inline.clear_annotations(bufnr)
		result = { hunk_anchors = {}, deleted_lines = {} }
	end
	state.hunk_anchors = result.hunk_anchors or {}

	-- Deleted lines have no real buffer row (they're virt_lines). Index them
	-- by the buffer line they render next to so `c` can comment on them (#355).
	state.deleted_anchors = {}
	for _, d in ipairs(result.deleted_lines or {}) do
		local bucket = state.deleted_anchors[d.buf_line]
		if not bucket then
			bucket = {}
			state.deleted_anchors[d.buf_line] = bucket
		end
		bucket[#bucket + 1] = { old_line = d.old_line, text = d.text }
	end
	track_annotated(bufnr)

	if file_diff and file_diff.truncated then
		rstate.notify_warn(
			("PR diff for %s exceeds the GitHub per-file size limit; "
			.. "inline annotations are not available for this file."):format(path)
		)
	end

	threads.refresh_for_active()
	M.set_banner_winbar(winid)
	bind_review_keys(bufnr)

	-- Jump to first hunk so the change is immediately on screen.
	if opts.jump ~= false
		and winid and vim.api.nvim_win_is_valid(winid)
		and #state.hunk_anchors > 0 then
		pcall(vim.api.nvim_win_set_cursor, winid, { state.hunk_anchors[1], 0 })
	end

	-- Track which file index is now active (for next_file / prev_file)
	for i, f in ipairs(state.files) do
		if f.path == path then
			state.active_file_idx = i
			break
		end
	end

	-- Reveal the active file by expanding its ancestor folders.
	local parts = vim.split(path, "/", { plain = true })
	local acc = ""
	for i = 1, #parts - 1 do
		acc = acc == "" and parts[i] or (acc .. "/" .. parts[i])
		state.collapsed_dirs[acc] = nil
	end

	file_list.render()
end

--- Catch a file opened outside the file list (e.g. Telescope find_files,
--- :edit, a quickfix jump) that happens to be part of the PR diff, and
--- decorate it with the review overlay so the inline diff still shows.
---@param bufnr integer
function M.maybe_annotate_buffer(bufnr)
	if applying then
		return
	end
	if not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		return
	end
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	-- Only act inside the review tabpage to avoid surprising the user when
	-- they open the same file in an unrelated tab/window.
	if state.tabpage
		and vim.api.nvim_get_current_tabpage() ~= state.tabpage then
		return
	end
	local rel = rstate.buf_repo_relative(bufnr)
	if not rel or not state.file_diffs[rel] then
		return
	end
	-- Already decorated? Don't re-annotate, but DO re-sync the active
	-- pointers — otherwise switching back to a previously-opened file (via
	-- Telescope, :bnext, window focus, …) leaves active_path pointing at the
	-- other file, and a new comment gets saved against the wrong path.
	for _, b in ipairs(state.annotated_buffers) do
		if b == bufnr then
			state.active_path = rel
			state.active_bufnr = bufnr
			return
		end
	end
	local winid = vim.fn.bufwinid(bufnr)
	if winid == -1 then
		winid = state.diff_winid
	end
	apply_review_overlay(bufnr, rel, winid)
end

---@param path string
function M.open_file(path)
	if not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid) then
		rstate.notify_warn("Review mode is not active")
		return
	end
	if not path or path == "" then
		return
	end

	local file_diff = state.file_diffs[path]
	local full_path = rstate.repo_relative_path(path)
	local readable = full_path and vim.fn.filereadable(full_path) == 1

	vim.api.nvim_set_current_win(state.diff_winid)

	local bufnr
	if readable then
		-- Open the real file via :edit so filetype detection, treesitter,
		-- and LSP attach normally. We deliberately do NOT use `noautocmd`
		-- here — suppressing autocmds skips FileType and BufRead* events,
		-- which breaks syntax highlighting. The `applying` guard stops the
		-- BufWinEnter autocmd from racing us.
		applying = true
		pcall(vim.cmd, "silent edit " .. vim.fn.fnameescape(full_path))
		bufnr = vim.api.nvim_get_current_buf()
		applying = false

		-- If for any reason filetype wasn't picked up (e.g. the buffer
		-- was already open via another path), re-run filetype detection.
		if vim.api.nvim_get_option_value("filetype", { buf = bufnr }) == "" then
			pcall(vim.cmd, "filetype detect")
		end
	else
		local message = ("PR diff for %s\n\nThis file is not in the working tree.")
			:format(path)
		if file_diff and file_diff.status == "D" then
			message = ("PR #%s deletes %s\n\n(Showing diff only — no working tree file.)")
				:format(rstate.fmt_number(state.pr_number), path)
		end
		bufnr = M.placeholder_buffer(path, message)
		vim.api.nvim_win_set_buf(state.diff_winid, bufnr)
	end

	apply_review_overlay(bufnr, path, state.diff_winid)
end

-- ── navigation ─────────────────────────────────────────────────────────

function M.next_file()
	if #state.files == 0 then
		return
	end
	local idx = (state.active_file_idx or 0) + 1
	if idx > #state.files then
		idx = 1
	end
	M.open_file(state.files[idx].path)
end

function M.prev_file()
	if #state.files == 0 then
		return
	end
	local idx = (state.active_file_idx or 2) - 1
	if idx < 1 then
		idx = #state.files
	end
	M.open_file(state.files[idx].path)
end

---@param direction 1|-1
local function jump_hunk(direction)
	if not state.diff_winid
		or not vim.api.nvim_win_is_valid(state.diff_winid)
		or #state.hunk_anchors == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(state.diff_winid)[1]
	local anchors = state.hunk_anchors
	if direction > 0 then
		for _, line in ipairs(anchors) do
			if line > cur then
				pcall(vim.api.nvim_win_set_cursor, state.diff_winid, { line, 0 })
				return
			end
		end
		pcall(vim.api.nvim_win_set_cursor, state.diff_winid, { anchors[1], 0 })
		return
	end
	for i = #anchors, 1, -1 do
		if anchors[i] < cur then
			pcall(vim.api.nvim_win_set_cursor, state.diff_winid, { anchors[i], 0 })
			return
		end
	end
	pcall(vim.api.nvim_win_set_cursor, state.diff_winid,
		{ anchors[#anchors], 0 })
end

function M.next_hunk()
	jump_hunk(1)
end

function M.prev_hunk()
	jump_hunk(-1)
end

-- ── view toggles ───────────────────────────────────────────────────────

function M.toggle_inline_comments()
	state.show_inline_comments = not state.show_inline_comments
	threads.refresh_for_active()
end

--- Toggle between the git-diff overlay (added/removed annotations) and a
--- plain view of the file as it is in the branch (#357). Some diffs are
--- noisy; this lets the reviewer read the file normally and flip back.
--- Comments stay visible in both modes.
function M.toggle_diff_view()
	state.show_diff = not state.show_diff
	if state.active_bufnr
		and vim.api.nvim_buf_is_valid(state.active_bufnr)
		and state.active_path then
		-- Re-apply the overlay on the active buffer to add/remove annotations.
		apply_review_overlay(
			state.active_bufnr, state.active_path,
			state.diff_winid, { jump = false }
		)
	end
	M.set_banner_winbar(state.diff_winid)
	file_list.render()
	rstate.notify_info(state.show_diff
		and "Diff view: showing PR changes"
		or "Diff view: showing file as in branch (diff hidden)")
end

return M
