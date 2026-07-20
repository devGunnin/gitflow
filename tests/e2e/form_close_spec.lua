-- tests/e2e/form_close_spec.lua — form/picker cleanup on every close route
--
-- Run:
--   nvim --headless -u tests/minimal_init.lua -l tests/e2e/form_close_spec.lua
--
-- Verifies:
--   1. A typed form draft is stashed no matter how the float closes — the
--      plugin's own q bind, :q!, :bd! or a layout change — not only via q
--   2. on_cancel fires exactly ONCE per close route for the form and both
--      pickers, and not at all when the user submits
--   3. The global 'completeopt' the form borrows is restored on every route,
--      including a refused open
--   4. A terminal too small for a usable float degrades to nil, not a crash

local T = _G.T

local form = require("gitflow.ui.form")
local list_picker = require("gitflow.ui.list_picker")
local label_picker = require("gitflow.ui.label_picker")

---@param columns integer
---@param lines integer
---@param fn fun()
local function with_screen(columns, lines, fn)
	local saved_columns, saved_lines = vim.o.columns, vim.o.lines
	vim.o.columns, vim.o.lines = columns, lines
	local ok, err = pcall(fn)
	vim.o.columns, vim.o.lines = saved_columns, saved_lines
	if not ok then
		error(err, 0)
	end
end

--- The close routes a user can reach that bypass the plugin's own q bind.
--- `:q` (no bang) is deliberately absent: the form buffer is `acwrite` and
--- always modified once rendered, so Neovim answers plain `:q` with E37 and
--- the user reaches for one of these instead.
local HOOK_ROUTES = {
	["quit!"] = function(winid, _)
		vim.api.nvim_win_call(winid, function()
			vim.cmd("quit!")
		end)
	end,
	["layout change"] = function(winid, _)
		vim.api.nvim_win_close(winid, true)
	end,
	["buffer delete"] = function(_, bufnr)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end,
}

---@param winid integer
---@param keys string
local function press_in(winid, keys)
	vim.api.nvim_set_current_win(winid)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false
	)
end

--- Open a one-field form and type `text` into its value row.
---@param draft_key string
---@param text string
---@param on_cancel fun()|nil
---@return table state
local function open_typed_form(draft_key, text, on_cancel)
	form._drafts[draft_key] = nil
	local state = form.open({
		title = "Close Route",
		fields = { { name = "Title", key = "title" } },
		draft_key = draft_key,
		on_submit = function() end,
		on_cancel = on_cancel,
	})
	T.assert_true(state ~= nil and state.winid ~= nil, "form should open")
	-- Row 3 (0-indexed 2) is the single field's value row.
	vim.api.nvim_buf_set_lines(state.bufnr, 2, 3, false, { text })
	return state
end

---@param state table|nil
local function force_close(state)
	if not state then
		return
	end
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		pcall(vim.api.nvim_win_close, state.winid, true)
	end
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
	end
end

T.run_suite("E2E: Form and picker close routes", {
	-- ── 1. drafts survive every close route ──────────────────────────

	["a typed draft survives every close route, not just the q bind"] = function()
		for route, close in pairs(HOOK_ROUTES) do
			local key = "test:form:draft:" .. route
			local state = open_typed_form(key, "draft via " .. route)
			close(state.winid, state.bufnr)
			vim.wait(50, function()
				return false
			end, 10)
			T.assert_true(
				form._drafts[key] ~= nil,
				("closing via %s must stash the draft, not discard it"):format(route)
			)
			T.assert_equals(
				form._drafts[key].title,
				"draft via " .. route,
				("the draft stashed on %s must be the typed text"):format(route)
			)
			form._drafts[key] = nil
		end
	end,

	["a draft stashed on an abnormal close is restored on reopen"] = function()
		local key = "test:form:draft:reopen"
		local state = open_typed_form(key, "resume me")
		vim.api.nvim_win_close(state.winid, true)
		vim.wait(50, function()
			return false
		end, 10)

		local reopened = form.open({
			title = "Close Route",
			fields = { { name = "Title", key = "title" } },
			draft_key = key,
			on_submit = function() end,
		})
		T.assert_true(reopened ~= nil, "reopen should succeed")
		T.assert_equals(
			vim.api.nvim_buf_get_lines(reopened.bufnr, 2, 3, false)[1],
			"resume me",
			"reopening the form must restore the stashed draft"
		)
		force_close(reopened)
		form._drafts[key] = nil
	end,

	-- ── 2. on_cancel fires exactly once ──────────────────────────────

	["form on_cancel fires exactly once per close route"] = function()
		for route, close in pairs(HOOK_ROUTES) do
			local calls = 0
			local key = "test:form:cancel:" .. route
			local state = open_typed_form(key, "x", function()
				calls = calls + 1
			end)
			close(state.winid, state.bufnr)
			vim.wait(50, function()
				return false
			end, 10)
			T.assert_equals(
				calls, 1, ("on_cancel must fire exactly once for %s"):format(route)
			)
			form._drafts[key] = nil
		end
	end,

	["form on_cancel fires once via the q bind and stays latched"] = function()
		local calls = 0
		local key = "test:form:cancel:qbind"
		local state = open_typed_form(key, "x", function()
			calls = calls + 1
		end)
		local winid = state.winid
		press_in(winid, "q")
		vim.wait(50, function()
			return false
		end, 10)
		T.assert_equals(calls, 1, "the q bind must fire on_cancel exactly once")
		T.assert_false(
			vim.api.nvim_win_is_valid(winid), "the q bind must close the float"
		)
		form._drafts[key] = nil
	end,

	["submitting a form neither cancels nor leaves a draft"] = function()
		local key = "test:form:submit"
		local cancelled, submitted = 0, nil
		form._drafts[key] = nil
		local state = form.open({
			title = "Close Route",
			fields = { { name = "Title", key = "title" } },
			draft_key = key,
			on_submit = function(values)
				submitted = values.title
			end,
			on_cancel = function()
				cancelled = cancelled + 1
			end,
		})
		vim.api.nvim_buf_set_lines(state.bufnr, 2, 3, false, { "shipped" })
		press_in(state.winid, "<CR>")
		vim.wait(50, function()
			return false
		end, 10)

		T.assert_equals(submitted, "shipped", "submit should deliver the typed value")
		T.assert_equals(cancelled, 0, "a submitted form must not also cancel")
		T.assert_true(
			form._drafts[key] == nil, "a submitted form must not leave a draft behind"
		)
	end,

	["list picker on_cancel fires exactly once per close route"] = function()
		for route, close in pairs(HOOK_ROUTES) do
			local calls = 0
			local state = list_picker.open({
				title = "Pick",
				items = { "alpha", "beta" },
				on_submit = function() end,
				on_cancel = function()
					calls = calls + 1
				end,
			})
			T.assert_true(state ~= nil, "list picker should open")
			close(state.winid, state.bufnr)
			vim.wait(50, function()
				return false
			end, 10)
			T.assert_equals(
				calls, 1,
				("list picker on_cancel must fire exactly once for %s"):format(route)
			)
		end
	end,

	["label picker on_cancel fires exactly once per close route"] = function()
		for route, close in pairs(HOOK_ROUTES) do
			local calls = 0
			local state = label_picker.open({
				title = "Labels",
				labels = { { name = "bug" }, { name = "chore" } },
				on_submit = function() end,
				on_cancel = function()
					calls = calls + 1
				end,
			})
			T.assert_true(state ~= nil, "label picker should open")
			close(state.winid, state.bufnr)
			vim.wait(50, function()
				return false
			end, 10)
			T.assert_equals(
				calls, 1,
				("label picker on_cancel must fire exactly once for %s"):format(route)
			)
		end
	end,

	["a picker cancelled by its q bind fires on_cancel exactly once"] = function()
		for _, picker in ipairs({
			{ name = "list", open = function(on_cancel)
				return list_picker.open({
					title = "Pick",
					items = { "alpha", "beta" },
					on_submit = function() end,
					on_cancel = on_cancel,
				})
			end },
			{ name = "label", open = function(on_cancel)
				return label_picker.open({
					title = "Labels",
					labels = { { name = "bug" } },
					on_submit = function() end,
					on_cancel = on_cancel,
				})
			end },
		}) do
			local calls = 0
			local state = picker.open(function()
				calls = calls + 1
			end)
			press_in(state.winid, "q")
			vim.wait(50, function()
				return false
			end, 10)
			T.assert_equals(
				calls, 1,
				("%s picker q bind must fire on_cancel exactly once"):format(picker.name)
			)
		end
	end,

	["submitting a picker does not fire on_cancel"] = function()
		local cancelled, selected = 0, nil
		local state = list_picker.open({
			title = "Pick",
			items = { "alpha", "beta" },
			multi_select = false,
			on_submit = function(selections)
				selected = selections[1]
			end,
			on_cancel = function()
				cancelled = cancelled + 1
			end,
		})
		press_in(state.winid, "<CR>")
		vim.wait(50, function()
			return false
		end, 10)
		T.assert_true(selected ~= nil, "picker submit should deliver a selection")
		T.assert_equals(cancelled, 0, "a submitted picker must not also cancel")
	end,

	-- ── 3. the borrowed global option is given back ──────────────────

	["completeopt is restored after every form close route"] = function()
		local original = vim.o.completeopt
		for route, close in pairs(HOOK_ROUTES) do
			local key = "test:form:completeopt:" .. route
			local state = open_typed_form(key, "x")
			T.assert_true(
				vim.o.completeopt ~= original,
				"the open form should be borrowing completeopt"
			)
			close(state.winid, state.bufnr)
			vim.wait(50, function()
				return false
			end, 10)
			T.assert_equals(
				vim.o.completeopt, original,
				("completeopt must be restored after %s"):format(route)
			)
			form._drafts[key] = nil
		end
	end,

	-- ── 4. a refused float degrades cleanly ──────────────────────────

	["a terminal too small yields nil instead of a broken window"] = function()
		local original = vim.o.completeopt
		local results = {}
		with_screen(12, 4, function()
			results.form = form.open({
				title = "Tiny",
				fields = { { name = "Title", key = "title" } },
				draft_key = "test:form:tiny",
				on_submit = function() end,
			})
			results.list = list_picker.open({
				title = "Tiny",
				items = { "alpha" },
				on_submit = function() end,
			})
			results.label = label_picker.open({
				title = "Tiny",
				labels = { { name = "bug" } },
				on_submit = function() end,
			})
		end)

		T.assert_true(results.form == nil, "form.open should refuse a tiny terminal")
		T.assert_true(results.list == nil, "list_picker.open should refuse a tiny terminal")
		T.assert_true(results.label == nil, "label_picker.open should refuse a tiny terminal")
		T.assert_equals(
			vim.o.completeopt, original,
			"a refused form must not leave completeopt clobbered"
		)
	end,
})

print("E2E form/picker close-route tests passed")
