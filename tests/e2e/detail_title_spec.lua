--- tests/e2e/detail_title_spec.lua
---
--- Verifies that issue and PR detail views display the title
--- as a visible field before the Body section.

local commands = require("gitflow.commands")
local issues_panel = require("gitflow.panels.issues")
local prs_panel = require("gitflow.panels.prs")
local ui = require("gitflow.ui")
local cfg = _G.TestConfig

---@param panel_name "issues"|"prs"
---@param message string
---@param predicate fun(lines: string[]): boolean
---@return string[]
local function wait_for_detail_render(panel_name, message, predicate)
	local matched_lines = {}
	T.wait_until(function()
		local bufnr = ui.buffer.get(panel_name)
		if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
			return false
		end
		local lines = T.buf_lines(bufnr)
		if not predicate(lines) then
			return false
		end
		matched_lines = vim.deepcopy(lines)
		return true
	end, message, 5000)
	return matched_lines
end

T.run_suite("detail_title_spec", {

	-- ── Issue detail view ──────────────────────────

	["issue view shows Title field"] = function()
		T.cleanup_panels()
		issues_panel.open_view(1, cfg)
		local lines = wait_for_detail_render("issues", "issue view should render Title line", function(lines)
			return T.find_line(lines, "Title:") ~= nil
		end)

		local bufnr = ui.buffer.get("issues")
		T.assert_true(
			bufnr ~= nil
				and vim.api.nvim_buf_is_valid(bufnr),
			"issues buffer should exist"
		)

		local title_line = T.find_line(
			lines, "Title:"
		)
		T.assert_true(
			title_line ~= nil,
			"issue view should have a Title: line"
		)

		-- Title must contain the fixture title
		T.assert_contains(
			lines[title_line],
			"Setup CI pipeline",
			"Title line should show the issue title"
		)

		T.cleanup_panels()
	end,

	["issue view Title appears before Body"] = function()
		T.cleanup_panels()
		issues_panel.open_view(1, cfg)
		local lines = wait_for_detail_render("issues", "issue view should render Title and Body", function(lines)
			local title_idx = T.find_line(lines, "Title:")
			local body_idx = T.find_line(lines, "Body")
			return title_idx ~= nil and body_idx ~= nil
		end)

		local bufnr = ui.buffer.get("issues")
		T.assert_true(
			bufnr ~= nil,
			"issues buffer should exist"
		)

		local title_idx = T.find_line(lines, "Title:")
		local body_idx = T.find_line(lines, "Body")
		T.assert_true(
			title_idx ~= nil and body_idx ~= nil,
			"both Title and Body lines must exist"
		)
		T.assert_true(
			title_idx < body_idx,
			"Title line must appear before Body"
		)

		T.cleanup_panels()
	end,

	-- ── PR detail view ─────────────────────────────

	["pr view shows Title field"] = function()
		T.cleanup_panels()
		prs_panel.open_view(42, cfg)
		local lines = wait_for_detail_render("prs", "PR view should render Title line", function(lines)
			return T.find_line(lines, "Title:") ~= nil
		end)

		local bufnr = ui.buffer.get("prs")
		T.assert_true(
			bufnr ~= nil
				and vim.api.nvim_buf_is_valid(bufnr),
			"prs buffer should exist"
		)

		local title_line = T.find_line(
			lines, "Title:"
		)
		T.assert_true(
			title_line ~= nil,
			"PR view should have a Title: line"
		)

		-- Title must contain the fixture title
		T.assert_contains(
			lines[title_line],
			"Add dark mode support",
			"Title line should show the PR title"
		)

		T.cleanup_panels()
	end,

	["pr view Title appears before Body"] = function()
		T.cleanup_panels()
		prs_panel.open_view(42, cfg)
		local lines = wait_for_detail_render("prs", "PR view should render Title and Body", function(lines)
			local title_idx = T.find_line(lines, "Title:")
			local body_idx = T.find_line(lines, "Body")
			return title_idx ~= nil and body_idx ~= nil
		end)

		local bufnr = ui.buffer.get("prs")
		T.assert_true(
			bufnr ~= nil,
			"prs buffer should exist"
		)

		local title_idx = T.find_line(lines, "Title:")
		local body_idx = T.find_line(lines, "Body")
		T.assert_true(
			title_idx ~= nil and body_idx ~= nil,
			"both Title and Body lines must exist"
		)
		T.assert_true(
			title_idx < body_idx,
			"Title line must appear before Body"
		)

		T.cleanup_panels()
	end,
})
