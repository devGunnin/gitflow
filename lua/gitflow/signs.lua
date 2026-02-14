local git = require("gitflow.git")

local M = {}

local SIGN_GROUP = "GitflowSigns"
local EXTMARK_NAMESPACE = vim.api.nvim_create_namespace("gitflow_signs")

M.sign_group = SIGN_GROUP
M.extmark_namespace = EXTMARK_NAMESPACE

local SIGN_TYPES = {
	added = {
		name = "GitflowSignAdded",
		hl = "GitflowAdded",
		config_key = "added",
	},
	modified = {
		name = "GitflowSignModified",
		hl = "GitflowModified",
		config_key = "modified",
	},
	deleted = {
		name = "GitflowSignDeleted",
		hl = "GitflowRemoved",
		config_key = "deleted",
	},
	conflict = {
		name = "GitflowSignConflict",
		hl = "GitflowConflictLocal",
		config_key = "conflict",
	},
}

M.use_extmarks = vim.fn.has("nvim-0.10") == 1
M.state = {
	cfg = nil,
	enabled = true,
	attached = {},
	update_ticks = {},
	next_sign_id = 1,
	augroup = nil,
}

---@param text string
---@return string[]
local function split_lines(text)
	if text == "" then
		return {}
	end
	return vim.split(text, "\n", { plain = true, trimempty = true })
end

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

---@param root string
---@param absolute string
---@return string|nil
local function relative_path(root, absolute)
	if vim.fs and vim.fs.relpath then
		local rel = vim.fs.relpath(root, absolute)
		if rel and rel ~= "" then
			return rel
		end
	end

	local prefix = root:gsub("/+$", "") .. "/"
	if vim.startswith(absolute, prefix) then
		return absolute:sub(#prefix + 1)
	end
	return nil
end

---@param output string
---@return boolean
local function output_mentions_missing_head(output)
	local normalized = (output or ""):lower()
	return normalized:find("unknown revision", 1, true) ~= nil
		or normalized:find("bad revision", 1, true) ~= nil
		or normalized:find("ambiguous argument 'head'", 1, true) ~= nil
end

local function define_highlights()
	vim.api.nvim_set_hl(0, "GitflowAdded", { link = "DiffAdd", default = true })
	vim.api.nvim_set_hl(0, "GitflowModified", { link = "DiffChange", default = true })
	vim.api.nvim_set_hl(0, "GitflowRemoved", { link = "DiffDelete", default = true })
end

---@param cfg GitflowConfig
local function define_signs(cfg)
	for _, sign in pairs(SIGN_TYPES) do
		vim.fn.sign_define(sign.name, {
			text = cfg.signs[sign.config_key],
			texthl = sign.hl,
		})
	end
end

---@param bufnr integer
local function clear_signs(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if M.use_extmarks then
		vim.api.nvim_buf_clear_namespace(bufnr, EXTMARK_NAMESPACE, 0, -1)
		return
	end

	vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })
end

---@param output string
---@return table[]
function M.parse_diff_hunks(output)
	local changes = {}
	local current_new_line = 1
	local pending_deletions = 0
	local pending_deletion_line = 1

	local function flush_deletions()
		for _ = 1, pending_deletions do
			changes[#changes + 1] = {
				type = "deleted",
				line = pending_deletion_line,
			}
		end
		pending_deletions = 0
	end

	for _, line in ipairs(split_lines(output)) do
		local old_start, _, new_start = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
		if old_start and new_start then
			flush_deletions()
			current_new_line = tonumber(new_start) or 1
		elseif vim.startswith(line, "+") and not vim.startswith(line, "+++") then
			if pending_deletions > 0 then
				changes[#changes + 1] = { type = "modified", line = current_new_line }
				pending_deletions = pending_deletions - 1
			else
				changes[#changes + 1] = { type = "added", line = current_new_line }
			end
			current_new_line = current_new_line + 1
		elseif vim.startswith(line, "-") and not vim.startswith(line, "---") then
			if pending_deletions == 0 then
				pending_deletion_line = current_new_line
			end
			pending_deletions = pending_deletions + 1
		elseif vim.startswith(line, " ") then
			flush_deletions()
			current_new_line = current_new_line + 1
		end
	end

	flush_deletions()
	return changes
end

---@param bufnr integer
---@return table[]
local function conflict_signs_for_buffer(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local conflicts = {}

	for index, line in ipairs(lines) do
		if vim.startswith(line, "<<<<<<<")
			or vim.startswith(line, "=======")
			or vim.startswith(line, ">>>>>>>")
		then
			conflicts[#conflicts + 1] = { type = "conflict", line = index }
		end
	end

	if #conflicts == 0 then
		conflicts[#conflicts + 1] = { type = "conflict", line = 1 }
	end
	return conflicts
end

---@param bufnr integer
---@param signs table[]
local function place_signs(bufnr, signs)
	clear_signs(bufnr)
	if #signs == 0 then
		return
	end

	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	local seen = {}

	for _, sign in ipairs(signs) do
		local sign_type = SIGN_TYPES[sign.type]
		if sign_type then
			local line = math.max(1, math.min(tonumber(sign.line) or 1, line_count))
			local key = ("%s:%d"):format(sign.type, line)
			if not seen[key] then
				seen[key] = true
				if M.use_extmarks then
					vim.api.nvim_buf_set_extmark(bufnr, EXTMARK_NAMESPACE, line - 1, 0, {
						sign_text = M.state.cfg.signs[sign_type.config_key],
						sign_hl_group = sign_type.hl,
						priority = 10,
					})
				else
					vim.fn.sign_place(
						M.state.next_sign_id,
						SIGN_GROUP,
						sign_type.name,
						bufnr,
						{ lnum = line, priority = 10 }
					)
					M.state.next_sign_id = M.state.next_sign_id + 1
				end
			end
		end
	end
end

---@param path string
---@param cb fun(root: string|nil)
local function resolve_repo_root(path, cb)
	local directory = vim.fn.fnamemodify(path, ":h")
	git.git({ "rev-parse", "--show-toplevel" }, { cwd = directory }, function(result)
		if result.code ~= 0 then
			cb(nil)
			return
		end
		local root = vim.trim(result.stdout or "")
		if root == "" then
			cb(nil)
			return
		end
		cb(root)
	end)
end

---@param root string
---@param relpath string
---@param cb fun(err: string|nil, conflict: boolean|nil)
local function file_has_conflicts(root, relpath, cb)
	git.git({ "status", "--porcelain=v1", "--", relpath }, { cwd = root }, function(result)
		if result.code ~= 0 then
			cb("git status for signs failed", nil)
			return
		end

		for _, line in ipairs(split_lines(result.stdout or "")) do
			local xy = line:sub(1, 2)
			local index_status = xy:sub(1, 1)
			local worktree_status = xy:sub(2, 2)
			local unmerged = index_status == "U"
				or worktree_status == "U"
				or xy == "AA"
				or xy == "DD"
			if unmerged then
				cb(nil, true)
				return
			end
		end

		cb(nil, false)
	end)
end

---@param root string
---@param relpath string
---@param cb fun(err: string|nil, diff_output: string|nil)
local function get_file_diff(root, relpath, cb)
	local primary_args = { "diff", "--no-color", "--no-ext-diff", "-U0", "HEAD", "--", relpath }
	git.git(primary_args, { cwd = root }, function(result)
		if result.code == 0 then
			cb(nil, result.stdout or "")
			return
		end

		local output = git.output(result)
		if not output_mentions_missing_head(output) then
			cb(("git diff failed for '%s': %s"):format(relpath, output), nil)
			return
		end

		local fallback_args = { "diff", "--no-color", "--no-ext-diff", "-U0", "--", relpath }
		git.git(fallback_args, { cwd = root }, function(fallback)
			if fallback.code ~= 0 then
				cb(("git diff failed for '%s': %s"):format(relpath, git.output(fallback)), nil)
				return
			end
			cb(nil, fallback.stdout or "")
		end)
	end)
end

---@param bufnr integer
function M.update_signs(bufnr)
	if not M.state.enabled then
		return
	end
	if not is_normal_file_buffer(bufnr) then
		M.detach(bufnr)
		return
	end

	local path = buffer_path(bufnr)
	if not path then
		clear_signs(bufnr)
		return
	end

	local tick = (M.state.update_ticks[bufnr] or 0) + 1
	M.state.update_ticks[bufnr] = tick

	resolve_repo_root(path, function(root)
		if M.state.update_ticks[bufnr] ~= tick then
			return
		end
		if not root then
			clear_signs(bufnr)
			return
		end

		local relpath = relative_path(root, path)
		if not relpath then
			clear_signs(bufnr)
			return
		end

		file_has_conflicts(root, relpath, function(_, conflict)
			if M.state.update_ticks[bufnr] ~= tick then
				return
			end
			if conflict then
				place_signs(bufnr, conflict_signs_for_buffer(bufnr))
				return
			end

			get_file_diff(root, relpath, function(err, diff_output)
				if M.state.update_ticks[bufnr] ~= tick then
					return
				end
				if err then
					clear_signs(bufnr)
					return
				end
				place_signs(bufnr, M.parse_diff_hunks(diff_output or ""))
			end)
		end)
	end)
end

---@param bufnr integer
function M.attach(bufnr)
	if not M.state.enabled then
		return
	end
	if not is_normal_file_buffer(bufnr) then
		return
	end
	if not buffer_path(bufnr) then
		return
	end

	M.state.attached[bufnr] = true
	M.update_signs(bufnr)
end

---@param bufnr integer
function M.detach(bufnr)
	M.state.attached[bufnr] = nil
	M.state.update_ticks[bufnr] = nil
	clear_signs(bufnr)
end

function M.refresh_all()
	for bufnr, _ in pairs(M.state.attached) do
		if vim.api.nvim_buf_is_valid(bufnr) and is_normal_file_buffer(bufnr) then
			M.update_signs(bufnr)
		else
			M.detach(bufnr)
		end
	end
end

---@param cfg GitflowConfig
function M.setup(cfg)
	M.state.cfg = cfg
	M.state.enabled = cfg.signs.enable ~= false

	define_highlights()
	define_signs(cfg)

	if M.state.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M.state.augroup)
	end
	M.state.augroup = vim.api.nvim_create_augroup("GitflowSigns", { clear = true })

	for bufnr, _ in pairs(M.state.attached) do
		M.detach(bufnr)
	end

	if not M.state.enabled then
		return
	end

	vim.api.nvim_create_autocmd("BufEnter", {
		group = M.state.augroup,
		callback = function(args)
			M.attach(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = M.state.augroup,
		callback = function(args)
			M.attach(args.buf)
			M.update_signs(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = M.state.augroup,
		callback = function(args)
			M.detach(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		group = M.state.augroup,
		pattern = "GitflowPostOperation",
		callback = function()
			M.refresh_all()
		end,
	})

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		M.attach(bufnr)
	end
end

return M
