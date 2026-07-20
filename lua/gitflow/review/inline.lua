--- lua/gitflow/review/inline.lua
---
--- Parse a unified PR diff and apply inline annotations to a real file
--- buffer: highlight added lines, render removed lines as virt_lines, and
--- track hunk boundaries for navigation. Comments (existing + pending)
--- are applied as a separate overlay so they can be toggled / refreshed
--- without touching the diff annotations themselves.

local M = {}

local DIFF_NS = vim.api.nvim_create_namespace("gitflow_review_diff")
local COMMENT_NS = vim.api.nvim_create_namespace("gitflow_review_inline_comments")

M.DIFF_NS = DIFF_NS
M.COMMENT_NS = COMMENT_NS

---@class GitflowReviewFileDiff
---@field path string
---@field status "A"|"D"|"M"|"R"
---@field hunks GitflowReviewHunk[]

---@class GitflowReviewHunk
---@field header string
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field lines GitflowReviewHunkLine[]

---@class GitflowReviewHunkLine
---@field kind "add"|"del"|"ctx"
---@field text string
---@field old_line integer|nil
---@field new_line integer|nil

---@param text string|nil
---@return string[]
local function split_lines(text)
	if not text or text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

---@param header string
---@return integer, integer, integer, integer
local function parse_hunk_header(header)
	local old_start, old_count, new_start, new_count =
		header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
	if not old_start then
		return 0, 0, 0, 0
	end
	return
		tonumber(old_start) or 0,
		tonumber(old_count) == nil and 1 or (tonumber(old_count) or 1),
		tonumber(new_start) or 0,
		tonumber(new_count) == nil and 1 or (tonumber(new_count) or 1)
end

--- Parse hunk-only patch text (no `diff --git` / `+++/---` headers)
--- as produced by the GitHub pulls/.../files API.  Returns a list of
--- hunks matching the GitflowReviewHunk shape.
---@param patch_text string|nil
---@return GitflowReviewHunk[]
function M.parse_hunks_from_patch(patch_text)
	local hunks = {}
	local current_hunk = nil
	local old_line, new_line = 0, 0

	for _, line in ipairs(split_lines(patch_text)) do
		if vim.startswith(line, "@@") then
			local os, oc, ns, nc = parse_hunk_header(line)
			current_hunk = {
				header = line,
				old_start = os, old_count = oc,
				new_start = ns, new_count = nc,
				lines = {},
			}
			hunks[#hunks + 1] = current_hunk
			old_line, new_line = os, ns
		elseif current_hunk then
			local first = line:sub(1, 1)
			if first == "+" then
				current_hunk.lines[#current_hunk.lines + 1] = {
					kind = "add",
					text = line:sub(2),
					new_line = new_line,
				}
				new_line = new_line + 1
			elseif first == "-" then
				current_hunk.lines[#current_hunk.lines + 1] = {
					kind = "del",
					text = line:sub(2),
					old_line = old_line,
				}
				old_line = old_line + 1
			elseif first == " " then
				current_hunk.lines[#current_hunk.lines + 1] = {
					kind = "ctx",
					text = line:sub(2),
					old_line = old_line,
					new_line = new_line,
				}
				old_line = old_line + 1
				new_line = new_line + 1
			end
		end
	end

	return hunks
end

--- Parse a unified diff into a per-file structure.
---@param diff_text string|nil
---@return table<string, GitflowReviewFileDiff>
function M.parse_diff(diff_text)
	local files = {}
	local current = nil
	local current_hunk = nil
	local old_line = 0
	local new_line = 0

	for _, line in ipairs(split_lines(diff_text)) do
		local old_path, new_path =
			line:match("^diff %-%-git a/(.+) b/(.+)$")
		if old_path and new_path then
			current = {
				path = new_path,
				status = "M",
				hunks = {},
			}
			files[new_path] = current
			current_hunk = nil
			old_line = 0
			new_line = 0
		elseif current and line:match("^new file mode") then
			current.status = "A"
		elseif current and line:match("^deleted file mode") then
			current.status = "D"
			-- For deleted files, the path under +++ is /dev/null; keep
			-- the old path as the canonical path so callers can find it.
			current.path = old_path or current.path
			files[current.path] = current
		elseif current and (line:match("^rename from")
			or line:match("^similarity index")) then
			current.status = "R"
		elseif current and vim.startswith(line, "@@") then
			local os, oc, ns, nc = parse_hunk_header(line)
			current_hunk = {
				header = line,
				old_start = os,
				old_count = oc,
				new_start = ns,
				new_count = nc,
				lines = {},
			}
			current.hunks[#current.hunks + 1] = current_hunk
			old_line = os
			new_line = ns
		elseif current and current_hunk then
			local first = line:sub(1, 1)
			if first == "+" then
				current_hunk.lines[#current_hunk.lines + 1] = {
					kind = "add",
					text = line:sub(2),
					new_line = new_line,
				}
				new_line = new_line + 1
			elseif first == "-" then
				current_hunk.lines[#current_hunk.lines + 1] = {
					kind = "del",
					text = line:sub(2),
					old_line = old_line,
				}
				old_line = old_line + 1
			elseif first == " " then
				current_hunk.lines[#current_hunk.lines + 1] = {
					kind = "ctx",
					text = line:sub(2),
					old_line = old_line,
					new_line = new_line,
				}
				old_line = old_line + 1
				new_line = new_line + 1
			end
			-- ignore "\ No newline at end of file" and similar
		end
	end

	return files
end

--- Clear the inline diff annotations on a buffer.
---@param bufnr integer
function M.clear_annotations(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, DIFF_NS, 0, -1)
end

--- Clear inline comments on a buffer.
---@param bufnr integer
function M.clear_comments(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, COMMENT_NS, 0, -1)
end

---@param bufnr integer
---@return integer
local function buf_line_count(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end
	return vim.api.nvim_buf_line_count(bufnr)
end

---@param bufnr integer
---@return string|nil
local function buf_treesitter_lang(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
	if not ft or ft == "" then
		return nil
	end
	if not vim.treesitter or not vim.treesitter.language then
		return nil
	end
	local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
	if ok and type(lang) == "string" and lang ~= "" then
		-- Confirm the parser is actually installed before returning.
		local ok_add, _ = pcall(vim.treesitter.language.add, lang)
		if ok_add then
			return lang
		end
	end
	return nil
end

--- Turn a single-line piece of text into a list of `{chunk, hl}` tuples
--- using the treesitter highlights query for `lang`. Each chunk's
--- highlight is a stack `{ base_hl, capture_hl }` so the caller's
--- base highlight (typically `DiffDelete`) supplies the background
--- and the treesitter capture supplies the foreground.
---
--- Falls back to a single `{ text, base_hl }` chunk if treesitter is
--- unavailable, the language has no highlights query, or parsing fails.
---@param text string
---@param lang string|nil
---@param base_hl string
---@return table[]
local function ts_highlight_line(text, lang, base_hl)
	if not text or text == "" then
		return { { text or "", base_hl } }
	end
	if not lang or not vim.treesitter or not vim.treesitter.query then
		return { { text, base_hl } }
	end

	local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, lang)
	if not ok_parser or not parser then
		return { { text, base_hl } }
	end

	local ok_parse, trees = pcall(function() return parser:parse() end)
	if not ok_parse or type(trees) ~= "table" or not trees[1] then
		return { { text, base_hl } }
	end
	local root = trees[1]:root()
	if not root then
		return { { text, base_hl } }
	end

	local get_query = vim.treesitter.query.get
		or vim.treesitter.query.get_query
	if not get_query then
		return { { text, base_hl } }
	end
	local ok_q, query = pcall(get_query, lang, "highlights")
	if not ok_q or not query then
		return { { text, base_hl } }
	end

	-- Sweep positions 0..#text-1 to compute the active hl at each col.
	-- Longer captures get overwritten by shorter (more specific) ones.
	local len = #text
	local hl_at = {}
	local ok_iter = pcall(function()
		for id, node in query:iter_captures(root, text, 0, 1) do
			local capture_name = query.captures[id]
			if capture_name then
				local sr, sc, er, ec = node:range()
				if sr == 0 and er == 0 and sc < ec then
					local span_len = ec - sc
					-- Tag with span length so shorter (more specific) wins.
					for i = sc, math.min(ec, len) - 1 do
						local existing = hl_at[i]
						if not existing or existing.len >= span_len then
							hl_at[i] = {
								hl = "@" .. capture_name .. "." .. lang,
								len = span_len,
							}
						end
					end
				end
			end
		end
	end)
	if not ok_iter then
		return { { text, base_hl } }
	end

	local chunks = {}
	local i = 0
	while i < len do
		local cur = hl_at[i]
		local j = i + 1
		while j < len do
			local nxt = hl_at[j]
			if (cur and nxt and cur.hl == nxt.hl)
				or (not cur and not nxt) then
				j = j + 1
			else
				break
			end
		end
		local segment = text:sub(i + 1, j)
		if cur and cur.hl then
			chunks[#chunks + 1] = { segment, { base_hl, cur.hl } }
		else
			chunks[#chunks + 1] = { segment, base_hl }
		end
		i = j
	end

	if #chunks == 0 then
		return { { text, base_hl } }
	end
	return chunks
end

M._ts_highlight_line = ts_highlight_line

---@param bufnr integer
---@param new_line integer
---@return integer
local function clamp_anchor(bufnr, new_line)
	local total = buf_line_count(bufnr)
	if total == 0 then
		return 0
	end
	if new_line < 1 then
		return 1
	end
	if new_line > total then
		return total
	end
	return new_line
end

---@class GitflowReviewDeletedAnchor
---@field buf_line integer  buffer line (1-based) the removed block is anchored at
---@field old_line integer|nil  old-side (LEFT) line number of the removed line
---@field text string  the removed line's text

---@class GitflowReviewAnnotateResult
---@field added_lines integer[]  buffer lines (1-based) highlighted as added
---@field hunk_anchors integer[] buffer lines (1-based) that start each hunk
---@field deleted_lines GitflowReviewDeletedAnchor[]  removed lines + their anchor

--- Apply diff annotations to a buffer that contains the real file.
---@param bufnr integer
---@param file_diff GitflowReviewFileDiff|nil
---@return GitflowReviewAnnotateResult
function M.apply_annotations(bufnr, file_diff)
	local result = { added_lines = {}, hunk_anchors = {}, deleted_lines = {} }
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return result
	end

	M.clear_annotations(bufnr)
	if not file_diff or not file_diff.hunks then
		return result
	end

	local total = buf_line_count(bufnr)
	local lang = buf_treesitter_lang(bufnr)

	for _, hunk in ipairs(file_diff.hunks) do
		local pending_removals = {}
		local anchor_for_hunk = nil

		local function flush_removals_above(new_line)
			if #pending_removals == 0 then
				return
			end
			local anchor = new_line
			local position = "above"
			if anchor < 1 then
				anchor = 1
			end
			if anchor > total then
				anchor = total
				position = "below"
			end
			local virt_lines = {}
			for _, removed in ipairs(pending_removals) do
				local chunks = { { "- ", "DiffDelete" } }
				for _, ch in ipairs(
					ts_highlight_line(removed.text, lang, "DiffDelete")
				) do
					chunks[#chunks + 1] = ch
				end
				virt_lines[#virt_lines + 1] = chunks
				-- Record so callers can offer "comment on this deleted line":
				-- the removed line has no real buffer row (it's a virt_line),
				-- so we anchor it to the buffer line it renders next to.
				result.deleted_lines[#result.deleted_lines + 1] = {
					buf_line = anchor,
					old_line = removed.old_line,
					text = removed.text,
				}
			end
			local opts = {
				virt_lines = virt_lines,
				virt_lines_above = position == "above",
			}
			pcall(vim.api.nvim_buf_set_extmark, bufnr, DIFF_NS,
				anchor - 1, 0, opts)
			pending_removals = {}
		end

		for _, line in ipairs(hunk.lines) do
			if line.kind == "del" then
				pending_removals[#pending_removals + 1] = line
			elseif line.kind == "add" and line.new_line then
				local anchor = clamp_anchor(bufnr, line.new_line)
				flush_removals_above(anchor)
				if anchor >= 1 then
					pcall(
						vim.api.nvim_buf_set_extmark, bufnr, DIFF_NS,
						anchor - 1, 0,
						{
							line_hl_group = "DiffAdd",
							sign_text = "+",
							sign_hl_group = "GitflowAdded",
						}
					)
					result.added_lines[#result.added_lines + 1] = anchor
					if not anchor_for_hunk then
						anchor_for_hunk = anchor
					end
				end
			elseif line.kind == "ctx" and line.new_line then
				local anchor = clamp_anchor(bufnr, line.new_line)
				flush_removals_above(anchor)
				if not anchor_for_hunk then
					anchor_for_hunk = anchor
				end
			end
		end

		if #pending_removals > 0 then
			-- Removals fall at the end of the hunk with no anchor below.
			local last_new = hunk.new_start + math.max(0, hunk.new_count - 1)
			flush_removals_above(clamp_anchor(bufnr, last_new + 1))
		end

		if anchor_for_hunk then
			result.hunk_anchors[#result.hunk_anchors + 1] = anchor_for_hunk
		elseif hunk.new_start then
			result.hunk_anchors[#result.hunk_anchors + 1] =
				clamp_anchor(bufnr, hunk.new_start)
		end
	end

	return result
end

-- ── Suggested changes (GitHub ```suggestion blocks) ─────────────────────
--
-- A suggestion is not a separate API object: it is a fenced block inside an
-- ordinary review-comment body, applied to the new-side lines the comment
-- anchors to.  These helpers build and parse that block.

--- The new-file lines `start_new`..`end_new` exactly as the PR diff has them.
--- Every line in the range must be present (added or context) — a gap returns
--- an error rather than a guess, because a suggestion assembled from the wrong
--- lines would silently rewrite the author's file.
---@param file_diff GitflowReviewFileDiff|nil
---@param start_new integer
---@param end_new integer
---@return string[]|nil, string|nil
function M.new_side_lines(file_diff, start_new, end_new)
	if type(start_new) ~= "number" or type(end_new) ~= "number"
		or start_new < 1 or end_new < start_new then
		return nil, "invalid line range"
	end
	if not file_diff or type(file_diff.hunks) ~= "table" then
		return nil, "this file has no parsed PR diff"
	end

	local by_line = {}
	for _, hunk in ipairs(file_diff.hunks) do
		for _, l in ipairs(hunk.lines) do
			-- Deleted lines carry no new_line, so they can never shadow a
			-- new-side line here.
			if l.new_line and l.new_line >= start_new
				and l.new_line <= end_new then
				by_line[l.new_line] = l.text or ""
			end
		end
	end

	local out = {}
	for n = start_new, end_new do
		if by_line[n] == nil then
			return nil, ("line %d is not part of the PR diff"):format(n)
		end
		out[#out + 1] = by_line[n]
	end
	assert(#out == end_new - start_new + 1,
		"suggestion source must cover the whole range")
	return out, nil
end

---@param lines string[]
---@return integer
local function longest_backtick_run(lines)
	local longest = 0
	for _, line in ipairs(lines) do
		for run in tostring(line):gmatch("`+") do
			if #run > longest then
				longest = #run
			end
		end
	end
	return longest
end

--- Wrap `lines` in a ```suggestion fence. The fence outgrows any backtick run
--- in the content, so suggesting on fenced markdown does not break the block.
---@param lines string[]
---@return string
function M.suggestion_block(lines)
	assert(type(lines) == "table", "suggestion lines must be a table")
	local fence = string.rep("`", math.max(3, longest_backtick_run(lines) + 1))
	local out = { fence .. "suggestion" }
	for _, l in ipairs(lines) do
		out[#out + 1] = tostring(l)
	end
	out[#out + 1] = fence
	return table.concat(out, "\n")
end

---@param lines string[]
---@param from integer
---@param fence string
---@return integer|nil  index of the closing fence line
local function find_fence_close(lines, from, fence)
	for i = from, #lines do
		local run = lines[i]:match("^%s*(`+)%s*$")
		if run and #run >= #fence then
			return i
		end
	end
	return nil
end

---@class GitflowReviewBodySegment
---@field kind "text"|"suggestion"
---@field lines string[]

--- Split a comment body into prose and suggestion blocks so a reviewer can
--- tell a proposed edit from prose. An unterminated fence stays prose.
---@param body string|nil
---@return GitflowReviewBodySegment[]
function M.split_suggestions(body)
	local lines = split_lines(body)
	local segments = {}
	local text = {}

	local function flush_text()
		if #text > 0 then
			segments[#segments + 1] = { kind = "text", lines = text }
			text = {}
		end
	end

	local i = 1
	while i <= #lines do
		local fence = lines[i]:match("^%s*(`+)suggestion%s*$")
		local close_at = (fence and #fence >= 3)
			and find_fence_close(lines, i + 1, fence) or nil
		if close_at then
			flush_text()
			local block = {}
			for j = i + 1, close_at - 1 do
				block[#block + 1] = lines[j]
			end
			segments[#segments + 1] = { kind = "suggestion", lines = block }
			i = close_at + 1
		else
			text[#text + 1] = lines[i]
			i = i + 1
		end
	end
	flush_text()
	return segments
end

---@param body string|nil
---@return boolean
function M.has_suggestion(body)
	for _, seg in ipairs(M.split_suggestions(body)) do
		if seg.kind == "suggestion" then
			return true
		end
	end
	return false
end

---@class GitflowReviewInlineComment
---@field author string|nil
---@field body string
---@field new_line integer|nil
---@field old_line integer|nil
---@field pending boolean
---@field count integer|nil  number of comments in this thread (for label)
---@field expanded boolean|nil  thread is folded out (#360)
---@field replies { author: string|nil, body: string }[]|nil  when expanded

local BOX_MAX_WIDTH = 72
local BOX_MIN_WIDTH = 28
-- Left margin so the box floats slightly off the gutter rather than
-- hugging the sign/number column.
local BOX_INDENT = "  "

---@param s string
---@return integer
local function disp_width(s)
	local ok, w = pcall(vim.fn.strdisplaywidth, s)
	if ok and type(w) == "number" then
		return w
	end
	return #s
end

--- Word-wrap `text` (which may contain embedded newlines) to `width`
--- display columns, hard-splitting words longer than the width.
---@param text string
---@param width integer
---@return string[]
local function wrap_text(text, width)
	local out = {}
	for _, raw in ipairs(vim.split(text or "", "\n",
		{ plain = true, trimempty = false })) do
		if raw == "" then
			out[#out + 1] = ""
		else
			local line = ""
			for token in raw:gmatch("%S+") do
				local word = token
				while disp_width(word) > width do
					if line ~= "" then
						out[#out + 1] = line
						line = ""
					end
					out[#out + 1] = word:sub(1, width)
					word = word:sub(width + 1)
				end
				if line == "" then
					line = word
				elseif disp_width(line) + 1 + disp_width(word) <= width then
					line = line .. " " .. word
				else
					out[#out + 1] = line
					line = word
				end
			end
			out[#out + 1] = line
		end
	end
	if #out == 0 then
		out[1] = ""
	end
	return out
end

--- Split `text` at exactly `width` display columns without reflowing words, so
--- proposed code survives the box verbatim across continuation rows.
---@param text string
---@param width integer
---@return string[]
local function hard_wrap(text, width)
	assert(width > 0, "hard_wrap width must be positive")
	local out = {}
	local rest = text or ""
	repeat
		if disp_width(rest) <= width then
			out[#out + 1] = rest
			break
		end
		-- Byte-wise cut is safe enough here: over-wide rows only clip.
		out[#out + 1] = rest:sub(1, width)
		rest = rest:sub(width + 1)
	until rest == ""
	if #out == 0 then
		out[1] = ""
	end
	return out
end

---@class GitflowReviewBoxRow
---@field text string
---@field hl string

local SUGGESTION_GUTTER = "▏"

--- Rows for one comment body: prose word-wraps, suggestion blocks are marked
--- and hard-wrapped so the reviewer sees the proposed lines as code (#367).
---@param body string|nil
---@return GitflowReviewBoxRow[]
local function body_rows(body)
	local rows = {}
	for _, seg in ipairs(M.split_suggestions(body)) do
		if seg.kind == "suggestion" then
			rows[#rows + 1] = {
				text = SUGGESTION_GUTTER .. " suggested change",
				hl = "GitflowReviewAuthor",
			}
			for _, l in ipairs(seg.lines) do
				for _, part in ipairs(hard_wrap(l, BOX_MAX_WIDTH - 4)) do
					rows[#rows + 1] = {
						text = ("%s + %s"):format(SUGGESTION_GUTTER, part),
						hl = "GitflowAdded",
					}
				end
			end
		else
			local prose = table.concat(seg.lines, "\n")
			if vim.trim(prose) ~= "" then
				for _, l in ipairs(wrap_text(prose, BOX_MAX_WIDTH)) do
					rows[#rows + 1] = { text = l, hl = "GitflowReviewCommentBody" }
				end
			end
		end
	end
	if #rows == 0 then
		rows[1] = { text = "", hl = "GitflowReviewCommentBody" }
	end
	return rows
end

--- Title shown in the top border of a comment box.
---@param c GitflowReviewInlineComment
---@return string
local function box_header(c)
	local author = (c.author and c.author ~= "") and c.author or "unknown"
	local count = c.count or 1
	local header = ("%s · %s"):format(c.pending and "draft" or "thread", author)
	if M.has_suggestion(c.body) then
		header = header .. " · suggestion"
	end
	if count > 1 then
		header = header .. (" · %d repl%s"):format(
			count - 1, (count - 1) == 1 and "y" or "ies")
		-- Advertise the fold-out: the replies are invisible otherwise (#360).
		if not c.expanded then
			header = header .. " · <leader>t"
		end
	end
	local line_no = c.new_line or c.old_line
	if line_no then
		header = header .. (" · L%d"):format(line_no)
	end
	return header
end

--- Reply blocks for a folded-out thread (#360); empty when collapsed.
---@param c GitflowReviewInlineComment
---@return { author: string, rows: GitflowReviewBoxRow[] }[]
local function box_reply_blocks(c)
	local blocks = {}
	for _, r in ipairs(c.replies or {}) do
		local who = (r.author and r.author ~= "") and r.author or "unknown"
		blocks[#blocks + 1] = {
			author = ("@%s"):format(who),
			rows = body_rows(r.body),
		}
	end
	return blocks
end

--- Widest content row, clamped to the box's min/max, excluding the borders.
---@param header string
---@param rows GitflowReviewBoxRow[]
---@param replies { author: string, rows: GitflowReviewBoxRow[] }[]
---@return integer
local function box_inner_width(header, rows, replies)
	local inner = disp_width(header) + 2
	for _, row in ipairs(rows) do
		inner = math.max(inner, disp_width(row.text))
	end
	for _, reply in ipairs(replies) do
		inner = math.max(inner, disp_width(reply.author) + 2)
		for _, row in ipairs(reply.rows) do
			inner = math.max(inner, disp_width(row.text))
		end
	end
	return math.max(BOX_MIN_WIDTH, math.min(inner, BOX_MAX_WIDTH))
end

--- Build the virt_lines for a single comment, drawn as a rounded box:
---
---   ╭─ draft · you ─────────╮
---   │ the comment body      │
---   ╰───────────────────────╯
---
--- A folded-out thread appends each reply under its own author rule (#360).
---@param c GitflowReviewInlineComment
---@return table[]  list of virt_line chunk-lists
local function build_comment_box(c)
	local border_hl = c.pending
		and "GitflowReviewDraftBox" or "GitflowReviewCommentBox"
	local header = box_header(c)
	local rows = body_rows(c.body)
	local replies = box_reply_blocks(c)

	local inner = box_inner_width(header, rows, replies)
	local span = inner + 2 -- cells between the two corner glyphs

	local function pad(s)
		local gap = inner - disp_width(s)
		if gap > 0 then
			return s .. string.rep(" ", gap)
		end
		return s
	end

	local virt_lines = {}

	-- Top border with the header embedded in the dashes.
	local header_seg_w = 2 + disp_width(header) + 1 -- "─ " + header + " "
	local dashes = math.max(0, span - header_seg_w)
	virt_lines[#virt_lines + 1] = {
		{ BOX_INDENT, "GitflowReviewCommentBox" },
		{ "╭─ ", border_hl },
		{ header, "GitflowReviewAuthor" },
		{ " " .. string.rep("─", dashes) .. "╮", border_hl },
	}

	---@param body_rows_list GitflowReviewBoxRow[]
	local function push_body_rows(body_rows_list)
		for _, row in ipairs(body_rows_list) do
			virt_lines[#virt_lines + 1] = {
				{ BOX_INDENT, "GitflowReviewCommentBox" },
				{ "│ ", border_hl },
				{ pad(row.text), row.hl },
				{ " │", border_hl },
			}
		end
	end

	push_body_rows(rows)

	for _, reply in ipairs(replies) do
		local seg_w = 2 + disp_width(reply.author) + 1 -- "─ " + author + " "
		virt_lines[#virt_lines + 1] = {
			{ BOX_INDENT, "GitflowReviewCommentBox" },
			{ "├─ ", border_hl },
			{ reply.author, "GitflowReviewAuthor" },
			{ " " .. string.rep("─", math.max(0, span - seg_w)) .. "┤",
				border_hl },
		}
		push_body_rows(reply.rows)
	end

	-- Bottom border.
	virt_lines[#virt_lines + 1] = {
		{ BOX_INDENT, "GitflowReviewCommentBox" },
		{ "╰" .. string.rep("─", span) .. "╯", border_hl },
	}

	return virt_lines
end

--- Render a list of comment markers on the buffer.
---
--- show_body=true (default): each comment is drawn as a rounded note box
---   in virt_lines below its anchor line.
--- show_body=false: only a compact end-of-line marker is shown so the
---   line still advertises that a comment exists (collapsed view).
---@param bufnr integer
---@param comments GitflowReviewInlineComment[]
---@param opts table|nil  { show_body: boolean }
function M.apply_comments(bufnr, comments, opts)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.clear_comments(bufnr)
	local show_body = not (opts and opts.show_body == false)
	local total = buf_line_count(bufnr)

	for _, c in ipairs(comments or {}) do
		local anchor = c.new_line or c.old_line
		if anchor and anchor >= 1 and anchor <= total then
			local extmark = {}

			if show_body and c.body and c.body ~= "" then
				extmark.virt_lines = build_comment_box(c)
			else
				-- Collapsed: compact end-of-line badge only.  A proposed edit
				-- is named even here, so it is never mistaken for prose (#367).
				local marker
				if M.has_suggestion(c.body) then
					marker = c.pending and " ● draft suggestion "
						or " ● suggestion "
				else
					marker = c.pending and " ● draft " or " ● thread "
				end
				local marker_hl = c.pending
					and "GitflowReviewChangesRequested"
					or "GitflowReviewAuthor"
				local count = c.count or 1
				local count_label = count > 1
					and (" (%d)"):format(count) or ""
				local author_label = ""
				if c.author and c.author ~= "" then
					author_label = ("@%s"):format(c.author)
				end
				extmark.virt_text = {
					{ marker, marker_hl },
					{ author_label, "GitflowReviewAuthor" },
					{ count_label, "GitflowReviewComment" },
				}
				extmark.virt_text_pos = "eol"
			end

			pcall(
				vim.api.nvim_buf_set_extmark,
				bufnr, COMMENT_NS, anchor - 1, 0, extmark
			)
		end
	end
end

return M
