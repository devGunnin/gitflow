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

local function find_name(entries, target)
	for _, entry in ipairs(entries) do
		if entry.name == target then
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
		error(("git command failed (%s): %s"):format(table.concat(cmd, " "), output), 2)
	end

	return output, code
end

local function write_file(path, lines)
	vim.fn.writefile(lines, path)
end

local config = require("gitflow.config")
local defaults = config.defaults()
assert_equals(defaults.sync.pull_strategy, "rebase", "default pull strategy should be rebase")
assert_equals(defaults.keybindings.palette, "<leader>gp", "default palette keybinding should exist")
assert_deep_equals(
	defaults.quick_actions.quick_commit,
	{ "commit" },
	"default quick_commit sequence should include commit step"
)
assert_deep_equals(
	defaults.quick_actions.quick_push,
	{ "commit", "push" },
	"default quick_push sequence should include commit + push"
)

local invalid = vim.deepcopy(defaults)
invalid.sync.pull_strategy = "invalid"
local ok, err = pcall(config.validate, invalid)
assert_true(not ok, "config.validate should reject invalid pull strategy")
assert_true(
	tostring(err):find("sync.pull_strategy", 1, true) ~= nil,
	"invalid pull strategy error should mention sync.pull_strategy"
)

local invalid_quick_actions = vim.deepcopy(defaults)
invalid_quick_actions.quick_actions.quick_push = { "invalid" }
local quick_ok, quick_err = pcall(config.validate, invalid_quick_actions)
assert_true(not quick_ok, "config.validate should reject invalid quick-action step")
assert_true(
	tostring(quick_err):find("quick_actions.quick_push", 1, true) ~= nil,
	"invalid quick-action error should mention quick_actions.quick_push"
)

local repo_dir = vim.fn.tempname()
local remote_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(repo_dir, "p"), 1, "temp repo should be created")
assert_equals(vim.fn.mkdir(remote_dir, "p"), 1, "temp remote should be created")

run_git(repo_dir, { "init", "--initial-branch=main" })
run_git(repo_dir, { "config", "user.email", "stage7@example.com" })
run_git(repo_dir, { "config", "user.name", "Stage7 Tester" })
write_file(repo_dir .. "/tracked.txt", { "base line" })
run_git(repo_dir, { "add", "tracked.txt" })
run_git(repo_dir, { "commit", "-m", "initial" })

run_git(remote_dir, { "init", "--bare" })
run_git(repo_dir, { "remote", "add", "origin", remote_dir })
run_git(repo_dir, { "push", "-u", "origin", "main" })

local previous_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)
vim.env.GIT_EDITOR = ":"

local original_input = vim.ui.input
local prompt_values = { "stage7 quick commit", "stage7 quick push" }
vim.ui.input = function(_, on_confirm)
	on_confirm(table.remove(prompt_values, 1))
end

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 45,
		},
	},
	sync = {
		pull_strategy = "rebase",
	},
})

local mapping = vim.fn.maparg(cfg.keybindings.palette, "n", false, true)
assert_true(
	type(mapping) == "table" and mapping.rhs == "<Plug>(GitflowPalette)",
	"default palette keymap should map to palette plug"
)

local commands = require("gitflow.commands")
local completion = commands.complete("")
for _, subcommand in ipairs({ "sync", "palette", "quick-commit", "quick-push" }) do
	assert_true(contains(completion, subcommand), ("missing subcommand '%s'"):format(subcommand))
end

write_file(repo_dir .. "/tracked.txt", { "base line", "quick commit line" })
commands.dispatch({ "quick-commit" }, cfg)
wait_until(function()
	local output = run_git(repo_dir, { "log", "--oneline", "-n", "1" })
	return output:find("stage7 quick commit", 1, true) ~= nil
end, "quick-commit should create a commit")

write_file(repo_dir .. "/tracked.txt", { "base line", "quick commit line", "quick push line" })
commands.dispatch({ "quick-push" }, cfg)
wait_until(function()
	local ahead = vim.trim(run_git(repo_dir, { "rev-list", "--count", "@{upstream}..HEAD" }))
	return ahead == "0"
end, "quick-push should leave branch in sync with upstream")

local git_mod = require("gitflow.git")
prompt_values[#prompt_values + 1] = "unused quick push prompt"
local prompt_count_before = #prompt_values
cfg = gitflow.setup({
	quick_actions = {
		quick_push = { "push" },
	},
})

write_file(repo_dir .. "/tracked.txt", {
	"base line",
	"quick commit line",
	"quick push line",
	"custom quick action line",
})

local original_git_for_custom = git_mod.git
local custom_push_calls = 0
git_mod.git = function(args, opts, cb)
	if args[1] == "push" then
		custom_push_calls = custom_push_calls + 1
	end
	return original_git_for_custom(args, opts, cb)
end

commands.dispatch({ "quick-push" }, cfg)
wait_until(function()
	return custom_push_calls > 0
end, "custom quick-push sequence should execute push step")
git_mod.git = original_git_for_custom

local status_output = run_git(repo_dir, { "status", "--short", "--", "tracked.txt" })
assert_true(
	status_output:find("tracked.txt", 1, true) ~= nil,
	"custom quick-push sequence should leave tracked changes uncommitted"
)
assert_equals(
	#prompt_values,
	prompt_count_before,
	"custom quick-push sequence should not prompt for a commit message"
)

local git_branch = require("gitflow.git.branch")
local conflict_panel = require("gitflow.panels.conflict")
local palette_panel = require("gitflow.panels.palette")

local original_git = git_mod.git
local original_fetch = git_branch.fetch
local original_ahead = git_branch.is_ahead_of_upstream
local original_conflict_open = conflict_panel.open

local calls = {}
git_branch.fetch = function(_, _, cb)
	calls[#calls + 1] = "fetch"
	cb(nil, { code = 0, signal = 0, stdout = "", stderr = "", cmd = { "git", "fetch" } })
end
git_branch.is_ahead_of_upstream = function(_, cb)
	calls[#calls + 1] = "ahead"
	cb(nil, true, 2, { code = 0, signal = 0, stdout = "2", stderr = "", cmd = { "git" } })
end
git_mod.git = function(args, _, cb)
	if args[1] == "pull" then
		calls[#calls + 1] = "pull"
		cb({
			code = 0,
			signal = 0,
			stdout = "Already up to date.",
			stderr = "",
			cmd = { "git", "pull" },
		})
		return
	end

	if args[1] == "push" then
		calls[#calls + 1] = "push"
		cb({ code = 0, signal = 0, stdout = "push ok", stderr = "", cmd = { "git", "push" } })
		return
	end

	cb({ code = 0, signal = 0, stdout = "", stderr = "", cmd = { "git" } })
end

commands.dispatch({ "sync" }, cfg)
assert_deep_equals(calls, { "fetch", "pull", "ahead", "push" }, "sync should run sequentially")

calls = {}
local conflict_opened = false
git_branch.fetch = function(_, _, cb)
	calls[#calls + 1] = "fetch"
	cb(nil, { code = 0, signal = 0, stdout = "", stderr = "", cmd = { "git", "fetch" } })
end
git_branch.is_ahead_of_upstream = function(_, cb)
	calls[#calls + 1] = "ahead"
	cb(nil, true, 1, { code = 0, signal = 0, stdout = "1", stderr = "", cmd = { "git" } })
end
git_mod.git = function(args, _, cb)
	if args[1] == "pull" then
		calls[#calls + 1] = "pull"
		cb({
			code = 1,
			signal = 0,
			stdout = "",
			stderr = "CONFLICT (content): Merge conflict in tracked.txt",
			cmd = { "git", "pull" },
		})
		return
	end

	if args[1] == "push" then
		calls[#calls + 1] = "push"
		cb({ code = 0, signal = 0, stdout = "push ok", stderr = "", cmd = { "git", "push" } })
		return
	end

	cb({ code = 0, signal = 0, stdout = "", stderr = "", cmd = { "git" } })
end
conflict_panel.open = function()
	conflict_opened = true
end

commands.dispatch({ "sync" }, cfg)
wait_until(function()
	return conflict_opened
end, "sync conflict path should open conflict panel")
assert_true(not contains(calls, "ahead"), "sync should stop before ahead-check on pull conflict")
assert_true(not contains(calls, "push"), "sync should stop before push on pull conflict")

git_mod.git = original_git
git_branch.fetch = original_fetch
git_branch.is_ahead_of_upstream = original_ahead
conflict_panel.open = original_conflict_open

local entries = commands.palette_entries(cfg)
local fuzzy = palette_panel.filter_entries(entries, "qpsh")
assert_true(find_name(fuzzy, "quick-push"), "palette fuzzy filter should match quick-push")

local picked = nil
palette_panel.open(cfg, {
	{
		name = "status",
		description = "Open status panel",
		category = "Git",
		keybinding = "gs",
	},
	{
		name = "sync",
		description = "Run sync",
		category = "Git",
		keybinding = nil,
	},
}, function(entry)
	picked = entry.name
end)

local prompt_bufnr = palette_panel.state.prompt_bufnr
local list_winid = palette_panel.state.list_winid
assert_true(prompt_bufnr ~= nil, "palette prompt buffer should exist")
assert_true(list_winid ~= nil, "palette list window should exist")

vim.api.nvim_buf_set_lines(prompt_bufnr, 0, 1, false, { "sync" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = prompt_bufnr })

wait_until(function()
	for _, entry in pairs(palette_panel.state.line_entries) do
		if entry.name == "sync" then
			return true
		end
	end
	return false
end, "palette should filter to sync entry")

local selected_line = nil
for line, entry in pairs(palette_panel.state.line_entries) do
	if entry.name == "sync" then
		selected_line = line
		break
	end
end
assert_true(selected_line ~= nil, "filtered palette should include sync line")

vim.api.nvim_set_current_win(list_winid)
vim.cmd("stopinsert")
vim.api.nvim_win_set_cursor(list_winid, { selected_line, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)

wait_until(function()
	return picked == "sync"
end, "pressing <CR> in palette should execute selected command")
assert_true(not palette_panel.is_open(), "palette should close after selection")

palette_panel.close()
vim.ui.input = original_input
vim.fn.chdir(previous_cwd)

print("Stage 7 smoke tests passed")
