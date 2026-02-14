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
			("%s (expected=%s, actual=%s)")
				:format(message, vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

local function assert_deep_equals(actual, expected, message)
	if not vim.deep_equal(actual, expected) then
		error(
			("%s (expected=%s, actual=%s)")
				:format(message, vim.inspect(expected), vim.inspect(actual)),
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

local function find_line(lines, needle, start_line)
	local from = start_line or 1
	for i = from, #lines do
		if lines[i]:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function read_lines(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	return vim.fn.readfile(path)
end

local function log_has_all(log_path, patterns)
	for _, line in ipairs(read_lines(log_path)) do
		local matches = true
		for _, pattern in ipairs(patterns) do
			if line:find(pattern, 1, true) == nil then
				matches = false
				break
			end
		end
		if matches then
			return true
		end
	end
	return false
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

local function find_float_window_by_filetype(filetype)
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local ok, config = pcall(vim.api.nvim_win_get_config, winid)
		if ok and config.relative and config.relative ~= "" then
			local bufnr = vim.api.nvim_win_get_buf(winid)
			local ft = vim.api.nvim_get_option_value(
				"filetype", { buf = bufnr }
			)
			if ft == filetype then
				return winid, bufnr
			end
		end
	end
	return nil, nil
end

-- ── gh/git stub setup ──────────────────────────────────────────

local stub_root = vim.fn.tempname()
assert_equals(
	vim.fn.mkdir(stub_root, "p"), 1, "stub root should be created"
)
local stub_bin = stub_root .. "/bin"
assert_equals(
	vim.fn.mkdir(stub_bin, "p"), 1, "stub bin should be created"
)
local gh_log = stub_root .. "/gh.log"

local gh_script = [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GITFLOW_GH_LOG"

if [ "$#" -ge 1 ] && [ "$1" = "--version" ]; then
  echo "gh version 2.55.0"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com as picker-test"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  sleep 0.1
  cat <<'JSON'
[{"number":10,"title":"Picker test issue","state":"OPEN","labels":[{"name":"bug","color":"d73a4a"}],"assignees":[{"login":"octocat"}],"author":{"login":"octocat"},"updatedAt":"2026-02-14T00:00:00Z"}]
JSON
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://example.com/issues/11"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  sleep 0.1
  cat <<'JSON'
[{"number":20,"title":"Picker test PR","state":"OPEN","isDraft":false,"labels":[{"name":"enhancement","color":"a2eeef"}],"author":{"login":"octocat"},"headRefName":"feature/pickers","baseRefName":"main","updatedAt":"2026-02-14T00:00:00Z","mergedAt":null,"assignees":[]}]
JSON
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://example.com/pull/21"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "list" ]; then
  sleep 0.1
  cat <<'JSON'
[{"name":"bug","color":"d73a4a","description":"Something is broken","isDefault":false},{"name":"enhancement","color":"a2eeef","description":"New feature","isDefault":false}]
JSON
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo '{"name":"Gitflow","nameWithOwner":"devGunnin/Gitflow","url":"https://github.com/devGunnin/Gitflow","description":"","isPrivate":false,"defaultBranchRef":{"name":"main"}}'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "api" ]; then
  case "$*" in
    *assignees*)
      printf 'alice\nbob\ncharlie\n'
      exit 0
      ;;
  esac
fi

echo "unsupported gh args: $*" >&2
exit 1
]]

local gh_path = stub_bin .. "/gh"
vim.fn.writefile(vim.split(gh_script, "\n", { plain = true }), gh_path)
vim.fn.setfperm(gh_path, "rwxr-xr-x")

-- Git stub: only for-each-ref is needed for branch listing
local git_script = [[#!/bin/sh
set -eu

if [ "$#" -ge 1 ] && [ "$1" = "for-each-ref" ]; then
  printf ' \tmain\trefs/heads/main\n'
  printf ' \tdevelop\trefs/heads/develop\n'
  printf ' \tfeature/pickers\trefs/heads/feature/pickers\n'
  printf ' \torigin\trefs/remotes/origin\n'
  printf ' \torigin/main\trefs/remotes/origin/main\n'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then
  pwd
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "rev-parse" ] && [ "$2" = "--abbrev-ref" ] && [ "$3" = "HEAD" ]; then
  echo "main"
  exit 0
fi

if [ "$#" -ge 1 ] && [ "$1" = "rev-parse" ]; then
  echo "main"
  exit 0
fi

if [ "$#" -ge 1 ] && [ "$1" = "diff" ]; then
  exit 0
fi

if [ "$#" -ge 1 ] && [ "$1" = "status" ]; then
  echo "nothing to commit"
  exit 0
fi

echo "git: $*" >&2
exit 0
]]

local git_path = stub_bin .. "/git"
vim.fn.writefile(vim.split(git_script, "\n", { plain = true }), git_path)
vim.fn.setfperm(git_path, "rwxr-xr-x")

local original_path = vim.env.PATH
local original_notify = vim.notify
vim.env.PATH = stub_bin .. ":" .. (original_path or "")
vim.env.GITFLOW_GH_LOG = gh_log

local gitflow = require("gitflow")
local cfg = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 44,
		},
	},
})

local notifications = {}
vim.notify = function(message, level, _)
	notifications[#notifications + 1] = {
		message = tostring(message),
		level = level,
	}
end

local passed = 0

-- ── Test 1: List picker module loads ──────────────────────────

local list_picker = require("gitflow.ui.list_picker")
assert_true(
	type(list_picker.open) == "function",
	"list_picker.open should be a function"
)
assert_true(
	type(list_picker.filter_items) == "function",
	"list_picker.filter_items should be a function"
)
passed = passed + 1
print(("  [%d] list_picker module loads"):format(passed))

-- ── Test 2: filter_items fuzzy filtering ──────────────────────

local filtered = list_picker.filter_items({
	{ name = "main" },
	{ name = "develop" },
	{ name = "feature/pickers" },
	{ name = "bugfix/typo" },
}, "dev")
assert_equals(#filtered, 1, "fuzzy filter should narrow to one item")
assert_equals(
	filtered[1].name, "develop",
	"fuzzy filter should match 'develop'"
)

local filtered_all = list_picker.filter_items({
	{ name = "main" },
	{ name = "develop" },
}, "")
assert_equals(
	#filtered_all, 2,
	"empty query should return all items"
)
passed = passed + 1
print(("  [%d] filter_items fuzzy filtering works"):format(passed))

-- ── Test 3: List picker opens with multi-select mode ──────────

local multi_submit = nil
local multi_state = list_picker.open({
	title = "Multi Select Test",
	items = {
		{ name = "alice", description = "Developer" },
		{ name = "bob", description = "Designer" },
		{ name = "charlie", description = "PM" },
	},
	selected = { "alice" },
	multi_select = true,
	on_submit = function(selected)
		multi_submit = selected
	end,
})

assert_true(multi_state.winid ~= nil, "picker should create a window")
assert_true(
	vim.api.nvim_win_is_valid(multi_state.winid),
	"picker window should be valid"
)
assert_true(multi_state.multi_select, "should be multi-select mode")

local picker_lines = vim.api.nvim_buf_get_lines(
	multi_state.bufnr, 0, -1, false
)
assert_true(
	find_line(picker_lines, "[x] alice") ~= nil,
	"picker should mark preselected items"
)
assert_true(
	find_line(picker_lines, "[ ] bob") ~= nil,
	"picker should show unselected items"
)

-- Check keymaps: multi-select should have Space toggle and <CR> apply
assert_keymaps(multi_state.bufnr, {
	"j", "k", " ", "<CR>", "/", "c", "q", "<Esc>",
})

-- Toggle bob and confirm
vim.api.nvim_set_current_win(multi_state.winid)
vim.api.nvim_feedkeys("j", "x", false)  -- move to bob
vim.api.nvim_feedkeys(" ", "x", false)   -- toggle bob
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<CR>", true, false, true),
	"x", false
)

wait_until(function()
	return multi_submit ~= nil
end, "multi-select submit should fire")
assert_deep_equals(
	multi_submit, { "alice", "bob" },
	"multi-select should return toggled items"
)
passed = passed + 1
print(("  [%d] list_picker multi-select works"):format(passed))

-- ── Test 4: List picker opens with single-select mode ─────────

local single_submit = nil
local single_state = list_picker.open({
	title = "Single Select Test",
	items = {
		{ name = "main" },
		{ name = "develop" },
		{ name = "feature/pickers" },
	},
	multi_select = false,
	on_submit = function(selected)
		single_submit = selected
	end,
})

assert_true(single_state.winid ~= nil, "single picker should create window")
assert_true(
	not single_state.multi_select, "should be single-select mode"
)

local single_lines = vim.api.nvim_buf_get_lines(
	single_state.bufnr, 0, -1, false
)
-- Single-select uses ">" marker, not checkboxes
assert_true(
	find_line(single_lines, "[x]") == nil,
	"single-select should not have checkboxes"
)

-- Select first item (CR on active line, items sorted alphabetically)
vim.api.nvim_set_current_win(single_state.winid)
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<CR>", true, false, true),
	"x", false
)

wait_until(function()
	return single_submit ~= nil
end, "single-select submit should fire")
assert_equals(
	#single_submit, 1,
	"single-select should return exactly one item"
)
-- Items are sorted alphabetically: develop, feature/pickers, main
assert_equals(
	single_submit[1], "develop",
	"single-select should return the first alphabetical item"
)
passed = passed + 1
print(("  [%d] list_picker single-select works"):format(passed))

-- ── Test 5: List picker cancel ────────────────────────────────

local cancel_called = false
local cancel_state = list_picker.open({
	title = "Cancel Test",
	items = { { name = "item1" } },
	on_submit = function(_) end,
	on_cancel = function()
		cancel_called = true
	end,
})

vim.api.nvim_set_current_win(cancel_state.winid)
vim.api.nvim_feedkeys("q", "x", false)

wait_until(function()
	return cancel_called
end, "cancel callback should fire", 1000)
assert_true(cancel_state.closed, "picker should be marked closed")
passed = passed + 1
print(("  [%d] list_picker cancel works"):format(passed))

-- ── Test 6: List picker with string items ─────────────────────

local string_state = list_picker.open({
	title = "String Items",
	items = { "alpha", "beta", "gamma" },
	on_submit = function(_) end,
})

assert_equals(
	#string_state.items, 3,
	"string items should be normalized to table items"
)
assert_equals(
	string_state.items[1].name, "alpha",
	"first string item name should be 'alpha'"
)

pcall(vim.api.nvim_win_close, string_state.winid, true)
pcall(vim.api.nvim_buf_delete, string_state.bufnr, { force = true })
passed = passed + 1
print(("  [%d] list_picker handles string items"):format(passed))

-- ── Test 7: List picker active-line highlighting ──────────────

local hl_state = list_picker.open({
	title = "Highlight Test",
	items = {
		{ name = "one" },
		{ name = "two" },
	},
	on_submit = function(_) end,
})

assert_true(
	hl_state.active_line ~= nil,
	"active_line should be set after open"
)
assert_equals(
	hl_state.active_line, 3,
	"active_line should be 3 (first item after header + separator)"
)

local hl_ns = vim.api.nvim_create_namespace("gitflow_list_picker_hl")
local hl_marks = vim.api.nvim_buf_get_extmarks(
	hl_state.bufnr, hl_ns,
	{ hl_state.active_line - 1, 0 },
	{ hl_state.active_line - 1, -1 },
	{ details = true }
)
local has_active_hl = false
for _, mark in ipairs(hl_marks) do
	local details = mark[4]
	if details and details.hl_group == "GitflowFormActiveField" then
		has_active_hl = true
		break
	end
end
assert_true(
	has_active_hl,
	"active line should have GitflowFormActiveField highlight"
)

pcall(vim.api.nvim_win_close, hl_state.winid, true)
pcall(vim.api.nvim_buf_delete, hl_state.bufnr, { force = true })
passed = passed + 1
print(("  [%d] list_picker active-line highlighting works"):format(passed))

-- ── Test 8: Issue form has assignee picker (<C-l>) ────────────

local buffer = require("gitflow.ui.buffer")
local commands = require("gitflow.commands")
local issues_panel = require("gitflow.panels.issues")

-- Open issue list first
commands.dispatch({ "issue", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "#10") ~= nil
end, "issue list should render")

-- Stub out list_picker to verify it gets called for assignees
local list_picker_stub = require("gitflow.ui.list_picker")
local original_list_picker_open = list_picker_stub.open
local assignee_picker_opened = false
local assignee_picker_items = nil
list_picker_stub.open = function(opts)
	if opts.title and opts.title:find("Assignee") then
		assignee_picker_opened = true
		assignee_picker_items = opts.items
		opts.on_submit({ "alice", "bob" })
		return {
			bufnr = nil, winid = nil, closed = true,
			items = {}, selected = {}, multi_select = true,
			query = "", filtered = {}, line_entries = {},
			active_line = nil, on_submit = opts.on_submit,
		}
	end
	return original_list_picker_open(opts)
end

issues_panel.create_interactive()
wait_until(function()
	local winid = find_float_window_by_filetype("gitflow-form")
	return winid ~= nil
end, "issue form should open", 3000)

-- Navigate to Assignees field and trigger picker
local issue_form_win, issue_form_buf =
	find_float_window_by_filetype("gitflow-form")
assert_true(
	issue_form_win ~= nil, "issue form window should be found"
)

local issue_form_lines = vim.api.nvim_buf_get_lines(
	issue_form_buf, 0, -1, false
)
-- Verify form has <C-l> keymap (picker hint)
assert_true(
	find_line(issue_form_lines, "<C-l> picker") ~= nil,
	"issue form should show <C-l> picker hint"
)

-- Fill title first
local title_line = find_line(issue_form_lines, "Title")
assert_true(title_line ~= nil, "issue form should have Title")
vim.api.nvim_buf_set_lines(
	issue_form_buf,
	title_line,
	title_line + 1,
	false,
	{ "Picker assignee test" }
)

-- Navigate to Assignees field (field 4) and trigger picker
vim.api.nvim_set_current_win(issue_form_win)
local tab = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
vim.api.nvim_feedkeys(tab, "x", false) -- field 1 -> 2
vim.api.nvim_feedkeys(tab, "x", false) -- field 2 -> 3
vim.api.nvim_feedkeys(tab, "x", false) -- field 3 -> 4 (assignees)
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<C-l>", true, false, true),
	"x", false
)

-- Submit form
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<CR>", true, false, true),
	"x", false
)

wait_until(function()
	return log_has_all(gh_log, {
		"issue create",
		"--title Picker assignee test",
		"--assignee alice,bob",
	})
end, "issue create should include picker-selected assignees", 3000)

assert_true(
	assignee_picker_opened,
	"assignee picker should have been opened for issue form"
)
list_picker_stub.open = original_list_picker_open
passed = passed + 1
print(("  [%d] issue form assignee picker works"):format(passed))

-- ── Test 9: PR form has branch picker (<C-l>) ─────────────────

local pr_panel = require("gitflow.panels.prs")
commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "#20") ~= nil
end, "pr list should render")

-- Stub both list_picker and label_picker for PR form
local branch_picker_opened = false
local branch_picker_items = nil
local reviewer_picker_opened = false
list_picker_stub.open = function(opts)
	if opts.title and opts.title:find("Branch") then
		branch_picker_opened = true
		branch_picker_items = opts.items
		assert_true(
			not opts.multi_select,
			"branch picker should be single-select"
		)
		opts.on_submit({ "develop" })
		return {
			bufnr = nil, winid = nil, closed = true,
			items = {}, selected = {}, multi_select = false,
			query = "", filtered = {}, line_entries = {},
			active_line = nil, on_submit = opts.on_submit,
		}
	elseif opts.title and opts.title:find("Reviewer") then
		reviewer_picker_opened = true
		opts.on_submit({ "alice" })
		return {
			bufnr = nil, winid = nil, closed = true,
			items = {}, selected = {}, multi_select = true,
			query = "", filtered = {}, line_entries = {},
			active_line = nil, on_submit = opts.on_submit,
		}
	end
	return original_list_picker_open(opts)
end

local label_picker_mod = require("gitflow.ui.label_picker")
local original_label_picker_open = label_picker_mod.open
label_picker_mod.open = function(opts)
	opts.on_submit({ "bug" })
	return { bufnr = nil, winid = nil }
end

pr_panel.create_interactive()
wait_until(function()
	local winid = find_float_window_by_filetype("gitflow-form")
	return winid ~= nil
end, "pr form should open", 3000)

local pr_form_win, pr_form_buf =
	find_float_window_by_filetype("gitflow-form")
assert_true(pr_form_win ~= nil, "pr form window should be found")

local pr_form_lines = vim.api.nvim_buf_get_lines(
	pr_form_buf, 0, -1, false
)
-- Verify form has <C-l> picker hint
assert_true(
	find_line(pr_form_lines, "<C-l> picker") ~= nil,
	"pr form should show <C-l> picker hint"
)

-- Fill title
local pr_title_line = find_line(pr_form_lines, "Title")
vim.api.nvim_buf_set_lines(
	pr_form_buf,
	pr_title_line,
	pr_title_line + 1,
	false,
	{ "PR picker branch test" }
)

-- Navigate to Base branch (field 3) and trigger picker
vim.api.nvim_set_current_win(pr_form_win)
vim.api.nvim_feedkeys(tab, "x", false) -- 1 -> 2
vim.api.nvim_feedkeys(tab, "x", false) -- 2 -> 3 (base branch)
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<C-l>", true, false, true),
	"x", false
)

-- Navigate to Reviewers (field 4) and trigger picker
vim.api.nvim_feedkeys(tab, "x", false) -- 3 -> 4
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<C-l>", true, false, true),
	"x", false
)

-- Navigate to Labels (field 5) and trigger picker
vim.api.nvim_feedkeys(tab, "x", false) -- 4 -> 5
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<C-l>", true, false, true),
	"x", false
)

-- Submit
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<CR>", true, false, true),
	"x", false
)

wait_until(function()
	return log_has_all(gh_log, {
		"pr create",
		"--title PR picker branch test",
		"--base develop",
	})
end, "pr create should include picker-selected base branch", 3000)

assert_true(
	branch_picker_opened,
	"branch picker should have been opened for PR form"
)
assert_true(
	branch_picker_items ~= nil and #branch_picker_items > 0,
	"branch picker should have received branch items"
)
assert_true(
	reviewer_picker_opened,
	"reviewer picker should have been opened for PR form"
)

list_picker_stub.open = original_list_picker_open
label_picker_mod.open = original_label_picker_open
passed = passed + 1
print(("  [%d] pr form branch and reviewer pickers work"):format(passed))

-- ── Test 10: PR form branch items include local branches ──────

-- branch_picker_items was captured during test 9
local has_main = false
local has_develop = false
local has_feature = false
local has_origin = false
local has_origin_main = false
for _, item in ipairs(branch_picker_items or {}) do
	if item.name == "main" then
		has_main = true
	end
	if item.name == "develop" then
		has_develop = true
	end
	if item.name == "feature/pickers" then
		has_feature = true
	end
	if item.name == "origin" then
		has_origin = true
	end
	if item.name == "origin/main" then
		has_origin_main = true
	end
end
assert_true(has_main, "branch items should include main")
assert_true(has_develop, "branch items should include develop")
assert_true(has_feature, "branch items should include feature/pickers")
assert_true(not has_origin, "branch items should exclude remote sentinel origin")
assert_true(not has_origin_main, "branch items should exclude remote branch origin/main")
passed = passed + 1
print(("  [%d] pr form branch items include local branches"):format(passed))

-- ── Cleanup ────────────────────────────────────────────────────

vim.notify = original_notify
vim.env.PATH = original_path
print(
	("Stage 10 picker smoke tests passed (%d tests)"):format(passed)
)
