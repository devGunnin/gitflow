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

local function count_lines_with(lines, needle)
	local count = 0
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) ~= nil then
			count = count + 1
		end
	end
	return count
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

local function assert_keymap_absent(bufnr, lhs)
	local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
	for _, map in ipairs(keymaps) do
		if map.lhs == lhs then
			error(("unexpected keymap '%s'"):format(lhs), 2)
		end
	end
end

local function current_cmdline_mapping(lhs)
	local mapping = vim.fn.maparg(lhs, "c", false, true)
	if type(mapping) ~= "table" or mapping.lhs == nil then
		return nil
	end
	return mapping
end

local function restore_cmdline_mapping(lhs, mapping)
	pcall(vim.keymap.del, "c", lhs)
	if mapping then
		vim.fn.mapset("c", false, mapping)
	end
end

local stub_root = vim.fn.tempname()
assert_equals(vim.fn.mkdir(stub_root, "p"), 1, "stub root should be created")
local stub_bin = stub_root .. "/bin"
assert_equals(vim.fn.mkdir(stub_bin, "p"), 1, "stub bin should be created")
local gh_log = stub_root .. "/gh.log"
local pr_edit_fail_once = stub_root .. "/pr_edit_fail_once"

local gh_script = [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$GITFLOW_GH_LOG"

if [ "$#" -ge 1 ] && [ "$1" = "--version" ]; then
  echo "gh version 2.55.0"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com as stage4-test"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  sleep 0.15
  echo '[{"number":1,"title":"Stage4 issue","state":"OPEN","labels":[{"name":"bug"}],"assignees":[],"author":{"login":"octocat"},"updatedAt":"2026-02-08T00:00:00Z"}]'
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "issue" ] && [ "$2" = "view" ] && [ "$3" = "1" ]; then
  sleep 0.15
  echo '{"number":1,"title":"Stage4 issue","body":"Issue body","state":"OPEN","labels":[{"name":"bug"}],"author":{"login":"octocat"},"comments":[{"body":"First comment","author":{"login":"hubot"}}]}'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://example.com/devGunnin/Gitflow/issues/2"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  echo "issue comment ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "close" ]; then
  echo "issue close ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "reopen" ]; then
  echo "issue reopen ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  echo "issue edit ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  sleep 0.15
  echo '[{"number":7,"title":"Stage4 PR","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"headRefName":"feature/stage4","baseRefName":"main","updatedAt":"2026-02-08T00:00:00Z","mergedAt":null}]'
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "7" ]; then
  sleep 0.15
  echo '{"number":7,"title":"Stage4 PR","body":"PR body","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"headRefName":"feature/stage4","baseRefName":"main","reviewRequests":[],"reviews":[],"comments":[{"body":"Looks good!","author":{"login":"reviewer1"}},{"body":"Line one\nLine two","author":{"login":"reviewer2"}}],"files":[{"path":"lua/gitflow/commands.lua"}]}'
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "9" ]; then
  sleep 0.15
  echo '{"number":9,"title":"No comments PR","body":"Empty","state":"OPEN","isDraft":false,"author":{"login":"octocat"},"headRefName":"feature/empty","baseRefName":"main","reviewRequests":[],"reviews":[],"comments":[],"files":[]}'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "https://example.com/devGunnin/Gitflow/pull/8"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  echo "pr comment ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  echo "pr merge ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "checkout" ]; then
  echo "pr checkout ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "close" ]; then
  echo "pr close ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  case " $* " in
    *" --add-label "*)
      case " $* " in
        *" --remove-label "*)
          if [ ! -f "$GITFLOW_PR_EDIT_FAIL_ONCE" ]; then
            : > "$GITFLOW_PR_EDIT_FAIL_ONCE"
            echo "GraphQL: Projects (classic) is being deprecated in favor" >&2
            echo "of the new Projects experience. (repository.pullRequest.projectCards)" >&2
            exit 1
          fi
          ;;
      esac
      ;;
  esac
  echo "pr edit ok"
  exit 0
fi

if [ "$#" -ge 4 ] && [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "POST" ] \
  && [ "$4" = "repos/{owner}/{repo}/issues/7/labels" ]; then
  echo '{"ok":true}'
  exit 0
fi

if [ "$#" -ge 4 ] && [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "DELETE" ]; then
  case "$4" in
    repos/{owner}/{repo}/issues/7/labels/*)
      echo '{"ok":true}'
      exit 0
      ;;
  esac
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "list" ]; then
  sleep 0.15
  echo '[{"name":"bug","color":"ff0000","description":"Bug label","isDefault":false},{"name":"docs","color":"00ff00","description":"Docs","isDefault":false}]'
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "create" ]; then
  echo "label create ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "label" ] && [ "$2" = "delete" ]; then
  echo "label delete ok"
  exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo '{"name":"Gitflow","nameWithOwner":"devGunnin/Gitflow","url":"https://github.com/devGunnin/Gitflow","description":"repo","isPrivate":false,"defaultBranchRef":{"name":"main"}}'
  exit 0
fi

echo "unsupported gh args: $*" >&2
exit 1
]]

local gh_path = stub_bin .. "/gh"
vim.fn.writefile(vim.split(gh_script, "\n", { plain = true }), gh_path)
vim.fn.setfperm(gh_path, "rwxr-xr-x")

local original_path = vim.env.PATH
local original_input = vim.ui.input
local original_fn_input = vim.fn.input
local original_inputsave = vim.fn.inputsave
local original_inputrestore = vim.fn.inputrestore
local original_wildchar = vim.o.wildchar
local original_wildcharm = vim.o.wildcharm
local original_wildmenu = vim.o.wildmenu
local original_wildmode = vim.o.wildmode
local original_notify = vim.notify
vim.env.PATH = stub_bin .. ":" .. (original_path or "")
vim.env.GITFLOW_GH_LOG = gh_log
vim.env.GITFLOW_PR_EDIT_FAIL_ONCE = pr_edit_fail_once

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

local gh = require("gitflow.gh")
assert_true(gh.state.checked, "gh prerequisites should be checked on setup")
assert_true(gh.state.available, "gh should be available with stub")
assert_true(gh.state.authenticated, "gh auth should pass with stub")

local gh_log_lines = read_lines(gh_log)
assert_true(#gh_log_lines >= 2, "setup should invoke gh prerequisite commands")
assert_true(find_line(gh_log_lines, "--version") ~= nil, "setup should call gh --version")
assert_true(find_line(gh_log_lines, "auth status") ~= nil, "setup should call gh auth status")

local commands = require("gitflow.commands")
local pr_panel = require("gitflow.panels.prs")
local notifications = {}
vim.notify = function(message, level, _)
	notifications[#notifications + 1] = {
		message = tostring(message),
		level = level,
	}
end
local subcommands = commands.complete("")
for _, expected in ipairs({ "issue", "pr", "label" }) do
	assert_true(contains(subcommands, expected), ("missing subcommand '%s'"):format(expected))
end

local issue_actions = commands.complete("", "Gitflow issue ", 0)
for _, expected in ipairs({ "list", "view", "create", "comment", "close", "reopen", "edit" }) do
	assert_true(contains(issue_actions, expected), ("missing issue action '%s'"):format(expected))
end

local pr_actions = commands.complete("", "Gitflow pr ", 0)
for _, expected in ipairs({
	"list",
	"view",
	"review",
	"submit-review",
	"respond",
	"create",
	"comment",
	"merge",
	"checkout",
	"close",
	"edit",
}) do
	assert_true(contains(pr_actions, expected), ("missing pr action '%s'"):format(expected))
end

local issue_edit_tokens = commands.complete("", "Gitflow issue edit 1 ", 0)
assert_true(contains(issue_edit_tokens, "add="), "issue edit completion should include add=")
assert_true(contains(issue_edit_tokens, "remove="), "issue edit completion should include remove=")

local issue_add_completion = commands.complete("add=b", "Gitflow issue edit 1 add=b", 0)
assert_true(
	contains(issue_add_completion, "add=bug"),
	"issue edit add completion should suggest labels"
)

local issue_add_multi = commands.complete("add=bug,d", "Gitflow issue edit 1 add=bug,d", 0)
assert_true(
	contains(issue_add_multi, "add=bug,docs"),
	"issue edit add completion should support comma-separated labels"
)

local pr_edit_tokens = commands.complete("", "Gitflow pr edit 7 ", 0)
assert_true(contains(pr_edit_tokens, "add="), "pr edit completion should include add=")
assert_true(contains(pr_edit_tokens, "remove="), "pr edit completion should include remove=")

local pr_add_completion = commands.complete("add=d", "Gitflow pr edit 7 add=d", 0)
assert_true(contains(pr_add_completion, "add=docs"), "pr edit add completion should suggest labels")

commands.dispatch({ "issue", "list", "open" }, cfg)
local buffer = require("gitflow.ui.buffer")
wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading issues...") ~= nil
end, "issue list should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Stage4 issue") ~= nil
end, "issue list should render issue entries")

local issue_buf = buffer.get("issues")
assert_true(issue_buf ~= nil, "issue panel should open")
assert_keymaps(issue_buf, { "<CR>", "c", "C", "x", "L", "q" })
assert_keymap_absent(issue_buf, "l")

commands.dispatch({ "issue", "view", "1" }, cfg)
wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading issue #1") ~= nil
end, "issue view should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("issues")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Issue #1: Stage4 issue") ~= nil
end, "issue view should render issue details")

local issues_panel = require("gitflow.panels.issues")
local issue_prompt_completion = nil
local completion_function_name = nil
local ui_input_calls = 0
local inputsave_calls = 0
local inputrestore_calls = 0
local sentinel_tab_mapping = "PleneryBustedDirectory"
local original_ui_input = vim.ui.input
local original_fn_input = vim.fn.input
local original_inputsave = vim.fn.inputsave
local original_inputrestore = vim.fn.inputrestore
local original_wildchar = vim.o.wildchar
local original_wildcharm = vim.o.wildcharm
local original_wildmenu = vim.o.wildmenu
local original_wildmode = vim.o.wildmode

local function current_cmdline_mapping(lhs)
	local mapping = vim.fn.maparg(lhs, "c", false, true)
	if type(mapping) ~= "table" or mapping.lhs == nil then
		return nil
	end
	return mapping
end

local function restore_cmdline_mapping(lhs, mapping)
	pcall(vim.keymap.del, "c", lhs)
	if mapping then
		vim.fn.mapset("c", false, mapping)
	end
end

local original_tab_mapping = current_cmdline_mapping("<Tab>")
local sentinel_wildchar = 26
local sentinel_wildcharm = 26
local sentinel_wildmenu = false
local sentinel_wildmode = "full"

vim.o.wildchar = sentinel_wildchar
vim.o.wildcharm = sentinel_wildcharm
vim.o.wildmenu = sentinel_wildmenu
vim.o.wildmode = sentinel_wildmode

vim.cmd(("cnoremap <Tab> %s"):format(sentinel_tab_mapping))

vim.ui.input = function(_, _)
	ui_input_calls = ui_input_calls + 1
	error("issue label prompt should not use vim.ui.input when completion is configured", 2)
end

vim.fn.inputsave = function()
	inputsave_calls = inputsave_calls + 1
	return 1
end

vim.fn.inputrestore = function()
	inputrestore_calls = inputrestore_calls + 1
	return 1
end

vim.fn.input = function(opts)
	issue_prompt_completion = opts.completion
	assert_true(
		type(issue_prompt_completion) == "string",
		"issue label prompt should configure completion"
	)
	assert_equals(vim.o.wildchar, 9, "issue label prompt should force wildchar to <Tab>")
	assert_equals(vim.o.wildcharm, 9, "issue label prompt should force wildcharm to <Tab>")
	assert_true(vim.o.wildmenu, "issue label prompt should force wildmenu")
	assert_equals(
		vim.o.wildmode,
		"longest:full,full",
		"issue label prompt should force completion wildmode"
	)
	assert_true(
		current_cmdline_mapping("<Tab>") == nil,
		"issue label prompt should temporarily disable cmdline <Tab> mappings"
	)

	completion_function_name = issue_prompt_completion:match("^customlist,v:lua%.([%w_]+)$")
	assert_true(completion_function_name ~= nil, "issue label prompt should use custom completion")
	assert_true(
		type(_G[completion_function_name]) == "function",
		"custom completion function should exist"
	)

	local add_candidates = _G[completion_function_name]("d", "", 0)
	assert_true(
		contains(add_candidates, "docs"),
		"issue label completion should suggest matching add label"
	)

	local remove_candidates = _G[completion_function_name]("-d", "", 0)
	assert_true(
		contains(remove_candidates, "-docs"),
		"issue label completion should preserve remove prefix"
	)

	local multi_candidates = _G[completion_function_name]("+bug,d", "", 0)
	assert_true(
		contains(multi_candidates, "+bug,docs"),
		"issue label completion should support comma-separated values"
	)

	return "+docs"
end

local gh_lines_before_label_edit = #read_lines(gh_log)
issues_panel.edit_labels_under_cursor()
wait_until(function()
	local lines = read_lines(gh_log)
	return find_line(lines, "issue edit 1 --add-label docs", gh_lines_before_label_edit + 1) ~= nil
end, "issue panel label edit should invoke gh issue edit")

assert_true(
	completion_function_name ~= nil and _G[completion_function_name] == nil,
	"issue label completion function should be cleaned up after input"
)
assert_equals(ui_input_calls, 0, "issue label prompt should bypass vim.ui.input")
assert_equals(inputsave_calls, 1, "issue label prompt should call inputsave once")
assert_equals(inputrestore_calls, 1, "issue label prompt should call inputrestore once")
assert_equals(vim.o.wildchar, sentinel_wildchar, "issue label prompt should restore wildchar")
assert_equals(vim.o.wildcharm, sentinel_wildcharm, "issue label prompt should restore wildcharm")
assert_equals(vim.o.wildmenu, sentinel_wildmenu, "issue label prompt should restore wildmenu")
assert_equals(vim.o.wildmode, sentinel_wildmode, "issue label prompt should restore wildmode")
local restored_tab_mapping = current_cmdline_mapping("<Tab>")
assert_true(restored_tab_mapping ~= nil, "issue label prompt should restore cmdline <Tab> mapping")
assert_equals(
	restored_tab_mapping.rhs,
	sentinel_tab_mapping,
	"issue label prompt should restore cmdline <Tab> mapping"
)
restore_cmdline_mapping("<Tab>", original_tab_mapping)
vim.ui.input = original_ui_input
vim.fn.input = original_fn_input
vim.fn.inputsave = original_inputsave
vim.fn.inputrestore = original_inputrestore
vim.o.wildchar = original_wildchar
vim.o.wildcharm = original_wildcharm
vim.o.wildmenu = original_wildmenu
vim.o.wildmode = original_wildmode

-- Test: create_interactive opens form-based float with correct fields
issues_panel.create_interactive()
wait_until(function()
	local wins = vim.api.nvim_list_wins()
	for _, winid in ipairs(wins) do
		local ok, wc = pcall(vim.api.nvim_win_get_config, winid)
		if ok and wc.relative and wc.relative ~= "" then
			local wbuf = vim.api.nvim_win_get_buf(winid)
			local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
			if ft == "gitflow-form" then
				return true
			end
		end
	end
	return false
end, "create_interactive should open form float", 3000)

local create_form_lines = {}
for _, winid in ipairs(vim.api.nvim_list_wins()) do
	local ok, wc = pcall(vim.api.nvim_win_get_config, winid)
	if ok and wc.relative and wc.relative ~= "" then
		local wbuf = vim.api.nvim_win_get_buf(winid)
		local ft = vim.api.nvim_get_option_value("filetype", { buf = wbuf })
		if ft == "gitflow-form" then
			create_form_lines = vim.api.nvim_buf_get_lines(wbuf, 0, -1, false)
			vim.api.nvim_win_close(winid, true)
			break
		end
	end
end
assert_true(#create_form_lines > 0, "issue create form should have content")
assert_true(
	find_line(create_form_lines, "Title") ~= nil,
	"issue create form should have Title field"
)
assert_true(
	find_line(create_form_lines, "Labels") ~= nil,
	"issue create form should have Labels field"
)

commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading pull requests...") ~= nil
end, "pr list should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Stage4 PR") ~= nil
end, "pr list should render pr entries")

local pr_buf = buffer.get("prs")
assert_true(pr_buf ~= nil, "pr panel should open")
assert_keymaps(pr_buf, { "<CR>", "c", "C", "L", "m", "o", "q" })
assert_keymap_absent(pr_buf, "l")

local pr_lines = vim.api.nvim_buf_get_lines(pr_buf, 0, -1, false)
local pr_line = find_line(pr_lines, "Stage4 PR")
assert_true(pr_line ~= nil, "pr list line should exist")
vim.api.nvim_set_current_win(pr_panel.state.winid)
vim.api.nvim_win_set_cursor(pr_panel.state.winid, { pr_line, 0 })

local prompt_values = { "+bug,-wip,docs" }
local completion_function_name = nil
local ui_input_calls = 0
local inputsave_calls = 0
local inputrestore_calls = 0
local sentinel_tab_mapping = "PlenaryBustedDirectory"
local original_tab_mapping = current_cmdline_mapping("<Tab>")
local sentinel_wildchar = 26
local sentinel_wildcharm = 26
local sentinel_wildmenu = false
local sentinel_wildmode = "full"

vim.o.wildchar = sentinel_wildchar
vim.o.wildcharm = sentinel_wildcharm
vim.o.wildmenu = sentinel_wildmenu
vim.o.wildmode = sentinel_wildmode
vim.cmd(("cnoremap <Tab> %s"):format(sentinel_tab_mapping))

vim.ui.input = function(_, _)
	ui_input_calls = ui_input_calls + 1
	error("pr label prompt should not use vim.ui.input when completion is configured", 2)
end

vim.fn.inputsave = function()
	inputsave_calls = inputsave_calls + 1
	return 1
end

vim.fn.inputrestore = function()
	inputrestore_calls = inputrestore_calls + 1
	return 1
end

vim.fn.input = function(opts)
	local completion = opts.completion
	assert_true(type(completion) == "string", "pr label prompt should configure completion")
	assert_equals(vim.o.wildchar, 9, "pr label prompt should force wildchar to <Tab>")
	assert_equals(vim.o.wildcharm, 9, "pr label prompt should force wildcharm to <Tab>")
	assert_true(vim.o.wildmenu, "pr label prompt should force wildmenu")
	assert_equals(vim.o.wildmode, "longest:full,full", "pr label prompt should force wildmode")
	assert_true(
		current_cmdline_mapping("<Tab>") == nil,
		"pr label prompt should temporarily disable cmdline <Tab> mappings"
	)

	completion_function_name = completion:match("^customlist,v:lua%.([%w_]+)$")
	assert_true(completion_function_name ~= nil, "pr label prompt should use custom completion")
	assert_true(type(_G[completion_function_name]) == "function", "completion function should exist")

	local add_candidates = _G[completion_function_name]("d", "", 0)
	assert_true(
		contains(add_candidates, "docs"),
		"pr label completion should suggest matching add label"
	)

	local remove_candidates = _G[completion_function_name]("-d", "", 0)
	assert_true(
		contains(remove_candidates, "-docs"),
		"pr label completion should preserve remove prefix"
	)

	local multi_candidates = _G[completion_function_name]("+bug,d", "", 0)
	assert_true(
		contains(multi_candidates, "+bug,docs"),
		"pr label completion should support comma-separated values"
	)

	return table.remove(prompt_values, 1)
end

pr_panel.edit_labels_under_cursor()
wait_until(function()
	local lines = read_lines(gh_log)
	return find_line(lines, "pr edit 7 --add-label bug,docs --remove-label wip") ~= nil
end, "pr list label edit should call gh pr edit with add/remove labels")
wait_until(function()
	local lines = read_lines(gh_log)
	return find_line(lines, "api --method POST repos/{owner}/{repo}/issues/7/labels") ~= nil
		and find_line(lines, "labels[]=bug") ~= nil
		and find_line(lines, "labels[]=docs") ~= nil
		and find_line(lines, "api --method DELETE repos/{owner}/{repo}/issues/7/labels/wip") ~= nil
end, "pr label fallback should call gh api issue label endpoints")
wait_until(function()
	local notification = notifications[#notifications]
	return notification ~= nil and notification.message == "Updated labels for PR #7"
end, "pr list fallback should still report label update")
assert_true(
	completion_function_name ~= nil and _G[completion_function_name] == nil,
	"pr label completion function should be cleaned up after input"
)
assert_equals(ui_input_calls, 0, "pr label prompt should bypass vim.ui.input")
assert_equals(inputsave_calls, 1, "pr label prompt should call inputsave once")
assert_equals(inputrestore_calls, 1, "pr label prompt should call inputrestore once")
assert_equals(vim.o.wildchar, sentinel_wildchar, "pr label prompt should restore wildchar")
assert_equals(vim.o.wildcharm, sentinel_wildcharm, "pr label prompt should restore wildcharm")
assert_equals(vim.o.wildmenu, sentinel_wildmenu, "pr label prompt should restore wildmenu")
assert_equals(vim.o.wildmode, sentinel_wildmode, "pr label prompt should restore wildmode")
local restored_tab_mapping = current_cmdline_mapping("<Tab>")
assert_true(restored_tab_mapping ~= nil, "pr label prompt should restore cmdline <Tab> mapping")
assert_equals(
	restored_tab_mapping.rhs,
	sentinel_tab_mapping,
	"pr label prompt should restore cmdline <Tab> mapping"
)
restore_cmdline_mapping("<Tab>", original_tab_mapping)
vim.ui.input = original_input
vim.fn.input = function(_)
	return table.remove(prompt_values, 1)
end
vim.fn.inputsave = function()
	return 1
end
vim.fn.inputrestore = function()
	return 1
end

commands.dispatch({ "pr", "list", "open" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Stage4 PR") ~= nil
end, "pr list should re-render before no-selection test")

vim.api.nvim_set_current_win(pr_panel.state.winid)
vim.api.nvim_win_set_cursor(pr_panel.state.winid, { 1, 0 })
pr_panel.edit_labels_under_cursor()
assert_true(
	notifications[#notifications].message == "No pull request selected",
	"no selection should warn in pr list mode"
)

commands.dispatch({ "pr", "view", "7" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading PR #7") ~= nil
end, "pr view should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "PR #7: Stage4 PR") ~= nil
end, "pr view should render details")

-- Test: PR view should display comments
local pr_view_buf = buffer.get("prs")
local pr_view_lines = vim.api.nvim_buf_get_lines(pr_view_buf, 0, -1, false)

local comments_header = find_line(pr_view_lines, "Comments")
assert_true(comments_header ~= nil, "pr view should have Comments section header")
local comments_divider = find_line(pr_view_lines, "--------", comments_header)
assert_true(comments_divider ~= nil, "pr view should have Comments divider")

local reviewer1_line = find_line(pr_view_lines, "reviewer1:", comments_header)
assert_true(reviewer1_line ~= nil, "pr view should show first comment author")
local comment1_body = find_line(pr_view_lines, "  Looks good!", reviewer1_line)
assert_true(comment1_body ~= nil, "pr view should show first comment body indented")

local reviewer2_line = find_line(pr_view_lines, "reviewer2:", reviewer1_line)
assert_true(reviewer2_line ~= nil, "pr view should show second comment author")
local comment2_line1 = find_line(pr_view_lines, "  Line one", reviewer2_line)
assert_true(comment2_line1 ~= nil, "pr view should show multiline comment line 1")
local comment2_line2 = find_line(pr_view_lines, "  Line two", comment2_line1)
assert_true(comment2_line2 ~= nil, "pr view should show multiline comment line 2")

-- Test: PR view with zero comments should show (none)
commands.dispatch({ "pr", "view", "9" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "PR #9: No comments PR") ~= nil
end, "pr view should render PR #9 details")

local no_comment_lines = vim.api.nvim_buf_get_lines(buffer.get("prs"), 0, -1, false)
local no_comments_header = find_line(no_comment_lines, "Comments")
assert_true(no_comments_header ~= nil, "pr view with no comments should have Comments header")
local no_comments_none = find_line(no_comment_lines, "(none)", no_comments_header)
assert_true(no_comments_none ~= nil, "pr view with no comments should show (none)")

-- Switch back to PR #7 view for remaining tests
commands.dispatch({ "pr", "view", "7" }, cfg)
wait_until(function()
	local bufnr = buffer.get("prs")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "PR #7: Stage4 PR") ~= nil
end, "pr view should re-render PR #7 for remaining tests")

prompt_values = { "-bug,triage" }
pr_panel.edit_labels_under_cursor()
wait_until(function()
	local lines = read_lines(gh_log)
	return find_line(lines, "pr edit 7 --add-label triage --remove-label bug") ~= nil
end, "pr view label edit should call gh pr edit with add/remove labels")

local edit_count_before = count_lines_with(read_lines(gh_log), "pr edit 7")
prompt_values = { "   " }
pr_panel.edit_labels_under_cursor()
assert_true(
	notifications[#notifications].message == "No label edits provided",
	"blank label input should warn"
)
vim.wait(150)
local edit_count_after = count_lines_with(read_lines(gh_log), "pr edit 7")
assert_equals(edit_count_after, edit_count_before, "blank label input should not call gh pr edit")

commands.dispatch({ "label", "list" }, cfg)
wait_until(function()
	local bufnr = buffer.get("labels")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "Loading labels...") ~= nil
end, "label list should show loading indicator", 1000)

wait_until(function()
	local bufnr = buffer.get("labels")
	if not bufnr then
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return find_line(lines, "bug (#ff0000)") ~= nil
end, "label list should render labels")

commands.dispatch({ "label", "create", "stage4", "00ff00", "Green", "label" }, cfg)
commands.dispatch({ "pr", "edit", "7", "add=bug,docs", "remove=wip", "reviewers=octocat" }, cfg)
commands.dispatch({ "pr", "merge", "7", "squash" }, cfg)
commands.dispatch({ "pr", "checkout", "7" }, cfg)
commands.dispatch({ "issue", "close", "1" }, cfg)

wait_until(function()
	local lines = read_lines(gh_log)
	return find_line(lines, "label create stage4 --color 00ff00 --description Green label") ~= nil
		and find_line(lines, "label list --json name --limit 200") ~= nil
		and find_line(lines, "pr edit 7 --add-label bug,docs --remove-label wip --add-reviewer octocat")
			~= nil
		and find_line(lines, "pr merge 7 --squash") ~= nil
		and find_line(lines, "pr checkout 7") ~= nil
		and find_line(lines, "issue close 1") ~= nil
end, "stage4 command actions should invoke gh")

vim.notify = original_notify
vim.ui.input = original_input
vim.fn.input = original_fn_input
vim.fn.inputsave = original_inputsave
vim.fn.inputrestore = original_inputrestore
vim.o.wildchar = original_wildchar
vim.o.wildcharm = original_wildcharm
vim.o.wildmenu = original_wildmenu
vim.o.wildmode = original_wildmode
vim.env.PATH = original_path
vim.env.GITFLOW_PR_EDIT_FAIL_ONCE = nil
print("Stage 4 smoke tests passed")
