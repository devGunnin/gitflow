-- scripts/test_t3_github_panels.lua — T3 (gf-github-panels-ui) behavior that
-- test_panel_base.lua's generic contract does not cover:
--   * a failed fetch with nothing cached yet renders as an error, visibly
--     distinct (different highlight groups) from the loading state — the
--     "failure painted as loading" defect the audit found at
--     prs.lua:662,688, issues.lua:714,737, labels.lua:229;
--   * reopening a panel that already has data paints it in the same frame,
--     before the reconciling refetch resolves;
--   * the new client-side pagination (#283) pages the cached list without
--     another `gh` call;
--   * the cache is scoped to the repo it was filled in, a failed refresh is
--     visible even with rows on screen, and `b` leaves view mode (T3 review).

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
			-- Kept across close only for THIS repo and query; the scoped-cache
			-- test below drives the other-repo half of the contract.
			assert_true(
				mod.state.cache ~= nil,
				("%s should keep its cache across close, in the same repo")
					:format(case.name)
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
	test(("%s: <C-n>/<C-p> page the cached list without another gh call")
		:format(case.name), function()
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

-- ── the cache is scoped: another repo's rows never paint or resolve ──
-- `gh` resolves the repo from the cwd, so an unkeyed module-level cache
-- painted repo A's rows in repo B — with line_entries registered, so `m`
-- merge / `x` close / `d` delete resolved a stale row and fired against the
-- CURRENT repo.

for _, case in ipairs(CASES) do
	test(("%s: a cache filled in another repo neither paints nor resolves"):format(
		case.name
	), function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local gh_mod = require(case.module)
		local real_list = gh_mod.list
		local original_cwd = vim.fn.getcwd()
		local repo_a, repo_b = vim.fn.tempname(), vim.fn.tempname()
		vim.fn.mkdir(repo_a, "p")
		vim.fn.mkdir(repo_b, "p")

		mod.close()
		mod.state.cache = nil

		local ok, err = pcall(function()
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			gh_mod.list = function(...)
				local cb = select(select("#", ...), ...)
				cb(nil, { case.item(1, "REPO-A-ONLY") })
			end
			case.open(mod)
			assert_true(
				buffer_text(mod.state.bufnr):find("REPO-A-ONLY", 1, true) ~= nil,
				("%s should have painted the repo A row"):format(case.name)
			)
			mod.close()

			-- Reopen in another repo with the reconciling fetch held: whatever
			-- is on screen in that frame is what a keypress acts on.
			vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
			local held_cb
			gh_mod.list = function(...)
				held_cb = select(select("#", ...), ...)
			end
			case.open(mod)

			assert_true(
				buffer_text(mod.state.bufnr):find("REPO-A-ONLY", 1, true) == nil,
				("%s painted repo A's row in repo B: %q")
					:format(case.name, buffer_text(mod.state.bufnr))
			)
			assert_true(
				next(mod.state.line_entries) == nil,
				("%s left repo A's rows resolvable in repo B"):format(case.name)
			)
			assert_true(
				held_cb ~= nil,
				("%s should still kick a reconciling refetch"):format(case.name)
			)
		end)

		gh_mod.list = real_list
		vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
		mod.close()
		mod.state.cache = nil
		vim.fn.delete(repo_a, "rf")
		vim.fn.delete(repo_b, "rf")
		assert_true(ok, tostring(err))
	end)
end

-- ── a scope change while a fetch is in flight never paints its rows ──
-- The key was stamped from the scope the fetch was ISSUED under, but the
-- success path painted the cache directly: `:cd` during a load put repo A's
-- rows on screen, actionable, while `gh` already resolved repo B.

for _, case in ipairs(CASES) do
	test(("%s: rows landing after a cd are discarded and refetched"):format(
		case.name
	), function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local gh_mod = require(case.module)
		local real_list = gh_mod.list
		local original_cwd = vim.fn.getcwd()
		local repo_a, repo_b = vim.fn.tempname(), vim.fn.tempname()
		vim.fn.mkdir(repo_a, "p")
		vim.fn.mkdir(repo_b, "p")

		mod.close()
		mod.state.cache = nil

		local calls, held_cb = 0, nil
		local ok, err = pcall(function()
			vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
			gh_mod.list = function(...)
				calls = calls + 1
				held_cb = select(select("#", ...), ...)
			end
			case.open(mod)
			assert_true(
				held_cb ~= nil,
				("%s should have issued a fetch in repo A"):format(case.name)
			)

			-- Move while it is in flight, then let repo A's rows land.
			local release = held_cb
			held_cb = nil
			vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
			release(nil, { case.item(1, "REPO-A-ONLY") })

			assert_true(
				buffer_text(mod.state.bufnr):find("REPO-A-ONLY", 1, true) == nil,
				("%s painted repo A's row after moving to repo B: %q")
					:format(case.name, buffer_text(mod.state.bufnr))
			)
			assert_true(
				next(mod.state.line_entries) == nil,
				("%s left repo A's rows resolvable in repo B"):format(case.name)
			)
			assert_true(
				calls == 2 and held_cb ~= nil,
				("%s did not refetch under the new scope (%d fetches)")
					:format(case.name, calls)
			)
		end)

		gh_mod.list = real_list
		vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
		mod.close()
		mod.state.cache = nil
		vim.fn.delete(repo_a, "rf")
		vim.fn.delete(repo_b, "rf")
		assert_true(ok, tostring(err))
	end)
end

-- ── a failed refresh with rows already on screen still shows the failure ──
-- The error render used to be gated on an empty cache, so a failed refresh
-- with content painted nothing at all: no error state, no map invalidation,
-- and stale rows stayed actionable indefinitely.

for _, case in ipairs(CASES) do
	test(("%s: a failed refresh with rows on screen paints the error and drops them")
		:format(case.name), function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local gh_mod = require(case.module)
		local real_list = gh_mod.list
		local real_notify = require("gitflow.utils").notify
		require("gitflow.utils").notify = function() end

		mod.close()
		mod.state.cache = nil

		local ok, err = pcall(function()
			gh_mod.list = function(...)
				local cb = select(select("#", ...), ...)
				cb(nil, { case.item(1, "Live item") })
			end
			case.open(mod)
			assert_true(
				next(mod.state.line_entries) ~= nil,
				("%s should have actionable rows before the failure")
					:format(case.name)
			)

			gh_mod.list = function(...)
				local cb = select(select("#", ...), ...)
				cb("network error")
			end
			mod.refresh()

			local text = buffer_text(mod.state.bufnr)
			assert_true(
				text:find("Failed to load", 1, true) ~= nil,
				("%s hid a failed refresh behind stale rows: %q")
					:format(case.name, text)
			)
			assert_true(
				text:find("Live item", 1, true) == nil,
				("%s still shows rows from before the failed refresh")
					:format(case.name)
			)
			assert_true(
				next(mod.state.line_entries) == nil,
				("%s left rows resolvable after a failed refresh"):format(case.name)
			)
			assert_true(
				mod.state.cache == nil,
				("%s kept a cache a failed refresh could not confirm")
					:format(case.name)
			)
		end)

		gh_mod.list = real_list
		require("gitflow.utils").notify = real_notify
		mod.close()
		mod.state.cache = nil
		assert_true(ok, tostring(err))
	end)
end

-- ── `b` leaves view mode even when the list it returns to fails to load ──

---@type { name: string, module: string, item: fun(): table, stub_extra: (fun(gh_mod: table): fun())|nil }[]
local BACK_CASES = {
	{
		name = "prs",
		module = "gitflow.gh.prs",
		item = function()
			return { number = 5, title = "Detail PR", state = "open", body = "" }
		end,
		-- The PR detail only paints once its review comments land too.
		stub_extra = function(gh_mod)
			local real = gh_mod.review_comments
			gh_mod.review_comments = function(...)
				local cb = select(select("#", ...), ...)
				cb(nil, {})
			end
			return function()
				gh_mod.review_comments = real
			end
		end,
	},
	{
		name = "issues",
		module = "gitflow.gh.issues",
		item = function()
			return { number = 9, title = "Detail issue", state = "open", body = "" }
		end,
	},
}

for _, case in ipairs(BACK_CASES) do
	test(("%s: b leaves view mode even when the list fetch fails"):format(case.name),
		function()
			local modname = "gitflow.panels." .. case.name
			local mod = require(modname)
			local P = panel_object(modname)
			local gh_mod = require(case.module)
			local real_list, real_view = gh_mod.list, gh_mod.view
			local real_notify = require("gitflow.utils").notify
			local restore_extra = case.stub_extra and case.stub_extra(gh_mod)
			require("gitflow.utils").notify = function() end

			mod.close()
			mod.state.cache = nil

			local ok, err = pcall(function()
				-- Straight into the detail view, so no list cache exists.
				gh_mod.view = function(...)
					local cb = select(select("#", ...), ...)
					cb(nil, case.item())
				end
				mod.open_view(case.item().number, cfg)
				assert_true(
					mod.state.mode == "view",
					("%s should be in the detail view"):format(case.name)
				)

				gh_mod.list = function(...)
					local cb = select(select("#", ...), ...)
					cb("network error")
				end
				local back
				for _, entry in ipairs(P:keymap_entries("view")) do
					if entry.key == "b" then
						back = entry
					end
				end
				assert_true(back ~= nil, ("%s has no b binding"):format(case.name))
				back.run("b")

				assert_true(
					mod.state.mode == "list",
					("%s stayed in view mode after b, so r reopens the detail")
						:format(case.name)
				)
			end)

			gh_mod.list, gh_mod.view = real_list, real_view
			if restore_extra then
				restore_extra()
			end
			require("gitflow.utils").notify = real_notify
			mod.close()
			mod.state.cache = nil
			assert_true(ok, tostring(err))
		end)
end

-- ── pagination is off `n`, and tiered below the core verbs ──
-- `n` is vim's search-next in these read-only markdown buffers, and a narrow
-- float used to advertise two pagination keys while eliding merge/close-PR.

---@type { name: string, module: string }[]
local PAGINATION_KEY_CASES = {
	{ name = "prs", module = "gitflow.gh.prs" },
	{ name = "labels", module = "gitflow.gh.labels" },
}

for _, case in ipairs(PAGINATION_KEY_CASES) do
	test(("%s: pagination is not bound to n"):format(case.name), function()
		local modname = "gitflow.panels." .. case.name
		local mod = require(modname)
		local gh_mod = require(case.module)
		local real_list = gh_mod.list
		gh_mod.list = function(...)
			local cb = select(select("#", ...), ...)
			cb(nil, {})
		end

		local ok, err = pcall(function()
			mod.open(cfg)
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(mod.state.bufnr, "n")) do
				assert_true(
					map.lhs ~= "n",
					("%s binds n, shadowing vim's search-next"):format(case.name)
				)
			end
		end)

		gh_mod.list = real_list
		mod.close()
		mod.state.cache = nil
		assert_true(ok, tostring(err))
	end)
end

test("prs: a narrow hint bar keeps merge and drops pagination", function()
	local P = panel_object("gitflow.panels.prs")
	local footer = P:footer("list", 60)
	assert_true(
		footer:find("merge", 1, true) ~= nil,
		("a 60-column PR bar dropped merge: %q"):format(footer)
	)
	assert_true(
		footer:find("next page", 1, true) == nil,
		("a 60-column PR bar kept pagination over its core verbs: %q"):format(footer)
	)
end)

-- ── the GitHub state-change verbs are tagged destructive ──
-- Untagged, the base's destructive-first drop pass is a no-op: a cramped bar
-- keeps advertising `x close` while dropping the verbs it exists for.

---@type { panel: string, key: string }[]
local DESTRUCTIVE_HINTS = {
	{ panel = "prs", key = "x" },
	{ panel = "issues", key = "x" },
	{ panel = "labels", key = "d" },
}

for _, case in ipairs(DESTRUCTIVE_HINTS) do
	test(("%s: %s is tagged destructive, so a cramped bar drops it first")
		:format(case.panel, case.key), function()
		local P = panel_object("gitflow.panels." .. case.panel)
		local tagged = false
		for _, hint in ipairs(P:hints("list")) do
			if hint[1] == case.key then
				tagged = hint.destructive == true
			end
		end
		assert_true(
			tagged,
			("%s: %s is not marked destructive"):format(case.panel, case.key)
		)
		local narrow = P:footer("list", 60)
		assert_true(
			narrow:find(case.key .. " ", 1, true) == nil
				or narrow:find("close", 1, true) == nil,
			("%s kept its destructive verb on a 60-column bar: %q")
				:format(case.panel, narrow)
		)
	end)
end

print(("T3 github-panels tests: %d/%d passed"):format(passed, passed + failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
