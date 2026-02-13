local icons = require("gitflow.icons")

local M = {}

local SEPARATOR_CHAR = "\u{2500}" -- ─ box drawing horizontal

---Build a separator line of the given width.
---@param width integer|nil  fill width (defaults to 50)
---@return string
function M.separator(width)
	return string.rep(SEPARATOR_CHAR, width or 50)
end

---Format a title bar line with optional icon.
---@param text string
---@return string
function M.title(text)
	return text
end

---Format a section header with count and separator.
---@param text string  section name
---@param count integer|nil  optional item count
---@return string header, string separator  two lines
function M.section(text, count)
	local header
	if count then
		header = ("%s (%d)"):format(text, count)
	else
		header = text
	end
	return header, M.separator()
end

---Format an empty-state placeholder.
---@param text string|nil  placeholder text (defaults to "(none)")
---@return string
function M.empty(text)
	return ("  %s"):format(text or "(none)")
end

---Format a content entry with indentation.
---@param text string
---@return string
function M.entry(text)
	return ("  %s"):format(text)
end

---Format key hints for a footer line (inline or float footer).
---@param hints string  raw key hint text, e.g. "q close  r refresh"
---@return string
function M.footer(hints)
	return hints
end

---Format key hints as structured pairs for display.
---Each pair is "key=action" separated by double space.
---@param pairs table[]  list of {key, action} pairs
---@return string
function M.format_key_hints(pairs)
	local parts = {}
	for _, pair in ipairs(pairs) do
		parts[#parts + 1] = ("%s %s"):format(pair[1], pair[2])
	end
	return table.concat(parts, "  ")
end

---Apply standard panel highlights to a buffer after rendering.
---Applies GitflowTitle to line 0, scans for section headers, separators,
---and footer metadata lines.
---@param bufnr integer
---@param ns integer  highlight namespace
---@param lines string[]
---@param opts table|nil  { footer_line = integer|nil, entry_highlights = table|nil }
function M.apply_panel_highlights(bufnr, ns, lines, opts)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local options = opts or {}

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	-- Title bar: line 0
	if #lines > 0 then
		vim.api.nvim_buf_add_highlight(bufnr, ns, "GitflowTitle", 0, 0, -1)
	end

	-- Scan for separator lines and section headers
	local sep_pattern = "^" .. SEPARATOR_CHAR
	for line_no, line in ipairs(lines) do
		local idx = line_no - 1
		if line:find(sep_pattern) then
			vim.api.nvim_buf_add_highlight(bufnr, ns, "GitflowSeparator", idx, 0, -1)
		end
	end

	-- Footer line
	if options.footer_line then
		vim.api.nvim_buf_add_highlight(
			bufnr, ns, "GitflowFooter", options.footer_line - 1, 0, -1
		)
	end

	-- Entry-level highlights (panel-specific)
	if options.entry_highlights then
		for line_no, group in pairs(options.entry_highlights) do
			vim.api.nvim_buf_add_highlight(bufnr, ns, group, line_no - 1, 0, -1)
		end
	end
end

---Build a standard panel header block: title + blank line.
---@param title_text string
---@return string[]
function M.panel_header(title_text)
	return {
		M.title(title_text),
		"",
	}
end

---Build a standard panel footer block: blank line + branch info + key hints.
---@param current_branch string|nil
---@param key_hints string|nil  inline key hint text
---@return string[]
function M.panel_footer(current_branch, key_hints)
	local lines = {}
	if current_branch then
		lines[#lines + 1] = ""
		lines[#lines + 1] = ("Current branch: %s"):format(current_branch)
	end
	if key_hints then
		lines[#lines + 1] = ""
		lines[#lines + 1] = M.footer(key_hints)
	end
	return lines
end

return M
