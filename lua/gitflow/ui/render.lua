local M = {}

-- ── design tokens ──────────────────────────────────────────────────────
-- One spacing scale and one glyph set for every gitflow surface. Panels and
-- components indent and punctuate with these, never with ad-hoc literals, so
-- the whole plugin reads as one visual language.

---Indent steps. Chrome hugs the frame, content sits in the gutter, anything
---subordinate to a content row is indented one more step.
M.spacing = {
	edge = " ",      -- rules, section headers, hint bars
	gutter = "  ",   -- content rows: summaries, metadata, state lines
	indent = "    ", -- nested under a content row: detail, grouped hints
}

---Shared glyphs. Kept plain-unicode (not Nerd Font) so they render everywhere;
---Nerd Font glyphs and their ASCII fallbacks live in `gitflow.icons`.
M.glyphs = {
	rule = "\u{2500}",     -- ─  panel and section rule
	bullet = "\u{b7}",     -- ·  inline separator between hint entries
	arrow = "\u{2192}",    -- →  "from → to"
	ellipsis = "\u{2026}", -- …  truncation marker
}

---Separator between entries on a single line (hint bars, summary chips).
M.separators = {
	hint = "   ",                             -- between key-hint entries
	field = "    ",                           -- between fields on a summary bar
	inline = " " .. M.glyphs.bullet .. " ",   -- between inline metadata values
}

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

---Read the user's fixed rule width from config, if they set a positive one.
---0 means "adaptive" (the config validator's own wording) and is not fixed.
---@return integer|nil
local function configured_width()
	local ok, cfg = pcall(require, "gitflow.config")
	if not ok or not cfg or not cfg.current or not cfg.current.ui then
		return nil
	end
	local cw = tonumber(cfg.current.ui.separator_width)
	if cw and cw >= 1 then
		return math.floor(cw)
	end
	return nil
end

---Resolve the static fallback width.
---Priority: opts.fallback → config ui.separator_width → vim.o.columns → 50.
---@param explicit_fallback number|nil  caller-provided fallback
---@return integer
local function resolve_fallback(explicit_fallback)
	if explicit_fallback then
		return math.floor(explicit_fallback)
	end
	local fixed = configured_width()
	if fixed then
		return fixed
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

---Whether a panel should draw its title inside the buffer. Floats already show
---the title in their frame chrome, so only splits need an inline one.
---@param opts table|nil  { winid?, bufnr? }
---@return boolean
function M.wants_inline_title(opts)
	return not M.is_floating(opts)
end

---Resolve content width for a panel buffer/window. A positive
---`ui.separator_width` is a fixed width -- honored even with a window present,
---since "fixed" (the option's own doc) would otherwise only ever apply when
---there is no window to measure -- but never wider than the window itself.
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
	width = math.floor(width)

	local fixed = configured_width()
	if fixed then
		return math.max(min_width, math.min(fixed, width))
	end

	return math.max(min_width, width)
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
	return string.rep(M.glyphs.rule, sep_width)
end

---@param line string|nil
---@return boolean
function M.is_separator(line)
	return type(line) == "string" and vim.startswith(line, M.glyphs.rule)
end

-- ── Declarative line + span builder ────────────────────────────────────
-- Build buffer content as a sequence of lines, each composed of styled
-- "chunks" ({ text, highlight_group }).  Highlights are recorded as byte
-- spans and applied to a namespace as extmarks.  This is the only rendering
-- primitive: every panel builds a builder and calls B:flush().

---@class GitflowRenderBuilder
---@field lines string[]
---@field spans table<integer, table[]>  line_no(1-based) -> { {col_start, col_end, hl}, ... }

-- Snapshot of what render() last wrote to a (buffer, namespace) pair, so an
-- unchanged re-render can leave both the lines and the extmarks alone. Keyed
-- by bufnr; dropped when the buffer dies, so a recycled bufnr never inherits
-- a dead buffer's snapshot.
local snapshots = {}
local snapshot_augroup =
	vim.api.nvim_create_augroup("GitflowRenderSnapshots", { clear = true })

---@param bufnr integer
---@return table  ns -> { lines = string[], spans = table }
local function snapshots_for(bufnr)
	local per_buffer = snapshots[bufnr]
	if per_buffer then
		return per_buffer
	end
	per_buffer = {}
	snapshots[bufnr] = per_buffer
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = snapshot_augroup,
		buffer = bufnr,
		callback = function()
			snapshots[bufnr] = nil
		end,
	})
	return per_buffer
end

local EMPTY_SPANS = {}

---@param a table[]|nil
---@param b table[]|nil
---@return boolean
local function spans_equal(a, b)
	a = a or EMPTY_SPANS
	b = b or EMPTY_SPANS
	if #a ~= #b then
		return false
	end
	for index = 1, #a do
		local left, right = a[index], b[index]
		if left[1] ~= right[1] or left[2] ~= right[2] or left[3] ~= right[3] then
			return false
		end
	end
	return true
end

---Apply one recorded span as an extmark.
---@param bufnr integer
---@param ns integer
---@param line_no integer  1-based
---@param text string  the line's text (bounds a col_end of -1)
---@param span table  { col_start, col_end, hl_group }
local function set_span(bufnr, ns, line_no, text, span)
	local col_end = span[2]
	if col_end == nil or col_end < 0 then
		col_end = #text
	end
	-- pcall guards only the async-close race (bufnr deleted since the caller's
	-- validity check) -- bad hl_group/col never error here (verified), so nothing real is hidden.
	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_no - 1, span[1], {
		end_row = line_no - 1,
		end_col = col_end,
		hl_group = span[3],
		strict = false,
	})
end

---Create a new line builder.
---@return GitflowRenderBuilder
function M.builder()
	local B = { lines = {}, spans = {}, flushed = false }

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

	---Render into a buffer, touching only what changed since the last render.
	---Lines are diffed against the previous render (one nvim_buf_set_lines over
	---the changed range, none at all when nothing moved) and highlight spans are
	---re-applied only on lines whose text or spans differ. This is what keeps a
	---refresh from flickering and from resetting the cursor.
	---
	---Contracts the caller owns: `buffer_target` and `bufnr` must name the
	---same buffer, `ns` must belong to this builder alone (the snapshot assumes
	---nothing else clears or writes that namespace), and the builder itself is
	---single-use — mutating it after this call corrupts the stored snapshot.
	---@param buffer_target string|integer  buffer name or bufnr for ui.buffer.update
	---@param bufnr integer  resolved bufnr to apply highlights on
	---@param ns integer  highlight namespace
	function B:render(buffer_target, bufnr, ns)
		if self.flushed then
			error("builder is single-use: already flushed")
		end
		self.flushed = true
		local buffer = require("gitflow.ui.buffer")
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			buffer.update(buffer_target, self.lines)
			return
		end

		-- No snapshot means nothing is known about what is on screen (first
		-- render into this buffer), so repaint every span rather than assume.
		local per_buffer = snapshots_for(bufnr)
		local previous = per_buffer[ns]
		local full_repaint = previous == nil

		local prefix, suffix, old_count = buffer.set_lines_diffed(bufnr, self.lines, ns)

		-- Middle (rewritten text): nvim_buf_set_lines dropped its extmarks.
		local middle_from, middle_to = prefix + 1, #self.lines - suffix
		if middle_to >= middle_from then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, middle_from - 1, middle_to)
			for line_no = middle_from, middle_to do
				for _, span in ipairs(self.spans[line_no] or EMPTY_SPANS) do
					set_span(bufnr, ns, line_no, self.lines[line_no], span)
				end
			end
		end

		-- Unchanged text above and below: their extmarks are still in place and
		-- shifted with the edit, so repaint only where the spans themselves moved.
		local old_spans = previous and previous.spans or nil
		local function repaint_if_spans_changed(line_no, old_line_no)
			local want = self.spans[line_no]
			if not full_repaint and spans_equal(want, old_spans[old_line_no]) then
				return
			end
			vim.api.nvim_buf_clear_namespace(bufnr, ns, line_no - 1, line_no)
			for _, span in ipairs(want or EMPTY_SPANS) do
				set_span(bufnr, ns, line_no, self.lines[line_no], span)
			end
		end

		for line_no = 1, prefix do
			repaint_if_spans_changed(line_no, line_no)
		end
		for offset = 0, suffix - 1 do
			repaint_if_spans_changed(#self.lines - offset, old_count - offset)
		end

		-- Builders are single-use, discarded right after flush -- aliasing
		-- self.spans instead of deep-copying it is safe and skips the cost.
		per_buffer[ns] = { spans = self.spans }
	end

	---Render this builder into a panel buffer. The single flush path: panels
	---never call ui.buffer.update and apply highlights by hand.
	---@param buffer_target string|integer  buffer name or bufnr for ui.buffer.update
	---@param bufnr integer  resolved bufnr to apply highlights on
	---@param ns integer  highlight namespace
	function B:flush(buffer_target, bufnr, ns)
		self:render(buffer_target, bufnr, ns)
	end

	---Apply recorded highlight spans to a buffer namespace, replacing whatever
	---the namespace held. For surfaces that write their own lines (the pickers,
	---which keep a live prompt line) and so cannot use render().
	---@param bufnr integer
	---@param ns integer
	function B:apply(bufnr, ns)
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		for line_no, list in pairs(self.spans) do
			for _, span in ipairs(list) do
				set_span(bufnr, ns, line_no, self.lines[line_no] or "", span)
			end
		end
	end

	return B
end

---Apply a single highlight span to a buffer namespace as an extmark.
---The replacement for nvim_buf_add_highlight, deprecated in Neovim 0.11.
---@param bufnr integer
---@param ns integer
---@param group string
---@param line integer  0-based row
---@param col_start integer  0-based byte col
---@param col_end integer  0-based byte col, or -1 for end of line
function M.highlight(bufnr, ns, group, line, col_start, col_end)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local resolved_end = col_end
	if resolved_end == nil or resolved_end < 0 then
		local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
		resolved_end = text and #text or 0
	end
	-- Same guard as set_span: only the post-check async-close race can error here.
	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, col_start, {
		end_row = line,
		end_col = resolved_end,
		hl_group = group,
		strict = false,
	})
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
		return M.glyphs.ellipsis
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
	return out .. M.glyphs.ellipsis
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
	local sep = options.sep or M.separators.hint
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
