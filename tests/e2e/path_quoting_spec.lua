-- tests/e2e/path_quoting_spec.lua — git C-quoted path decoding
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/path_quoting_spec.lua
--
-- Git C-quotes any porcelain/diff path with a space, quote, backslash or
-- non-ASCII byte (`café.txt` -> `"caf\303\251.txt"`). The fixture strings
-- below are verbatim `git status --porcelain=v1` / `git diff` output from
-- git 2.54.0; the second half re-checks the same paths against real git.

local T = _G.T

local git_path = require("gitflow.git.path")
local git_status = require("gitflow.git.status")
local git_diff = require("gitflow.git.diff")

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h:h")

-- ── unquote ────────────────────────────────────────────────────────────

T.assert_equals(git_path.unquote("plain.txt"), "plain.txt", "plain ASCII path is untouched")
T.assert_equals(
	git_path.unquote("dir/sub/plain-name_1.txt"),
	"dir/sub/plain-name_1.txt",
	"unquoted nested path is untouched"
)
T.assert_equals(
	git_path.unquote('"caf\\303\\251.txt"'),
	"café.txt",
	"octal escapes recombine into multi-byte UTF-8"
)
T.assert_equals(git_path.unquote('"my file.txt"'), "my file.txt", "space-quoted path loses its quotes")
T.assert_equals(git_path.unquote('"quote\\"d.txt"'), 'quote"d.txt', "escaped double quote decodes")
T.assert_equals(git_path.unquote('"back\\\\slash.txt"'), "back\\slash.txt", "escaped backslash decodes")
T.assert_equals(git_path.unquote('"nl\\nname.txt"'), "nl\nname.txt", "newline escape decodes")
T.assert_equals(git_path.unquote('"tab\\there.txt"'), "tab\there.txt", "tab escape decodes")
T.assert_equals(
	git_path.unquote('a "quoted" middle.txt'),
	'a "quoted" middle.txt',
	"path not wrapped in quotes is untouched"
)

-- ── porcelain status lines ─────────────────────────────────────────────

local unicode_entry = git_status.parse_line(' M "caf\\303\\251.txt"')
T.assert_equals(unicode_entry.path, "café.txt", "modified unicode path is decoded")
T.assert_true(unicode_entry.unstaged, "modified unicode path is unstaged")

local spaced_entry = git_status.parse_line(' M "my file.txt"')
T.assert_equals(spaced_entry.path, "my file.txt", "modified spaced path is decoded")

local plain_entry = git_status.parse_line(" M plain.txt")
T.assert_equals(plain_entry.path, "plain.txt", "plain ASCII status path is unchanged")
T.assert_equals(plain_entry.original_path, nil, "plain ASCII status path has no rename source")

local untracked_entry = git_status.parse_line('?? "new unicode \\303\\270.txt"')
T.assert_equals(untracked_entry.path, "new unicode ø.txt", "untracked unicode path is decoded")
T.assert_true(untracked_entry.untracked, "untracked entry keeps its flag")

local ignored_entry = git_status.parse_line('!! "ign ored.txt"')
T.assert_equals(ignored_entry.path, "ign ored.txt", "ignored spaced path is decoded")

-- ── renames (either side quoted independently) ─────────────────────────

local both_quoted = git_status.parse_line('R  "caf\\303\\251.txt" -> "na\\303\\257ve renamed.txt"')
T.assert_equals(both_quoted.path, "naïve renamed.txt", "rename destination is decoded")
T.assert_equals(both_quoted.original_path, "café.txt", "rename source is decoded")

local dest_only = git_status.parse_line('R  plain.txt -> "plain renamed.txt"')
T.assert_equals(dest_only.path, "plain renamed.txt", "quoted-destination rename decodes")
T.assert_equals(dest_only.original_path, "plain.txt", "unquoted rename source is unchanged")

local plain_rename = git_status.parse_line("R  old.txt -> new.txt")
T.assert_equals(plain_rename.path, "new.txt", "plain ASCII rename destination is unchanged")
T.assert_equals(plain_rename.original_path, "old.txt", "plain ASCII rename source is unchanged")

-- A name containing a literal " -> " is always quoted, so the split is exact.
local arrow_name = git_status.parse_line('R  old.txt -> "a -> b.txt"')
T.assert_equals(arrow_name.path, "a -> b.txt", "arrow inside a quoted name is not a separator")
T.assert_equals(arrow_name.original_path, "old.txt", "arrow-name rename source survives the split")

-- ── diff --git headers ─────────────────────────────────────────────────

local diff_output = table.concat({
	'diff --git "a/caf\\303\\251.txt" "b/na\\303\\257ve renamed.txt"',
	"@@ -1 +1 @@",
	"-a",
	"+b",
	'diff --git a/plain.txt "b/\\303\\274nicode.txt"',
	"@@ -1 +1 @@",
	"-c",
	"+d",
	"diff --git a/my file.txt b/my file.txt",
	"@@ -1 +1 @@",
	"-e",
	"+f",
	"diff --git a/plain2.txt b/plain2.txt",
	"@@ -1 +1 @@",
	"-g",
	"+h",
}, "\n")

local parsed = git_diff.parse(diff_output)
T.assert_equals(#parsed.files, 4, "every diff header starts a file")
T.assert_equals(parsed.files[1].old_path, "café.txt", "quoted diff source is decoded")
T.assert_equals(parsed.files[1].new_path, "naïve renamed.txt", "quoted diff destination is decoded")
T.assert_equals(parsed.files[2].old_path, "plain.txt", "unquoted side of a mixed header is unchanged")
T.assert_equals(parsed.files[2].new_path, "ünicode.txt", "quoted side of a mixed header is decoded")
T.assert_equals(parsed.files[3].new_path, "my file.txt", "unquoted spaced diff path is unchanged")
T.assert_equals(parsed.files[4].new_path, "plain2.txt", "plain ASCII diff path is unchanged")

local _, _, line_context = git_diff.collect_markers(vim.split(diff_output, "\n", { plain = true }), 1)
T.assert_equals(line_context[3].path, "naïve renamed.txt", "unicode file keeps line attribution")
T.assert_equals(line_context[15].path, "plain2.txt", "plain ASCII file keeps line attribution")

-- ── real git round-trip ────────────────────────────────────────────────

dofile(project_root .. "/scripts/test_real_git.lua")
T.assert_true(
	(vim.env.GITFLOW_GIT_REAL or "") ~= "" or vim.fn.exepath("git") ~= "",
	"real git binary is required for the round-trip checks"
)

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")

---@param args string[]
local function run_git(args)
	local result = vim.system(vim.list_extend({ "git" }, args), { cwd = repo, text = true }):wait()
	T.assert_equals(result.code, 0, ("git %s failed: %s"):format(args[1], result.stderr or ""))
end

---@param name string
---@param text string
local function write_file(name, text)
	local fd = assert(io.open(repo .. "/" .. name, "w"))
	fd:write(text)
	fd:close()
end

run_git({ "init", "-q", "-b", "main", "." })
run_git({ "config", "user.email", "test@example.com" })
run_git({ "config", "user.name", "test" })
write_file("plain.txt", "one\n")
write_file("café.txt", "two\n")
write_file("my file.txt", "three\n")
run_git({ "add", "-A" })
run_git({ "commit", "-qm", "init" })
run_git({ "mv", "café.txt", "naïve renamed.txt" })
write_file("my file.txt", "three changed\n")
write_file("plain.txt", "one changed\n")

---@return table<string, GitflowStatusEntry>
local function fetch_by_path()
	local err, entries = T.wait_async(function(done)
		git_status.fetch({ cwd = repo }, function(fetch_err, fetched)
			done(fetch_err, fetched)
		end)
	end)
	T.assert_equals(err, nil, "status fetch succeeded")
	local by_path = {}
	for _, entry in ipairs(entries) do
		by_path[entry.path] = entry
	end
	return by_path
end

local by_path = fetch_by_path()
T.assert_true(by_path["naïve renamed.txt"] ~= nil, "real git rename destination is decoded")
T.assert_equals(
	by_path["naïve renamed.txt"].original_path,
	"café.txt",
	"real git rename source is decoded"
)
T.assert_true(by_path["my file.txt"] ~= nil, "real git spaced path is decoded")
T.assert_true(by_path["plain.txt"] ~= nil, "real git plain ASCII path is unaffected")

-- Staging is the failing operation the decoding exists for: the quoted
-- literal is not a real path, so `git add --` cannot find it.
local stage_err = T.wait_async(function(done)
	git_status.stage_file("my file.txt", { cwd = repo }, function(err)
		done(err)
	end)
end)
T.assert_equals(stage_err, nil, "staging a spaced path succeeds")
T.assert_true(fetch_by_path()["my file.txt"].staged, "spaced path is staged after add")

local unstage_err = T.wait_async(function(done)
	git_status.unstage_file("my file.txt", { cwd = repo }, function(err)
		done(err)
	end)
end)
T.assert_equals(unstage_err, nil, "unstaging a spaced path succeeds")
T.assert_true(not fetch_by_path()["my file.txt"].staged, "spaced path is unstaged after restore")

local revert_err = T.wait_async(function(done)
	git_status.revert_file("my file.txt", { cwd = repo }, function(err)
		done(err)
	end)
end)
T.assert_equals(revert_err, nil, "reverting a spaced path succeeds")
T.assert_true(fetch_by_path()["my file.txt"] == nil, "spaced path is clean after revert")

local diff_err, _, real_parsed = T.wait_async(function(done)
	git_diff.get({ cwd = repo, staged = true }, function(err, output, parsed_diff)
		done(err, output, parsed_diff)
	end)
end)
T.assert_equals(diff_err, nil, "staged diff fetch succeeded")
local diff_paths = {}
for _, file in ipairs(real_parsed.files) do
	diff_paths[file.new_path] = true
end
T.assert_true(diff_paths["naïve renamed.txt"], "real git diff header path is decoded")

vim.fn.delete(repo, "rf")

-- ── conflicted paths (real git merge) ──────────────────────────────────

local git_conflict = require("gitflow.git.conflict")

local conflict_repo = vim.fn.tempname()
vim.fn.mkdir(conflict_repo, "p")

---@param args string[]
local function run_conflict_git(args)
	local result = vim.system(
		vim.list_extend({ "git" }, args),
		{ cwd = conflict_repo, text = true }
	):wait()
	T.assert_equals(result.code, 0, ("git %s failed: %s"):format(args[1], result.stderr or ""))
end

---@param name string
---@param text string
local function write_conflict_file(name, text)
	local fd = assert(io.open(conflict_repo .. "/" .. name, "w"))
	fd:write(text)
	fd:close()
end

run_conflict_git({ "init", "-q", "-b", "main", "." })
run_conflict_git({ "config", "user.email", "test@example.com" })
run_conflict_git({ "config", "user.name", "test" })
write_conflict_file("café conflict.txt", "base\n")
write_conflict_file("plain.txt", "base\n")
run_conflict_git({ "add", "-A" })
run_conflict_git({ "commit", "-qm", "init" })
run_conflict_git({ "checkout", "-q", "-b", "other" })
write_conflict_file("café conflict.txt", "other\n")
write_conflict_file("plain.txt", "other\n")
run_conflict_git({ "commit", "-qam", "other" })
run_conflict_git({ "checkout", "-q", "main" })
write_conflict_file("café conflict.txt", "mine\n")
write_conflict_file("plain.txt", "mine\n")
run_conflict_git({ "commit", "-qam", "mine" })
-- merge is expected to fail with conflicts; run it directly, not via run_conflict_git
vim.system({ "git", "merge", "other" }, { cwd = conflict_repo, text = true }):wait()

local conflict_err, conflicted = T.wait_async(function(done)
	git_conflict.list({ cwd = conflict_repo }, function(err, paths)
		done(err, paths)
	end)
end)
T.assert_equals(conflict_err, nil, "conflict list succeeded")
T.assert_deep_equals(
	conflicted,
	{ "café conflict.txt", "plain.txt" },
	"conflicted paths are decoded, plain ASCII untouched"
)

vim.fn.delete(conflict_repo, "rf")

print("path_quoting_spec: all assertions passed")
