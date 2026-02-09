local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(message, vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

local function assert_deep_equals(actual, expected, message)
	if not vim.deep_equal(actual, expected) then
		error(
			("%s (expected=%s, actual=%s)"):format(message, vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

local function contains(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

local function wait_until(predicate, message, timeout_ms)
	local ok = vim.wait(timeout_ms or 6000, predicate, 20)
	assert_true(ok, message)
end

local function run_git(repo_dir, args, should_succeed)
	local cmd = { "git" }
	vim.list_extend(cmd, args)

	local output = ""
	local code = 1
	if vim.system then
		local result = vim.system(cmd, { cwd = repo_dir, text = true }):wait()
		output = (result.stdout or "") .. (result.stderr or "")
		code = result.code or 1
	else
		local previous = vim.fn.getcwd()
		vim.fn.chdir(repo_dir)
		output = vim.fn.system(cmd)
		code = vim.v.shell_error
		vim.fn.chdir(previous)
	end

	if should_succeed == nil then
		should_succeed = true
	end
	if should_succeed and code ~= 0 then
		error(("git command failed (%s): %s"):format(table.concat(cmd, " "), output), 2)
	end

	return output, code
end

local function write_file(path, lines)
	vim.fn.writefile(lines, path)
end

local function read_file(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.fn.readfile(path)
end

local function find_line(lines, needle, start_line)
	local from = start_line or 1
	for i = from, #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function assert_keymaps(bufnr, required)
	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	local missing = {}
	for _, lhs in ipairs(required) do
		missing[lhs] = true
	end
	for _, map in ipairs(keymaps) do
		if missing[map.lhs] ~= nil then
			missing[map.lhs] = nil
		end
	end
	for lhs, _ in pairs(missing) do
		error(("missing keymap '%s'"):format(lhs), 2)
	end
end

local function has_conflict(repo_dir, path)
	local output = run_git(repo_dir, { "diff", "--name-only", "--diff-filter=U" }, false)
	if not path then
		return vim.trim(output) ~= ""
	end
	return output:find(path, 1, true) ~= nil
end

local function marker_count(path)
	local total = 0
	for _, line in ipairs(read_file(path)) do
		if vim.startswith(line, "<<<<<<<") then
			total = total + 1
		end
	end
	return total
end

local function in_merge(repo_dir)
	local git_dir = vim.trim(run_git(repo_dir, { "rev-parse", "--git-dir" }))
	return vim.fn.filereadable(repo_dir .. "/" .. git_dir .. "/MERGE_HEAD") == 1
end

local function in_rebase(repo_dir)
	local git_dir = vim.trim(run_git(repo_dir, { "rev-parse", "--git-dir" }))
	local full = repo_dir .. "/" .. git_dir
	return vim.fn.isdirectory(full .. "/rebase-merge") == 1
		or vim.fn.isdirectory(full .. "/rebase-apply") == 1
end

local function in_cherry_pick(repo_dir)
	local git_dir = vim.trim(run_git(repo_dir, { "rev-parse", "--git-dir" }))
	return vim.fn.filereadable(repo_dir .. "/" .. git_dir .. "/CHERRY_PICK_HEAD") == 1
end

local repo_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(repo_dir, "p"), 1, "temp repo should be created")

run_git(repo_dir, { "init", "--initial-branch=main" })
run_git(repo_dir, { "config", "user.email", "stage6@example.com" })
run_git(repo_dir, { "config", "user.name", "Stage6 Tester" })
run_git(repo_dir, { "config", "merge.conflictStyle", "diff3" })

write_file(repo_dir .. "/choose-local.txt", { "local base" })
write_file(repo_dir .. "/choose-base.txt", { "base base" })
write_file(repo_dir .. "/choose-remote.txt", { "remote base" })
write_file(repo_dir .. "/abort.txt", { "abort base" })
run_git(repo_dir, {
	"add",
	"choose-local.txt",
	"choose-base.txt",
	"choose-remote.txt",
	"abort.txt",
})
run_git(repo_dir, { "commit", "-m", "initial" })

run_git(repo_dir, { "checkout", "-b", "topic" })
write_file(repo_dir .. "/choose-local.txt", { "local topic" })
write_file(repo_dir .. "/choose-base.txt", { "base topic" })
write_file(repo_dir .. "/choose-remote.txt", { "remote topic" })
write_file(repo_dir .. "/abort.txt", { "abort topic" })
run_git(repo_dir, {
	"add",
	"choose-local.txt",
	"choose-base.txt",
	"choose-remote.txt",
	"abort.txt",
})
run_git(repo_dir, { "commit", "-m", "topic changes" })

run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/choose-local.txt", { "local main" })
write_file(repo_dir .. "/choose-base.txt", { "base main" })
write_file(repo_dir .. "/choose-remote.txt", { "remote main" })
write_file(repo_dir .. "/abort.txt", { "abort main" })
run_git(repo_dir, {
	"add",
	"choose-local.txt",
	"choose-base.txt",
	"choose-remote.txt",
	"abort.txt",
})
run_git(repo_dir, { "commit", "-m", "main changes" })

local previous_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)
vim.env.GIT_EDITOR = ":"

local original_confirm = vim.fn.confirm
vim.fn.confirm = function()
	return 1
end

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 46,
		},
	},
})

local commands = require("gitflow.commands")
local conflict_panel = require("gitflow.panels.conflict")
local conflict_view = require("gitflow.ui.conflict")
local status_panel = require("gitflow.panels.status")
local buffer = require("gitflow.ui.buffer")

local mapping = vim.fn.maparg(cfg.keybindings.conflict, "n", false, true)
assert_true(
	type(mapping) == "table" and mapping.rhs == "<Plug>(GitflowConflicts)",
	"default conflict keymap should map to plural conflicts command"
)

assert_true(
	contains(commands.complete(""), "conflicts"),
	"subcommand completion should include conflicts"
)

local merge_flag_completion = commands.complete("--", "Gitflow merge --", 0)
assert_true(
	contains(merge_flag_completion, "--abort"),
	"merge completion should include --abort flag"
)

commands.dispatch({ "merge", "topic" }, cfg)
wait_until(function()
	return has_conflict(repo_dir, "choose-local.txt")
		and has_conflict(repo_dir, "choose-base.txt")
		and has_conflict(repo_dir, "choose-remote.txt")
		and has_conflict(repo_dir, "abort.txt")
end, "merge should create conflict entries")

wait_until(function()
	if not conflict_panel.is_open() then
		return false
	end

	local bufnr = buffer.get("conflict")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Gitflow Conflicts") ~= nil
		and find_line(lines, "Active operation: merge") ~= nil
		and find_line(lines, "choose-local.txt") ~= nil
		and find_line(lines, "choose-base.txt") ~= nil
		and find_line(lines, "choose-remote.txt") ~= nil
		and find_line(lines, "abort.txt") ~= nil
end, "merge conflict should auto-open conflict panel")

local conflict_buf = buffer.get("conflict")
assert_true(conflict_buf ~= nil, "conflict panel buffer should exist")
assert_keymaps(conflict_buf, { "<CR>", "r", "R", "C", "A", "q" })

local asserted_view_shape = false

---@param path string
---@param side "local"|"base"|"remote"
---@param expected string
local function resolve_single_file(path, side, expected)
	local lines = vim.api.nvim_buf_get_lines(conflict_buf, 0, -1, false)
	local file_line = find_line(lines, path)
	assert_true(file_line ~= nil, ("'%s' should be listed in conflict panel"):format(path))

	vim.api.nvim_set_current_win(conflict_panel.state.winid)
	vim.api.nvim_win_set_cursor(conflict_panel.state.winid, { file_line, 0 })
	conflict_panel.open_under_cursor()

	wait_until(function()
		return conflict_view.is_open() and conflict_view.state.path == path
	end, ("conflict view should open for %s"):format(path))

	if not asserted_view_shape then
		local current_tab = vim.api.nvim_get_current_tabpage()
		assert_equals(
			#vim.api.nvim_tabpage_list_wins(current_tab),
			4,
			"3-way view should create three top panes and merged pane"
		)

		local merged_buf = conflict_view.state.merged_bufnr
		assert_true(merged_buf ~= nil, "merged buffer should be created")
		assert_keymaps(merged_buf, { "1", "2", "3", "a", "e", "]x", "[x", "q" })
		asserted_view_shape = true
	end

	vim.api.nvim_set_current_win(conflict_view.state.merged_winid)
	vim.api.nvim_win_set_cursor(
		conflict_view.state.merged_winid,
		{ conflict_view.state.hunks[1].start_line, 0 }
	)
	conflict_view.resolve_current(side)

	wait_until(function()
		return marker_count(repo_dir .. "/" .. path) == 0 and not has_conflict(repo_dir, path)
	end, ("resolution action should clear conflict markers in %s"):format(path))

	assert_deep_equals(
		read_file(repo_dir .. "/" .. path),
		{ expected },
		("resolved content for %s should match selected side"):format(path)
	)

	if conflict_view.is_open() then
		conflict_view.close()
	end
end

resolve_single_file("choose-local.txt", "local", "local main")
resolve_single_file("choose-base.txt", "base", "base base")
resolve_single_file("choose-remote.txt", "remote", "remote topic")

commands.dispatch({ "status" }, cfg)
wait_until(function()
	if not status_panel.is_open() then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(status_panel.state.bufnr, 0, -1, false)
	return find_line(lines, "abort.txt") ~= nil and find_line(lines, "UU  abort.txt") ~= nil
end, "status panel should display unresolved UU entry")

local status_lines = vim.api.nvim_buf_get_lines(status_panel.state.bufnr, 0, -1, false)
local abort_line = find_line(status_lines, "UU  abort.txt")
assert_true(abort_line ~= nil, "abort conflict should be selectable from status panel")
vim.api.nvim_set_current_win(status_panel.state.winid)
vim.api.nvim_win_set_cursor(status_panel.state.winid, { abort_line, 0 })
status_panel.open_conflict_under_cursor()

wait_until(function()
	return conflict_view.is_open() and conflict_view.state.path == "abort.txt"
end, "status cx action should open conflict view for UU file")

vim.api.nvim_set_current_win(conflict_view.state.merged_winid)
vim.api.nvim_win_set_cursor(
	conflict_view.state.merged_winid,
	{ conflict_view.state.hunks[1].start_line, 0 }
)
conflict_view.edit_current_hunk()
vim.api.nvim_buf_set_lines(
	conflict_view.state.merged_bufnr,
	0,
	-1,
	false,
	{ "abort manual resolution" }
)
conflict_view.refresh()

wait_until(function()
	return vim.deep_equal(read_file(repo_dir .. "/abort.txt"), { "abort manual resolution" })
		and not has_conflict(repo_dir, "abort.txt")
end, "manual edit path should resolve and persist conflict content")

if conflict_view.is_open() then
	conflict_view.close()
end

wait_until(function()
	local lines = vim.api.nvim_buf_get_lines(conflict_buf, 0, -1, false)
	return find_line(lines, "Unresolved files: 0") ~= nil
end, "conflict panel should refresh when all files are resolved")

wait_until(function()
	return not in_merge(repo_dir)
end, "resolved merge should prompt and continue automatically")

run_git(repo_dir, { "checkout", "-b", "abort-topic" })
write_file(repo_dir .. "/abort-merge.txt", { "abort topic value" })
run_git(repo_dir, { "add", "abort-merge.txt" })
run_git(repo_dir, { "commit", "-m", "abort topic change" })

run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/abort-merge.txt", { "abort main value" })
run_git(repo_dir, { "add", "abort-merge.txt" })
run_git(repo_dir, { "commit", "-m", "abort main change" })

commands.dispatch({ "merge", "abort-topic" }, cfg)
wait_until(function()
		return has_conflict(repo_dir, "abort-merge.txt")
			and in_merge(repo_dir)
			and conflict_panel.is_open()
end, "merge conflict for abort flow should open panel")

commands.dispatch({ "merge", "--abort" }, cfg)
wait_until(function()
	return not in_merge(repo_dir)
		and not has_conflict(repo_dir, "abort-merge.txt")
		and not conflict_panel.is_open()
end, "merge --abort should clear conflict state and close conflict panel")
assert_deep_equals(
	read_file(repo_dir .. "/abort-merge.txt"),
	{ "abort main value" },
	"abort should restore pre-merge working tree content"
)

write_file(repo_dir .. "/rebase-file.txt", { "rebase base" })
run_git(repo_dir, { "add", "rebase-file.txt" })
run_git(repo_dir, { "commit", "-m", "rebase base" })

run_git(repo_dir, { "checkout", "-b", "rebase-topic" })
write_file(repo_dir .. "/rebase-file.txt", { "rebase topic" })
run_git(repo_dir, { "add", "rebase-file.txt" })
run_git(repo_dir, { "commit", "-m", "rebase topic change" })

run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/rebase-file.txt", { "rebase main" })
run_git(repo_dir, { "add", "rebase-file.txt" })
run_git(repo_dir, { "commit", "-m", "rebase main change" })

run_git(repo_dir, { "checkout", "rebase-topic" })
commands.dispatch({ "rebase", "main" }, cfg)
wait_until(function()
		return in_rebase(repo_dir)
			and has_conflict(repo_dir, "rebase-file.txt")
			and conflict_panel.is_open()
end, "rebase conflicts should auto-open conflict panel")

commands.dispatch({ "rebase", "--abort" }, cfg)
wait_until(function()
	return not in_rebase(repo_dir) and not conflict_panel.is_open()
end, "rebase --abort should close conflict panel")

run_git(repo_dir, { "checkout", "main" })
run_git(repo_dir, { "checkout", "-b", "cherry-source" })
write_file(repo_dir .. "/cherry-file.txt", { "cherry topic" })
run_git(repo_dir, { "add", "cherry-file.txt" })
run_git(repo_dir, { "commit", "-m", "cherry source change" })
local cherry_sha = vim.trim(run_git(repo_dir, { "rev-parse", "HEAD" }))

run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/cherry-file.txt", { "cherry main" })
run_git(repo_dir, { "add", "cherry-file.txt" })
run_git(repo_dir, { "commit", "-m", "cherry main change" })

commands.dispatch({ "cherry-pick", cherry_sha }, cfg)
wait_until(function()
	return in_cherry_pick(repo_dir)
		and has_conflict(repo_dir, "cherry-file.txt")
		and conflict_panel.is_open()
end, "cherry-pick conflicts should auto-open conflict panel")

conflict_panel.abort_operation()
wait_until(function()
	return not in_cherry_pick(repo_dir) and not has_conflict(repo_dir, "cherry-file.txt")
end, "abort operation should clear cherry-pick conflict state")

commands.dispatch({ "conflicts" }, cfg)
wait_until(function()
	return conflict_panel.is_open()
end, ":Gitflow conflicts should be invokable directly")

commands.dispatch({ "close" }, cfg)

vim.fn.confirm = original_confirm
vim.fn.chdir(previous_cwd)

print("Stage 6 smoke tests passed")
