--- lua/gitflow/inline_blame.lua
---
--- Current-line inline git blame: shows "<author>, <YYYY-MM-DD> • <summary>"
--- as virtual text at the end of the line the cursor is on, the way many
--- modern git plugins do.  It is a per-buffer toggle (`:Gitflow blame`) and,
--- when `blame.auto` is set, attaches automatically to every file buffer.
---
--- Blame is computed lazily for the single cursor line via
---   git blame --line-porcelain --contents - -L <n>,<n> -- <file>
--- feeding the live buffer contents on stdin so unsaved edits map correctly
--- and uncommitted lines are reported as such.  Lookups are debounced so
--- ordinary cursor movement does not spawn a git process per keystroke.

local git = require("gitflow.git")

local M = {}

local NS = vim.api.nvim_create_namespace("gitflow_inline_blame")
M.namespace = NS

M.state = {
	cfg = nil,
	-- master switch (cfg.inline_blame.enable); when false the feature is inert.
	available = true,
	-- bufnr -> true for buffers currently displaying inline blame.
	enabled = {},
	-- bufnr -> monotonically increasing token for debounce/staleness checks.
	tick = {},
	-- bufnr -> last line number we rendered blame for (avoids re-blaming on
	-- horizontal cursor movement).
	last_line = {},
	augroup = nil,
}

---@param bufnr integer
---@return boolean
local function is_normal_file_buffer(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
		return false
	end
	if not vim.api.nvim_get_option_value("buflisted", { buf = bufnr }) then
		return false
	end
	return true
end

---@param bufnr integer
---@return string|nil
local function buffer_path(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end
	return vim.fn.fnamemodify(path, ":p")
end

---@param bufnr integer
local function clear(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

--- Parse a single line of `git blame --line-porcelain` output into the bits
--- we render.
---@param output string
---@return { sha: string, author: string, date: string, summary: string, committed: boolean }|nil
local function parse_porcelain(output)
	if not output or output == "" then
		return nil
	end

	local lines = vim.split(output, "\n", { plain = true })
	local header = lines[1] or ""
	local sha = header:match("^(%x+)")
	if not sha then
		return nil
	end

	local author, summary, epoch
	for _, line in ipairs(lines) do
		local a = line:match("^author (.+)$")
		if a then
			author = a
		end
		local t = line:match("^author%-time (%d+)$")
		if t then
			epoch = tonumber(t)
		end
		local s = line:match("^summary (.+)$")
		if s then
			summary = s
		end
	end

	local committed = sha:match("^0+$") == nil
	local date_format = (M.state.cfg
		and M.state.cfg.inline_blame
		and M.state.cfg.inline_blame.date_format) or "%Y-%m-%d"
	local date = epoch and os.date(date_format, epoch) or ""

	return {
		sha = sha,
		author = author or "?",
		date = tostring(date),
		summary = summary or "",
		committed = committed,
	}
end

---@param info { author: string, date: string, summary: string, committed: boolean }
---@return string
local function format_blame(info)
	if not info.committed then
		return "You • Uncommitted change"
	end
	local parts = ("%s, %s"):format(info.author, info.date)
	if info.summary ~= "" then
		parts = parts .. " • " .. info.summary
	end
	return parts
end

---@param bufnr integer
---@param lnum integer  1-based line number
local function render_line(bufnr, lnum)
	if not M.state.available or not M.state.enabled[bufnr] then
		return
	end
	if not is_normal_file_buffer(bufnr) then
		M.disable(bufnr)
		return
	end

	local path = buffer_path(bufnr)
	if not path then
		clear(bufnr)
		return
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if lnum < 1 or lnum > line_count then
		return
	end

	local tick = (M.state.tick[bufnr] or 0) + 1
	M.state.tick[bufnr] = tick

	local contents = table.concat(
		vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"
	) .. "\n"

	local directory = vim.fn.fnamemodify(path, ":h")
	local args = {
		"blame", "--line-porcelain",
		"--contents", "-",
		"-L", ("%d,%d"):format(lnum, lnum),
		"--", path,
	}

	git.git(args, { cwd = directory, stdin = contents }, function(result)
		-- Stale: the cursor moved or the buffer changed since we asked.
		if M.state.tick[bufnr] ~= tick then
			return
		end
		if not M.state.enabled[bufnr]
			or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		if result.code ~= 0 then
			clear(bufnr)
			return
		end

		local info = parse_porcelain(result.stdout or "")
		clear(bufnr)
		if not info then
			return
		end

		-- The line may have shifted while the async blame was in flight;
		-- only place the mark if the cursor line is still in range.
		if lnum > vim.api.nvim_buf_line_count(bufnr) then
			return
		end

		local hl = "GitflowBlameInline"
		pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum - 1, 0, {
			virt_text = { { format_blame(info), hl } },
			virt_text_pos = "eol",
			hl_mode = "combine",
			priority = 5,
		})
	end)
end

--- Schedule a debounced blame of the cursor line in `bufnr`.
---@param bufnr integer
local function schedule(bufnr)
	if not M.state.available or not M.state.enabled[bufnr] then
		return
	end
	if not is_normal_file_buffer(bufnr) then
		return
	end

	local winid = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_buf(winid) ~= bufnr then
		return
	end

	local lnum = vim.api.nvim_win_get_cursor(winid)[1]
	-- If we already show blame for this exact line, leave it; re-blaming on
	-- every horizontal move or CursorHold tick would just respawn git.
	local has_mark =
		vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { limit = 1 })[1] ~= nil
	if M.state.last_line[bufnr] == lnum and has_mark then
		return
	end
	M.state.last_line[bufnr] = lnum

	-- Clear immediately so a stale annotation never lingers on the old line.
	clear(bufnr)

	local delay = (M.state.cfg
		and M.state.cfg.inline_blame
		and M.state.cfg.inline_blame.delay) or 200
	local token = (M.state.tick[bufnr] or 0) + 1
	M.state.tick[bufnr] = token

	vim.defer_fn(function()
		if M.state.tick[bufnr] ~= token then
			return
		end
		if not M.state.enabled[bufnr]
			or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		-- Confirm the cursor is still on the line we queued.
		local cur = vim.api.nvim_get_current_win()
		if vim.api.nvim_win_get_buf(cur) ~= bufnr then
			return
		end
		if vim.api.nvim_win_get_cursor(cur)[1] ~= lnum then
			return
		end
		render_line(bufnr, lnum)
	end, delay)
end

M.render_line = render_line

---@param bufnr integer
---@return boolean
function M.is_enabled(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return M.state.enabled[bufnr] == true
end

---@param bufnr integer
function M.enable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not M.state.available then
		return
	end
	if not is_normal_file_buffer(bufnr) then
		return
	end
	if not buffer_path(bufnr) then
		return
	end
	M.state.enabled[bufnr] = true
	M.state.last_line[bufnr] = nil
	-- Render the current line right away (debounced) for instant feedback.
	schedule(bufnr)
end

---@param bufnr integer
function M.disable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	M.state.enabled[bufnr] = nil
	M.state.tick[bufnr] = nil
	M.state.last_line[bufnr] = nil
	clear(bufnr)
end

--- Toggle inline blame for `bufnr`; returns the new enabled state.
---@param bufnr integer|nil
---@return boolean
function M.toggle(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if M.is_enabled(bufnr) then
		M.disable(bufnr)
		return false
	end
	M.enable(bufnr)
	return true
end

---@param cfg GitflowConfig
function M.setup(cfg)
	M.state.cfg = cfg
	local blame_cfg = cfg.inline_blame or {}
	M.state.available = blame_cfg.enable ~= false

	vim.api.nvim_set_hl(0, "GitflowBlameInline", { link = "Comment", default = true })

	if M.state.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M.state.augroup)
	end
	M.state.augroup = vim.api.nvim_create_augroup("GitflowInlineBlame", { clear = true })

	-- Disable everywhere on re-setup so stale state never leaks.
	for bufnr in pairs(M.state.enabled) do
		M.disable(bufnr)
	end

	if not M.state.available then
		return
	end

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
		group = M.state.augroup,
		callback = function(args)
			schedule(args.buf)
		end,
	})

	-- Hide the annotation while editing; it would otherwise jitter as the
	-- line content changes under the cursor.
	vim.api.nvim_create_autocmd("InsertEnter", {
		group = M.state.augroup,
		callback = function(args)
			if M.state.enabled[args.buf] then
				clear(args.buf)
			end
		end,
	})

	vim.api.nvim_create_autocmd("InsertLeave", {
		group = M.state.augroup,
		callback = function(args)
			if M.state.enabled[args.buf] then
				M.state.last_line[args.buf] = nil
				schedule(args.buf)
			end
		end,
	})

	-- Re-blame after a save so dates/summaries reflect new commits.
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = M.state.augroup,
		callback = function(args)
			if M.state.enabled[args.buf] then
				M.state.last_line[args.buf] = nil
				schedule(args.buf)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = M.state.augroup,
		callback = function(args)
			M.disable(args.buf)
		end,
	})

	if blame_cfg.auto then
		vim.api.nvim_create_autocmd("BufEnter", {
			group = M.state.augroup,
			callback = function(args)
				if is_normal_file_buffer(args.buf)
					and not M.state.enabled[args.buf] then
					M.enable(args.buf)
				end
			end,
		})
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if is_normal_file_buffer(bufnr) then
				M.enable(bufnr)
			end
		end
	end
end

return M
