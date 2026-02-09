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
			("%s (expected=%s, actual=%s)"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			),
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
	local ok = vim.wait(timeout_ms or 5000, predicate, 20)
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
		error(
			("git command failed (%s): %s"):format(table.concat(cmd, " "), output),
			2
		)
	end

	return output, code
end

local function write_file(path, lines)
	vim.fn.writefile(lines, path)
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

local function read_file(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.fn.readfile(path)
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

local repo_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(repo_dir, "p"), 1, "temp repo should be created")

run_git(repo_dir, { "init", "--initial-branch=main" })
run_git(repo_dir, { "config", "user.email", "stage6@example.com" })
run_git(repo_dir, { "config", "user.name", "Stage6 Tester" })

write_file(repo_dir .. "/shared.txt", { "base shared" })
write_file(repo_dir .. "/alt.txt", { "base alt" })
run_git(repo_dir, { "add", "shared.txt", "alt.txt" })
run_git(repo_dir, { "commit", "-m", "initial" })

run_git(repo_dir, { "checkout", "-b", "topic" })
write_file(repo_dir .. "/shared.txt", { "topic shared" })
write_file(repo_dir .. "/alt.txt", { "topic alt" })
run_git(repo_dir, { "add", "shared.txt", "alt.txt" })
run_git(repo_dir, { "commit", "-m", "topic changes" })

run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/shared.txt", { "main shared" })
write_file(repo_dir .. "/alt.txt", { "main alt" })
run_git(repo_dir, { "add", "shared.txt", "alt.txt" })
run_git(repo_dir, { "commit", "-m", "main changes" })

local previous_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)

run_git(repo_dir, { "merge", "topic" }, false)
assert_true(has_conflict(repo_dir, "shared.txt"), "shared conflict should exist")
assert_true(has_conflict(repo_dir, "alt.txt"), "alt conflict should exist")

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 47,
		},
	},
})

local conflict_mapping = vim.fn.maparg(cfg.keybindings.conflict, "n", false, true)
assert_true(
	type(conflict_mapping) == "table"
		and conflict_mapping.rhs == "<Plug>(GitflowConflict)",
	"default conflict keymap should map to conflict command"
)

local commands = require("gitflow.commands")
assert_true(
	contains(commands.complete(""), "conflict"),
	"subcommand completion should include conflict"
)

local conflict_panel = require("gitflow.panels.conflict")
local buffer = require("gitflow.ui.buffer")

commands.dispatch({ "conflict" }, cfg)
wait_until(function()
	local bufnr = buffer.get("conflict")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Gitflow Conflict Resolution") ~= nil
		and find_line(lines, "shared.txt") ~= nil
		and find_line(lines, "alt.txt") ~= nil
end, "conflict panel should render conflicted files")

local conflict_buf = buffer.get("conflict")
assert_true(conflict_buf ~= nil, "conflict panel should open")
assert_keymaps(conflict_buf, { "<CR>", "]c", "[c", "o", "t", "s", "A", "r", "q" })

assert_true(
	#conflict_panel.state.marker_lines >= 2,
	"conflict panel should index marker lines"
)
vim.api.nvim_set_current_win(conflict_panel.state.winid)
vim.api.nvim_win_set_cursor(conflict_panel.state.winid, { 1, 0 })

local first_marker_line = conflict_panel.state.marker_lines[1]
local last_marker_line = conflict_panel.state.marker_lines[#conflict_panel.state.marker_lines]
conflict_panel.next_marker()
assert_equals(
	vim.api.nvim_win_get_cursor(conflict_panel.state.winid)[1],
	first_marker_line,
	"next_marker should jump to first marker"
)
conflict_panel.prev_marker()
assert_equals(
	vim.api.nvim_win_get_cursor(conflict_panel.state.winid)[1],
	last_marker_line,
	"prev_marker should wrap to last marker"
)

local open_line = conflict_panel.state.marker_lines[1]
local open_entry = conflict_panel.state.line_entries[open_line]
assert_true(open_entry ~= nil, "marker entry should exist")

local function file_for_path(path)
	for _, file_entry in ipairs(conflict_panel.state.files) do
		if file_entry.path == path then
			return file_entry
		end
	end
	return nil
end

local open_file = file_for_path(open_entry.path)
assert_true(open_file ~= nil, "selected marker should resolve file entry")
local open_marker = open_file.markers[open_entry.marker_index]
assert_true(open_marker ~= nil, "selected marker should exist")

local window_count_before = #vim.api.nvim_list_wins()
vim.api.nvim_win_set_cursor(conflict_panel.state.winid, { open_line, 0 })
conflict_panel.open_under_cursor()
wait_until(function()
	return #vim.api.nvim_list_wins() == window_count_before + 1
end, "opening a conflicted file should create a split")

local opened_cursor = vim.api.nvim_win_get_cursor(0)
assert_equals(
	opened_cursor[1],
	open_marker.start_line,
	"open_under_cursor should jump to marker line"
)
vim.api.nvim_win_close(0, true)
vim.api.nvim_set_current_win(conflict_panel.state.winid)

local panel_lines = vim.api.nvim_buf_get_lines(conflict_buf, 0, -1, false)
local shared_line = find_line(panel_lines, "shared.txt")
assert_true(shared_line ~= nil, "shared file should be listed")
vim.api.nvim_win_set_cursor(conflict_panel.state.winid, { shared_line, 0 })
conflict_panel.accept_ours_under_cursor()
wait_until(function()
	return vim.deep_equal(read_file(repo_dir .. "/shared.txt"), { "main shared" })
end, "accept ours should apply main branch content")

panel_lines = vim.api.nvim_buf_get_lines(conflict_buf, 0, -1, false)
local alt_line = find_line(panel_lines, "alt.txt")
assert_true(alt_line ~= nil, "alt file should be listed")
vim.api.nvim_win_set_cursor(conflict_panel.state.winid, { alt_line, 0 })
conflict_panel.accept_theirs_under_cursor()
wait_until(function()
	return vim.deep_equal(read_file(repo_dir .. "/alt.txt"), { "topic alt" })
end, "accept theirs should apply topic branch content")

conflict_panel.stage_all()
wait_until(function()
	return not has_conflict(repo_dir, "shared.txt")
		and not has_conflict(repo_dir, "alt.txt")
end, "stage_all should resolve and stage all conflicted files")

wait_until(function()
	local lines = vim.api.nvim_buf_get_lines(conflict_buf, 0, -1, false)
	return find_line(lines, "Conflicted files: 0") ~= nil
		and find_line(lines, "  (none)") ~= nil
end, "panel should show no remaining conflicts after stage_all")

conflict_panel.close()
assert_true(not conflict_panel.is_open(), "conflict panel should close cleanly")

vim.fn.chdir(previous_cwd)
print("Stage 6 smoke tests passed")
