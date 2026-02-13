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

local function assert_contains(text, needle, message)
	assert_true(type(text) == "string", message)
	assert_true(text:find(needle, 1, true) ~= nil, message)
end

local config = require("gitflow.config")
local window = require("gitflow.ui.window")
local ui = require("gitflow.ui")

local defaults = config.defaults()
assert_equals(defaults.ui.float.title_pos, "center", "float.title_pos default should be center")
assert_equals(defaults.ui.float.footer, true, "float.footer default should be true")
assert_equals(defaults.ui.float.footer_pos, "center", "float.footer_pos default should be center")

local invalid_title_pos = vim.deepcopy(defaults)
invalid_title_pos.ui.float.title_pos = "middle"
local ok_title_pos, err_title_pos = pcall(config.validate, invalid_title_pos)
assert_true(not ok_title_pos, "config.validate should reject invalid float.title_pos")
assert_contains(tostring(err_title_pos), "title_pos", "title_pos error should mention title_pos")

local invalid_footer = vim.deepcopy(defaults)
invalid_footer.ui.float.footer = "yes"
local ok_footer, err_footer = pcall(config.validate, invalid_footer)
assert_true(not ok_footer, "config.validate should reject non-boolean float.footer")
assert_contains(
	tostring(err_footer),
	"ui.float.footer",
	"footer error should mention ui.float.footer"
)

local invalid_footer_pos = vim.deepcopy(defaults)
invalid_footer_pos.ui.float.footer_pos = "middle"
local ok_footer_pos, err_footer_pos = pcall(config.validate, invalid_footer_pos)
assert_true(not ok_footer_pos, "config.validate should reject invalid float.footer_pos")
assert_contains(
	tostring(err_footer_pos),
	"footer_pos",
	"footer_pos error should mention footer_pos"
)

local invalid_border = vim.deepcopy(defaults)
invalid_border.ui.float.border = "bad-border"
local ok_border, err_border = pcall(config.validate, invalid_border)
assert_true(not ok_border, "config.validate should reject invalid string float.border")
assert_contains(
	tostring(err_border),
	"ui.float.border",
	"border error should mention ui.float.border"
)

for _, border in ipairs({ "single", "double", "rounded", "shadow" }) do
	local cfg = config.setup({
		ui = {
			float = {
				border = border,
			},
		},
	})
	assert_equals(cfg.ui.float.border, border, ("config should retain border '%s'"):format(border))
	local bufnr = vim.api.nvim_create_buf(false, true)
	local winid = window.open_float({
		bufnr = bufnr,
		width = 0.4,
		height = 0.3,
		border = border,
		title = "Stage 8",
		title_pos = "right",
		footer = "Hints",
		footer_pos = "left",
	})
	assert_true(
		vim.api.nvim_win_is_valid(winid),
		("open_float should open with border '%s'"):format(border)
	)
	window.close(winid)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

local bufnr = vim.api.nvim_create_buf(false, true)
local winid = window.open_float({
	bufnr = bufnr,
	width = 0.5,
	height = 0.4,
	border = "double",
	title = "Window Title",
	title_pos = "right",
	footer = "Footer Hints",
	footer_pos = "left",
})
local win_cfg = vim.api.nvim_win_get_config(winid)
assert_equals(win_cfg.title_pos, "right", "open_float should pass title_pos")
assert_equals(win_cfg.footer_pos, "left", "open_float should pass footer_pos")
assert_true(
	type(win_cfg.title) == "table" and win_cfg.title[1][1] == "Window Title",
	"title text should be set"
)
assert_true(
	type(win_cfg.footer) == "table" and win_cfg.footer[1][1] == "Footer Hints",
	"footer text should be set on Neovim 0.10+"
)
local winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = winid })
assert_contains(
	winhighlight,
	"FloatFooter:GitflowFooter",
	"open_float should map FloatFooter highlight"
)
window.close(winid)
vim.api.nvim_buf_delete(bufnr, { force = true })

local original_has = vim.fn.has
vim.fn.has = function(feature)
	if feature == "nvim-0.10" then
		return 0
	end
	return original_has(feature)
end

local old_bufnr = vim.api.nvim_create_buf(false, true)
local old_winid = window.open_float({
	bufnr = old_bufnr,
	width = 0.4,
	height = 0.3,
	title = "Legacy",
	footer = "Ignored",
})
local old_cfg = vim.api.nvim_win_get_config(old_winid)
assert_true(old_cfg.footer == nil, "open_float should omit footer on Neovim < 0.10")
window.close(old_winid)
vim.api.nvim_buf_delete(old_bufnr, { force = true })
vim.fn.has = original_has

local float_cfg = config.setup({
	ui = {
		default_layout = "float",
		float = {
			width = 0.65,
			height = 0.55,
			border = "rounded",
			title = "Gitflow",
			title_pos = "right",
			footer = true,
			footer_pos = "left",
		},
	},
})

local captured = {}
local original_open_float = ui.window.open_float
ui.window.open_float = function(opts)
	captured[#captured + 1] = vim.deepcopy(opts)
	return original_open_float(opts)
end

local function find_capture(start_index, name)
	for i = #captured, start_index + 1, -1 do
		if captured[i].name == name then
			return captured[i]
		end
	end
	return nil
end

local function assert_float_panel_capture(start_index, name)
	local opts = find_capture(start_index, name)
	assert_true(opts ~= nil, ("expected float capture for panel '%s'"):format(name))
	assert_true(type(opts.title) == "string" and opts.title ~= "", "float panels should provide title")
	assert_equals(
		opts.title_pos,
		float_cfg.ui.float.title_pos,
		("panel '%s' should pass configured title_pos"):format(name)
	)
	assert_true(
		type(opts.footer) == "string" and opts.footer ~= "",
		"float panels should provide footer"
	)
	assert_equals(
		opts.footer_pos,
		float_cfg.ui.float.footer_pos,
		("panel '%s' should pass configured footer_pos"):format(name)
	)
	assert_equals(opts.border, float_cfg.ui.float.border, "float panels should use configured border")
end

local status_panel = require("gitflow.panels.status")
local branch_panel = require("gitflow.panels.branch")
local log_panel = require("gitflow.panels.log")
local stash_panel = require("gitflow.panels.stash")
local conflict_panel = require("gitflow.panels.conflict")
local issues_panel = require("gitflow.panels.issues")
local prs_panel = require("gitflow.panels.prs")
local review_panel = require("gitflow.panels.review")
local diff_panel = require("gitflow.panels.diff")
local palette_panel = require("gitflow.panels.palette")

local original_status_refresh = status_panel.refresh
status_panel.refresh = function() end
local start = #captured
status_panel.open(float_cfg, {})
assert_float_panel_capture(start, "status")
status_panel.close()
status_panel.refresh = original_status_refresh

local original_branch_refresh = branch_panel.refresh
branch_panel.refresh = function() end
start = #captured
branch_panel.open(float_cfg)
assert_float_panel_capture(start, "branch")
branch_panel.close()
branch_panel.refresh = original_branch_refresh

local original_log_refresh = log_panel.refresh
log_panel.refresh = function() end
start = #captured
log_panel.open(float_cfg, {})
assert_float_panel_capture(start, "log")
log_panel.close()
log_panel.refresh = original_log_refresh

local original_stash_refresh = stash_panel.refresh
stash_panel.refresh = function() end
start = #captured
stash_panel.open(float_cfg)
assert_float_panel_capture(start, "stash")
stash_panel.close()
stash_panel.refresh = original_stash_refresh

local original_conflict_refresh = conflict_panel.refresh
conflict_panel.refresh = function() end
start = #captured
conflict_panel.open(float_cfg, {})
assert_float_panel_capture(start, "conflict")
conflict_panel.close()
conflict_panel.refresh = original_conflict_refresh

local original_issues_refresh = issues_panel.refresh
issues_panel.refresh = function() end
start = #captured
issues_panel.open(float_cfg, {})
assert_float_panel_capture(start, "issues")
issues_panel.close()
issues_panel.refresh = original_issues_refresh

local original_prs_refresh = prs_panel.refresh
prs_panel.refresh = function() end
start = #captured
prs_panel.open(float_cfg, {})
assert_float_panel_capture(start, "prs")
prs_panel.close()
prs_panel.refresh = original_prs_refresh

local original_review_refresh = review_panel.refresh
review_panel.refresh = function() end
start = #captured
review_panel.open(float_cfg, 7)
assert_float_panel_capture(start, "review")
review_panel.close()
review_panel.refresh = original_review_refresh

local git_branch = require("gitflow.git.branch")
local git_diff = require("gitflow.git.diff")
local original_branch_current = git_branch.current
local original_diff_get = git_diff.get
git_branch.current = function(_, cb)
	cb(nil, "main")
end
git_diff.get = function(_, cb)
	cb(nil, "")
end
start = #captured
diff_panel.open(float_cfg, { staged = true })
assert_float_panel_capture(start, "diff")
diff_panel.close()
git_branch.current = original_branch_current
git_diff.get = original_diff_get

start = #captured
palette_panel.open(float_cfg, {
	{ name = "status", description = "Open status panel", category = "Git", keybinding = "gs" },
}, function(_) end)
assert_float_panel_capture(start, "palette_prompt")
assert_float_panel_capture(start, "palette_list")
palette_panel.close()

ui.window.open_float = original_open_float

print("Stage 8 windows tests passed")
