-- scripts/test_confirm_gates.lua — every destructive verb asks first, and
-- declining does nothing at all.
--
-- "Confirms" is only half the contract: a prompt that runs the operation
-- anyway, or that half-runs it before the answer lands, is worse than no
-- prompt. So each case here drives the verb with the confirm answering NO and
-- asserts the underlying git/gh/store call was never made — then answers YES
-- and asserts it was, so the gate cannot be satisfied by breaking the verb.
--
-- Covers the gates this change added or moved:
--   * branch `d` on an already-merged branch (previously deleted with no ask)
--   * issues `D` delete saved view (previously wrote the file on selection)
--   * stash `D` drop (moved onto ui.input.confirm so it is stubbable at all)

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

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(
				message, vim.inspect(expected), vim.inspect(actual)
			),
			2
		)
	end
end

print("Confirm gate tests")
print("==================")

local gitflow = require("gitflow")
local cfg = gitflow.setup({})
local input = require("gitflow.ui.input")

---Run `fn` with `ui.input.confirm` answering `answer`, restoring it after.
---@param answer boolean
---@param fn fun()
---@return string[]  the messages the verb prompted with
local function with_confirm(answer, fn)
	local real = input.confirm
	local prompts = {}
	input.confirm = function(message)
		prompts[#prompts + 1] = message
		return answer, answer and 1 or 2
	end
	local ok, err = pcall(fn)
	input.confirm = real
	if not ok then
		error(err, 0)
	end
	return prompts
end

---Put a panel's buffer under the cursor with one entry on line 1, so the
---panel's `entry_under_cursor` resolves without a real repository behind it.
---@param state table
---@param entry table
local function seed_cursor_entry(state, entry)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "entry" })
	vim.api.nvim_win_set_buf(0, bufnr)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	state.bufnr = bufnr
	state.line_entries = { [1] = entry }
	return bufnr
end

-- ── branch: deleting an already-merged branch ─────────────────────────

test("branch d on a merged branch confirms, and declining deletes nothing", function()
	local branch = require("gitflow.panels.branch")
	local git_branch = require("gitflow.git.branch")

	local real_list_merged, real_delete = git_branch.list_merged, git_branch.delete
	local deleted = {}
	git_branch.list_merged = function(_, cb)
		cb(nil, { ["feature/done"] = true })
	end
	git_branch.delete = function(name, force)
		deleted[#deleted + 1] = { name = name, force = force }
	end

	branch.state.cfg = cfg
	branch.state.view_mode = "list"
	seed_cursor_entry(branch.state, {
		name = "feature/done", is_remote = false, is_current = false,
	})

	local prompts = with_confirm(false, function()
		branch.delete_under_cursor(false)
	end)
	assert_equals(#prompts, 1, "a merged branch delete should ask first")
	assert_true(
		prompts[1]:find("feature/done", 1, true) ~= nil,
		"the prompt should name the branch"
	)
	assert_equals(#deleted, 0, "declining must not delete the branch")

	with_confirm(true, function()
		branch.delete_under_cursor(false)
	end)
	assert_equals(#deleted, 1, "accepting should delete the branch")
	assert_equals(deleted[1].name, "feature/done", "the named branch is deleted")

	git_branch.list_merged, git_branch.delete = real_list_merged, real_delete
	branch.state.bufnr = nil
	branch.state.line_entries = {}
end)

-- ── stash: dropping an entry ──────────────────────────────────────────

test("stash D confirms, and declining drops nothing", function()
	local stash = require("gitflow.panels.stash")
	local git_stash = require("gitflow.git.stash")

	local real_drop = git_stash.drop
	local dropped = {}
	git_stash.drop = function(index)
		dropped[#dropped + 1] = index
	end

	stash.state.cfg = cfg
	seed_cursor_entry(stash.state, { index = 0, ref = "stash@{0}" })

	local prompts = with_confirm(false, function()
		stash.drop_under_cursor()
	end)
	assert_equals(#prompts, 1, "dropping a stash should ask first")
	assert_true(
		prompts[1]:find("stash@{0}", 1, true) ~= nil,
		"the prompt should name the stash entry"
	)
	assert_equals(#dropped, 0, "declining must not drop the stash")

	with_confirm(true, function()
		stash.drop_under_cursor()
	end)
	assert_equals(#dropped, 1, "accepting should drop the stash")

	git_stash.drop = real_drop
	stash.state.bufnr = nil
	stash.state.line_entries = {}
end)

-- ── issues: deleting a saved view ─────────────────────────────────────

test("issues D confirms, and declining writes nothing", function()
	local issues = require("gitflow.panels.issues")
	local views_store = require("gitflow.issues.views")
	local list_picker = require("gitflow.ui.list_picker")

	local real_load, real_save = views_store.load, views_store.save
	local real_open = list_picker.open
	local saves = {}
	views_store.load = function()
		return {
			{
				name = "mine",
				filters = { state = "open" },
				sort = { key = "created", direction = "desc" },
			},
		}
	end
	views_store.save = function(views)
		saves[#saves + 1] = views
		return true
	end
	-- The picker is the selection, not the confirmation: submit immediately.
	list_picker.open = function(opts)
		opts.on_submit({ "mine" })
	end

	issues.state.cfg = cfg

	local prompts = with_confirm(false, function()
		issues.delete_view()
	end)
	assert_equals(#prompts, 1, "deleting a saved view should ask first")
	assert_true(
		prompts[1]:find("mine", 1, true) ~= nil,
		"the prompt should name the view"
	)
	assert_equals(#saves, 0, "declining must not rewrite the saved-views file")

	with_confirm(true, function()
		issues.delete_view()
	end)
	assert_equals(#saves, 1, "accepting should rewrite the saved-views file")

	views_store.load, views_store.save = real_load, real_save
	list_picker.open = real_open
end)

-- ── the registry says which verbs owe a gate ──────────────────────────

test("every destructive verb is reachable from a panel that registers it", function()
	local panel = require("gitflow.ui.panel")
	for _, path in ipairs(vim.fn.glob(project_root .. "/lua/gitflow/panels/*.lua", false, true)) do
		require("gitflow.panels." .. vim.fn.fnamemodify(path, ":t:r"))
	end

	local destructive = 0
	for _, surface in ipairs(panel.surfaces()) do
		for _, entry in ipairs(surface.keymaps) do
			if entry.destructive then
				destructive = destructive + 1
				assert_true(
					type(entry.run) == "function",
					("%s: %s is flagged destructive but binds nothing"):format(
						surface.name, entry.key
					)
				)
			end
		end
	end
	assert_true(destructive >= 10, "the destructive tier should not have emptied out")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
