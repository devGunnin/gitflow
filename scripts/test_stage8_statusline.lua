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

local function wait_until(predicate, message, timeout_ms)
	local ok = vim.wait(timeout_ms or 5000, predicate, 20)
	assert_true(ok, message)
end

local function run_git(cwd, args, should_succeed)
	local cmd = { "git" }
	vim.list_extend(cmd, args)

	local output = ""
	local code = 1
	if vim.system then
		local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
		output = (result.stdout or "") .. (result.stderr or "")
		code = result.code or 1
	else
		local previous = vim.fn.getcwd()
		vim.fn.chdir(cwd)
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

local function output_has_count(value, marker)
	return value:find(marker, 1, true) ~= nil
end

local base_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(base_dir, "p"), 1, "temp workspace should be created")

local remote_dir = base_dir .. "/remote.git"
local seed_dir = base_dir .. "/seed"
local repo_dir = base_dir .. "/repo"
local upstream_dir = base_dir .. "/upstream"

run_git(base_dir, { "init", "--bare", remote_dir })
run_git(base_dir, { "clone", remote_dir, seed_dir })
run_git(seed_dir, { "checkout", "-b", "main" })
run_git(seed_dir, { "config", "user.email", "stage8@example.com" })
run_git(seed_dir, { "config", "user.name", "Stage8 Seeder" })
write_file(seed_dir .. "/tracked.txt", { "alpha", "beta" })
run_git(seed_dir, { "add", "tracked.txt" })
run_git(seed_dir, { "commit", "-m", "seed" })
run_git(seed_dir, { "push", "-u", "origin", "main" })
run_git(base_dir, {
	("--git-dir=%s"):format(remote_dir),
	"symbolic-ref",
	"HEAD",
	"refs/heads/main",
})

run_git(base_dir, { "clone", remote_dir, repo_dir })
run_git(repo_dir, { "config", "user.email", "stage8@example.com" })
run_git(repo_dir, { "config", "user.name", "Stage8 Tester" })

run_git(base_dir, { "clone", remote_dir, upstream_dir })
run_git(upstream_dir, { "config", "user.email", "stage8@example.com" })
run_git(upstream_dir, { "config", "user.name", "Stage8 Upstream" })
write_file(upstream_dir .. "/upstream.txt", { "remote commit" })
run_git(upstream_dir, { "add", "upstream.txt" })
run_git(upstream_dir, { "commit", "-m", "upstream change" })
run_git(upstream_dir, { "push" })

write_file(repo_dir .. "/local.txt", { "local commit" })
run_git(repo_dir, { "add", "local.txt" })
run_git(repo_dir, { "commit", "-m", "local change" })
run_git(repo_dir, { "fetch", "origin" })

local previous_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)

local branch = vim.trim(run_git(repo_dir, { "rev-parse", "--abbrev-ref", "HEAD" }))
assert_true(branch ~= "", "test repo should have a current branch")

local gh = require("gitflow.gh")
local original_check_prerequisites = gh.check_prerequisites
gh.check_prerequisites = function(_)
	gh.state.checked = true
	gh.state.available = true
	gh.state.authenticated = true
	return true
end

local gitflow = require("gitflow")
gitflow.setup({})

assert_true(type(gitflow.statusline()) == "string", "statusline() should return plain string")

wait_until(function()
	local value = gitflow.statusline()
	return value:find(branch, 1, true) ~= nil and output_has_count(value, "↑1")
		and output_has_count(value, "↓1")
end, "statusline should include branch and ahead/behind counts")

vim.cmd("edit " .. vim.fn.fnameescape(repo_dir .. "/tracked.txt"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
	"alpha edited",
	"beta",
})
vim.cmd("write")

wait_until(function()
	return output_has_count(gitflow.statusline(), "*")
end, "BufWritePost should refresh statusline dirty marker")

run_git(repo_dir, { "add", "tracked.txt" })
run_git(repo_dir, { "commit", "-m", "clear dirty state" })
vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })

wait_until(function()
	return not output_has_count(gitflow.statusline(), "*")
end, "GitflowPostOperation should refresh cache after git operations")

wait_until(function()
	return not output_has_count(gitflow.statusline(), "*")
end, "statusline should be clean before FocusGained dirty check")

write_file(repo_dir .. "/focus_check.txt", { "focus dirty" })
vim.api.nvim_exec_autocmds("FocusGained", {})

wait_until(function()
	return output_has_count(gitflow.statusline(), "*")
end, "FocusGained should refresh statusline dirty marker")

local nongit_dir = base_dir .. "/nongit"
assert_equals(vim.fn.mkdir(nongit_dir, "p"), 1, "non-git directory should be created")
vim.fn.chdir(nongit_dir)
vim.api.nvim_exec_autocmds("FocusGained", {})

wait_until(function()
	return gitflow.statusline() == ""
end, "statusline should return empty string outside git repositories")

gh.check_prerequisites = original_check_prerequisites
vim.fn.chdir(previous_cwd)

print("Stage 8 statusline tests passed")
