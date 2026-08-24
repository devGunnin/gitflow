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

-- Moved off bare `gP` (Neovim's paste-before) in the v2 keymap overhaul.
test("palette default is `<leader>gx`", function()
	assert_equals(defaults.palette, "<leader>gx", "palette default")
	assert_equals(
		doc_entries["palette"],
		"<leader>gx",
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

-- Moved off bare `gr` (Neovim 0.11's LSP prefix) in the v2 keymap overhaul.
test("refresh default is `<leader>gz`", function()
	assert_equals(defaults.refresh, "<leader>gz", "refresh default")
	assert_equals(
		doc_entries["refresh"],
		"<leader>gz",
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

-- ── completeness ──────────────────────────────────────────────────────
-- Correctness of what happens to be listed is not enough: the drift that
-- actually bites is a key that exists and is documented NOWHERE. These check
-- the other direction — every runtime binding has a doc entry.

-- Every global action must appear in all three docs.
test("every config default is documented in all three places", function()
	local readme_keys = {}
	for _, row in ipairs(readme_mappings) do
		readme_keys[row.key] = true
	end
	for _, action in ipairs(vim.tbl_keys(defaults)) do
		local key = defaults[action]
		assert_true(
			doc_entries[action] ~= nil,
			("KEYBINDINGS.md documents no default for %s"):format(action)
		)
		assert_true(
			helptxt_defaults[action] ~= nil,
			("doc/gitflow.txt documents no default for %s"):format(action)
		)
		assert_true(
			readme_keys[key] == true,
			("README's Global Mappings table omits %s (%s)"):format(action, key)
		)
	end
end)

-- Panel keys. KEYBINDINGS.md marks each panel's table block with an HTML
-- comment naming the surface it documents; the marker is what makes this
-- checkable, and a new panel with no marker fails here rather than quietly
-- going undocumented. Comparison is on the KEYS THEMSELVES, not on the hint
-- label, so the doc stays free to write `s` and `u` on their own rows where
-- the registry advertises them as one `s/u` entry.

---Backtick-quoted keys in a table row's first cell, with `1-9` expanded.
---@param cell string
---@return string[]
local function keys_in_cell(cell)
	local out = {}
	for token in cell:gmatch("`([^`]+)`") do
		local first, last = token:match("^(%d)%-(%d)$")
		if first then
			for digit = tonumber(first), tonumber(last) do
				out[#out + 1] = tostring(digit)
			end
		else
			out[#out + 1] = token
		end
	end
	return out
end

---@return table<string, table<string, boolean>>
local function parse_panel_key_tables()
	local lines = vim.fn.readfile(root .. "KEYBINDINGS.md")
	local tables, current = {}, nil
	for _, line in ipairs(lines) do
		local marker = line:match("^<!%-%- keys: ([%w_]+) %-%->$")
		if marker then
			current = tables[marker] or {}
			tables[marker] = current
		elseif current then
			if line:match("^## ") then
				current = nil
			else
				local cell = line:match("^|([^|]+)|")
				if cell then
					for _, key in ipairs(keys_in_cell(cell)) do
						current[key] = true
					end
				end
			end
		end
	end
	return tables
end

local panel = require("gitflow.ui.panel")
for _, path in ipairs(vim.fn.glob(root .. "lua/gitflow/panels/*.lua", false, true)) do
	require("gitflow.panels." .. vim.fn.fnamemodify(path, ":t:r"))
end
require("gitflow.review.overlay")
require("gitflow.ui.conflict")

test("every panel key is documented, and every documented key exists", function()
	local documented = parse_panel_key_tables()
	local problems = {}

	for _, surface in ipairs(panel.surfaces()) do
		local rows = documented[surface.name]
		if not rows then
			problems[#problems + 1] = ("no `<!-- keys: %s -->` table in KEYBINDINGS.md")
				:format(surface.name)
		else
			-- Advertised keys must be documented; keys that are bound but
			-- deliberately unadvertised (aliases, no-ops) may be.
			local bound, advertised = {}, {}
			for _, entry in ipairs(surface.keymaps) do
				for _, key in ipairs(panel.bound_keys(entry)) do
					bound[key] = true
					if entry.desc then
						advertised[key] = true
					end
				end
			end
			for key in pairs(advertised) do
				if not rows[key] then
					problems[#problems + 1] =
						("%s binds `%s`, KEYBINDINGS.md does not list it"):format(
							surface.name, key
						)
				end
			end
			for key in pairs(rows) do
				if not bound[key] then
					problems[#problems + 1] =
						("KEYBINDINGS.md lists `%s` for %s, which binds no such key")
							:format(key, surface.name)
				end
			end
		end
	end

	table.sort(problems)
	assert_true(
		#problems == 0,
		"keybinding documentation drift:\n    " .. table.concat(problems, "\n    ")
	)
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
