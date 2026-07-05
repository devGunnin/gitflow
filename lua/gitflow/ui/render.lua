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
	if options.include_title ~= nil then
		return options.include_title == true
	end

	local winid = resolve_window_id(options)
	if not winid then
		return true
	end

	local ok, config = pcall(vim.api.nvim_win_get_config, winid)
	if not ok or type(config) ~= "table" then
		return true
	end

	return config.relative == nil or config.relative == ""
end

---Resolve the static fallback width.
---Priority: opts.fallback → config ui.separator_width → vim.o.columns → 50.
---@param explicit_fallback number|nil  caller-provided fallback
---@return integer
local function resolve_fallback(explicit_fallback)
	if explicit_fallback then
		return math.floor(explicit_fallback)
	end
	local ok, cfg = pcall(require, "gitflow.config")
	if ok and cfg and cfg.current and cfg.current.ui then
		local cw = tonumber(cfg.current.ui.separator_width)
		if cw and cw >= 1 then
			return math.floor(cw)
		end
	end
	local columns = vim.o.columns
	if columns and columns > 0 then
		return columns
	end
	return DEFAULT_SEPARATOR_WIDTH
end

---Whether the panel is rendered in a floating window (vs an inline split).
---Floats carry their key hints in the window footer chrome, so panels show an
---in-buffer hint bar only when this returns false.
---@param opts table|nil  { winid?, bufnr? }
---@return boolean
function M.is_floating(opts)
	local winid = resolve_window_id(opts)
	if not winid then
		return false
	end
	local ok, config = pcall(vim.api.nvim_win_get_config, winid)
	if not ok or type(config) ~= "table" then
		return false
	end
	return config.relative ~= nil and config.relative ~= ""
end

---Resolve content width for a panel buffer/window.
---@param opts table|nil  { winid?, bufnr?, fallback?, min_width? }
---@return integer
function M.content_width(opts)
	local options = opts or {}
	local min_width = tonumber(options.min_width) or MIN_SEPARATOR_WIDTH
	local winid = resolve_window_id(options)
	if not winid then
		return math.max(min_width, resolve_fallback(tonumber(options.fallback)))
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
---@param width integer|table|nil  fill width or context opts (defaults adaptive)
---@return string
function M.separator(width)
	local resolved = width
	if type(width) == "table" then
		resolved = M.content_width(width)
	end

	local sep_width = tonumber(resolved) or resolve_fallback(nil)
	sep_width = math.max(1, math.floor(sep_width))
	return string.rep(SEPARATOR_CHAR, sep_width)
end

---@param line string|nil
---@return boolean
function M.is_separator(line)
	return type(line) == "string" and vim.startswith(line, SEPARATOR_CHAR)
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
---Applies GitflowTitle to line 0 only when the first line is an inline
---header title, then scans separators and footer metadata lines.
---@param bufnr integer
---@param ns integer  highlight namespace
---@param lines string[]
---@param opts table|nil  { footer_line = integer|nil, entry_highlights = table|nil }
function M.apply_panel_highlights(bufnr, ns, lines, opts)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local options = opts or {}
	local has_inline_title = options.has_inline_title
	if has_inline_title == nil then
		has_inline_title = #lines > 0 and not M.is_separator(lines[1])
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	-- Title bar: line 0
	if has_inline_title then
		vim.api.nvim_buf_add_highlight(bufnr, ns, "GitflowTitle", 0, 0, -1)
	end

	-- Scan for separator lines and section headers
	for line_no, line in ipairs(lines) do
		local idx = line_no - 1
		if M.is_separator(line) then
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

---Build a standard panel header block.
---Split layout: title + separator.
---Float layout: separator only (frame title already provides chrome).
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

-- ── Declarative line + span builder ────────────────────────────────────
-- Build buffer content as a sequence of lines, each composed of styled
-- "chunks" ({ text, highlight_group }).  Highlights are recorded as byte
-- spans and applied to a namespace in one pass.  This is the shared
-- rendering primitive behind the issue/PR panels and the pickers.

---@class GitflowRenderBuilder
---@field lines string[]
---@field spans table<integer, table[]>  line_no(1-based) -> { {col_start, col_end, hl}, ... }

---Create a new line builder.
---@return GitflowRenderBuilder
function M.builder()
	local B = { lines = {}, spans = {} }

	---Append a line built from chunks.
	---@param chunks table[]  each item is a string or { text, hl } / { [1]=text, [2]=hl }
	---@return integer line_no
	function B:push(chunks)
		local text, spans, col = "", {}, 0
		for _, ch in ipairs(chunks or {}) do
			local t, hl
			if type(ch) == "table" then
				t = tostring(ch[1] ~= nil and ch[1] or (ch.text or ""))
				hl = ch[2] or ch.hl
			else
				t = tostring(ch)
			end
			if hl and t ~= "" then
				spans[#spans + 1] = { col, col + #t, hl }
			end
			text = text .. t
			col = col + #t
		end
		self.lines[#self.lines + 1] = text
		self.spans[#self.lines] = spans
		return #self.lines
	end

	---Append a raw line, optionally highlighting the whole line.
	---@param line string|nil
	---@param hl string|nil
	---@return integer line_no
	function B:raw(line, hl)
		self.lines[#self.lines + 1] = line or ""
		if hl then
			self.spans[#self.lines] = { { 0, -1, hl } }
		end
		return #self.lines
	end

	---Append a blank line.
	---@return integer line_no
	function B:blank()
		return self:raw("")
	end

	---Add an extra highlight span to an existing line.
	---@param line_no integer  1-based
	---@param col_start integer  0-based byte col
	---@param col_end integer  0-based byte col, or -1 for end of line
	---@param group string
	function B:hl(line_no, col_start, col_end, group)
		local list = self.spans[line_no] or {}
		list[#list + 1] = { col_start, col_end, group }
		self.spans[line_no] = list
	end

	---@return integer  number of lines so far
	function B:count()
		return #self.lines
	end

	---Flush lines into a buffer (via ui.buffer.update) and apply highlights.
	---@param buffer_target string|integer  buffer name or bufnr for ui.buffer.update
	---@param bufnr integer  resolved bufnr to apply highlights on
	---@param ns integer  highlight namespace
	function B:flush(buffer_target, bufnr, ns)
		require("gitflow.ui.buffer").update(buffer_target, self.lines)
		self:apply(bufnr, ns)
	end

	---Apply recorded highlight spans to a buffer namespace.
	---@param bufnr integer
	---@param ns integer
	function B:apply(bufnr, ns)
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		for line_no, list in pairs(self.spans) do
			for _, span in ipairs(list) do
				pcall(
					vim.api.nvim_buf_add_highlight,
					bufnr, ns, span[3], line_no - 1, span[1], span[2]
				)
			end
		end
	end

	return B
end

---Format an ISO-8601 UTC timestamp as a short relative time ("3 days ago").
---@param iso string|nil
---@return string  empty string when the timestamp can't be parsed
function M.relative_time(iso)
	if type(iso) ~= "string" or iso == "" then
		return ""
	end
	local y, mo, d, h, mi, s = iso:match(
		"(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
	)
	if not y then
		return ""
	end
	local t = os.time({
		year = tonumber(y), month = tonumber(mo), day = tonumber(d),
		hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
	})
	if not t then
		return ""
	end
	-- os.time interprets the table as local time; correct to treat input as UTC.
	local utc_offset = os.difftime(os.time(os.date("*t")), os.time(os.date("!*t")))
	t = t + utc_offset
	local diff = os.time() - t
	if diff < 0 then
		diff = 0
	end
	local minute, hour, day = 60, 3600, 86400
	if diff < minute then
		return "just now"
	elseif diff < hour then
		return ("%dm ago"):format(math.floor(diff / minute))
	elseif diff < day then
		return ("%dh ago"):format(math.floor(diff / hour))
	elseif diff < day * 7 then
		return ("%dd ago"):format(math.floor(diff / day))
	elseif diff < day * 30 then
		return ("%dw ago"):format(math.floor(diff / (day * 7)))
	elseif diff < day * 365 then
		return ("%dmo ago"):format(math.floor(diff / (day * 30)))
	end
	return ("%dy ago"):format(math.floor(diff / (day * 365)))
end

---Truncate a string to a maximum display width, adding an ellipsis.
---@param str string|nil
---@param max integer
---@return string
function M.truncate(str, max)
	str = tostring(str or "")
	if max <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(str) <= max then
		return str
	end
	if max == 1 then
		return "\u{2026}"
	end
	-- Walk characters until we'd exceed (max - 1) display cells, leaving room
	-- for the ellipsis.
	local out, width = "", 0
	local chars = vim.fn.split(str, "\\zs")
	for _, ch in ipairs(chars) do
		local cw = vim.fn.strdisplaywidth(ch)
		if width + cw > max - 1 then
			break
		end
		out = out .. ch
		width = width + cw
	end
	return out .. "\u{2026}"
end

---Pad a string on the right to a display width (truncating if needed).
---@param str string|nil
---@param width integer
---@return string
function M.pad_right(str, width)
	str = M.truncate(str, width)
	local pad = width - vim.fn.strdisplaywidth(str)
	if pad > 0 then
		str = str .. string.rep(" ", pad)
	end
	return str
end

---Build the chunks for a footer / hint bar from { key, label } pairs.
---Returns a chunk list suitable for builder:push, styling keys and labels
---distinctly with a dim separator between entries.
---@param pairs table[]  list of { key, label } (or { [1]=key, [2]=label })
---@param opts table|nil  { leading=string, sep=string }
---@return table[]  chunk list
function M.hint_chunks(pairs, opts)
	local options = opts or {}
	local sep = options.sep or "   "
	local chunks = {}
	if options.leading then
		chunks[#chunks + 1] = { options.leading, "GitflowHintSep" }
	end
	for index, pair in ipairs(pairs) do
		local key = pair.key or pair[1]
		local label = pair.label or pair[2]
		if index > 1 then
			chunks[#chunks + 1] = { sep, "GitflowHintSep" }
		end
		if key then
			chunks[#chunks + 1] = { key, "GitflowHintKey" }
		end
		if label then
			chunks[#chunks + 1] = { " " .. label, "GitflowHintText" }
		end
	end
	return chunks
end

return M
