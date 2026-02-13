vim.opt.runtimepath:append(".")

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		local error_message = ("%s (expected=%s, actual=%s)"):format(
			message,
			vim.inspect(expected),
			vim.inspect(actual)
		)
		error(error_message, 2)
	end
end

local gitflow = require("gitflow")
local config = gitflow.setup({
	ui = {
		default_layout = "split",
		split = {
			orientation = "vertical",
			size = 40,
		},
	},
	highlights = {
		GitflowTitle = {
			fg = 12345,
			bold = true,
		},
	},
})

assert_equals(config.ui.split.size, 40, "setup should merge user config")
assert_true(vim.fn.hlexists("GitflowBorder") == 1, "GitflowBorder highlight should be defined")
assert_true(vim.fn.hlexists("GitflowTitle") == 1, "GitflowTitle highlight should be defined")
local title_hl = vim.api.nvim_get_hl(0, { name = "GitflowTitle", link = false })
assert_equals(title_hl.bold, true, "GitflowTitle highlight override should apply")
assert_equals(title_hl.fg, 12345, "GitflowTitle highlight fg override should apply")

local command_defs = vim.api.nvim_get_commands({})
assert_true(command_defs.Gitflow ~= nil, ":Gitflow command should be registered")

local commands = require("gitflow.commands")
local usage = commands.dispatch({}, config)
assert_true(usage:find("Gitflow usage", 1, true) ~= nil, ":Gitflow with no args should show usage")

local buffer = require("gitflow.ui.buffer")
local bufnr = buffer.create("test-panel", {
	lines = { "first", "second", "third" },
})
assert_true(vim.api.nvim_buf_is_valid(bufnr), "scratch buffer should be created")
assert_equals(
	vim.api.nvim_get_option_value("buftype", { buf = bufnr }),
	"nofile",
	"buftype should be nofile"
)
assert_equals(
	vim.api.nvim_get_option_value("swapfile", { buf = bufnr }),
	false,
	"swapfile should be disabled"
)

local first_win = vim.api.nvim_open_win(bufnr, true, {
	relative = "editor",
	width = 40,
	height = 8,
	row = 1,
	col = 1,
	border = "single",
})
vim.api.nvim_win_set_cursor(first_win, { 2, 0 })
assert_true(
	buffer.update("test-panel", { "one", "two", "three", "four" }),
	"buffer update should succeed"
)
assert_equals(
	vim.api.nvim_win_get_cursor(first_win)[1],
	2,
	"cursor line should be preserved on update"
)
vim.api.nvim_win_close(first_win, true)

assert_true(buffer.teardown("test-panel"), "buffer teardown should succeed")
assert_true(
	buffer.get("test-panel") == nil,
	"buffer registry entry should be removed after teardown"
)

local window = require("gitflow.ui.window")
local float_buf = buffer.create("float-panel", {
	lines = { "float body" },
})

local close_hook_called = false
local float_win = window.open_float({
	name = "float-panel",
	bufnr = float_buf,
	width = 0.5,
	height = 0.4,
	border = "double",
	title = "Stage 1",
	title_pos = "left",
	footer = "[q] Close",
	footer_pos = "right",
	on_close = function()
		close_hook_called = true
	end,
})

local float_cfg = vim.api.nvim_win_get_config(float_win)
assert_equals(float_cfg.relative, "editor", "float window should be editor-relative")
assert_true(float_cfg.border ~= nil, "float window should include border configuration")
assert_true(float_cfg.title ~= nil, "float window should include title configuration")
assert_equals(float_cfg.title_pos, "left", "float window should include title position")

local winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = float_win })
assert_true(
	winhighlight:find("FloatBorder:GitflowBorder", 1, true) ~= nil,
	"float window should apply Gitflow border winhighlight"
)

if vim.fn.has("nvim-0.10") == 1 then
	assert_equals(float_cfg.footer_pos, "right", "float window should include footer position")
	assert_true(float_cfg.footer ~= nil, "float window should include footer")
end
window.close(float_win)
vim.cmd("redraw")
assert_true(close_hook_called, "window close hook should run")

local split_buf = buffer.create("split-panel", {
	lines = { "split body" },
})
local split_win = window.open_split({
	name = "split-panel",
	bufnr = split_buf,
	orientation = config.ui.split.orientation,
	size = config.ui.split.size,
})
assert_equals(vim.api.nvim_win_get_width(split_win), 40, "split width should honor configured size")
window.close(split_win)

buffer.teardown("float-panel")
buffer.teardown("split-panel")

print("Stage 1 smoke tests passed")
