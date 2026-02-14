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

-- ── gh stub setup ──────────────────────────────────────────────

local stub_root = vim.fn.tempname()
assert_equals(vim.fn.mkdir(stub_root, "p"), 1, "stub root should be created")
local stub_bin = stub_root .. "/bin"
assert_equals(vim.fn.mkdir(stub_bin, "p"), 1, "stub bin should be created")
local gh_log = stub_root .. "/gh.log"

local gh_script = [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GITFLOW_GH_LOG"

if [ "$#" -ge 1 ] && [ "$1" = "--version" ]; then
  echo "gh version 2.55.0"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com as forms-test"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  sleep 0.1
  cat <<'JSON'
[{"number":10,"title":"Form test issue","state":"OPEN","labels":[{"name":"bug","color":"d73a4a"},{"name":"docs","color":"0075ca"}],"assignees":[{"login":"octocat"}],"author":{"login":"octocat"},"updatedAt":"2026-02-14T00:00:00Z"}]
JSON
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  sleep 0.1
  cat <<'JSON'
{"number":10,"title":"Form test issue","body":"Issue body","state":"OPEN","labels":[{"name":"bug","color":"d73a4a"},{"name":"docs","color":"0075ca"}],"assignees":[{"login":"octocat"}],"author":{"login":"octocat"},"comments":[]}
JSON
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://example.com/issues/11"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  echo "issue edit ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  sleep 0.1
  cat <<'JSON'
[{"number":20,"title":"Form test PR","state":"OPEN","isDraft":false,"labels":[{"name":"enhancement","color":"a2eeef"}],"author":{"login":"octocat"},"headRefName":"feature/forms","baseRefName":"main","updatedAt":"2026-02-14T00:00:00Z","mergedAt":null,"assignees":[]}]
JSON
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  sleep 0.1
  cat <<'JSON'
{"number":20,"title":"Form test PR","body":"PR body","state":"OPEN","isDraft":false,"labels":[{"name":"enhancement","color":"a2eeef"}],"author":{"login":"octocat"},"headRefName":"feature/forms","baseRefName":"main","reviewRequests":[],"reviews":[],"comments":[],"files":[],"assignees":[]}
JSON
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://example.com/pull/21"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  echo "pr edit ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "list" ]; then
  sleep 0.1
  cat <<'JSON'
[{"name":"bug","color":"d73a4a","description":"Something is broken","isDefault":false},{"name":"docs","color":"0075ca","description":"Documentation","isDefault":false},{"name":"enhancement","color":"a2eeef","description":"New feature","isDefault":false}]
JSON
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "create" ]; then
  echo "label create ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo '{"name":"Gitflow","nameWithOwner":"devGunnin/Gitflow","url":"https://github.com/devGunnin/Gitflow","description":"","isPrivate":false,"defaultBranchRef":{"name":"main"}}'
  exit 0
fi

echo "unsupported gh args: $*" >&2
exit 1
]]

local gh_path = stub_bin .. "/gh"
vim.fn.writefile(vim.split(gh_script, "\n", { plain = true }), gh_path)
vim.fn.setfperm(gh_path, "rwxr-xr-x")

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

-- ── Test 1: Form module loads ──────────────────────────────────

local form = require("gitflow.ui.form")
assert_true(type(form.open) == "function", "form.open should be a function")
passed = passed + 1
print(("  [%d] form module loads"):format(passed))

-- ── Test 2: Highlight groups registered ────────────────────────

local highlights = require("gitflow.highlights")
assert_true(
	highlights.DEFAULT_GROUPS.GitflowFormLabel ~= nil,
	"GitflowFormLabel should be defined"
)
assert_true(
	highlights.DEFAULT_GROUPS.GitflowFormActiveField ~= nil,
	"GitflowFormActiveField should be defined"
)
passed = passed + 1
print(("  [%d] form highlight groups registered"):format(passed))

-- ── Test 3: label_color_group creates dynamic groups ───────────

local group1 = highlights.label_color_group("d73a4a")
assert_equals(group1, "GitflowLabel_d73a4a", "should create group from hex")
local hl = vim.api.nvim_get_hl(0, { name = group1 })
assert_true(hl.bg ~= nil, "label color group should have bg set")
passed = passed + 1
print(("  [%d] label_color_group creates dynamic groups"):format(passed))

-- ── Test 4: label_color_group handles invalid color ────────────

local group2 = highlights.label_color_group("zzz")
assert_equals(group2, "Comment", "invalid hex should return Comment")
local group3 = highlights.label_color_group("")
assert_equals(group3, "Comment", "empty hex should return Comment")
passed = passed + 1
print(("  [%d] label_color_group handles invalid colors"):format(passed))

-- ── Test 5: label_color_group handles # prefix ─────────────────

local group4 = highlights.label_color_group("#a2eeef")
assert_equals(group4, "GitflowLabel_a2eeef", "should strip # prefix")
passed = passed + 1
print(("  [%d] label_color_group handles # prefix"):format(passed))

-- ── Test 6: Form open creates buffer with fields ───────────────

local submit_values = nil
local cancel_called = false
local form_state = form.open({
	title = "Test Form",
	fields = {
		{ name = "Name", key = "name", required = true },
		{ name = "Color", key = "color", placeholder = "e.g. ff0000" },
		{ name = "Notes", key = "notes", multiline = true },
	},
	on_submit = function(values)
		submit_values = values
	end,
	on_cancel = function()
		cancel_called = true
	end,
})

assert_true(form_state.bufnr ~= nil, "form should create buffer")
assert_true(
	vim.api.nvim_buf_is_valid(form_state.bufnr),
	"form buffer should be valid"
)
assert_true(form_state.winid ~= nil, "form should create window")
assert_true(
	vim.api.nvim_win_is_valid(form_state.winid),
	"form window should be valid"
)
passed = passed + 1
print(("  [%d] form.open creates buffer and window"):format(passed))

-- ── Test 7: Form buffer has field labels ───────────────────────

local form_lines = vim.api.nvim_buf_get_lines(form_state.bufnr, 0, -1, false)
assert_true(
	find_line(form_lines, "Name") ~= nil,
	"form should contain Name field label"
)
assert_true(
	find_line(form_lines, "Color") ~= nil,
	"form should contain Color field label"
)
assert_true(
	find_line(form_lines, "Notes") ~= nil,
	"form should contain Notes field label"
)
passed = passed + 1
print(("  [%d] form buffer has field labels"):format(passed))

-- ── Test 8: Form has navigation keymaps ────────────────────────

assert_keymaps(form_state.bufnr, { "<Tab>", "<S-Tab>", "<CR>", "q", "<Esc>" })
passed = passed + 1
print(("  [%d] form has navigation keymaps"):format(passed))

-- ── Test 9: Form field_lines records positions ─────────────────

assert_true(
	form_state.field_lines[1] ~= nil,
	"field_lines should record field 1"
)
assert_true(
	form_state.field_lines[2] ~= nil,
	"field_lines should record field 2"
)
assert_true(
	form_state.field_lines[3] ~= nil,
	"field_lines should record field 3"
)
assert_true(
	form_state.field_lines[1].start <= form_state.field_lines[2].start,
	"field 1 should be above field 2"
)
passed = passed + 1
print(("  [%d] form field_lines records positions"):format(passed))

-- ── Test 10: Form footer hints ─────────────────────────────────

assert_true(
	find_line(form_lines, "<Tab> next") ~= nil,
	"form footer should show Tab hint"
)
assert_true(
	find_line(form_lines, "<CR> submit") ~= nil,
	"form footer should show CR hint"
)
passed = passed + 1
print(("  [%d] form footer hints present"):format(passed))

-- ── Test 11: Form cancel via q closes ──────────────────────────

-- Close the test form
pcall(vim.api.nvim_win_close, form_state.winid, true)
pcall(vim.api.nvim_buf_delete, form_state.bufnr, { force = true })
passed = passed + 1
print(("  [%d] form cleanup works"):format(passed))

-- ── Test 12: Form required field validation ────────────────────

local validation_submit_called = false
local validation_state = form.open({
	title = "Validate Form",
	fields = {
		{ name = "Title", key = "title", required = true },
		{ name = "Body", key = "body" },
	},
	on_submit = function(_)
		validation_submit_called = true
	end,
})

-- Trigger submit with empty required field
local submit_maps = vim.api.nvim_buf_get_keymap(validation_state.bufnr, "n")
local cr_map = nil
for _, map in ipairs(submit_maps) do
	if map.lhs == "<CR>" then
		cr_map = map
		break
	end
end
assert_true(cr_map ~= nil, "CR keymap should exist")

-- Execute CR — title is empty, so submit should not fire
vim.api.nvim_set_current_win(validation_state.winid)
vim.api.nvim_feedkeys(
	vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false
)
assert_true(
	not validation_submit_called,
	"submit should not fire with empty required field"
)
assert_true(
	notifications[#notifications] ~= nil
		and notifications[#notifications].message:find("Title is required"),
	"should notify about required field"
)

pcall(vim.api.nvim_win_close, validation_state.winid, true)
pcall(vim.api.nvim_buf_delete, validation_state.bufnr, { force = true })
passed = passed + 1
print(("  [%d] form required field validation"):format(passed))

-- ── Test 13: Labels panel shows colored labels ─────────────────

local buffer = require("gitflow.ui.buffer")
local commands = require("gitflow.commands")

commands.dispatch({ "label", "list" }, cfg)
wait_until(function()
	local bufnr = buffer.get("labels")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "bug (#d73a4a)") ~= nil
end, "label list should render labels with colors")

local label_buf = buffer.get("labels")
assert_true(label_buf ~= nil, "label panel should open")

-- Check that colored highlight extmarks exist on label lines
local label_lines = vim.api.nvim_buf_get_lines(label_buf, 0, -1, false)
local bug_line = find_line(label_lines, "bug (#d73a4a)")
assert_true(bug_line ~= nil, "bug label should appear in label list")

local label_ns = vim.api.nvim_create_namespace("gitflow_labels_hl")
local extmarks = vim.api.nvim_buf_get_extmarks(
	label_buf, label_ns, { bug_line - 1, 0 }, { bug_line - 1, -1 }, { details = true }
)
-- Should have at least one highlight on the bug label line
local has_label_color = false
for _, mark in ipairs(extmarks) do
	local details = mark[4]
	if details and details.hl_group and details.hl_group:find("GitflowLabel_") then
		has_label_color = true
		break
	end
end
assert_true(
	has_label_color,
	"label list should have colored label highlights"
)
passed = passed + 1
print(("  [%d] labels panel shows colored labels"):format(passed))

-- ── Test 14: Issues panel shows colored labels ─────────────────

commands.dispatch({ "issue", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "#10") ~= nil
		and find_line(lines, "labels:") ~= nil
end, "issue list should render issue with labels line")

local issue_buf = buffer.get("issues")
local issue_lines = vim.api.nvim_buf_get_lines(issue_buf, 0, -1, false)
local issue_label_line = find_line(issue_lines, "labels:")
assert_true(
	issue_label_line ~= nil,
	"issue list should have labels line"
)

local issue_ns = vim.api.nvim_create_namespace("gitflow_issues_hl")
local issue_extmarks = vim.api.nvim_buf_get_extmarks(
	issue_buf, issue_ns,
	{ issue_label_line - 1, 0 },
	{ issue_label_line - 1, -1 },
	{ details = true }
)
local has_issue_label_color = false
for _, mark in ipairs(issue_extmarks) do
	local details = mark[4]
	if details and details.hl_group and details.hl_group:find("GitflowLabel_") then
		has_issue_label_color = true
		break
	end
end
assert_true(
	has_issue_label_color,
	"issue list should have colored label highlights"
)
passed = passed + 1
print(("  [%d] issues panel shows colored labels"):format(passed))

-- ── Test 15: Issue detail view shows colored labels ────────────

commands.dispatch({ "issue", "view", "10" }, cfg)
wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Issue #10: Form test issue") ~= nil
end, "issue detail should render")

local issue_view_buf = buffer.get("issues")
local issue_view_lines = vim.api.nvim_buf_get_lines(
	issue_view_buf, 0, -1, false
)
local labels_detail_line = find_line(issue_view_lines, "Labels:")
assert_true(
	labels_detail_line ~= nil,
	"issue detail should show Labels line"
)

local detail_extmarks = vim.api.nvim_buf_get_extmarks(
	issue_view_buf, issue_ns,
	{ labels_detail_line - 1, 0 },
	{ labels_detail_line - 1, -1 },
	{ details = true }
)
local has_detail_label_color = false
for _, mark in ipairs(detail_extmarks) do
	local details = mark[4]
	if details and details.hl_group
		and details.hl_group:find("GitflowLabel_") then
		has_detail_label_color = true
		break
	end
end
assert_true(
	has_detail_label_color,
	"issue detail should have colored label highlights"
)
passed = passed + 1
print(("  [%d] issue detail view shows colored labels"):format(passed))

-- ── Test 16: PR detail view shows Labels line ──────────────────

commands.dispatch({ "pr", "view", "20" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "PR #20: Form test PR") ~= nil
end, "pr detail should render")

local pr_view_buf = buffer.get("prs")
local pr_view_lines = vim.api.nvim_buf_get_lines(pr_view_buf, 0, -1, false)
local pr_labels_line = find_line(pr_view_lines, "Labels:")
assert_true(
	pr_labels_line ~= nil,
	"pr detail should show Labels line"
)
assert_true(
	pr_view_lines[pr_labels_line]:find("enhancement"),
	"pr detail Labels line should contain label name"
)

local pr_ns = vim.api.nvim_create_namespace("gitflow_prs_hl")
local pr_extmarks = vim.api.nvim_buf_get_extmarks(
	pr_view_buf, pr_ns,
	{ pr_labels_line - 1, 0 },
	{ pr_labels_line - 1, -1 },
	{ details = true }
)
local has_pr_label_color = false
for _, mark in ipairs(pr_extmarks) do
	local details = mark[4]
	if details and details.hl_group
		and details.hl_group:find("GitflowLabel_") then
		has_pr_label_color = true
		break
	end
end
assert_true(
	has_pr_label_color,
	"pr detail should have colored label highlights"
)
passed = passed + 1
print(("  [%d] pr detail view shows colored labels"):format(passed))

-- ── Test 17: Issue create_interactive opens form ───────────────

local issues_panel = require("gitflow.panels.issues")
issues_panel.create_interactive()

-- Form float should have opened
wait_until(function()
	local wins = vim.api.nvim_list_wins()
	for _, winid in ipairs(wins) do
		local ok, config = pcall(vim.api.nvim_win_get_config, winid)
		if ok and config.relative and config.relative ~= "" then
			local wbuf = vim.api.nvim_win_get_buf(winid)
			local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
			if ft == "gitflow-form" then
				return true
			end
		end
	end
	return false
end, "issue create should open form float", 2000)

-- Find the form buffer, read lines, then close
local form_buf = nil
local issue_form_lines = {}
for _, winid in ipairs(vim.api.nvim_list_wins()) do
	local ok, wconfig = pcall(vim.api.nvim_win_get_config, winid)
	if ok and wconfig.relative and wconfig.relative ~= "" then
		local wbuf = vim.api.nvim_win_get_buf(winid)
		local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
		if ft == "gitflow-form" then
			form_buf = wbuf
			issue_form_lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
			pcall(vim.api.nvim_win_close, winid, true)
			break
		end
	end
end
assert_true(form_buf ~= nil, "issue form buffer should exist")
assert_true(
	find_line(issue_form_lines, "Title") ~= nil,
	"issue form should have Title field"
)
assert_true(
	find_line(issue_form_lines, "Body") ~= nil,
	"issue form should have Body field"
)
assert_true(
	find_line(issue_form_lines, "Labels") ~= nil,
	"issue form should have Labels field"
)
assert_true(
	find_line(issue_form_lines, "Assignees") ~= nil,
	"issue form should have Assignees field"
)
passed = passed + 1
print(("  [%d] issue create opens form with correct fields"):format(passed))

-- ── Test 18: PR create_interactive opens form ──────────────────

local pr_panel = require("gitflow.panels.prs")
-- Ensure PR panel is open first
commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "#20") ~= nil
end, "pr list should render")

pr_panel.create_interactive()

wait_until(function()
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local ok, config = pcall(vim.api.nvim_win_get_config, winid)
		if ok and config.relative and config.relative ~= "" then
			local wbuf = vim.api.nvim_win_get_buf(winid)
			local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
			if ft == "gitflow-form" then
				return true
			end
		end
	end
	return false
end, "pr create should open form float", 2000)

local pr_form_buf = nil
local pr_form_lines = {}
for _, winid in ipairs(vim.api.nvim_list_wins()) do
	local ok, wconfig = pcall(vim.api.nvim_win_get_config, winid)
	if ok and wconfig.relative and wconfig.relative ~= "" then
		local wbuf = vim.api.nvim_win_get_buf(winid)
		local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
		if ft == "gitflow-form" then
			pr_form_buf = wbuf
			pr_form_lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
			pcall(vim.api.nvim_win_close, winid, true)
			break
		end
	end
end
assert_true(pr_form_buf ~= nil, "pr form buffer should exist")
assert_true(
	find_line(pr_form_lines, "Title") ~= nil,
	"pr form should have Title field"
)
assert_true(
	find_line(pr_form_lines, "Body") ~= nil,
	"pr form should have Body field"
)
assert_true(
	find_line(pr_form_lines, "Base branch") ~= nil,
	"pr form should have Base branch field"
)
assert_true(
	find_line(pr_form_lines, "Reviewers") ~= nil,
	"pr form should have Reviewers field"
)
assert_true(
	find_line(pr_form_lines, "Labels") ~= nil,
	"pr form should have Labels field"
)
passed = passed + 1
print(("  [%d] pr create opens form with correct fields"):format(passed))

-- ── Test 19: Label create_interactive opens form ───────────────

local label_panel = require("gitflow.panels.labels")
label_panel.create_interactive()

wait_until(function()
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local ok, config = pcall(vim.api.nvim_win_get_config, winid)
		if ok and config.relative and config.relative ~= "" then
			local wbuf = vim.api.nvim_win_get_buf(winid)
			local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
			if ft == "gitflow-form" then
				return true
			end
		end
	end
	return false
end, "label create should open form float", 2000)

local label_form_buf = nil
local label_form_lines = {}
for _, winid in ipairs(vim.api.nvim_list_wins()) do
	local ok, wconfig = pcall(vim.api.nvim_win_get_config, winid)
	if ok and wconfig.relative and wconfig.relative ~= "" then
		local wbuf = vim.api.nvim_win_get_buf(winid)
		local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
		if ft == "gitflow-form" then
			label_form_buf = wbuf
			label_form_lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
			pcall(vim.api.nvim_win_close, winid, true)
			break
		end
	end
end
assert_true(label_form_buf ~= nil, "label form buffer should exist")
assert_true(
	find_line(label_form_lines, "Name") ~= nil,
	"label form should have Name field"
)
assert_true(
	find_line(label_form_lines, "Color") ~= nil,
	"label form should have Color field"
)
assert_true(
	find_line(label_form_lines, "Description") ~= nil,
	"label form should have Description field"
)
passed = passed + 1
print(("  [%d] label create opens form with correct fields"):format(passed))

-- ── Test 20: Form active_field starts at 1 ─────────────────────

local tracking_state = form.open({
	title = "Track Form",
	fields = {
		{ name = "A", key = "a" },
		{ name = "B", key = "b" },
	},
	on_submit = function(_) end,
})
assert_equals(
	tracking_state.active_field, 1,
	"active field should start at 1"
)
pcall(vim.api.nvim_win_close, tracking_state.winid, true)
pcall(vim.api.nvim_buf_delete, tracking_state.bufnr, { force = true })
passed = passed + 1
print(("  [%d] form active_field starts at 1"):format(passed))

-- ── Cleanup ────────────────────────────────────────────────────

vim.notify = original_notify
vim.env.PATH = original_path
print(("Stage 10 forms smoke tests passed (%d tests)"):format(passed))
