-- scripts/test_t3_github_panels.lua — T3 (gf-github-panels-ui) behavior that
-- test_panel_base.lua's generic contract does not cover:
--   * a failed fetch with nothing cached yet renders as an error, visibly
--     distinct (different highlight groups) from the loading state — the
--     "failure painted as loading" defect the audit found at
--     prs.lua:662,688, issues.lua:714,737, labels.lua:229;
--   * reopening a panel that already has data paints it in the same frame,
--     before the reconciling refetch resolves;
--   * the new client-side pagination (#283) pages the cached list without
--     another `gh` call.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, failed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " — " .. tostring(err))
	end
end

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local gitflow = require("gitflow")
gitflow.setup({
	ui = { default_layout = "split", split = { orientation = "vertical", size = 60 } },
})
local cfg = require("gitflow.config").current

---Find a panel module's private `P`, the same way test_panel_base.lua does:
---walk its functions' upvalues for one named `P`.
---@param modname string
---@return table
local function panel_object(modname)
	local mod = require(modname)
	for _, fn in pairs(mod) do
		if type(fn) == "function" then
			local index = 1
			while true do
				local name, value = debug.getupvalue(fn, index)
				if not name then
					break
				end
				if name == "P" and type(value) == "table" and value.ns then
					return value
				end
				index = index + 1
			end
		end
	end
	error(("could not find the panel object of %s"):format(modname))
end

---@param bufnr integer
---@return string
local function buffer_text(bufnr)
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---Every highlight group applied anywhere in the panel's own namespace.
---@param modname string
---@return table<string, boolean>
local function highlight_groups(modname)
	local P = panel_object(modname)
	local groups = {}
	if not P.state.bufnr or not vim.api.nvim_buf_is_valid(P.state.bufnr) then
		return groups
	end
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
		P.state.bufnr, P.ns, 0, -1, { details = true }
	)) do
		local hl = mark[4] and mark[4].hl_group
		if hl then
			groups[hl] = true
		end
	end
	return groups
end

---@class GitflowT3PanelCase
---@field name string  panel module name (also its display name)
---@field module string  gh module the panel fetches through
---@field open fun(mod: table)  open the panel with the shared `cfg`
---@field item fun(number: integer, title: string): table  one fake list row
---@field find_title fun(text: string, title: string): boolean

---@type GitflowT3PanelCase[]
local CASES = {
	{
		name = "prs",
		module = "gitflow.gh.prs",
		open = function(mod) mod.open(cfg) end,
		item = function(number, title)
			return { number = number, title = title, state = "open" }
		end,
	},
	{
		name = "issues",
		module = "gitflow.gh.issues",
		open = function(mod) mod.open(cfg) end,
		item = function(number, title)
			return { number = number, title = title, state = "open" }
		end,
	},
	{
		name = "labels",
		module = "gitflow.gh.labels",
		open = function(mod) mod.open(cfg) end,
		item = function(_, title)
			return { name = title, color = "ff0000", description = "" }
		end,
	},
}

-- ── a failed first fetch renders an error, not a stuck loading screen ──

for _, case in ipairs(CASES) do
	test(("%s: a failed fetch with nothing cached renders an error, not loading"):format(
		case.name
	), function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local gh_mod = require(case.module)
		local real_list = gh_mod.list
		local real_notify = require("gitflow.utils").notify
		require("gitflow.utils").notify = function() end

		mod.close()
		mod.state.cache = nil
		gh_mod.list = function(...)
			local cb = select(select("#", ...), ...)
			cb("network error")
		end

		local ok, err = pcall(function()
			case.open(mod)

			local groups = highlight_groups(modname)
			assert_true(
				groups["GitflowStateError"] == true
					or groups["GitflowStateErrorIcon"] == true,
				("%s should paint the error_state component"):format(case.name)
			)
			assert_true(
				groups["GitflowLoadingText"] ~= true
					and groups["GitflowLoadingIcon"] ~= true,
				("%s left the loading state on screen after the fetch failed")
					:format(case.name)
			)

			local text = buffer_text(mod.state.bufnr)
			assert_true(
				text:find("Failed to load", 1, true) ~= nil,
				("%s buffer should say the fetch failed: %q"):format(case.name, text)
			)
		end)

		gh_mod.list = real_list
		require("gitflow.utils").notify = real_notify
		mod.close()
		mod.state.cache = nil
		assert_true(ok, tostring(err))
	end)
end

-- ── reopening a panel with data paints it before the refetch resolves ──

for _, case in ipairs(CASES) do
	test(("%s: reopening paints from cache in one frame, then reconciles"):format(
		case.name
	), function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local gh_mod = require(case.module)
		local real_list = gh_mod.list

		mod.close()
		mod.state.cache = nil

		local ok, err = pcall(function()
			-- Seed the cache with an initial, synchronously-answered fetch.
			gh_mod.list = function(...)
				local cb = select(select("#", ...), ...)
				cb(nil, { case.item(1, "Old item") })
			end
			case.open(mod)
			assert_true(
				buffer_text(mod.state.bufnr):find("Old item", 1, true) ~= nil,
				("%s should have painted the seeded item"):format(case.name)
			)
			mod.close()
			assert_true(
				mod.state.cache ~= nil,
				("%s should keep its cache across close"):format(case.name)
			)

			-- Reopen with the lister held: the cached frame must appear
			-- before this callback is ever answered.
			local held_cb
			gh_mod.list = function(...)
				held_cb = select(select("#", ...), ...)
			end
			case.open(mod)

			assert_true(
				buffer_text(mod.state.bufnr):find("Old item", 1, true) ~= nil,
				("%s should paint the cached item on open, before reconciling")
					:format(case.name)
			)
			assert_true(
				held_cb ~= nil,
				("%s should still kick a reconciling refetch"):format(case.name)
			)

			-- Reconcile: the fresh fetch replaces the stale cache.
			held_cb(nil, { case.item(2, "New item") })
			local text = buffer_text(mod.state.bufnr)
			assert_true(
				text:find("New item", 1, true) ~= nil,
				("%s should reconcile to the fresh fetch"):format(case.name)
			)
			assert_true(
				text:find("Old item", 1, true) == nil,
				("%s should not still show the stale item once reconciled")
					:format(case.name)
			)
		end)

		gh_mod.list = real_list
		mod.close()
		mod.state.cache = nil
		assert_true(ok, tostring(err))
	end)
end

-- ── pagination (#283): prs and labels page the cache, no extra `gh` call ──

---@type { name: string, module: string, open: fun(mod: table), item: fun(n: integer): table }[]
local PAGINATED_CASES = {
	{
		name = "prs",
		module = "gitflow.gh.prs",
		open = function(mod) mod.open(cfg) end,
		item = function(n)
			return { number = n, title = ("Item %d"):format(n), state = "open" }
		end,
	},
	{
		name = "labels",
		module = "gitflow.gh.labels",
		open = function(mod) mod.open(cfg) end,
		item = function(n)
			return { name = ("label-%02d"):format(n), color = "ff0000", description = "" }
		end,
	},
}

for _, case in ipairs(PAGINATED_CASES) do
	test(("%s: n/p page the cached list without another gh call"):format(case.name), function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local gh_mod = require(case.module)
		local real_list = gh_mod.list

		mod.close()
		mod.state.cache = nil

		local calls = 0
		local items = {}
		for n = 1, 45 do
			items[n] = case.item(n)
		end
		gh_mod.list = function(...)
			calls = calls + 1
			local cb = select(select("#", ...), ...)
			cb(nil, items)
		end

		local ok, err = pcall(function()
			case.open(mod)
			assert_true(calls == 1, "panel should fetch once on open")
			local first_page = buffer_text(mod.state.bufnr)
			assert_true(
				first_page:find("45", 1, true) ~= nil,
				("%s summary should report the full count"):format(case.name)
			)

			mod.next_page()
			assert_true(calls == 1, "next_page should not re-fetch from gh")
			local second_page = buffer_text(mod.state.bufnr)
			assert_true(
				second_page ~= first_page,
				("%s next_page should change the rendered page"):format(case.name)
			)

			mod.prev_page()
			assert_true(calls == 1, "prev_page should not re-fetch from gh")
			assert_true(
				buffer_text(mod.state.bufnr) == first_page,
				("%s prev_page should return to the first page's content")
					:format(case.name)
			)
		end)

		gh_mod.list = real_list
		mod.close()
		mod.state.cache = nil
		assert_true(ok, tostring(err))
	end)
end

print(("T3 github-panels tests: %d/%d passed"):format(passed, passed + failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
