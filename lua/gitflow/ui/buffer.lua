---@class GitflowBufferCreateOpts
---@field lines? string[]
---@field filetype? string

---@class GitflowBufferRecord
---@field bufnr integer
---@field augroup integer

local M = {}

---@type table<string, GitflowBufferRecord>
M.registry = {}

---@param name string
---@return string
local function normalize_name(name)
	return name:gsub("[^%w_]", "_")
end

---@param name string
local function clear_registry_entry(name)
	M.registry[name] = nil
end

---@param name string
---@param bufnr integer
local function create_cleanup_autocmd(name, bufnr)
	local group_name = ("GitflowBuffer_%s"):format(normalize_name(name))
	local augroup = vim.api.nvim_create_augroup(group_name, { clear = true })
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = augroup,
		buffer = bufnr,
		callback = function()
			clear_registry_entry(name)
		end,
	})
	return augroup
end

---@param bufnr integer
---@param lines string[]
local function set_lines_preserve_cursor(bufnr, lines)
	local windows = {}
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(winid) == bufnr then
			windows[#windows + 1] = {
				winid = winid,
				cursor = vim.api.nvim_win_get_cursor(winid),
			}
		end
	end

	local modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", modifiable, { buf = bufnr })

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for _, entry in ipairs(windows) do
		if vim.api.nvim_win_is_valid(entry.winid) then
			local line = math.max(1, math.min(entry.cursor[1], line_count))
			vim.api.nvim_win_set_cursor(entry.winid, { line, entry.cursor[2] })
		end
	end
end

---@param target string|integer
---@return integer|nil
local function resolve_buffer(target)
	if type(target) == "number" then
		if vim.api.nvim_buf_is_valid(target) then
			return target
		end
		return nil
	end

	local record = M.registry[target]
	if record and vim.api.nvim_buf_is_valid(record.bufnr) then
		return record.bufnr
	end
	if record then
		clear_registry_entry(target)
	end
	return nil
end

---@param name string
---@param opts GitflowBufferCreateOpts|nil
---@return integer
function M.create(name, opts)
	local existing = M.registry[name]
	if existing and vim.api.nvim_buf_is_valid(existing.bufnr) then
		if opts and opts.lines then
			set_lines_preserve_cursor(existing.bufnr, opts.lines)
		end
		return existing.bufnr
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, ("gitflow://%s"):format(name))
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("buflisted", false, { buf = bufnr })
	vim.api.nvim_set_option_value("undofile", false, { buf = bufnr })

	if opts and opts.filetype then
		vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = bufnr })
	end
	if opts and opts.lines then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.lines)
	end

	local augroup = create_cleanup_autocmd(name, bufnr)
	M.registry[name] = { bufnr = bufnr, augroup = augroup }
	return bufnr
end

---@param target string|integer
---@param lines string[]
---@return boolean
function M.update(target, lines)
	local bufnr = resolve_buffer(target)
	if not bufnr then
		return false
	end

	set_lines_preserve_cursor(bufnr, lines)
	return true
end

---@param target string|integer
---@return boolean
function M.teardown(target)
	local bufnr = resolve_buffer(target)
	if not bufnr then
		return false
	end

	for name, record in pairs(M.registry) do
		if record.bufnr == bufnr then
			clear_registry_entry(name)
			break
		end
	end

	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	return true
end

---@param name string
---@return integer|nil
function M.get(name)
	local record = M.registry[name]
	if not record then
		return nil
	end
	if vim.api.nvim_buf_is_valid(record.bufnr) then
		return record.bufnr
	end
	clear_registry_entry(name)
	return nil
end

---@return table<string, integer>
function M.list()
	local list = {}
	for name, record in pairs(M.registry) do
		if vim.api.nvim_buf_is_valid(record.bufnr) then
			list[name] = record.bufnr
		else
			clear_registry_entry(name)
		end
	end
	return list
end

return M
