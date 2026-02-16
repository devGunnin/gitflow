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

-- Read KEYBINDINGS.md and extract the global table entries
local root = vim.fn.fnamemodify(".", ":p")
local doc_path = root .. "KEYBINDINGS.md"
local lines = vim.fn.readfile(doc_path)
assert_true(#lines > 0, "KEYBINDINGS.md should exist")

-- Parse global keybinding table rows:
-- | `<key>` | <action> | `<config_key>` |
local doc_entries = {}
local in_global = false
for _, line in ipairs(lines) do
	if line:find("## Global", 1, true) then
		in_global = true
	elseif line:match("^## ") and in_global then
		break
	end
	if in_global then
		local key, config_key = line:match(
			"^| `([^`]+)` |[^|]+| `([^`]+)` |$"
		)
		if key and config_key then
			doc_entries[config_key] = key
		end
	end
end

test(
	"KEYBINDINGS.md global table has entries",
	function()
		local count = 0
		for _ in pairs(doc_entries) do
			count = count + 1
		end
		assert_true(
			count > 0,
			"should parse at least one entry"
		)
	end
)

test(
	"issue doc entry exists",
	function()
		assert_true(
			doc_entries["issue"] ~= nil,
			"issue should be in KEYBINDINGS.md global table"
		)
	end
)

test(
	"issue doc entry matches config default",
	function()
		assert_equals(
			doc_entries["issue"],
			defaults.issue,
			"KEYBINDINGS.md issue key"
		)
	end
)

test(
	"issue keybinding is lowercase <leader>gi",
	function()
		assert_equals(
			doc_entries["issue"],
			"<leader>gi",
			"issue doc entry should be lowercase"
		)
		assert_equals(
			defaults.issue,
			"<leader>gi",
			"issue config default should be lowercase"
		)
	end
)

test(
	"PR doc entry exists",
	function()
		assert_true(
			doc_entries["pr"] ~= nil,
			"pr should be in KEYBINDINGS.md global table"
		)
	end
)

test(
	"PR doc entry matches config default",
	function()
		assert_equals(
			doc_entries["pr"],
			defaults.pr,
			"KEYBINDINGS.md pr key"
		)
	end
)

test(
	"PR keybinding is lowercase <leader>gr",
	function()
		assert_equals(
			doc_entries["pr"],
			"<leader>gr",
			"PR doc entry should be lowercase"
		)
		assert_equals(
			defaults.pr,
			"<leader>gr",
			"PR config default should be lowercase"
		)
	end
)

test(
	"PR and reset keybindings are distinct",
	function()
		assert_true(
			defaults.pr ~= defaults.reset,
			"pr and reset must have different keys"
		)
		assert_true(
			doc_entries["pr"] ~= doc_entries["reset"],
			"pr and reset docs must show different keys"
		)
	end
)

test(
	"reset doc entry exists",
	function()
		assert_true(
			doc_entries["reset"] ~= nil,
			"reset should be in KEYBINDINGS.md"
		)
	end
)

test(
	"reset doc entry matches config default",
	function()
		assert_equals(
			doc_entries["reset"],
			defaults.reset,
			"KEYBINDINGS.md reset key"
		)
	end
)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	vim.cmd("cquit! 1")
end
vim.cmd("qall!")
