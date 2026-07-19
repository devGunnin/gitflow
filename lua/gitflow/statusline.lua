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
---@field root_cache { cwd: string, root: string }|nil
M.state = {
	cache = "",
	cwd = nil,
	updating = false,
	pending = false,
	warmed = false,
	augroup = nil,
	waiters = {},
	root_cache = nil,
}

--- Drop the memoized repository root so the next refresh re-resolves it.
function M.invalidate_root_cache()
	M.state.root_cache = nil
end

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

local function redraw_statusline()
	vim.schedule(function()
		pcall(vim.cmd, "redrawstatus")
	end)
end

---@param value string
---@param cwd string
local function finish_refresh(value, cwd)
	local normalized = value or ""
	local changed = M.state.cache ~= normalized or M.state.cwd ~= cwd or not M.state.warmed

	M.state.cache = normalized
	M.state.cwd = cwd
	M.state.warmed = true
	M.state.updating = false
	notify_waiters(M.state.cache)
	if changed then
		redraw_statusline()
	end

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

--- Resolve the repository root for `cwd`, reusing the memoized value.
--- Only the branch/ahead/behind/dirty state is re-read every refresh; the root
--- is stable for a given cwd and is invalidated explicitly by its callers.
---@param cwd string
---@param cb fun(repo_root: string|nil)
local function resolve_repo_root(cwd, cb)
	local cached = M.state.root_cache
	if cached and cached.cwd == cwd then
		cb(cached.root)
		return
	end

	git.git({ "rev-parse", "--show-toplevel" }, { cwd = cwd }, function(result)
		if result.code ~= 0 then
			cb(nil)
			return
		end

		local repo_root = vim.trim(result.stdout or "")
		if repo_root == "" then
			cb(nil)
			return
		end

		-- Only successful lookups are cached: a non-repo cwd already costs one
		-- probe, and caching the miss would hide a repo created later.
		M.state.root_cache = { cwd = cwd, root = repo_root }
		cb(repo_root)
	end)
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
	resolve_repo_root(cwd, function(repo_root)
		if not repo_root then
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
	M.invalidate_root_cache()

	vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost" }, {
		group = M.state.augroup,
		callback = function(event)
			-- Regaining focus is when an out-of-band change to the root (a
			-- nested `git init`, a worktree swap) is plausible; a buffer write
			-- cannot move the root, so the frequent event keeps the cache.
			if event.event == "FocusGained" then
				M.invalidate_root_cache()
			end
			M.refresh()
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		group = M.state.augroup,
		pattern = "GitflowPostOperation",
		callback = function()
			M.invalidate_root_cache()
			M.refresh()
		end,
	})
end

return M
