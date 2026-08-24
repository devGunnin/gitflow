-- scripts/test_matcher_spec.lua — pins the fuzzy-matcher ranking behavior
-- that existed before ui/list_picker.lua, ui/label_picker.lua and
-- panels/palette.lua were unified onto one ui/matcher.lua implementation.
--
-- Every expected value below was captured by running the THREE separate,
-- pre-refactor fuzzy_score/normalize implementations against these exact
-- fixtures, so a passing run here means the unification did not silently
-- change ranking — only structure. §2 also pins raw fuzzy_score numbers
-- (§2b), not just final orderings, since none of these fixtures' orderings
-- happen to depend on the score formula's streak-bonus term.
--
-- Run: nvim --headless -u NONE -l scripts/test_matcher_spec.lua

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed = 0

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(
			("%s (expected=%s, actual=%s)"):format(
				message, vim.inspect(expected), vim.inspect(actual)
			),
			2
		)
	end
	passed = passed + 1
end

local function assert_true(cond, message)
	if not cond then
		error(message, 2)
	end
	passed = passed + 1
end

local function assert_names(items, expected_csv, message)
	local names = {}
	for _, item in ipairs(items) do
		names[#names + 1] = item.name
	end
	assert_equals(table.concat(names, ","), expected_csv, message)
end

local matcher = require("gitflow.ui.matcher")

-- ── 1. matcher.normalize ────────────────────────────────────────────

assert_equals(matcher.normalize("  Main  "), "main", "normalize trims and lowercases")
assert_equals(matcher.normalize(nil), "", "normalize(nil) is empty string")
assert_equals(matcher.normalize(42), "42", "normalize coerces non-string input")

-- ── 2. matcher.fuzzy_score ──────────────────────────────────────────

assert_equals(matcher.fuzzy_score("anything", ""), 0, "empty needle always scores 0")
assert_equals(matcher.fuzzy_score("develop", "zzz"), nil, "a non-subsequence needle scores nil")
assert_true(
	matcher.fuzzy_score("feature/pickers", "fp") ~= nil,
	"a subsequence needle scores non-nil"
)
assert_true(
	matcher.fuzzy_score("main", "main") > matcher.fuzzy_score("main", "mn"),
	"a full contiguous match outscores a skipped-character match"
)
assert_true(
	matcher.fuzzy_score("main", "MAIN") == matcher.fuzzy_score("MAIN", "main"),
	"matching is case-insensitive on both sides"
)

-- ── 2b. fuzzy_score pins the score FORMULA, not just final ordering ──
-- Each additive term (contiguous-match streak bonus, skip-distance penalty
-- floor) is pinned by its raw number, since the ordering-only fixtures in
-- §4-§6 never happen to hinge on the streak term specifically.
assert_equals(
	matcher.fuzzy_score("main", "main"), 50,
	"2b. a 4-char contiguous run pins the growing streak bonus: 11+12+13+14"
)
assert_equals(
	matcher.fuzzy_score("develop", "dev"), 36,
	"2b. a 3-char contiguous run pins the streak bonus: 11+12+13"
)
assert_equals(
	matcher.fuzzy_score("develop", "dp"), 12,
	"2b. one contiguous char plus one 5-skip pins the skip penalty floor: 11 + max(1, 6-5)"
)

-- ── 3. matcher.match_positions ──────────────────────────────────────

assert_equals(
	table.concat(matcher.match_positions("develop", "dev"), ","),
	"0,1,2",
	"match_positions returns the greedy leftmost subsequence"
)
assert_equals(
	#matcher.match_positions("develop", ""),
	0,
	"match_positions on an empty query returns no positions"
)
assert_equals(
	#matcher.match_positions("develop", "zzz"),
	0,
	"match_positions on a non-subsequence returns no positions"
)

-- ── 4. list_picker.filter_items ranking (baseline, pre-refactor) ────

local list_picker = require("gitflow.ui.list_picker")

local branch_items = {
	{ name = "main" }, { name = "develop" }, { name = "feature/pickers" },
	{ name = "bugfix/typo" }, { name = "release/1.0" }, { name = "hotfix/urgent" },
}
assert_names(list_picker.filter_items(branch_items, "dev"), "develop", "4a. list: dev")
assert_names(
	list_picker.filter_items(branch_items, "e"),
	"develop,feature/pickers,release/1.0,hotfix/urgent",
	"4b. list: e"
)
assert_names(
	list_picker.filter_items(branch_items, ""),
	"bugfix/typo,develop,feature/pickers,hotfix/urgent,main,release/1.0",
	"4c. list: empty query returns all items alphabetically"
)
assert_names(list_picker.filter_items(branch_items, "fp"), "feature/pickers,bugfix/typo", "4d. list: fp")
assert_names(list_picker.filter_items(branch_items, "zzz"), "", "4e. list: no match")
assert_names(list_picker.filter_items(branch_items, "main"), "main", "4f. list: exact")

local desc_items = {
	{ name = "alice", description = "Developer" },
	{ name = "bob", description = "Designer" },
	{ name = "charlie", description = "PM" },
	{ name = "alicia", description = "QA" },
}
assert_names(
	list_picker.filter_items(desc_items, "ali"),
	"alice,alicia,charlie",
	"4g. list: ali (matches charlie via description)"
)
assert_names(
	list_picker.filter_items(desc_items, "de"),
	"bob,alice",
	"4h. list: de ranks bob's description above alice's"
)

-- Leading/trailing whitespace on the item itself does not change matching
-- (normalize trims both haystack and needle before scoring).
assert_names(
	list_picker.filter_items({ { name = "  spacey  " }, { name = "normal" } }, "  spacey  "),
	"  spacey  ",
	"4i. list: padded item name still matches a padded query"
)

-- ── 5. label_picker.filter_labels ranking (baseline, pre-refactor) ──

local label_picker = require("gitflow.ui.label_picker")

local labels = {
	{ name = "bug", color = "d73a4a", description = "Something is broken" },
	{ name = "enhancement", color = "a2eeef", description = "New feature" },
	{ name = "documentation", color = "0075ca" },
	{ name = "bugfix-candidate", color = "ffcc00" },
}
assert_names(label_picker.filter_labels(labels, "bug"), "bug,bugfix-candidate", "5a. label: bug")
assert_names(label_picker.filter_labels(labels, "doc"), "documentation", "5b. label: doc")
assert_names(
	label_picker.filter_labels(labels, ""),
	"bug,bugfix-candidate,documentation,enhancement",
	"5c. label: empty query returns all labels alphabetically"
)
assert_names(
	label_picker.filter_labels(labels, "e"),
	"enhancement,bug,bugfix-candidate,documentation",
	"5d. label: e ranks by score before name"
)

-- ── 6. palette.filter_entries ranking (baseline, pre-refactor) ──────

local gh = require("gitflow.gh")
local original_check = gh.check_prerequisites
gh.check_prerequisites = function(_)
	gh.state.checked = true
	gh.state.available = true
	gh.state.authenticated = true
	return true
end
require("gitflow").setup({})
gh.check_prerequisites = original_check

local palette = require("gitflow.panels.palette")
local entries = {
	{ name = "status", description = "Open git status panel", category = "Git", keybinding = "gs" },
	{ name = "branch", description = "Open branch list panel", category = "Git", keybinding = "<leader>gb" },
	{ name = "issue", description = "GitHub issues list", category = "GitHub", keybinding = "<leader>gi" },
	{ name = "pr", description = "GitHub PRs list", category = "GitHub", keybinding = "<leader>gr" },
	{ name = "palette", description = "Open command palette", category = "UI", keybinding = "<leader>go" },
	{ name = "help", description = "Show Gitflow usage", category = "UI", keybinding = nil },
}
assert_names(palette.filter_entries(entries, "s"), "status,branch,issue,pr,help", "6a. palette: s")
assert_names(palette.filter_entries(entries, "iss"), "status,issue,pr", "6b. palette: iss")
assert_names(
	palette.filter_entries(entries, ""),
	"branch,status,issue,pr,help,palette",
	"6c. palette: empty query groups by category then name"
)
assert_names(palette.filter_entries(entries, "gi"), "branch,status,pr,issue,help", "6d. palette: gi")
assert_names(palette.filter_entries(entries, "pane"), "branch,status,palette", "6e. palette: pane")

-- Padding in an entry field behaved the same before the unified matcher
-- started trimming palette's haystack too (see ui/matcher.lua normalize).
local padded_entries = {
	{ name = "  padded", description = "trailing  ", category = "Git", keybinding = nil },
	{ name = "clean", description = "normal", category = "Git", keybinding = nil },
}
assert_names(palette.filter_entries(padded_entries, "pad"), "  padded", "6f. palette: padded name still matches")
assert_names(
	palette.filter_entries(padded_entries, "trailing"),
	"  padded",
	"6g. palette: padded description still matches"
)

-- ── 7. Cross-module parity: the same shape scores the same way ──────
-- list_picker and label_picker both go through picker.filter_items, which
-- is the same matcher.fuzzy_score palette now uses -- so an equivalent
-- name/description set ranks identically regardless of which picker it
-- came through.

local shared_shape = {
	{ name = "alpha", description = "first" },
	{ name = "alarm", description = "second" },
	{ name = "beta", description = "third" },
}
local via_list = list_picker.filter_items(shared_shape, "al")
local via_label = label_picker.filter_labels(shared_shape, "al")
local list_names, label_names = {}, {}
for _, item in ipairs(via_list) do list_names[#list_names + 1] = item.name end
for _, item in ipairs(via_label) do label_names[#label_names + 1] = item.name end
assert_equals(
	table.concat(list_names, ","), table.concat(label_names, ","),
	"7. list_picker and label_picker rank an equivalent shape identically"
)

print(("Matcher spec passed (%d assertions)"):format(passed))
