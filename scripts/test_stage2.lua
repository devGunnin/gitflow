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

local unpack_fn = table.unpack or unpack

local function wait_async(start, timeout_ms)
	local done = false
	local result = nil

	start(function(...)
		result = { ... }
		done = true
	end)

	local ok = vim.wait(timeout_ms or 5000, function()
		return done
	end, 10)
	assert_true(ok, "async callback timed out")
	return unpack_fn(result)
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

local function assert_mapping(lhs, expected_rhs, message)
	local mapping = vim.fn.maparg(lhs, "n", false, true)
	assert_true(type(mapping) == "table" and mapping.rhs == expected_rhs, message)
end

local function find_line(lines, needle, start_line)
	local start_idx = start_line or 1
	for i = start_idx, #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function current_branch(repo_dir)
	return vim.trim(run_git(repo_dir, { "rev-parse", "--abbrev-ref", "HEAD" }))
end

local function find_line_in_range(lines, needle, start_line, end_line)
	local start_idx = start_line or 1
	local end_idx = math.min(end_line or #lines, #lines)
	for i = start_idx, end_idx do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local repo_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(repo_dir, "p"), 1, "temp repo directory should be created")

run_git(repo_dir, { "init" })
run_git(repo_dir, { "config", "user.email", "stage2@example.com" })
run_git(repo_dir, { "config", "user.name", "Stage2 Tester" })

write_file(repo_dir .. "/tracked.txt", { "alpha", "beta" })
run_git(repo_dir, { "add", "tracked.txt" })
run_git(repo_dir, { "commit", "-m", "initial" })

write_file(repo_dir .. "/tracked.txt", { "alpha", "beta", "gamma" })
write_file(repo_dir .. "/new.txt", { "new file" })

local original_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 45,
		},
	},
	git = {
		log = {
			count = 25,
			format = "%h %s",
		},
	},
})

assert_equals(cfg.git.log.count, 25, "setup should merge git.log config")
assert_mapping("gs", "<Plug>(GitflowStatus)", "default status keymap should be registered")
assert_mapping("gp", "<Plug>(GitflowPush)", "default push keymap should be registered")
assert_mapping("gP", "<Plug>(GitflowPull)", "default pull keymap should be registered")
assert_mapping("<Plug>(GitflowFetch)", "<Cmd>Gitflow fetch<CR>", "fetch plug keymap should be registered")
assert_mapping(
	cfg.keybindings.fetch,
	"<Plug>(GitflowFetch)",
	"default fetch keymap should be registered"
)

local commands = require("gitflow.commands")
local all_subcommands = commands.complete("")
for _, expected in ipairs({
	"status",
	"commit",
	"push",
	"pull",
	"fetch",
	"diff",
	"log",
	"stash",
}) do
	assert_true(contains(all_subcommands, expected), ("missing subcommand '%s'"):format(expected))
end

local status = require("gitflow.git.status")
local diff = require("gitflow.git.diff")
local git_log = require("gitflow.git.log")
local stash = require("gitflow.git.stash")
local status_panel = require("gitflow.panels.status")
local diff_panel = require("gitflow.panels.diff")
local log_panel = require("gitflow.panels.log")
local stash_panel = require("gitflow.panels.stash")
assert_equals(type(stash_panel.is_open), "function", "stash panel should expose is_open")
assert_true(not stash_panel.is_open(), "stash panel should start closed")

local parsed = status.parse("M  staged.txt\n M unstaged.txt\n?? new.txt")
assert_equals(#parsed, 3, "status parser should parse porcelain lines")

local err, _, grouped = wait_async(function(done)
	status.fetch({}, function(fetch_err, entries, fetch_grouped)
		done(fetch_err, entries, fetch_grouped)
	end)
end)
assert_equals(err, nil, "status.fetch should succeed")
assert_equals(#grouped.unstaged, 1, "tracked file should be unstaged")
assert_equals(grouped.unstaged[1].path, "tracked.txt", "unstaged entry should match tracked file")
assert_equals(#grouped.untracked, 1, "new file should be untracked")
assert_equals(grouped.untracked[1].path, "new.txt", "untracked entry should match")

local stage_err = wait_async(function(done)
	status.stage_file("new.txt", {}, function(inner_err)
		done(inner_err)
	end)
end)
assert_equals(stage_err, nil, "stage_file should succeed")

local _, _, grouped_after_stage = wait_async(function(done)
	status.fetch({}, function(fetch_err, entries, fetch_grouped)
		done(fetch_err, entries, fetch_grouped)
	end)
end)
assert_true(#grouped_after_stage.staged >= 1, "staged group should include staged file")

local unstage_err = wait_async(function(done)
	status.unstage_file("new.txt", {}, function(inner_err)
		done(inner_err)
	end)
end)
assert_equals(unstage_err, nil, "unstage_file should succeed")

local diff_err, diff_output, diff_parsed = wait_async(function(done)
	diff.get({}, function(inner_err, output, parsed_output)
		done(inner_err, output, parsed_output)
	end)
end)
assert_equals(diff_err, nil, "diff.get should succeed")
assert_true(diff_output:find("diff --git", 1, true) ~= nil, "diff output should include header")
assert_true(#diff_parsed.files >= 1, "diff parser should extract at least one file")

local stage_all_err = wait_async(function(done)
	status.stage_all({}, function(inner_err)
		done(inner_err)
	end)
end)
assert_equals(stage_all_err, nil, "stage_all should succeed")

local original_input = vim.ui.input
local original_confirm = vim.fn.confirm
vim.ui.input = function(_, on_confirm)
	on_confirm("stage2 automated commit")
end
vim.fn.confirm = function()
	return 1
end

commands.dispatch({ "commit" }, cfg)
local commit_seen = vim.wait(5000, function()
	local log_output = run_git(repo_dir, { "log", "--oneline", "-n", "1" })
	return log_output:find("stage2 automated commit", 1, true) ~= nil
end, 25)
assert_true(commit_seen, "commit command should create a commit")

vim.ui.input = original_input
vim.fn.confirm = original_confirm

write_file(repo_dir .. "/tracked.txt", { "alpha", "beta", "gamma", "delta" })
local stage_tracked_err = wait_async(function(done)
	status.stage_file("tracked.txt", {}, function(inner_err)
		done(inner_err)
	end)
end)
assert_equals(stage_tracked_err, nil, "stage_file should stage tracked file")

local captured_diff_request = nil
status_panel.open(cfg, {
	on_open_diff = function(request)
		captured_diff_request = request
	end,
})
local panel_ready = vim.wait(5000, function()
	if not status_panel.state.bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(status_panel.state.bufnr, 0, -1, false)
	return find_line(lines, "Staged") ~= nil
end, 25)
assert_true(panel_ready, "status panel should render staged entries")

local status_buf = require("gitflow.ui.buffer").get("status")
assert_true(status_buf ~= nil, "status panel should create a status buffer")

local status_keymaps = vim.api.nvim_buf_get_keymap(status_buf, "n")
local has_revert_keymap = false
local has_push_commit_keymap = false
for _, mapping in ipairs(status_keymaps) do
	if mapping.lhs == "X" then
		has_revert_keymap = true
	elseif mapping.lhs == "p" then
		has_push_commit_keymap = true
	end
end
assert_true(has_revert_keymap, "status panel should map X for file revert")
assert_true(has_push_commit_keymap, "status panel should map p for commit push")

local status_lines = vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)
local expected_branch_line = ("Current branch: %s"):format(current_branch(repo_dir))
local staged_header_line = find_line(status_lines, "Staged")
assert_true(staged_header_line ~= nil, "status panel should include staged section")
local no_upstream_history = find_line(status_lines, "Commit History")
assert_true(no_upstream_history == nil, "commit history should not appear without upstream")
local staged_tracked_line = find_line(status_lines, "tracked.txt", staged_header_line + 1)
assert_true(staged_tracked_line ~= nil, "staged tracked file should be visible")
assert_equals(
	status_lines[#status_lines],
	expected_branch_line,
	"status panel should display current branch at the bottom"
)

vim.api.nvim_set_current_win(status_panel.state.winid)
vim.api.nvim_win_set_cursor(status_panel.state.winid, { staged_tracked_line, 0 })
status_panel.open_diff_under_cursor()
assert_true(captured_diff_request ~= nil, "dd should send a diff request")
assert_equals(
	captured_diff_request.path,
	"tracked.txt",
	"diff request should include selected path"
)
assert_equals(captured_diff_request.staged, true, "staged file diff should use --staged")

local revert_confirm = vim.fn.confirm
vim.fn.confirm = function()
	return 1
end
vim.api.nvim_win_set_cursor(status_panel.state.winid, { staged_tracked_line, 0 })
status_panel.revert_under_cursor()
local reverted = vim.wait(5000, function()
	local output = run_git(repo_dir, { "status", "--porcelain=v1", "--", "tracked.txt" })
	return vim.trim(output) == ""
end, 25)
vim.fn.confirm = revert_confirm
assert_true(reverted, "revert action should clear tracked file changes")
assert_deep_equals(
	vim.fn.readfile(repo_dir .. "/tracked.txt"),
	{ "alpha", "beta", "gamma" },
	"revert should restore tracked file content"
)

local branch_name = vim.trim(run_git(repo_dir, { "rev-parse", "--abbrev-ref", "HEAD" }))
local remote_dir = vim.fn.tempname()
run_git(repo_dir, { "init", "--bare", remote_dir })
run_git(repo_dir, { "remote", "add", "origin", remote_dir })
run_git(repo_dir, { "push", "-u", "origin", branch_name })

write_file(repo_dir .. "/tracked.txt", { "alpha", "beta", "gamma", "push-one" })
run_git(repo_dir, { "add", "tracked.txt" })
run_git(repo_dir, { "commit", "-m", "push one" })
local push_one_sha = vim.trim(run_git(repo_dir, { "rev-parse", "HEAD" }))

write_file(repo_dir .. "/tracked.txt", { "alpha", "beta", "gamma", "push-two" })
run_git(repo_dir, { "add", "tracked.txt" })
run_git(repo_dir, { "commit", "-m", "push two" })
local push_two_sha = vim.trim(run_git(repo_dir, { "rev-parse", "HEAD" }))

status_panel.refresh()
local outgoing_ready = vim.wait(5000, function()
	local lines = vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)
	local outgoing_header = find_line(lines, "Outgoing")
	if not outgoing_header then
		return false
	end
	return find_line(lines, "push one", outgoing_header + 1) ~= nil
		and find_line(lines, "push two", outgoing_header + 1) ~= nil
end, 25)
assert_true(outgoing_ready, "outgoing section should include local commits not on upstream")

local outgoing_lines = vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)
local history_header_after_refresh = find_line(outgoing_lines, "Commit History")
local outgoing_header_line = find_line(outgoing_lines, "Outgoing")
assert_true(history_header_after_refresh ~= nil, "commit history should appear with outgoing commits")
assert_true(outgoing_header_line ~= nil, "outgoing header should remain visible")
local push_one_history_line = find_line_in_range(
	outgoing_lines,
	"push one",
	history_header_after_refresh + 1,
	outgoing_header_line - 1
)
assert_true(push_one_history_line ~= nil, "push target commit should be selectable in history section")

captured_diff_request = nil
vim.api.nvim_win_set_cursor(status_panel.state.winid, { push_one_history_line, 0 })
status_panel.open_diff_under_cursor()
assert_true(captured_diff_request ~= nil, "dd should support commit entries")
assert_equals(
	captured_diff_request.commit,
	push_one_sha,
	"commit diff should target selected commit"
)

local push_confirm = vim.fn.confirm
vim.fn.confirm = function()
	return 1
end
vim.api.nvim_win_set_cursor(status_panel.state.winid, { push_one_history_line, 0 })
status_panel.push_under_cursor()
local partial_push_done = vim.wait(5000, function()
	local remote_head = vim.trim(run_git(repo_dir, {
		("--git-dir=%s"):format(remote_dir),
		"rev-parse",
		("refs/heads/%s"):format(branch_name),
	}))
	return remote_head == push_one_sha
end, 25)
vim.fn.confirm = push_confirm
assert_true(partial_push_done, "push from history should push only up to selected commit")

local push_two_still_outgoing = vim.wait(5000, function()
	local lines = vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)
	local outgoing_header = find_line(lines, "Outgoing")
	if not outgoing_header then
		return false
	end
	local outgoing_push_one = find_line(lines, "push one", outgoing_header + 1)
	local outgoing_push_two = find_line(lines, "push two", outgoing_header + 1)
	return outgoing_push_one == nil and outgoing_push_two ~= nil
end, 25)
assert_true(push_two_still_outgoing, "selected push should leave newer outgoing commits unpushed")

local upstream_clone_dir = vim.fn.tempname()
run_git(repo_dir, { "clone", remote_dir, upstream_clone_dir })
run_git(upstream_clone_dir, { "config", "user.email", "upstream@example.com" })
run_git(upstream_clone_dir, { "config", "user.name", "Upstream Tester" })
run_git(upstream_clone_dir, { "checkout", branch_name })
write_file(upstream_clone_dir .. "/incoming.txt", { "incoming remote change" })
run_git(upstream_clone_dir, { "add", "incoming.txt" })
run_git(upstream_clone_dir, { "commit", "-m", "incoming remote commit" })
local incoming_sha = vim.trim(run_git(upstream_clone_dir, { "rev-parse", "HEAD" }))
run_git(upstream_clone_dir, { "push", "origin", branch_name })
run_git(repo_dir, { "fetch", "origin" })

status_panel.refresh()
local incoming_ready = vim.wait(5000, function()
	local lines = vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)
	local incoming_header = find_line(lines, "Incoming")
	if not incoming_header then
		return false
	end
	return find_line(lines, "incoming remote commit", incoming_header + 1) ~= nil
end, 25)
assert_true(incoming_ready, "incoming section should show upstream-only commits")

local incoming_lines = vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)
local incoming_header_line = find_line(incoming_lines, "Incoming")
local incoming_commit_line = find_line(
	incoming_lines,
	"incoming remote commit",
	incoming_header_line + 1
)
assert_true(incoming_commit_line ~= nil, "incoming commit should be selectable")

captured_diff_request = nil
vim.api.nvim_win_set_cursor(status_panel.state.winid, { incoming_commit_line, 0 })
status_panel.open_diff_under_cursor()
assert_true(captured_diff_request ~= nil, "dd should open diff for incoming commit entries")
assert_equals(
	captured_diff_request.commit,
	incoming_sha,
	"incoming commit diff should target selected sha"
)
assert_true(
	push_two_sha ~= incoming_sha,
	"test setup should keep outgoing and incoming commits distinct"
)

commands.dispatch({ "diff" }, cfg)
local diff_ready = vim.wait(5000, function()
	if not diff_panel.state.bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(diff_panel.state.bufnr, 0, -1, false)
	return lines[#lines] == expected_branch_line
end, 25)
assert_true(diff_ready, "diff panel should display current branch at the bottom")

commands.dispatch({ "log" }, cfg)
local log_ready = vim.wait(5000, function()
	if not log_panel.state.bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(log_panel.state.bufnr, 0, -1, false)
	return lines[#lines] == expected_branch_line
end, 25)
assert_true(log_ready, "log panel should display current branch at the bottom")

commands.dispatch({ "stash", "list" }, cfg)
local stash_panel_ready = vim.wait(5000, function()
	if not stash_panel.state.bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(stash_panel.state.bufnr, 0, -1, false)
	return find_line(lines, "Gitflow Stash") ~= nil and lines[#lines] == expected_branch_line
end, 25)
assert_true(stash_panel_ready, "stash panel should render")
local stash_lines = vim.api.nvim_buf_get_lines(stash_panel.state.bufnr, 0, -1, false)
assert_equals(
	stash_lines[#stash_lines],
	expected_branch_line,
	"stash panel should display current branch at the bottom"
)
assert_true(stash_panel.is_open(), "stash panel should report open state")

local stash_buf = require("gitflow.ui.buffer").get("stash")
assert_true(stash_buf ~= nil, "stash panel should create a stash buffer")

local stash_keymaps = vim.api.nvim_buf_get_keymap(stash_buf, "n")
local has_pop_keymap = false
local has_drop_keymap = false
for _, mapping in ipairs(stash_keymaps) do
	if mapping.lhs == "P" then
		has_pop_keymap = true
	elseif mapping.lhs == "D" then
		has_drop_keymap = true
	end
end
assert_true(has_pop_keymap, "stash panel should map P for stash pop")
assert_true(has_drop_keymap, "stash panel should map D for stash drop")

local log_err, log_entries = wait_async(function(done)
	git_log.list({ count = 10, format = "%h %s" }, function(inner_err, entries)
		done(inner_err, entries)
	end)
end)
assert_equals(log_err, nil, "log.list should succeed")
assert_true(#log_entries >= 1, "log should contain at least one commit")

write_file(repo_dir .. "/tracked.txt", { "alpha", "beta", "gamma", "stash-change" })

local stash_push_err = wait_async(function(done)
	stash.push({ message = "stage2 stash" }, function(inner_err)
		done(inner_err)
	end)
end)
assert_equals(stash_push_err, nil, "stash push should succeed")

local stash_list_err, stash_entries = wait_async(function(done)
	stash.list({}, function(inner_err, entries)
		done(inner_err, entries)
	end)
end)
assert_equals(stash_list_err, nil, "stash list should succeed")
assert_true(#stash_entries >= 1, "stash list should contain pushed entry")

local stash_drop_err = wait_async(function(done)
	stash.drop(stash_entries[1].index, {}, function(inner_err)
		done(inner_err)
	end)
end)
assert_equals(stash_drop_err, nil, "stash drop should succeed")

commands.dispatch({ "close" }, cfg)
assert_true(not stash_panel.is_open(), "stash panel should report closed after :Gitflow close")
vim.fn.chdir(original_cwd)

print("Stage 2 smoke tests passed")
