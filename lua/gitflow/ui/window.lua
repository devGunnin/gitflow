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
---@field on_close fun(winid: integer)|nil

local M = {}

---@type table<string, GitflowWindowRecord>
M.registry = {}

---@param dimension number
---@param max_value integer
---@return integer
local function resolve_dimension(dimension, max_value)
	if dimension > 0 and dimension <= 1 then
		return math.max(1, math.floor(max_value * dimension))
	end
	return math.max(1, math.floor(dimension))
end

---@param name string|nil
---@param winid integer
---@param on_close fun(winid: integer)|nil
local function register_window(name, winid, on_close)
	if name then
		M.registry[name] = { winid = winid, on_close = on_close }
	end
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(winid),
		once = true,
		callback = function()
			if name and M.registry[name] and M.registry[name].winid == winid then
				M.registry[name] = nil
			end
			if on_close then
				on_close(winid)
			end
		end,
	})
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

	register_window(options.name, winid, options.on_close)

	if options.enter == false and vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_set_current_win(current_win)
	end

	return winid
end

---@param opts GitflowWindowOpenFloatOpts
---@return integer
function M.open_float(opts)
	local columns = vim.o.columns
	local lines = vim.o.lines - vim.o.cmdheight
	local width = resolve_dimension(opts.width or 0.8, columns)
	local height = resolve_dimension(opts.height or 0.7, lines)
	local row = opts.row or math.floor((lines - height) / 2)
	local col = opts.col or math.floor((columns - width) / 2)

	local win_opts = {
		relative = "editor",
		style = "minimal",
		width = width,
		height = height,
		row = row,
		col = col,
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

	local winid = vim.api.nvim_open_win(opts.bufnr, opts.enter ~= false, win_opts)
	vim.api.nvim_set_option_value(
		"winhighlight",
		"FloatBorder:GitflowBorder,FloatTitle:GitflowTitle,"
			.. "FloatFooter:GitflowFooter,WinSeparator:GitflowBorder",
		{ win = winid }
	)

	register_window(opts.name, winid, opts.on_close)
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
