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

-- --------------------------------------------------------
-- 1. Config schema: icons defaults and validation
-- --------------------------------------------------------
local config = require("gitflow.config")

local defaults = config.defaults()
assert_true(
	type(defaults.icons) == "table",
	"config.defaults should include icons table"
)
assert_equals(
	defaults.icons.enable,
	false,
	"icons.enable should default to false"
)

-- validate accepts valid icons config
local valid = vim.deepcopy(defaults)
valid.icons.enable = true
local ok_valid, _ = pcall(config.validate, valid)
assert_true(ok_valid, "config.validate should accept icons.enable = true")

valid.icons.enable = false
ok_valid, _ = pcall(config.validate, valid)
assert_true(ok_valid, "config.validate should accept icons.enable = false")

-- validate rejects non-table icons
local invalid_table = vim.deepcopy(defaults)
invalid_table.icons = "invalid"
local ok_inv, err_inv = pcall(config.validate, invalid_table)
assert_true(not ok_inv, "config.validate should reject non-table icons")
assert_true(
	tostring(err_inv):find("icons", 1, true) ~= nil,
	"invalid icons config error should mention icons"
)

-- validate rejects non-boolean enable
local invalid_enable = vim.deepcopy(defaults)
invalid_enable.icons.enable = "yes"
local ok_inv2, err_inv2 = pcall(config.validate, invalid_enable)
assert_true(
	not ok_inv2,
	"config.validate should reject non-boolean icons.enable"
)
assert_true(
	tostring(err_inv2):find("icons.enable", 1, true) ~= nil,
	"invalid icons.enable error should mention icons.enable"
)

print("  [pass] config icons schema and validation")

-- --------------------------------------------------------
-- 2. Icons module: ASCII fallback (default, enable=false)
-- --------------------------------------------------------
local icons = require("gitflow.icons")

-- Setup with icons disabled
icons.setup({ icons = { enable = false } })

-- git_state category
assert_equals(
	icons.get("git_state", "added"), "+",
	"git_state.added should return '+' when disabled"
)
assert_equals(
	icons.get("git_state", "modified"), "~",
	"git_state.modified should return '~' when disabled"
)
assert_equals(
	icons.get("git_state", "deleted"), "-",
	"git_state.deleted should return '-' when disabled"
)
assert_equals(
	icons.get("git_state", "conflict"), "!",
	"git_state.conflict should return '!' when disabled"
)
assert_equals(
	icons.get("git_state", "staged"), "S",
	"git_state.staged should return 'S' when disabled"
)
assert_equals(
	icons.get("git_state", "unstaged"), "U",
	"git_state.unstaged should return 'U' when disabled"
)
assert_equals(
	icons.get("git_state", "untracked"), "?",
	"git_state.untracked should return '?' when disabled"
)
assert_equals(
	icons.get("git_state", "commit"), "*",
	"git_state.commit should return '*' when disabled"
)

-- github category
assert_equals(
	icons.get("github", "pr_open"), "[open]",
	"github.pr_open should return '[open]' when disabled"
)
assert_equals(
	icons.get("github", "pr_merged"), "[merged]",
	"github.pr_merged should return '[merged]' when disabled"
)
assert_equals(
	icons.get("github", "pr_closed"), "[closed]",
	"github.pr_closed should return '[closed]' when disabled"
)
assert_equals(
	icons.get("github", "pr_draft"), "[draft]",
	"github.pr_draft should return '[draft]' when disabled"
)
assert_equals(
	icons.get("github", "issue_open"), "[open]",
	"github.issue_open should return '[open]' when disabled"
)
assert_equals(
	icons.get("github", "issue_closed"), "[closed]",
	"github.issue_closed should return '[closed]' when disabled"
)

-- branch category
assert_equals(
	icons.get("branch", "current"), "*",
	"branch.current should return '*' when disabled"
)
assert_equals(
	icons.get("branch", "remote"), "@",
	"branch.remote should return '@' when disabled"
)

-- file_status category
assert_equals(
	icons.get("file_status", "A"), "[+]",
	"file_status.A should return '[+]' when disabled"
)
assert_equals(
	icons.get("file_status", "D"), "[-]",
	"file_status.D should return '[-]' when disabled"
)
assert_equals(
	icons.get("file_status", "R"), "[R]",
	"file_status.R should return '[R]' when disabled"
)
assert_equals(
	icons.get("file_status", "M"), "[~]",
	"file_status.M should return '[~]' when disabled"
)

print("  [pass] icons ASCII fallback (enable=false)")

-- --------------------------------------------------------
-- 3. Icons module: Nerd Font mode (enable=true)
-- --------------------------------------------------------
icons.setup({ icons = { enable = true } })

-- Nerd Font icons should be non-empty and different from ASCII
local nerd_added = icons.get("git_state", "added")
assert_true(
	nerd_added ~= "" and nerd_added ~= "+",
	"git_state.added should return Nerd Font icon when enabled"
)

local nerd_pr_open = icons.get("github", "pr_open")
assert_true(
	nerd_pr_open ~= "" and nerd_pr_open ~= "[open]",
	"github.pr_open should return Nerd Font icon when enabled"
)

local nerd_branch_current = icons.get("branch", "current")
assert_true(
	nerd_branch_current ~= "" and nerd_branch_current ~= "*",
	"branch.current should return Nerd Font icon when enabled"
)

local nerd_file_a = icons.get("file_status", "A")
assert_true(
	nerd_file_a ~= "" and nerd_file_a ~= "[+]",
	"file_status.A should return Nerd Font icon when enabled"
)

local nerd_issue_open = icons.get("github", "issue_open")
assert_true(
	nerd_issue_open ~= "" and nerd_issue_open ~= "[open]",
	"github.issue_open should return Nerd Font icon when enabled"
)

local nerd_commit = icons.get("git_state", "commit")
assert_true(
	nerd_commit ~= "" and nerd_commit ~= "*",
	"git_state.commit should return Nerd Font icon when enabled"
)

print("  [pass] icons Nerd Font mode (enable=true)")

-- --------------------------------------------------------
-- 4. Icons module: unknown category/name returns empty string
-- --------------------------------------------------------
assert_equals(
	icons.get("nonexistent", "foo"), "",
	"unknown category should return empty string"
)
assert_equals(
	icons.get("git_state", "nonexistent"), "",
	"unknown name should return empty string"
)
assert_equals(
	icons.get("", ""), "",
	"empty category/name should return empty string"
)

print("  [pass] icons unknown category/name returns empty string")

-- --------------------------------------------------------
-- 5. Icons module: setup can be called multiple times
-- --------------------------------------------------------
icons.setup({ icons = { enable = false } })
assert_equals(
	icons.get("git_state", "added"), "+",
	"after re-setup with disabled, should return ASCII"
)

icons.setup({ icons = { enable = true } })
assert_true(
	icons.get("git_state", "added") ~= "+",
	"after re-setup with enabled, should return Nerd Font"
)

icons.setup({ icons = { enable = false } })
assert_equals(
	icons.get("git_state", "added"), "+",
	"setup should be idempotent across calls"
)

print("  [pass] icons setup idempotency")

-- --------------------------------------------------------
-- 6. Integration: gitflow.setup wires icons
-- --------------------------------------------------------
local gh = require("gitflow.gh")
local original_check_prerequisites = gh.check_prerequisites

gh.check_prerequisites = function(_)
	gh.state.checked = true
	gh.state.available = true
	gh.state.authenticated = true
	return true
end

local gitflow = require("gitflow")
gitflow.setup({ icons = { enable = true } })

local after_setup = icons.get("git_state", "added")
assert_true(
	after_setup ~= "+",
	"gitflow.setup with icons.enable=true should propagate to icons module"
)

gitflow.setup({ icons = { enable = false } })
assert_equals(
	icons.get("git_state", "added"), "+",
	"gitflow.setup with icons.enable=false should propagate"
)

gh.check_prerequisites = original_check_prerequisites

print("  [pass] gitflow.setup wires icons module")

-- --------------------------------------------------------
-- 7. Panel integration: verify icon module is required
-- --------------------------------------------------------
-- We verify that panel modules can be loaded and that icons
-- module is accessible from them (no require errors)
local ok_status = pcall(require, "gitflow.panels.status")
assert_true(ok_status, "panels/status.lua should load with icons require")

local ok_branch = pcall(require, "gitflow.panels.branch")
assert_true(ok_branch, "panels/branch.lua should load with icons require")

local ok_prs = pcall(require, "gitflow.panels.prs")
assert_true(ok_prs, "panels/prs.lua should load with icons require")

local ok_issues = pcall(require, "gitflow.panels.issues")
assert_true(ok_issues, "panels/issues.lua should load with icons require")

local ok_review = pcall(require, "gitflow.panels.review")
assert_true(ok_review, "panels/review.lua should load with icons require")

local ok_log = pcall(require, "gitflow.panels.log")
assert_true(ok_log, "panels/log.lua should load with icons require")

print("  [pass] all panels load with icons integration")

print("Stage 8 icon tests passed")
