--- Panel base: one open/close/refresh lifecycle for every gitflow panel.
---
--- A panel declares what it is (name, title, filetype) and which keys it
--- binds; the base owns everything that used to be copy-pasted into each
--- `ensure_window`: buffer creation, float-or-split placement, the `open_float`
--- nil check, keymap binding, the stale-request generation guard, and the
--- loading / empty / error states. Hint chrome is generated from the same
--- keymap registry for both layouts, so a split bar and a float footer can no
--- longer disagree with each other or with the keys the panel actually bound.

local buffer = require("gitflow.ui.buffer")
local window = require("gitflow.ui.window")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")

---@class GitflowPanelKeymap
---@field key string  the key sequence, also the hint's key label
---@field keys string[]|nil  keys to bind when `key` is a range label ("1-9")
---@field desc string  hint text; entries without one are bound but not hinted
---@field run fun(key: string)  the action; receives the key that fired it
---@field mode string|string[]|nil  default "n"
---@field views string[]|nil  views this key belongs to (nil = every view)
---@field nowait boolean|nil  default true
---@field hint boolean|nil  false to bind without advertising
---@field bind boolean|nil  false to advertise a key another entry already binds
---@field essential boolean|nil  never dropped when the float footer overflows

---@class GitflowPanelSpec
---@field name string  buffer/window registry name
---@field title string  panel title (float chrome and inline split title)
---@field filetype string|nil
---@field loading string|nil  first-paint placeholder label
---@field state table|nil  the panel's own state table to adopt
---@field keymaps GitflowPanelKeymap[]|nil
---@field on_close fun()|nil  extra teardown when the window closes

local M = {}

---@class GitflowPanel
---@field name string
---@field title string
---@field ns integer
---@field state table
local Panel = {}
Panel.__index = Panel

---@param spec GitflowPanelSpec
---@return GitflowPanel
function M.new(spec)
	assert(type(spec.name) == "string" and spec.name ~= "", "panel needs a name")
	assert(type(spec.title) == "string" and spec.title ~= "", "panel needs a title")

	local state = spec.state or {}
	state.bufnr = nil
	state.winid = nil
	state.request_id = 0

	return setmetatable({
		name = spec.name,
		title = spec.title,
		filetype = spec.filetype,
		loading = spec.loading,
		keymaps = spec.keymaps or {},
		on_close = spec.on_close,
		ns = vim.api.nvim_create_namespace("gitflow_" .. spec.name .. "_hl"),
		state = state,
	}, Panel)
end

-- ── request generation ─────────────────────────────────────────────────
-- Every async chain a panel starts captures the id current at its start and
-- drops its result if a newer one has begun. Bumping on open, refresh and on
-- either way a panel closes -- M.close() or the window going away under `:q`
-- -- is what stops a slow response from repainting a superseded view,
-- painting into an invisible buffer, or resurrecting a closed panel.

---Start a new request generation and return its id.
---@return integer
function Panel:next_request()
	self.state.request_id = (self.state.request_id or 0) + 1
	return self.state.request_id
end

---Whether `request_id` is still the live generation and the panel can be
---painted (buffer alive). False means the caller's result is stale — drop it.
---@param request_id integer
---@return boolean
function Panel:is_active(request_id)
	if self.state.request_id ~= request_id then
		return false
	end
	return self:is_open()
end

---@return boolean
function Panel:is_open()
	local bufnr = self.state.bufnr
	return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---Whether the panel currently has a live window. Distinct from `is_open`:
---a `:q` leaves the buffer (and its state) alive with no window.
---@return boolean
function Panel:has_window()
	local winid = self.state.winid
	return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

---@return integer|nil
function Panel:bufnr()
	if self:is_open() then
		return self.state.bufnr
	end
	return nil
end

---Context for the width/layout-aware render helpers.
---@return table  { bufnr, winid }
function Panel:render_opts()
	return { bufnr = self.state.bufnr, winid = self.state.winid }
end

-- ── keymap registry → hints ────────────────────────────────────────────

---@param entry GitflowPanelKeymap
---@param view string|nil
---@return boolean
local function shows_in_view(entry, view)
	if not entry.views then
		return true
	end
	for _, candidate in ipairs(entry.views) do
		if candidate == view then
			return true
		end
	end
	return false
end

---The advertised keys for a view, as `{ key, label }` pairs. The single
---source both hint surfaces (and a future `?` overlay) read.
---@param view string|nil
---@return table[]
function Panel:hints(view)
	local pairs_out = {}
	for _, entry in ipairs(self.keymaps) do
		if entry.hint ~= false and entry.desc and shows_in_view(entry, view) then
			pairs_out[#pairs_out + 1] = {
				entry.key, entry.desc, essential = entry.essential,
			}
		end
	end
	return pairs_out
end

---The whole registry for a view, keys included — what a `?` overlay renders.
---@param view string|nil
---@return GitflowPanelKeymap[]
function Panel:keymap_entries(view)
	local entries = {}
	for _, entry in ipairs(self.keymaps) do
		if entry.desc and shows_in_view(entry, view) then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

---Reduce `hints` to what fits `width`, dropping conveniences from the end.
---Never drops an `essential` -- a destructive verb or the way out stays
---advertised -- and never drops below one entry, so a surface too narrow for
---the essentials alone overflows rather than hiding one of them.
---@param hints table[]
---@param width integer|nil  nil for unlimited
---@param width_of fun(shown: table[], truncated: boolean): integer
---@return table[] shown, boolean truncated
local function fit_hints(hints, width, width_of)
	if not width or width_of(hints, false) <= width then
		return hints, false
	end

	local keep = {}
	for index = 1, #hints do
		keep[index] = true
	end
	local function shown()
		local out = {}
		for index, hint in ipairs(hints) do
			if keep[index] then
				out[#out + 1] = hint
			end
		end
		return out
	end

	local count = #hints
	for index = #hints, 1, -1 do
		if count <= 1 then
			break
		end
		if not hints[index].essential then
			keep[index] = false
			count = count - 1
			local candidate = shown()
			if width_of(candidate, true) <= width then
				return candidate, true
			end
		end
	end
	return shown(), true
end

---The float footer's text for a hint list.
---@param shown table[]
---@param truncated boolean
---@return string
local function footer_text(shown, truncated)
	local sep = " " .. ui_render.glyphs.bullet .. " "
	local parts = {}
	for _, hint in ipairs(shown) do
		parts[#parts + 1] = hint[1] .. " " .. hint[2]
	end
	local text = " " .. table.concat(parts, sep)
	if truncated then
		text = text .. sep .. ui_render.glyphs.ellipsis
	end
	return text .. " "
end

---The split hint bar's `{ key, label }` pairs, ellipsis included. Mirrors
---what `render.hint_chunks` lays out, so measuring the two agrees.
---@param shown table[]
---@param truncated boolean
---@return table[]
local function hint_bar_pairs(shown, truncated)
	local out = {}
	for _, hint in ipairs(shown) do
		out[#out + 1] = hint
	end
	if truncated then
		out[#out + 1] = { ui_render.glyphs.ellipsis }
	end
	return out
end

---@param shown table[]
---@param truncated boolean
---@return integer
local function hint_bar_width(shown, truncated)
	local parts = {}
	for _, pair in ipairs(hint_bar_pairs(shown, truncated)) do
		parts[#parts + 1] = pair[2] and (pair[1] .. " " .. pair[2]) or pair[1]
	end
	return vim.fn.strdisplaywidth(
		ui_render.spacing.edge .. table.concat(parts, ui_render.separators.hint)
	)
end

---Build the float footer for a view. Entries that would overflow `width` are
---dropped and marked with an ellipsis rather than silently clipped by the
---window frame.
---@param view string|nil
---@param width integer|nil  usable footer width, nil for unlimited
---@return string
function Panel:footer(view, width)
	local hints = self:hints(view)
	if #hints == 0 then
		return ""
	end
	local shown, truncated = fit_hints(hints, width, function(candidate, cut)
		return vim.fn.strdisplaywidth(footer_text(candidate, cut))
	end)
	return footer_text(shown, truncated)
end

---Whether the panel's window is a float. Nil when it has no live window.
---@return boolean|nil
function Panel:window_is_float()
	local winid = self.state.winid
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return nil
	end
	local ok, win_cfg = pcall(vim.api.nvim_win_get_config, winid)
	if not ok or type(win_cfg) ~= "table" then
		return nil
	end
	return win_cfg.relative ~= nil and win_cfg.relative ~= ""
end

---Usable footer width for the panel's float, or nil when it isn't one.
---@return integer|nil
function Panel:footer_width()
	if self:window_is_float() ~= true then
		return nil
	end
	return math.max(1, vim.api.nvim_win_get_width(self.state.winid) - 2)
end

---Usable width of the panel's split, or nil when it isn't one.
---@return integer|nil
function Panel:split_width()
	if self:window_is_float() ~= false then
		return nil
	end
	return math.max(1, vim.api.nvim_win_get_width(self.state.winid))
end

---Re-render the float footer after a view switch. No-op for splits (their
---hint bar is redrawn with the buffer) and for Neovim without footer support.
---@param view string|nil
function Panel:refresh_footer(view)
	local width = self:footer_width()
	if not width or not self.footer_enabled or vim.fn.has("nvim-0.10") ~= 1 then
		return
	end
	pcall(vim.api.nvim_win_set_config, self.state.winid, {
		footer = self:footer(view, width),
	})
end

-- ── lifecycle ──────────────────────────────────────────────────────────

---Every key an entry binds. `key` doubles as the hint label, so an entry
---covering a range ("1-9") lists the real keys in `keys`.
---@param entry GitflowPanelKeymap
---@return string[]
function M.bound_keys(entry)
	return entry.keys or { entry.key }
end

---@param bufnr integer
function Panel:bind_keymaps(bufnr)
	for _, entry in ipairs(self.keymaps) do
		for _, key in ipairs(entry.bind == false and {} or M.bound_keys(entry)) do
			vim.keymap.set(entry.mode or "n", key, function()
				entry.run(key)
			end, {
				buffer = bufnr,
				silent = true,
				nowait = entry.nowait ~= false,
			})
		end
	end
end

---Open (or reuse) the panel's buffer and window and bind its keys.
---
---Returns false when the panel could not be placed — today only a terminal
---too small for a usable float, which `open_float` already reported. Nothing
---half-open is left behind; callers must not refresh after a false.
---@param cfg GitflowConfig
---@param opts { view?: string }|nil
---@return boolean opened
function Panel:ensure_window(cfg, opts)
	local view = opts and opts.view or nil

	local bufnr = self:bufnr()
	if not bufnr then
		bufnr = buffer.create(self.name, {
			filetype = self.filetype,
			lines = components.loading_lines(self.loading),
		})
		self.state.bufnr = bufnr
		-- Bind with the buffer, not with the window: a buffer handed back
		-- through the reuse path below would otherwise carry no keymaps.
		self:bind_keymaps(bufnr)
	end
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if self.state.winid and vim.api.nvim_win_is_valid(self.state.winid) then
		vim.api.nvim_win_set_buf(self.state.winid, bufnr)
		return true
	end

	local function on_close()
		self.state.winid = nil
		-- `:q` leaves the buffer alive (bufhidden=hide), so nothing else
		-- invalidates the refresh chain: without this a closed panel keeps
		-- running git and painting into a window nobody can see.
		self:next_request()
		if self.on_close then
			self.on_close()
		end
	end

	if cfg.ui.default_layout == "float" then
		local float_opts = {
			name = self.name,
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = ("  %s  "):format(self.title),
			title_pos = cfg.ui.float.title_pos,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = on_close,
		}
		self.footer_enabled = cfg.ui.float.footer and true or false
		if self.footer_enabled then
			-- Size the footer to the float it is about to go into, so a long
			-- key list elides visibly instead of being cut by the frame.
			local geometry = window.float_geometry(float_opts, window.float_area())
			float_opts.footer = self:footer(view, geometry and geometry.width - 2 or nil)
		end
		self.state.winid = window.open_float(float_opts)
		if not self.state.winid then
			-- open_float said why; leave no orphaned buffer behind.
			self:close()
			return false
		end
	else
		self.footer_enabled = false
		self.state.winid = window.open_split({
			name = self.name,
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = on_close,
		})
	end

	return true
end

---Close the panel: window, buffer, and any in-flight request.
function Panel:close()
	if self.state.winid then
		window.close(self.state.winid)
	else
		window.close(self.name)
	end

	if self.state.bufnr then
		buffer.teardown(self.state.bufnr)
	else
		buffer.teardown(self.name)
	end

	self.state.bufnr = nil
	self.state.winid = nil
	self:next_request()
end

-- ── rendering ──────────────────────────────────────────────────────────

---Start a render: a builder with the panel header already pushed.
---@param title string|nil  override for panels with per-view titles
---@return GitflowRenderBuilder
function Panel:begin_render(title)
	local B = ui_render.builder()
	components.header(B, title or self.title, self:render_opts())
	return B
end

---Push the generated hint bar. Splits get it in the buffer; floats already
---carry the same keys in their footer, so nothing is pushed there.
---@param B GitflowRenderBuilder
---@param view string|nil
---@param opts table|nil  { blank_before = boolean }
function Panel:push_hints(B, view, opts)
	local shown, truncated = fit_hints(
		self:hints(view), self:split_width(), hint_bar_width
	)
	components.split_hint_bar(
		B, self:render_opts(), hint_bar_pairs(shown, truncated), opts
	)
end

---Paint a finished builder into the panel buffer.
---@param B GitflowRenderBuilder
---@return boolean painted
function Panel:paint(B)
	local bufnr = self:bufnr()
	if not bufnr then
		return false
	end
	B:flush(bufnr, bufnr, self.ns)
	components.cursorline(self.state.winid, true)
	return true
end

---Drop the line->entry map a panel builds while rendering its list.
---
---A state render collapses the buffer, so a map built for the previous
---content would resolve a keypress on a hint or state line to an entry that
---is no longer on screen -- on the status panel, to `X discard changes`.
---`state.line_entries` is the base's name for that map: every adopting panel
---that keeps one uses it.
function Panel:clear_line_entries()
	if type(self.state.line_entries) == "table" then
		self.state.line_entries = {}
	end
end

---Paint the panel's loading state. The one way a gitflow panel says "working".
---@param label string|nil
---@param opts table|nil  { detail = string }
function Panel:render_loading(label, opts)
	self:clear_line_entries()
	local B = self:begin_render()
	components.loading(B, label or self.loading or "Loading…", opts)
	self:paint(B)
end

---Paint a failure into the panel. A dead request must never be left looking
---like one still in flight, so every panel error path lands here.
---@param message string
---@param opts table|nil  { detail = string, hint = string, view = string }
function Panel:render_error(message, opts)
	opts = opts or {}
	self:clear_line_entries()
	local B = self:begin_render()
	components.error_state(B, message, opts)
	self:push_hints(B, opts.view)
	self:paint(B)
end

return M
