local M = {}

local SEPARATOR_CHAR = "\u{2500}" -- ─ box drawing horizontal
local DEFAULT_SEPARATOR_WIDTH = 50
local MIN_SEPARATOR_WIDTH = 24

---@param opts table|nil
---@return integer|nil
local function resolve_window_id(opts)
	local options = opts or {}
	local winid = options.winid
	if winid and vim.api.nvim_win_is_valid(winid) then
		return winid
	end

	local bufnr = options.bufnr
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		local buf_winid = vim.fn.bufwinid(bufnr)
		if buf_winid ~= -1 and vim.api.nvim_win_is_valid(buf_winid) then
			return buf_winid
		end
	end

	return nil
end

---@param opts table|nil
---@return boolean
local function should_render_inline_title(opts)
	local options = opts or {}
	if options.inline_title ~= nil then
		return options.inline_title == true
	end

	local winid = resolve_window_id(options)
	if not winid then
		return true
	end

	local config = vim.api.nvim_win_get_config(winid)
	local relative = type(config) == "table" and config.relative or ""
	return relative == ""
end

---Resolve content width for a panel buffer/window.
---@param opts table|nil  { winid?, bufnr?, fallback?, min_width? }
---@return integer
function M.content_width(opts)
	local options = opts or {}
	local fallback = tonumber(options.fallback) or DEFAULT_SEPARATOR_WIDTH
	local min_width = tonumber(options.min_width) or MIN_SEPARATOR_WIDTH
	local winid = resolve_window_id(options)
	if not winid then
		return fallback
	end

	local width = vim.api.nvim_win_get_width(winid)
	local ok, info = pcall(vim.fn.getwininfo, winid)
	if ok and type(info) == "table" and info[1] then
		local textoff = tonumber(info[1].textoff) or 0
		width = width - textoff
	end

	return math.max(min_width, math.floor(width))
end

---Build a separator line of the given width.
---@param width integer|table|nil  fill width or context opts (defaults to 50)
---@return string
function M.separator(width)
	local resolved = width
	if type(width) == "table" then
		resolved = M.content_width(width)
	end

	local sep_width = tonumber(resolved) or DEFAULT_SEPARATOR_WIDTH
	sep_width = math.max(1, math.floor(sep_width))
	return string.rep(SEPARATOR_CHAR, sep_width)
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
---@param opts table|nil  separator width context
---@return string header, string separator  two lines
function M.section(text, count, opts)
	local header
	if count then
		header = ("%s (%d)"):format(text, count)
	else
		header = text
	end
	return header, M.separator(opts)
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
		local key = pair.key or pair[1]
		local action = pair.action or pair[2]
		if key and action then
			parts[#parts + 1] = ("%s %s"):format(key, action)
		end
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

	-- Title bar: line 0 (when present)
	if #lines > 0 and not vim.startswith(lines[1], SEPARATOR_CHAR) then
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

---Build a standard panel header block: title + separator.
---@param title_text string
---@param opts table|nil  separator width context
---@return string[]
function M.panel_header(title_text, opts)
	local lines = {}
	if should_render_inline_title(opts) then
		lines[#lines + 1] = M.title(title_text)
	end
	lines[#lines + 1] = M.separator(opts)
	return lines
end

---Build a standard panel footer block with separator and optional metadata.
---@param current_branch string|nil
---@param key_hints string|nil  inline key hint text
---@param opts table|nil  separator width context
---@return string[]
function M.panel_footer(current_branch, key_hints, opts)
	local lines = {}
	if current_branch or key_hints then
		lines[#lines + 1] = M.separator(opts)
		if current_branch then
			lines[#lines + 1] = ("Current branch: %s"):format(current_branch)
		end
		if key_hints then
			lines[#lines + 1] = M.footer(key_hints)
		end
	end
	return lines
end

return M
