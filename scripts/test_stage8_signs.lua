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

local function collect_signs(signs, bufnr)
	local entries = {}

	if signs.use_extmarks then
		local marks = vim.api.nvim_buf_get_extmarks(
			bufnr,
			signs.extmark_namespace,
			0,
			-1,
			{ details = true }
		)
		for _, mark in ipairs(marks) do
			local details = mark[4] or {}
			entries[#entries + 1] = {
				line = mark[2] + 1,
				text = details.sign_text,
				name = details.sign_hl_group,
			}
		end
		return entries
	end

	local placed = vim.fn.sign_getplaced(bufnr, { group = signs.sign_group })
	local groups = placed[1] and placed[1].signs or {}
	for _, sign in ipairs(groups) do
		entries[#entries + 1] = {
			line = sign.lnum,
			text = sign.name,
			name = sign.name,
		}
	end
	return entries
end

local function has_text(entries, text)
	for _, entry in ipairs(entries) do
		if vim.trim(entry.text or "") == text then
			return true
		end
	end
	return false
end

local function has_name(entries, name)
	for _, entry in ipairs(entries) do
		if entry.name == name then
			return true
		end
	end
	return false
end

local function has_type(changes, expected)
	for _, change in ipairs(changes) do
		if change.type == expected then
			return true
		end
	end
	return false
end

local config = require("gitflow.config")
local defaults = config.defaults()
assert_true(type(defaults.signs) == "table", "defaults.signs should exist")
assert_equals(defaults.signs.enable, true, "signs should be enabled by default")
assert_equals(defaults.signs.added, "+", "default added sign should match issue spec")
assert_equals(defaults.signs.modified, "~", "default modified sign should match issue spec")
assert_equals(defaults.signs.deleted, "−", "default deleted sign should match issue spec")
assert_equals(defaults.signs.conflict, "!", "default conflict sign should match issue spec")

local invalid_signs_type = vim.deepcopy(defaults)
invalid_signs_type.signs = "invalid"
local ok_type, err_type = pcall(config.validate, invalid_signs_type)
assert_true(not ok_type, "config.validate should reject non-table signs config")
assert_true(
	tostring(err_type):find("signs", 1, true) ~= nil,
	"invalid signs type error should mention signs"
)

local invalid_sign_width = vim.deepcopy(defaults)
invalid_sign_width.signs.added = ""
local ok_width, err_width = pcall(config.validate, invalid_sign_width)
assert_true(not ok_width, "config.validate should reject empty sign text")
assert_true(
	tostring(err_width):find("signs.added", 1, true) ~= nil,
	"invalid sign width error should mention signs.added"
)

local repo_dir = vim.fn.tempname()
assert_equals(vim.fn.mkdir(repo_dir, "p"), 1, "temp repo should be created")

run_git(repo_dir, { "init", "--initial-branch=main" })
run_git(repo_dir, { "config", "user.email", "stage8@example.com" })
run_git(repo_dir, { "config", "user.name", "Stage8 Tester" })
write_file(repo_dir .. "/tracked.txt", { "alpha", "beta", "gamma" })
run_git(repo_dir, { "add", "tracked.txt" })
run_git(repo_dir, { "commit", "-m", "initial" })

local previous_cwd = vim.fn.getcwd()
vim.fn.chdir(repo_dir)

local gh = require("gitflow.gh")
local original_check_prerequisites = gh.check_prerequisites
gh.check_prerequisites = function(_)
	gh.state.checked = true
	gh.state.available = true
	gh.state.authenticated = true
	return true
end

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	signs = {
		added = "+",
		modified = "~",
		deleted = "−",
		conflict = "!",
	},
})

local signs = require("gitflow.signs")
local defined = vim.fn.sign_getdefined("GitflowSignAdded")
assert_true(#defined > 0, "sign definitions should be created during setup")
assert_equals(
	vim.trim(defined[1].text or ""),
	cfg.signs.added,
	"custom sign text should propagate to sign definition"
)

local parsed = signs.parse_diff_hunks(table.concat({
	"@@ -1,2 +1,3 @@",
	"-alpha",
	"+alpha changed",
	" beta",
	"+delta",
	"@@ -5,1 +6,0 @@",
	"-removed line",
}, "\n"))
assert_true(has_type(parsed, "modified"), "diff parser should detect modified hunks")
assert_true(has_type(parsed, "added"), "diff parser should detect added hunks")
assert_true(has_type(parsed, "deleted"), "diff parser should detect deleted hunks")

vim.cmd("edit " .. vim.fn.fnameescape(repo_dir .. "/tracked.txt"))
local bufnr = vim.api.nvim_get_current_buf()

wait_until(function()
	return #collect_signs(signs, bufnr) == 0
end, "clean file should have no signs")

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"alpha",
	"beta changed",
	"gamma",
	"delta",
})
vim.cmd("write")

wait_until(function()
	local entries = collect_signs(signs, bufnr)
	if signs.use_extmarks then
		return has_text(entries, "~") and has_text(entries, "+")
	end
	return has_name(entries, "GitflowSignModified") and has_name(entries, "GitflowSignAdded")
end, "BufWritePost should place modified and added signs")

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"alpha",
	"beta changed",
})
vim.cmd("write")

wait_until(function()
	local entries = collect_signs(signs, bufnr)
	if signs.use_extmarks then
		return has_text(entries, "−")
	end
	return has_name(entries, "GitflowSignDeleted")
end, "deleting lines should place deleted signs")

run_git(repo_dir, { "add", "tracked.txt" })
run_git(repo_dir, { "commit", "-m", "finalize" })
vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })

wait_until(function()
	return #collect_signs(signs, bufnr) == 0
end, "post-operation refresh should clear signs after commit")

gitflow.setup({
	signs = { enable = false },
})
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"alpha",
	"beta changed",
	"disabled sign check",
})
vim.cmd("write")
vim.wait(250)
assert_equals(#collect_signs(signs, bufnr), 0, "disabled signs should not place indicators")

local nongit_path = vim.fn.tempname()
write_file(nongit_path, { "outside repo" })
vim.cmd("edit " .. vim.fn.fnameescape(nongit_path))
local nongit_bufnr = vim.api.nvim_get_current_buf()
signs.attach(nongit_bufnr)
signs.update_signs(nongit_bufnr)
vim.wait(250)
assert_equals(#collect_signs(signs, nongit_bufnr), 0, "non-git buffers should not receive signs")

gh.check_prerequisites = original_check_prerequisites
vim.fn.chdir(previous_cwd)

print("Stage 8 signs tests passed")
