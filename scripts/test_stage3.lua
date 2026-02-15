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

local function current_branch(repo_dir)
	return vim.trim(run_git(repo_dir, { "rev-parse", "--abbrev-ref", "HEAD" }))
end

local function branch_exists(repo_dir, name)
	local output = run_git(repo_dir, { "branch", "--list", name })
	return vim.trim(output) ~= ""
end

local function has_conflict(repo_dir, path)
	local output = run_git(repo_dir, { "diff", "--name-only", "--diff-filter=U" }, false)
	if path then
		return output:find(path, 1, true) ~= nil
	end
	return vim.trim(output) ~= ""
end

local function rebase_in_progress(repo_dir)
	local git_dir = vim.trim(run_git(repo_dir, { "rev-parse", "--git-dir" }))
	local prefix = repo_dir .. "/" .. git_dir
	return vim.fn.isdirectory(prefix .. "/rebase-merge") == 1
		or vim.fn.isdirectory(prefix .. "/rebase-apply") == 1
end

local repo_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(repo_dir, "p"), 1, "temp repo should be created")

local remote_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(remote_dir, "p"), 1, "temp remote dir should be created")

run_git(repo_dir, { "init", "--initial-branch=main" })
run_git(repo_dir, { "config", "user.email", "stage3@example.com" })
run_git(repo_dir, { "config", "user.name", "Stage3 Tester" })
run_git(repo_dir, { "remote", "add", "origin", remote_dir })
run_git(remote_dir, { "init", "--bare" })

write_file(repo_dir .. "/shared.txt", { "base" })
write_file(repo_dir .. "/seed.txt", { "seed" })
run_git(repo_dir, { "add", "shared.txt", "seed.txt" })
run_git(repo_dir, { "commit", "-m", "initial" })
run_git(repo_dir, { "push", "-u", "origin", "main" })

run_git(repo_dir, { "checkout", "-b", "feature/base" })
write_file(repo_dir .. "/feature.txt", { "feature branch" })
run_git(repo_dir, { "add", "feature.txt" })
run_git(repo_dir, { "commit", "-m", "feature branch commit" })
run_git(repo_dir, { "push", "-u", "origin", "feature/base" })
run_git(repo_dir, { "checkout", "main" })

local collaborator_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(collaborator_dir, "p"), 1, "temp collaborator dir should be created")
run_git(collaborator_dir, { "clone", remote_dir, "." })
run_git(collaborator_dir, { "config", "user.email", "collab@example.com" })
run_git(collaborator_dir, { "config", "user.name", "Collaborator" })
run_git(collaborator_dir, { "checkout", "-b", "feature/from-a", "origin/main" })
write_file(collaborator_dir .. "/from-a.txt", { "from collaborator" })
run_git(collaborator_dir, { "add", "from-a.txt" })
run_git(collaborator_dir, { "commit", "-m", "collaborator branch" })
run_git(collaborator_dir, { "push", "-u", "origin", "feature/from-a" })

local previous_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)
vim.env.GIT_EDITOR = ":"

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 48,
		},
	},
})

local commands = require("gitflow.commands")
local branch_panel = require("gitflow.panels.branch")

local subcommands = commands.complete("")
for _, expected in ipairs({ "branch", "merge", "rebase", "cherry-pick" }) do
	assert_true(contains(subcommands, expected), ("missing subcommand '%s'"):format(expected))
end
local nil_cmdline_subcommands = commands.complete("", nil, 0)
for _, expected in ipairs({ "branch", "merge", "rebase", "cherry-pick" }) do
	assert_true(
		contains(nil_cmdline_subcommands, expected),
		("missing subcommand '%s' for nil cmdline"):format(expected)
	)
end

local merge_completion = commands.complete("feature", "Gitflow merge feature", 0)
assert_true(
	contains(merge_completion, "feature/base"),
	"merge completion should include local feature/base branch"
)

local rebase_branch_completion = commands.complete("ma", "Gitflow rebase ma", 0)
assert_true(
	contains(rebase_branch_completion, "main"),
	"rebase completion should include main"
)

local rebase_flag_completion = commands.complete("--", "Gitflow rebase --", 0)
assert_true(
	contains(rebase_flag_completion, "--abort") and contains(rebase_flag_completion, "--continue"),
	"rebase completion should include abort/continue flags"
)

commands.dispatch({ "branch" }, cfg)
wait_until(function()
	return branch_panel.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(branch_panel.state.bufnr)
		and find_line(vim.api.nvim_buf_get_lines(branch_panel.state.bufnr, 0, -1, false), "Local") ~= nil
end, "branch panel should open")

local branch_lines = vim.api.nvim_buf_get_lines(branch_panel.state.bufnr, 0, -1, false)
assert_true(find_line(branch_lines, "Remote") ~= nil, "branch panel should render remote section")
local cur = current_branch(repo_dir)
local current_found = false
for _, bl in ipairs(branch_lines) do
	if bl:find(cur, 1, true) and bl:find("(current)", 1, true) then
		current_found = true
		break
	end
end
assert_true(current_found, "current branch should be indicated distinctly")

local branch_maps = vim.api.nvim_buf_get_keymap(branch_panel.state.bufnr, "n")
local required_maps = { ["<CR>"] = true, c = true, d = true, D = true, r = true, R = true, f = true, q = true }
for _, map in ipairs(branch_maps) do
	if required_maps[map.lhs] then
		required_maps[map.lhs] = false
	end
end
for lhs, missing in pairs(required_maps) do
	assert_true(not missing, ("branch panel keymap '%s' is missing"):format(lhs))
end

vim.api.nvim_set_current_win(branch_panel.state.winid)

local function move_cursor_to_branch(name)
	branch_panel.refresh()
	wait_until(function()
		if not branch_panel.state.bufnr then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(branch_panel.state.bufnr, 0, -1, false)
		local line = find_line(lines, (" %s"):format(name))
		if not line then
			line = find_line(lines, ("* %s"):format(name))
		end
		if not line then
			return false
		end
		vim.api.nvim_win_set_cursor(branch_panel.state.winid, { line, 0 })
		return true
	end, ("branch '%s' should be visible in panel"):format(name))
end

assert_true(
	find_line(branch_lines, "origin/feature/from-a") == nil,
	"collaborator branch should not be listed before fetch"
)

branch_panel.fetch_remotes()
wait_until(function()
	local lines = vim.api.nvim_buf_get_lines(branch_panel.state.bufnr, 0, -1, false)
	return find_line(lines, "origin/feature/from-a") ~= nil
end, "fetch action should refresh remote branch list")

move_cursor_to_branch("origin/feature/from-a")
branch_panel.switch_under_cursor()
wait_until(function()
	if current_branch(repo_dir) ~= "feature/from-a" then
		return false
	end
	local _, code = run_git(repo_dir, { "rev-parse", "--verify", "HEAD:from-a.txt" }, false)
	return code == 0
end, "switch action should fetch and track collaborator branch")

move_cursor_to_branch("main")

local original_input = vim.ui.input
local original_confirm = vim.fn.confirm
vim.ui.input = function(_, on_confirm)
	on_confirm("panel-created")
end
vim.fn.confirm = function()
	return 1
end
branch_panel.create_branch()
wait_until(function()
	return branch_exists(repo_dir, "panel-created")
end, "create action should create a branch")

move_cursor_to_branch("panel-created")
branch_panel.switch_under_cursor()
wait_until(function()
	return current_branch(repo_dir) == "panel-created"
end, "switch action should switch branch")

vim.ui.input = function(_, on_confirm)
	on_confirm("panel-renamed")
end
branch_panel.rename_under_cursor()
wait_until(function()
	return branch_exists(repo_dir, "panel-renamed") and current_branch(repo_dir) == "panel-renamed"
end, "rename action should rename branch")

run_git(repo_dir, { "checkout", "main" })
run_git(repo_dir, { "checkout", "-b", "panel-delete" })
write_file(repo_dir .. "/panel-delete.txt", { "delete me" })
run_git(repo_dir, { "add", "panel-delete.txt" })
run_git(repo_dir, { "commit", "-m", "panel delete branch" })
run_git(repo_dir, { "checkout", "main" })

move_cursor_to_branch("panel-delete")
vim.fn.confirm = function()
	return 1
end
branch_panel.delete_under_cursor(false)
wait_until(function()
	return not branch_exists(repo_dir, "panel-delete")
end, "delete action should remove selected branch")

run_git(repo_dir, { "checkout", "-b", "panel-force" })
write_file(repo_dir .. "/panel-force.txt", { "force delete me" })
run_git(repo_dir, { "add", "panel-force.txt" })
run_git(repo_dir, { "commit", "-m", "panel force branch" })
run_git(repo_dir, { "checkout", "main" })

move_cursor_to_branch("panel-force")
vim.fn.confirm = function()
	return 1
end
branch_panel.delete_under_cursor(true)
wait_until(function()
	return not branch_exists(repo_dir, "panel-force")
end, "force delete action should remove selected branch")

run_git(repo_dir, { "checkout", "-b", "merge-clean" })
write_file(repo_dir .. "/merge-clean.txt", { "merge clean" })
run_git(repo_dir, { "add", "merge-clean.txt" })
run_git(repo_dir, { "commit", "-m", "merge clean branch" })
run_git(repo_dir, { "checkout", "main" })

commands.dispatch({ "merge", "merge-clean" }, cfg)
wait_until(function()
	local _, code = run_git(repo_dir, { "rev-parse", "--verify", "HEAD:merge-clean.txt" }, false)
	return code == 0
end, "merge should apply clean branch changes")

run_git(repo_dir, { "checkout", "-b", "merge-conflict" })
write_file(repo_dir .. "/shared.txt", { "merge conflict branch" })
run_git(repo_dir, { "add", "shared.txt" })
run_git(repo_dir, { "commit", "-m", "merge conflict branch change" })
run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/shared.txt", { "merge conflict main" })
run_git(repo_dir, { "add", "shared.txt" })
run_git(repo_dir, { "commit", "-m", "merge conflict main change" })

commands.dispatch({ "merge", "merge-conflict" }, cfg)
wait_until(function()
	return has_conflict(repo_dir, "shared.txt")
end, "merge conflicts should be detected and listed")
run_git(repo_dir, { "merge", "--abort" })

write_file(repo_dir .. "/rebase-abort.txt", { "base" })
run_git(repo_dir, { "add", "rebase-abort.txt" })
run_git(repo_dir, { "commit", "-m", "rebase abort base" })
run_git(repo_dir, { "checkout", "-b", "rebase-abort" })
write_file(repo_dir .. "/rebase-abort.txt", { "topic" })
run_git(repo_dir, { "add", "rebase-abort.txt" })
run_git(repo_dir, { "commit", "-m", "rebase abort topic" })
run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/rebase-abort.txt", { "main" })
run_git(repo_dir, { "add", "rebase-abort.txt" })
run_git(repo_dir, { "commit", "-m", "rebase abort main" })
run_git(repo_dir, { "checkout", "rebase-abort" })

commands.dispatch({ "rebase", "main" }, cfg)
wait_until(function()
	return has_conflict(repo_dir, "rebase-abort.txt") and rebase_in_progress(repo_dir)
end, "rebase should stop on conflicts")
commands.dispatch({ "rebase", "--abort" }, cfg)
wait_until(function()
	return not rebase_in_progress(repo_dir)
end, "rebase --abort should clear rebase state")

run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/rebase-continue.txt", { "base" })
run_git(repo_dir, { "add", "rebase-continue.txt" })
run_git(repo_dir, { "commit", "-m", "rebase continue base" })
run_git(repo_dir, { "checkout", "-b", "rebase-continue" })
write_file(repo_dir .. "/rebase-continue.txt", { "topic" })
run_git(repo_dir, { "add", "rebase-continue.txt" })
run_git(repo_dir, { "commit", "-m", "rebase continue topic" })
run_git(repo_dir, { "checkout", "main" })
write_file(repo_dir .. "/rebase-continue.txt", { "main" })
run_git(repo_dir, { "add", "rebase-continue.txt" })
run_git(repo_dir, { "commit", "-m", "rebase continue main" })
run_git(repo_dir, { "checkout", "rebase-continue" })

commands.dispatch({ "rebase", "main" }, cfg)
wait_until(function()
	return has_conflict(repo_dir, "rebase-continue.txt") and rebase_in_progress(repo_dir)
end, "rebase continue scenario should conflict")

write_file(repo_dir .. "/rebase-continue.txt", { "resolved" })
run_git(repo_dir, { "add", "rebase-continue.txt" })
commands.dispatch({ "rebase", "--continue" }, cfg)
wait_until(function()
	if rebase_in_progress(repo_dir) then
		return false
	end
	return vim.trim(run_git(repo_dir, { "show", "HEAD:rebase-continue.txt" })) == "resolved"
end, "rebase --continue should complete after conflict resolution")

run_git(repo_dir, { "checkout", "main" })
run_git(repo_dir, { "checkout", "-b", "cherry-source" })
write_file(repo_dir .. "/cherry.txt", { "cherry pick me" })
run_git(repo_dir, { "add", "cherry.txt" })
run_git(repo_dir, { "commit", "-m", "cherry source commit" })
local cherry_sha = vim.trim(run_git(repo_dir, { "rev-parse", "HEAD" }))
run_git(repo_dir, { "checkout", "main" })

local cherry_completion = commands.complete(
	cherry_sha:sub(1, 8),
	"Gitflow cherry-pick " .. cherry_sha:sub(1, 8),
	0
)
assert_true(
	contains(cherry_completion, cherry_sha),
	"cherry-pick completion should include recent commit hash"
)

commands.dispatch({ "cherry-pick", cherry_sha }, cfg)
wait_until(function()
	local _, code = run_git(repo_dir, { "rev-parse", "--verify", "HEAD:cherry.txt" }, false)
	return code == 0
end, "cherry-pick should apply selected commit")

commands.dispatch({ "close" }, cfg)

vim.ui.input = original_input
vim.fn.confirm = original_confirm
vim.fn.chdir(previous_cwd)

print("Stage 3 smoke tests passed")
