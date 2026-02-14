-- tests/minimal_init.lua — deterministic Neovim environment for E2E tests
--
-- Usage:
--   nvim --headless -u tests/minimal_init.lua -l tests/e2e_smoke_test.lua

-- Resolve project root from this file's location
local script_path = debug.getinfo(1, "S").source:sub(2)
local tests_dir = vim.fn.fnamemodify(script_path, ":p:h")
local project_root = vim.fn.fnamemodify(tests_dir, ":h")

-- Deterministic editor options
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.undofile = false
vim.opt.shadafile = "NONE"
vim.opt.loadplugins = false
vim.opt.termguicolors = false

-- Prepend stub bin directory so test stubs override real git/gh
local stub_bin = tests_dir .. "/fixtures/bin"
vim.env.PATH = stub_bin .. ":" .. vim.env.PATH

-- Add project root to runtimepath so `require("gitflow")` resolves
vim.opt.runtimepath:prepend(project_root)

-- Load helpers into a global for convenience
_G.T = require("tests.helpers")

-- Load gitflow with test-safe defaults (no real git/gh side-effects)
local gitflow = require("gitflow")
_G.TestConfig = gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 40 },
	},
})
