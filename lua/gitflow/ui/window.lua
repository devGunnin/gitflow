---@class GitflowWindowOpenSplitOpts
---@field bufnr? integer
---@field name? string
---@field orientation? "vertical"|"horizontal"
---@field size? integer
---@field enter? boolean
---@field on_close? fun(winid: integer)

---@class GitflowWindowOpenFloatOpts
---@field bufnr integer
---@field name? string
---@field width? number
---@field height? number
---@field row? integer
---@field col? integer
---@field border? string|string[]
---@field title? string
---@field title_pos? "left"|"center"|"right"
---@field footer? string|string[]
---@field footer_pos? "left"|"center"|"right"
---@field enter? boolean
---@field on_close? fun(winid: integer)

---@class GitflowWindowRecord
---@field winid integer
---@field name string|nil
---@field on_close fun(winid: integer)|nil
---@field closed boolean
---@field augroup integer|nil

--- Usable editor rectangle for a float, with the tabline/statusline/cmdline
--- chrome already excluded.
---@class GitflowFloatArea
---@field columns integer
---@field lines integer
---@field first_row integer  editor row the usable area starts at
---@field scale_lines integer  rows a fractional height is measured against

---@class GitflowFloatGeometry
---@field width integer
---@field height integer
---@field row integer
---@field col integer

local utils = require("gitflow.utils")

local M = {}

--- Smallest float we still consider usable. Below this we refuse to open
--- rather than hand `nvim_open_win` a sliver (or a non-positive dimension).
M.MIN_FLOAT_WIDTH = 20
M.MIN_FLOAT_HEIGHT = 3

---@type table<string, GitflowWindowRecord>
M.registry = {}

---@type table<integer, GitflowWindowRecord>
local watched = {}

---@param value number
---@param low integer
---@param high integer
---@return integer
local function clamp(value, low, high)
	if value < low then
		return low
	end
	if value > high then
		return high
	end
	return math.floor(value)
end

---@param dimension number  fraction of max_value when in (0,1], else absolute cells
---@param max_value integer
---@return integer
local function resolve_dimension(dimension, max_value)
	if dimension > 0 and dimension <= 1 then
		return math.max(1, math.floor(max_value * dimension))
	end
	return math.max(1, math.floor(dimension))
end

---@param border string|string[]|nil
---@return integer  rows/columns the border adds around the content
local function border_padding(border)
	if border == "none" or border == "shadow" then
		return 0
	end
	return 2
end

---@return integer  rows the tabline occupies
local function tabline_rows()
	local show = vim.o.showtabline
	if show == 2 then
		return 1
	end
	if show == 1 and #vim.api.nvim_list_tabpages() > 1 then
		return 1
	end
	return 0
end

---@return integer  rows reserved below the editor area
local function bottom_chrome_rows()
	-- laststatus==1 only shows a statusline with >1 window, but a float is
	-- itself a window, so reserving the row unconditionally is the safe side.
	local statusline = vim.o.laststatus > 0 and 1 or 0
	return vim.o.cmdheight + statusline
end

--- Editor area a float may occupy without covering the tabline, the
--- statusline or the command line.
---@return GitflowFloatArea
function M.float_area()
	local first_row = tabline_rows()
	local usable = vim.o.lines - first_row - bottom_chrome_rows()
	return {
		columns = math.max(0, vim.o.columns),
		lines = math.max(0, usable),
		first_row = first_row,
		-- A configured fraction means "share of the editor", as it always
		-- has; the chrome-aware `lines` above is what it then has to fit in.
		scale_lines = math.max(0, vim.o.lines - vim.o.cmdheight),
	}
end

--- Fit a float inside `area`: resolve fractional sizes, clamp to a usable
--- minimum and to what actually fits (border included), and keep the whole
--- window on screen. Pure — reads no editor state.
---@param opts GitflowWindowOpenFloatOpts
---@param area GitflowFloatArea
---@return GitflowFloatGeometry|nil geometry, string|nil err
function M.float_geometry(opts, area)
	local pad = border_padding(opts.border)
	local max_width = area.columns - pad
	local max_height = area.lines - pad
	if max_width < M.MIN_FLOAT_WIDTH or max_height < M.MIN_FLOAT_HEIGHT then
		return nil, ("Terminal too small for this Gitflow window: need at least %dx%d, have %dx%d")
			:format(
				M.MIN_FLOAT_WIDTH + pad,
				M.MIN_FLOAT_HEIGHT + pad,
				area.columns,
				area.lines
			)
	end

	local width = clamp(
		resolve_dimension(opts.width or 0.8, area.columns), M.MIN_FLOAT_WIDTH, max_width
	)
	local height = clamp(
		resolve_dimension(opts.height or 0.7, area.scale_lines), M.MIN_FLOAT_HEIGHT, max_height
	)
	local max_row = area.lines - (height + pad)
	local max_col = area.columns - (width + pad)

	-- An explicit row is already in editor coordinates; a centred one is
	-- measured inside the usable area and shifted past the tabline.
	local row = opts.row
		and clamp(opts.row, area.first_row, area.first_row + max_row)
		or area.first_row + clamp(max_row / 2, 0, max_row)

	return {
		width = width,
		height = height,
		row = row,
		col = clamp(opts.col or max_col / 2, 0, max_col),
	}, nil
end

--- Run a window's `on_close` hook at most once, whichever close route got
--- here first, and drop the record.
---@param record GitflowWindowRecord
local function fire_close(record)
	if record.closed then
		return
	end
	record.closed = true

	if record.name and M.registry[record.name] == record then
		M.registry[record.name] = nil
	end
	watched[record.winid] = nil
	if record.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, record.augroup)
		record.augroup = nil
	end

	if record.on_close then
		record.on_close(record.winid)
	end
end

--- Track a window so its `on_close` hook fires exactly once, on every close
--- route: `:q`, `<C-w>c`, `:bd`/`:bw`, a layout change and `M.close` all raise
--- WinClosed; quitting Neovim raises only VimLeavePre. Re-registering a winid
--- replaces the previous record.
---@param winid integer
---@param opts { name?: string, on_close?: fun(winid: integer) }|nil
---@return boolean  false when the window is already gone
function M.register(winid, opts)
	if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
		return false
	end
	local options = opts or {}

	local previous = watched[winid]
	if previous then
		previous.closed = true
		if previous.augroup then
			pcall(vim.api.nvim_del_augroup_by_id, previous.augroup)
		end
	end

	---@type GitflowWindowRecord
	local record = {
		winid = winid,
		name = options.name,
		on_close = options.on_close,
		closed = false,
	}
	watched[winid] = record
	if options.name then
		M.registry[options.name] = record
	end

	record.augroup = vim.api.nvim_create_augroup(
		("GitflowWindow_%d"):format(winid), { clear = true }
	)
	vim.api.nvim_create_autocmd("WinClosed", {
		group = record.augroup,
		pattern = tostring(winid),
		callback = function()
			fire_close(record)
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = record.augroup,
		callback = function()
			fire_close(record)
		end,
	})
	return true
end

---@param target integer|string
---@return integer|nil
local function resolve_window(target)
	if type(target) == "number" then
		if vim.api.nvim_win_is_valid(target) then
			return target
		end
		return nil
	end

	local record = M.registry[target]
	if not record then
		return nil
	end
	if vim.api.nvim_win_is_valid(record.winid) then
		return record.winid
	end
	M.registry[target] = nil
	return nil
end

---@param opts GitflowWindowOpenSplitOpts|nil
---@return integer
function M.open_split(opts)
	local options = opts or {}
	local orientation = options.orientation or "vertical"
	local size = options.size or 50
	local current_win = vim.api.nvim_get_current_win()

	if orientation == "vertical" then
		vim.cmd("vsplit")
	else
		vim.cmd("split")
	end

	local winid = vim.api.nvim_get_current_win()
	if orientation == "vertical" then
		vim.api.nvim_win_set_width(winid, size)
	else
		vim.api.nvim_win_set_height(winid, size)
	end

	if options.bufnr and vim.api.nvim_buf_is_valid(options.bufnr) then
		vim.api.nvim_win_set_buf(winid, options.bufnr)
	end

	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:GitflowNormal",
		{ win = winid }
	)

	M.register(winid, { name = options.name, on_close = options.on_close })

	if options.enter == false and vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end

	return winid
end

---@param opts GitflowWindowOpenFloatOpts
---@return integer|nil  nil when the terminal is too small for a usable float
function M.open_float(opts)
	local geometry, err = M.float_geometry(opts, M.float_area())
	if not geometry then
		utils.notify(err, vim.log.levels.WARN)
		return nil
	end

	local win_opts = {
		relative = "editor",
		style = "minimal",
		width = geometry.width,
		height = geometry.height,
		row = geometry.row,
		col = geometry.col,
		border = opts.border or "rounded",
	}
	if opts.title then
		win_opts.title = opts.title
		win_opts.title_pos = opts.title_pos or "center"
	end
	if opts.footer and vim.fn.has("nvim-0.10") == 1 then
		win_opts.footer = opts.footer
		win_opts.footer_pos = opts.footer_pos or "center"
	end
	local winid = vim.api.nvim_open_win(
		opts.bufnr, opts.enter ~= false, win_opts
	)
	vim.api.nvim_set_option_value(
		"winhighlight",
		"FloatBorder:GitflowBorder,FloatTitle:GitflowTitle"
			.. ",FloatFooter:GitflowFooter,NormalFloat:GitflowNormal",
		{ win = winid }
	)

	M.register(winid, { name = opts.name, on_close = opts.on_close })
	return winid
end

---@param target integer|string
---@return boolean
function M.close(target)
	local winid = resolve_window(target)
	if not winid then
		return false
	end
	pcall(vim.api.nvim_win_close, winid, true)
	-- WinClosed normally got here first; this covers a close that raised no
	-- event, and is a no-op when it did.
	local record = watched[winid]
	if record then
		fire_close(record)
	end
	return true
end

---@param name string
---@return integer|nil
function M.get(name)
	local record = M.registry[name]
	if not record then
		return nil
	end
	if vim.api.nvim_win_is_valid(record.winid) then
		return record.winid
	end
	M.registry[name] = nil
	return nil
end

return M
