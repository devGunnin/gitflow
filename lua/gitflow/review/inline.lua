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

---@class GitflowReviewAnnotateResult
---@field added_lines integer[]  buffer lines (1-based) highlighted as added
---@field hunk_anchors integer[] buffer lines (1-based) that start each hunk

--- Apply diff annotations to a buffer that contains the real file.
---@param bufnr integer
---@param file_diff GitflowReviewFileDiff|nil
---@return GitflowReviewAnnotateResult
function M.apply_annotations(bufnr, file_diff)
	local result = { added_lines = {}, hunk_anchors = {} }
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return result
	end

	M.clear_annotations(bufnr)
	if not file_diff or not file_diff.hunks then
		return result
	end

	local total = buf_line_count(bufnr)

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
				virt_lines[#virt_lines + 1] = {
					{ "- " .. removed.text, "DiffDelete" },
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

---@class GitflowReviewInlineComment
---@field author string|nil
---@field body string
---@field new_line integer|nil
---@field old_line integer|nil
---@field pending boolean
---@field count integer|nil  number of comments in this thread (for label)

--- Render a list of comment markers on the buffer.
---
--- show_body=true (default): comment shown as virt_lines below the
---   anchor line.  The EOL marker is just a short label (kind + author +
---   count) so the body never appears twice.
--- show_body=false: only the EOL marker is shown (collapsed).
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
			local marker = c.pending and " [draft] " or " [thread] "
			local marker_hl = c.pending
				and "GitflowReviewChangesRequested"
				or "GitflowReviewAuthor"
			local count = c.count or 1
			local count_label = count > 1
				and (" (%d comments)"):format(count) or ""
			local author_label = ""
			if c.author and c.author ~= "" then
				author_label = ("@%s"):format(c.author)
			end

			local virt_text = {
				{ marker, marker_hl },
				{ author_label, "GitflowReviewAuthor" },
				{ count_label, "GitflowReviewComment" },
			}

			local extmark = {
				virt_text = virt_text,
				virt_text_pos = "eol",
			}

			if show_body and c.body and c.body ~= "" then
				local virt_lines = {}
				local body_lines = vim.split(c.body, "\n", {
					plain = true, trimempty = false,
				})
				for _, bl in ipairs(body_lines) do
					if #bl > 120 then
						bl = bl:sub(1, 117) .. "..."
					end
					virt_lines[#virt_lines + 1] = {
						{ "  " .. bl, "GitflowReviewComment" },
					}
				end
				extmark.virt_lines = virt_lines
			end

			pcall(
				vim.api.nvim_buf_set_extmark,
				bufnr, COMMENT_NS, anchor - 1, 0, extmark
			)
		end
	end
end

return M
