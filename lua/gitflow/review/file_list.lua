--- The review's file-list pane: the left half of the review tabpage.
---
--- This is the review's panel — it owns the buffer, the keymaps, the request
--- generation and the line→entry maps through `ui/panel.lua`. The one thing
--- the base does not own is placement: the pane is a fixed-width vsplit inside
--- the review's own tabpage, so `panels/review.lua` builds the window and
--- hands it here with `attach`.
---
--- Everything drawn goes through the render builder and `ui/components.lua`.

local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")
local ui_render = require("gitflow.ui.render")
local icons = require("gitflow.icons")
local rstate = require("gitflow.review.state")
local tree = require("gitflow.review.tree")
local keymaps = require("gitflow.review.keymaps")

local M = {}
local state = rstate.state

M.WIDTH = 44

local P = panel.new({
	name = "review_files",
	title = "PR Review",
	filetype = "gitflow-review-files",
	loading = "Loading changed files…",
	state = state,
	-- Three maps, all of them the stale-resolution hazard the base guards:
	-- a keypress on a collapsed pane must not resolve to a file, folder or
	-- draft that is no longer on screen.
	entry_maps = { "file_line_map", "dir_line_map", "draft_line_map" },
	keymaps = keymaps.for_surface("list"),
})

-- ── request generation ─────────────────────────────────────────────────
-- The file list is the review's panel, so the review's in-flight PR load is
-- tracked on its generation counter.

---@return integer
function M.next_request()
	return P:next_request()
end

--- Is this async response still the one the view is waiting for? Switching
--- PRs (or closing review mode) mid-load must not splice the old PR's files
--- and comment threads into the new view.
---@param request_id integer
---@param number integer|nil
---@return boolean
function M.is_active(request_id, number)
	return P:is_active(request_id) and state.pr_number == number
end

-- ── status glyphs ──────────────────────────────────────────────────────

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
	end
	return "GitflowModified"
end

-- ── the tree rows ──────────────────────────────────────────────────────

---Recursively emit tree rows into the builder, recording which file or folder
---each rendered line points at.
---@param node table
---@param depth integer
---@param prefix string  parent dir path (for collapse keys)
---@param ctx table  { B, threads, pending }
local function render_tree_node(node, depth, prefix, ctx)
	local B = ctx.B
	local indent = ui_render.spacing.edge
		.. string.rep(ui_render.spacing.gutter, depth)

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
		state.all_dirs[full] = true
		local collapsed = state.collapsed_dirs[full] == true
		local chunks = {
			{ indent, nil },
			{ (collapsed and "\u{25b8}" or "\u{25be}") .. " ",
				"GitflowReviewTreeGuide" },
			{ label .. "/", "GitflowReviewTreeDir" },
			{ ("  (%d)"):format(tree.leaf_count(child)), "GitflowReviewHint" },
		}
		-- When folded, surface hidden threads/drafts so the user doesn't
		-- have to expand every folder to find unresolved comments.
		if collapsed then
			local ct, cp = tree.comment_totals(child, ctx.threads, ctx.pending)
			if ct > 0 then
				chunks[#chunks + 1] =
					{ (" [%d]"):format(ct), "GitflowReviewComment" }
			end
			if cp > 0 then
				chunks[#chunks + 1] = {
					(" \u{25cf}%d"):format(cp), "GitflowReviewChangesRequested",
				}
			end
		end
		state.dir_line_map[B:push(chunks)] = full
		if not collapsed then
			render_tree_node(child, depth + 1, full, ctx)
		end
	end

	local files = vim.deepcopy(node.files)
	table.sort(files, function(a, b) return a.name < b.name end)
	for _, entry in ipairs(files) do
		local f = entry.file
		local chunks = {
			{ indent, nil },
			{ status_indicator(f.status) .. " ", status_hl(f.status) },
			{ entry.name, state.active_path == f.path and "GitflowTitle" or nil },
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
			chunks[#chunks + 1] =
				{ (" [%d]"):format(threads), "GitflowReviewComment" }
		end
		local pending = ctx.pending[f.path] or 0
		if pending > 0 then
			chunks[#chunks + 1] = {
				(" \u{25cf}%d"):format(pending), "GitflowReviewChangesRequested",
			}
		end
		local fd = state.file_diffs[f.path]
		if fd and fd.truncated then
			chunks[#chunks + 1] =
				{ " \u{26a0}", "GitflowReviewChangesRequested" }
		end
		state.file_line_map[B:push(chunks)] = entry.idx
	end
end

-- ── the sections ───────────────────────────────────────────────────────

---@param B GitflowRenderBuilder
local function push_rule(B)
	B:raw(ui_render.separator(P:render_opts()), "GitflowSeparator")
end

---Title block: which PR this is, who wrote it, where it is going, and which
---slice of it the pane is currently showing.
---@param B GitflowRenderBuilder
local function push_header(B)
	local gutter = ui_render.spacing.gutter
	components.header(B, (" PR REVIEW \u{b7} #%s"):format(
		rstate.fmt_number(state.pr_number)), P:render_opts())
	B:push({ { gutter, nil },
		{ state.pr_title or "(loading)", "GitflowCardTitle" } })
	if state.pr_author then
		B:push({ { gutter, nil },
			{ icons.get("ui", "author") .. " ", "GitflowSectionIcon" },
			{ "@" .. state.pr_author, "GitflowMeta" } })
	end
	if state.pr_head and state.pr_base then
		B:push({ { gutter, nil },
			{ icons.get("branch", "current") .. " ", "GitflowSectionIcon" },
			{ ("%s \u{2190} %s"):format(state.pr_base, state.pr_head),
				"GitflowMeta" } })
	end
	if state.commit_scope and state.commit_scope.label then
		B:push({ { gutter, nil },
			{ ("\u{25c6} scope: %s"):format(state.commit_scope.label),
				"GitflowReviewHint" } })
	end
	-- Which layer the diff pane is showing, so the toggle is never ambiguous.
	if not state.show_diff then
		B:push({ { gutter, nil },
			{ "\u{25c6} view: full file (diff hidden)", "GitflowReviewHint" } })
	end
	push_rule(B)
end

---The `Files (n)  +a -d  [t in f]` bar.
---@param B GitflowRenderBuilder
local function push_files_header(B)
	local total_add, total_del = 0, 0
	for _, f in ipairs(state.files) do
		total_add = total_add + (f.additions or 0)
		total_del = total_del + (f.deletions or 0)
	end
	-- Count files that carry remote review threads so a reviewer can see at
	-- a glance how much discussion exists and where.
	local files_with_threads, total_threads = 0, 0
	local seen = {}
	for _, t in ipairs(state.comment_threads) do
		if t.path then
			total_threads = total_threads + 1
			if not seen[t.path] then
				seen[t.path] = true
				files_with_threads = files_with_threads + 1
			end
		end
	end

	local chunks = {
		{ ui_render.spacing.edge, nil },
		{ ("Files (%d)"):format(#state.files), "GitflowSectionTitle" },
		{ ("  +%d"):format(total_add), "GitflowReviewCountAdd" },
		{ (" -%d"):format(total_del), "GitflowReviewCountDel" },
	}
	if total_threads > 0 then
		chunks[#chunks + 1] = {
			("  [%d in %d]"):format(total_threads, files_with_threads),
			"GitflowReviewComment",
		}
	end
	B:push(chunks)
	push_rule(B)
end

---The tree, or the state the tree is in instead.
---@param B GitflowRenderBuilder
local function push_files(B)
	if #state.files > 0 then
		local pending, threads = tree.counts_by_path()
		render_tree_node(tree.build(state.files), 0, "", {
			B = B, pending = pending, threads = threads,
		})
		return
	end
	if state.files_error then
		components.error_state(B, "Could not load changed files",
			{ detail = state.files_error })
	elseif state.files_loaded then
		components.empty(B, "No changed files",
			{ hint = "Nothing to review in this PR." })
	else
		components.loading(B, "Loading changed files\u{2026}")
	end
end

---Every unsubmitted draft, flagging the ones that no longer map to a line in
---the PR diff — those are exactly the ones GitHub rejects on submit.
---@param B GitflowRenderBuilder
local function push_drafts(B)
	local pending = state.pending_comments
	if #pending == 0 then
		return
	end

	local off_count = 0
	for _, pc in ipairs(pending) do
		if not rstate.draft_in_scope(pc) then
			off_count = off_count + 1
		end
	end

	B:blank()
	push_rule(B)
	local header = (" Drafts (%d)"):format(#pending)
	if off_count > 0 then
		header = header .. ("  \u{2717}%d off-diff"):format(off_count)
	end
	B:raw(header, off_count > 0
		and "GitflowReviewDraftOutOfScope" or "GitflowReviewHint")

	for idx, pc in ipairs(pending) do
		local in_scope = rstate.draft_in_scope(pc)
		-- ✓ = already on the PR (a partially-failed submit); it will not
		-- be posted again.
		local marker = "\u{25cf}"
		if pc.posted then
			marker = "\u{2713}"
		elseif not in_scope then
			marker = "\u{2717}"
		end
		local name = vim.fn.fnamemodify(pc.path or "?", ":t")
		local preview = vim.trim((pc.body or ""):gsub("%s+", " "))
		local locator
		if pc.file_level then
			locator = name .. " (file)"
		else
			locator = ("%s:%d"):format(name, pc.new_line or pc.old_line or 0)
		end
		local label = vim.fn.strcharpart(
			("  %s %s  %s"):format(marker, locator, preview), 0, M.WIDTH - 1)
		state.draft_line_map[B:raw(label, in_scope
			and "GitflowReviewDraftBox" or "GitflowReviewDraftOutOfScope")] = idx
	end
end

---Push a legend group, wrapping its hints onto as many rows as the pane needs.
---The pane is narrow and review mode is key-dense: eliding to a single bar the
---way a normal panel does would hide most of the verbs, so the legend wraps
---instead.
---@param B GitflowRenderBuilder
---@param label string
---@param hints table[]
---@param width integer
local function push_hint_group(B, label, hints, width)
	if #hints == 0 then
		return
	end
	local lead = vim.fn.strdisplaywidth(ui_render.spacing.indent)
	local sep = vim.fn.strdisplaywidth(ui_render.separators.hint)
	local rows, row, row_width = {}, {}, 0
	for _, hint in ipairs(hints) do
		local hint_width = vim.fn.strdisplaywidth(hint[1] .. " " .. hint[2])
		if #row > 0 and row_width + sep + hint_width > width then
			rows[#rows + 1] = row
			row, row_width = { hint }, lead + hint_width
		else
			row_width = (#row == 0 and lead or row_width + sep) + hint_width
			row[#row + 1] = hint
		end
	end
	rows[#rows + 1] = row

	for index, entries in ipairs(rows) do
		if index == 1 then
			components.hint_group(B, label, entries)
		else
			components.hint_bar(B, entries,
				{ leading = ui_render.spacing.indent })
		end
	end
end

---The glyph legend: what the markers in the tree rows mean. Hand-built rather
---than a hint group because each glyph carries its own highlight.
---@param B GitflowRenderBuilder
local function push_glyph_legend(B)
	local gutter, indent = ui_render.spacing.gutter, ui_render.spacing.indent
	B:push({ { gutter, nil }, { "LEGEND", "GitflowHintGroupLabel" } })
	B:push({
		{ indent, nil },
		{ "~", "GitflowModified" }, { " mod  ", "GitflowReviewHint" },
		{ "+", "GitflowAdded" }, { " add  ", "GitflowReviewHint" },
		{ "-", "GitflowRemoved" }, { " del  ", "GitflowReviewHint" },
		{ ">", "GitflowChip" }, { " ren", "GitflowReviewHint" },
	})
	B:push({
		{ indent, nil },
		{ "[n]", "GitflowReviewCountAdd" }, { " threads   ", "GitflowReviewHint" },
		{ "\u{25cf}n", "GitflowReviewDraftBox" }, { " drafts", "GitflowReviewHint" },
	})
end

---@param B GitflowRenderBuilder
local function push_legend(B)
	B:blank()
	push_rule(B)
	push_glyph_legend(B)
	local width = P:split_width() or M.WIDTH
	for _, group in ipairs(keymaps.GROUPS) do
		push_hint_group(B, group.label,
			keymaps.hints_for_group(group.id), width)
	end
	B:blank()
	components.hint_bar(B, keymaps.hints_for_group(keymaps.SESSION_GROUP),
		{ leading = ui_render.spacing.indent })
end

--- Repaint the whole pane. Every line→entry map is rebuilt from scratch here,
--- so a row can never resolve to something that scrolled off.
function M.render()
	if not P:bufnr() then
		return
	end
	state.file_line_map = {}
	state.dir_line_map = {}
	state.draft_line_map = {}
	state.all_dirs = {}

	local B = ui_render.builder()
	push_header(B)
	push_files_header(B)
	push_files(B)
	push_drafts(B)
	push_legend(B)
	P:paint(B)
end

-- ── cursor → entry ─────────────────────────────────────────────────────

---@param map table<integer, any>
---@return any|nil
local function under_cursor(map)
	if not P:has_window() then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(state.winid)[1]
	return map[cursor]
end

---@return integer|nil  index into state.files
function M.file_idx_under_cursor()
	return under_cursor(state.file_line_map)
end

---@return integer|nil  index into state.pending_comments
function M.draft_idx_under_cursor()
	return under_cursor(state.draft_line_map)
end

--- Toggle the collapsed state of the directory on the cursor line.
---@return boolean  true if a directory line was toggled
function M.toggle_dir_under_cursor()
	local full = under_cursor(state.dir_line_map)
	if not full then
		return false
	end
	local cursor = vim.api.nvim_win_get_cursor(state.winid)[1]
	state.collapsed_dirs[full] = not state.collapsed_dirs[full]
	M.render()
	local total = vim.api.nvim_buf_line_count(state.bufnr)
	pcall(vim.api.nvim_win_set_cursor, state.winid,
		{ math.min(cursor, total), 0 })
	return true
end

function M.collapse_all_dirs()
	for full in pairs(state.all_dirs) do
		state.collapsed_dirs[full] = true
	end
	M.render()
end

function M.expand_all_dirs()
	state.collapsed_dirs = {}
	M.render()
end

--- <CR> on a row: jump to a draft, fold a folder, or open a file.
function M.open_under_cursor()
	local comments = require("gitflow.review.comments")
	local draft_idx = M.draft_idx_under_cursor()
	if draft_idx then
		comments.jump_to_draft(state.pending_comments[draft_idx])
		return
	end
	if M.toggle_dir_under_cursor() then
		return
	end
	local idx = M.file_idx_under_cursor()
	local file = idx and state.files[idx]
	if file then
		require("gitflow.review.overlay").open_file(file.path)
	end
end

-- ── attachment ─────────────────────────────────────────────────────────

--- Adopt the buffer and window `panels/review.lua` built for the pane, and
--- bind the file-list keys onto the buffer.
---@param bufnr integer
---@param winid integer
function M.attach(bufnr, winid)
	state.bufnr = bufnr
	state.winid = winid
	P:bind_keymaps(bufnr)
end

--- Forget the pane. The generation is bumped so a load still in flight cannot
--- paint into the buffer we are about to drop.
function M.detach()
	state.bufnr = nil
	state.winid = nil
	P:next_request()
end

return M
