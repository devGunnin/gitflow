local git = require("gitflow.git")
local git_branch = require("gitflow.git.branch")
local git_status = require("gitflow.git.status")

local M = {}

---@class GitflowStatuslineState
---@field cache string
---@field cwd string|nil
---@field updating boolean
---@field pending boolean
---@field warmed boolean
---@field augroup integer|nil
---@field waiters fun(value: string)[]
M.state = {
	cache = "",
	cwd = nil,
	updating = false,
	pending = false,
	warmed = false,
	augroup = nil,
	waiters = {},
}

---@return string
local function current_cwd()
	return vim.fn.getcwd()
end

---@param output string
---@return boolean
local function output_mentions_no_upstream(output)
	local normalized = (output or ""):lower()
	if normalized:find("no upstream configured", 1, true) then
		return true
	end
	if normalized:find("no upstream", 1, true) then
		return true
	end
	if normalized:find("does not point to a branch", 1, true) then
		return true
	end
	if normalized:find("has no upstream branch", 1, true) then
		return true
	end
	return false
end

---@param branch string
---@param ahead integer
---@param behind integer
---@param has_upstream boolean
---@param dirty boolean
---@return string
local function format_statusline(branch, ahead, behind, has_upstream, dirty)
	local parts = { branch }
	if has_upstream then
		parts[#parts + 1] = ("↑%d ↓%d"):format(ahead, behind)
	end
	if dirty then
		parts[#parts + 1] = "*"
	end
	return table.concat(parts, " ")
end

---@param value string
local function notify_waiters(value)
	if #M.state.waiters == 0 then
		return
	end

	local callbacks = M.state.waiters
	M.state.waiters = {}
	for _, cb in ipairs(callbacks) do
		local ok = pcall(cb, value)
		if not ok then
			-- Ignore callback errors to keep statusline refresh non-fatal.
		end
	end
end

---@param value string
---@param cwd string
local function finish_refresh(value, cwd)
	M.state.cache = value or ""
	M.state.cwd = cwd
	M.state.warmed = true
	M.state.updating = false
	notify_waiters(M.state.cache)

	if M.state.pending then
		M.state.pending = false
		M.refresh()
	end
end

---@param repo_root string
---@param cb fun(ahead: integer, behind: integer, has_upstream: boolean)
local function read_divergence(repo_root, cb)
	git.git(
		{ "rev-list", "--left-right", "--count", "@{upstream}...HEAD" },
		{ cwd = repo_root },
		function(result)
			if result.code ~= 0 then
				local output = git.output(result)
				if output_mentions_no_upstream(output) then
					cb(0, 0, false)
					return
				end
				cb(0, 0, false)
				return
			end

			local left, right = vim.trim(result.stdout or ""):match("^(%d+)%s+(%d+)$")
			local behind = tonumber(left or "")
			local ahead = tonumber(right or "")
			if ahead == nil or behind == nil then
				cb(0, 0, false)
				return
			end
			cb(ahead, behind, true)
		end
	)
end

---@param on_done fun(value: string)|nil
function M.refresh(on_done)
	if type(on_done) == "function" then
		M.state.waiters[#M.state.waiters + 1] = on_done
	end

	if M.state.updating then
		M.state.pending = true
		return
	end
	M.state.updating = true

	local cwd = current_cwd()
	git.git({ "rev-parse", "--show-toplevel" }, { cwd = cwd }, function(root_result)
		if root_result.code ~= 0 then
			finish_refresh("", cwd)
			return
		end

		local repo_root = vim.trim(root_result.stdout or "")
		if repo_root == "" then
			finish_refresh("", cwd)
			return
		end

		git_branch.current({ cwd = repo_root }, function(err, branch)
			if err or not branch or branch == "" then
				finish_refresh("", cwd)
				return
			end

			read_divergence(repo_root, function(ahead, behind, has_upstream)
				git_status.fetch({ cwd = repo_root }, function(status_err, entries)
					local dirty = false
					if not status_err and type(entries) == "table" and #entries > 0 then
						dirty = true
					end

					local value = format_statusline(branch, ahead, behind, has_upstream, dirty)
					finish_refresh(value, cwd)
				end)
			end)
		end)
	end)
end

-- Usage examples:
-- Native statusline: vim.o.statusline = "%{%v:lua.require'gitflow'.statusline()%}"
-- lualine: require("lualine").setup({
--   sections = { lualine_c = { require("gitflow").statusline } },
-- })
-- heirline provider: function() return require("gitflow").statusline() end
---@return string
function M.get()
	local cwd = current_cwd()
	if M.state.cwd ~= cwd then
		M.state.cache = ""
		M.state.cwd = cwd
		M.state.warmed = false
	end

	if not M.state.warmed and not M.state.updating then
		M.refresh()
	end

	return M.state.cache or ""
end

function M.setup()
	if M.state.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M.state.augroup)
	end
	M.state.augroup = vim.api.nvim_create_augroup("GitflowStatusline", { clear = true })

	vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost" }, {
		group = M.state.augroup,
		callback = function()
			M.refresh()
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		group = M.state.augroup,
		pattern = "GitflowPostOperation",
		callback = function()
			M.refresh()
		end,
	})
end

return M
