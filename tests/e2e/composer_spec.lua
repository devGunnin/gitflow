-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/composer_spec.lua

local T = _G.T
local input = require("gitflow.ui.input")
local form = require("gitflow.ui.form")

local function close_composer(state)
	if state and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_close(state.winid, true)
	end
end

local function press(keys)
	local encoded = vim.api.nvim_replace_termcodes(keys, true, false, true)
	vim.api.nvim_feedkeys(encoded, "mx", false)
end

T.run_suite("E2E: Multiline Composer", {
	["accepts multiline text and submits it unchanged"] = function()
		local submitted
		local state = input.prompt({
			multiline = true,
			title = "Test comment",
			draft_key = "test:composer:submit",
		}, function(value)
			submitted = value
		end)

		T.assert_true(vim.api.nvim_buf_is_valid(state.bufnr), "composer buffer should be valid")
		T.assert_equals(vim.bo[state.bufnr].filetype, "gitflow-form", "composer should use the form filetype")
		vim.api.nvim_buf_set_lines(state.bufnr, 2, 3, false, { "first line", "second line" })
		vim.api.nvim_set_current_win(state.winid)
		vim.api.nvim_win_set_cursor(state.winid, { 3, 0 })
		press("<CR>")

		T.assert_equals(submitted, "first line\nsecond line", "composer should preserve newlines")
		T.assert_true(
			state.bufnr == nil or not vim.api.nvim_buf_is_valid(state.bufnr),
			"submitted composer should close"
		)
	end,

	["cancel saves a draft and reopening restores it"] = function()
		local key = "test:composer:draft"
		form._drafts[key] = nil
		local first = input.prompt({
			multiline = true, title = "Draft comment", draft_key = key }, function() end)
		vim.api.nvim_buf_set_lines(first.bufnr, 2, 3, false, { "saved", "across lines" })
		vim.api.nvim_set_current_win(first.winid)
		vim.api.nvim_win_set_cursor(first.winid, { 3, 0 })
		press("q")

		local reopened = input.prompt({
			multiline = true, title = "Draft comment", draft_key = key }, function() end)
		local lines = vim.api.nvim_buf_get_lines(reopened.bufnr, 2, 4, false)
		T.assert_equals(lines[1], "saved", "draft should restore its first line")
		T.assert_equals(lines[2], "across lines", "draft should restore its second line")
		close_composer(reopened)
		form._drafts[key] = nil
	end,
})
