vim.opt.runtimepath:append(".")

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		local err = ("%s (expected=%s, actual=%s)"):format(
			message,
			vim.inspect(expected),
			vim.inspect(actual)
		)
		error(err, 2)
	end
end

local passed = 0
local failed = 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " — " .. tostring(err))
	end
end

print("Keybinding documentation tests")
print("==============================")

local gitflow = require("gitflow")
local cfg = gitflow.setup({})
local defaults = cfg.keybindings

-- Parse the Global keybinding table out of KEYBINDINGS.md.
-- Row format: | `<key>` | <action> | `<config_key>` |
local root = vim.fn.fnamemodify(".", ":p")
local function parse_keybindings_md()
	local lines = vim.fn.readfile(root .. "KEYBINDINGS.md")
	assert_true(#lines > 0, "KEYBINDINGS.md should exist")
	local entries = {}
	local in_global = false
	for _, line in ipairs(lines) do
		if line:find("## Global", 1, true) then
			in_global = true
		elseif line:match("^## ") and in_global then
			break
		end
		if in_global then
			local key, cfg_key = line:match(
				"^| `([^`]+)` |[^|]+| `([^`]+)` |$"
			)
			if key and cfg_key then
				entries[cfg_key] = key
			end
		end
	end
	return entries
end

-- Parse the Global Mappings table out of README.md.
-- Row format: | `<key>` | <action label> |
local function parse_readme_global_mappings()
	local lines = vim.fn.readfile(root .. "README.md")
	assert_true(#lines > 0, "README.md should exist")
	local entries = {}
	local in_section = false
	for _, line in ipairs(lines) do
		if line:find("### Global Mappings", 1, true) then
			in_section = true
		elseif in_section and line:match("^##%s") then
			break
		end
		if in_section then
			local key, label = line:match("^| `([^`]+)` | ([^|]+) |$")
			if key and label then
				entries[#entries + 1] = {
					key = key,
					label = vim.trim(label),
				}
			end
		end
	end
	return entries
end

-- Parse the Default keybindings table out of doc/gitflow.txt.
-- Row format: "    <action>   <leader-or-key>   <Plug>(...)"
local function parse_helptxt_defaults()
	local lines = vim.fn.readfile(root .. "doc/gitflow.txt")
	assert_true(#lines > 0, "doc/gitflow.txt should exist")
	local entries = {}
	local in_table = false
	for _, line in ipairs(lines) do
		if line:match("^Default keybindings:") then
			in_table = true
		elseif in_table and line:match("^%S") then
			break
		end
		if in_table then
			local action, key =
				line:match("^%s+(%S+)%s+(%S+)%s+<Plug>%(Gitflow")
			if action and key and action ~= "Action" then
				entries[action] = key
			end
		end
	end
	return entries
end

local doc_entries = parse_keybindings_md()
local readme_mappings = parse_readme_global_mappings()
local helptxt_defaults = parse_helptxt_defaults()

test("KEYBINDINGS.md global table parses entries", function()
	local count = 0
	for _ in pairs(doc_entries) do
		count = count + 1
	end
	assert_true(count >= 10, "should parse multiple entries")
end)

test("README.md Global Mappings table parses entries", function()
	assert_true(#readme_mappings >= 10, "should parse multiple entries")
end)

test("doc/gitflow.txt default table parses entries", function()
	local count = 0
	for _ in pairs(helptxt_defaults) do
		count = count + 1
	end
	assert_true(count >= 10, "should parse multiple entries")
end)

-- Every config_key in KEYBINDINGS.md's Global table must match config defaults.
-- This is the regression gate for the QA DEFECT-001 class of bugs where the
-- defaults-table silently drifts from the documented contract.
test(
	"every KEYBINDINGS.md entry matches config.defaults()",
	function()
		for cfg_key, doc_key in pairs(doc_entries) do
			assert_true(
				defaults[cfg_key] ~= nil,
				("defaults.%s should exist"):format(cfg_key)
			)
			assert_equals(
				defaults[cfg_key],
				doc_key,
				("KEYBINDINGS.md vs defaults[%s]"):format(cfg_key)
			)
		end
	end
)

-- Every action in doc/gitflow.txt must match config defaults too.
test(
	"every doc/gitflow.txt entry matches config.defaults()",
	function()
		for action, help_key in pairs(helptxt_defaults) do
			assert_true(
				defaults[action] ~= nil,
				("defaults.%s should exist"):format(action)
			)
			assert_equals(
				defaults[action],
				help_key,
				("doc/gitflow.txt vs defaults[%s]"):format(action)
			)
		end
	end
)

-- KEYBINDINGS.md and doc/gitflow.txt must agree with each other.
test(
	"KEYBINDINGS.md and doc/gitflow.txt agree on default keys",
	function()
		for cfg_key, doc_key in pairs(doc_entries) do
			if helptxt_defaults[cfg_key] then
				assert_equals(
					helptxt_defaults[cfg_key],
					doc_key,
					("doc mismatch for %s"):format(cfg_key)
				)
			end
		end
	end
)

-- Every key listed in the README Global Mappings table must also be the
-- runtime default for exactly one action (i.e. the plugin actually installs
-- that mapping). This catches the class of bug where docs show a key the
-- setup code does not wire up.
test(
	"every README Global Mappings key is installed by setup()",
	function()
		local installed = {}
		for _, key in pairs(defaults) do
			installed[key] = true
		end
		for _, row in ipairs(readme_mappings) do
			assert_true(
				installed[row.key],
				("README lists %q (%s) but setup() does not install it")
					:format(row.key, row.label)
			)
		end
	end
)

-- No two documented default actions may collide on the same key.
test("no two default keybindings collide on the same key", function()
	local seen = {}
	for cfg_key, doc_key in pairs(doc_entries) do
		if seen[doc_key] then
			error(
				("KEYBINDINGS.md collision: %q used by both %s and %s"):format(
					doc_key,
					seen[doc_key],
					cfg_key
				),
				0
			)
		end
		seen[doc_key] = cfg_key
	end
end)

-- Spot checks for the three specific cases called out in the QA report.
test("push default is `<leader>gP`", function()
	assert_equals(defaults.push, "<leader>gP", "push default")
	assert_equals(doc_entries["push"], "<leader>gP", "KEYBINDINGS.md push")
end)

test("pull default is `<leader>gp`", function()
	assert_equals(defaults.pull, "<leader>gp", "pull default")
	assert_equals(doc_entries["pull"], "<leader>gp", "KEYBINDINGS.md pull")
end)

test("palette default is `gP`", function()
	assert_equals(defaults.palette, "gP", "palette default")
	assert_equals(
		doc_entries["palette"],
		"gP",
		"KEYBINDINGS.md palette"
	)
end)

test("open default is `<leader>go`", function()
	assert_equals(defaults.open, "<leader>go", "open default")
	assert_equals(doc_entries["open"], "<leader>go", "KEYBINDINGS.md open")
end)

test("label default is `<leader>gL`", function()
	assert_equals(defaults.label, "<leader>gL", "label default")
	assert_equals(doc_entries["label"], "<leader>gL", "KEYBINDINGS.md label")
end)

test("refresh default is `gr`", function()
	assert_equals(defaults.refresh, "gr", "refresh default")
	assert_equals(
		doc_entries["refresh"],
		"gr",
		"KEYBINDINGS.md refresh"
	)
end)

test("pr default is `<leader>gr`", function()
	assert_equals(defaults.pr, "<leader>gr", "pr default")
	assert_equals(doc_entries["pr"], "<leader>gr", "KEYBINDINGS.md pr")
end)

test("pr and reset keybindings are distinct", function()
	assert_true(
		defaults.pr ~= defaults.reset,
		"pr and reset must have different keys"
	)
	assert_true(
		doc_entries["pr"] ~= doc_entries["reset"],
		"pr and reset docs must show different keys"
	)
end)

test("reset default is `<leader>gR`", function()
	assert_equals(defaults.reset, "<leader>gR", "reset default")
	assert_equals(doc_entries["reset"], "<leader>gR", "KEYBINDINGS.md reset")
end)

-- After setup(), the actual runtime keymaps must resolve to the expected
-- <Plug> target. This uses maparg() the same way the test_boyz QA prober did,
-- so DEFECT-001 is observable the same way it was caught.
local plug_by_action = {
	help = "<Plug>(GitflowHelp)",
	open = "<Plug>(GitflowOpen)",
	refresh = "<Plug>(GitflowRefresh)",
	close = "<Plug>(GitflowClose)",
	status = "<Plug>(GitflowStatus)",
	branch = "<Plug>(GitflowBranch)",
	commit = "<Plug>(GitflowCommit)",
	push = "<Plug>(GitflowPush)",
	pull = "<Plug>(GitflowPull)",
	fetch = "<Plug>(GitflowFetch)",
	diff = "<Plug>(GitflowDiff)",
	log = "<Plug>(GitflowLog)",
	stash = "<Plug>(GitflowStash)",
	stash_push = "<Plug>(GitflowStashPush)",
	stash_pop = "<Plug>(GitflowStashPop)",
	issue = "<Plug>(GitflowIssue)",
	pr = "<Plug>(GitflowPr)",
	label = "<Plug>(GitflowLabel)",
	conflict = "<Plug>(GitflowConflicts)",
	palette = "<Plug>(GitflowPalette)",
	reset = "<Plug>(GitflowReset)",
}

test("every documented default resolves to its <Plug> target at runtime", function()
	local leader = vim.g.mapleader or "\\"
	for cfg_key, expected_plug in pairs(plug_by_action) do
		local key = doc_entries[cfg_key]
		assert_true(
			key ~= nil,
			("KEYBINDINGS.md should list a default for %s"):format(cfg_key)
		)
		local resolved = key:gsub("<leader>", leader)
		local m = vim.fn.maparg(resolved, "n", false, true) or {}
		assert_true(
			m.rhs ~= nil and m.rhs ~= "",
			("no mapping found for %s (%s)"):format(cfg_key, resolved)
		)
		assert_equals(
			m.rhs,
			expected_plug,
			("rhs for %s (%s)"):format(cfg_key, resolved)
		)
	end
end)

-- DEFECT-002: the documented GitflowSign* highlight groups must exist after
-- setup(), and must honor user overrides via setup({ highlights = ... }).
test("GitflowSign* highlight groups exist after setup()", function()
	for _, group in ipairs({
		"GitflowSignAdded",
		"GitflowSignModified",
		"GitflowSignDeleted",
		"GitflowSignConflict",
	}) do
		local hl = vim.api.nvim_get_hl(0, { name = group })
		assert_true(
			next(hl) ~= nil,
			("%s should be defined after setup()"):format(group)
		)
	end
end)

test("GitflowSign* override via setup.highlights takes effect", function()
	gitflow.setup({
		highlights = {
			GitflowSignAdded = { link = "DiffAdd" },
		},
	})
	local hl = vim.api.nvim_get_hl(0, { name = "GitflowSignAdded" })
	assert_true(next(hl) ~= nil, "GitflowSignAdded should still be defined")
	assert_equals(hl.link, "DiffAdd", "override should set link to DiffAdd")
	-- Reset defaults for any later scripts
	gitflow.setup({})
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
