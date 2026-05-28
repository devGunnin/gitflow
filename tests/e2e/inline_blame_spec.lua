-- tests/e2e/inline_blame_spec.lua — inline (current-line) blame E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/inline_blame_spec.lua
--
-- Verifies:
--   1. The `blame` subcommand is registered with :Gitflow
--   2. The gitflow_inline_blame namespace exists
--   3. toggle()/is_enabled() flip state for a buffer
--   4. enable() renders "<author>, <date> • <summary>" virt_text on the
--      cursor line, sourced from the (stubbed) git blame --line-porcelain
--   5. disable() removes the annotation

local T = _G.T

local inline_blame = require("gitflow.inline_blame")
local commands = require("gitflow.commands")

--- Open a throwaway on-disk file as a normal, listed buffer (inline blame
--- ignores scratch/nofile buffers).
---@return integer bufnr, string path
local function open_temp_file()
	local path = vim.fn.tempname() .. ".txt"
	T.write_file(path, { "alpha", "beta", "gamma" })
	vim.cmd("silent edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	return bufnr, path
end

---@param bufnr integer
---@return string|nil
local function inline_virt_text(bufnr)
	local marks = vim.api.nvim_buf_get_extmarks(
		bufnr, inline_blame.namespace, 0, -1, { details = true }
	)
	for _, m in ipairs(marks) do
		local details = m[4]
		if details and details.virt_text then
			local text = ""
			for _, chunk in ipairs(details.virt_text) do
				text = text .. tostring(chunk[1] or "")
			end
			return text
		end
	end
	return nil
end

T.run_suite("E2E: Inline Blame", {

	["blame subcommand is registered"] = function()
		T.assert_true(
			commands.subcommands.blame ~= nil,
			"`:Gitflow blame` subcommand should be registered"
		)
	end,

	["gitflow_inline_blame namespace is registered"] = function()
		local namespaces = vim.api.nvim_get_namespaces()
		T.assert_true(
			namespaces["gitflow_inline_blame"] ~= nil,
			"namespace 'gitflow_inline_blame' should exist"
		)
	end,

	["toggle enables then disables for a buffer"] = function()
		local bufnr = open_temp_file()

		local enabled = inline_blame.toggle(bufnr)
		T.assert_true(enabled, "first toggle should enable inline blame")
		T.assert_true(inline_blame.is_enabled(bufnr),
			"is_enabled should report true after enable")

		local disabled = inline_blame.toggle(bufnr)
		T.assert_false(disabled, "second toggle should disable inline blame")
		T.assert_false(inline_blame.is_enabled(bufnr),
			"is_enabled should report false after disable")

		vim.api.nvim_buf_delete(bufnr, { force = true })
	end,

	["enable renders author/date/summary virt_text on the cursor line"] = function()
		local bufnr = open_temp_file()

		inline_blame.enable(bufnr)
		T.wait_until(function()
			return inline_virt_text(bufnr) ~= nil
		end, "an inline-blame virt_text mark should appear", 5000)

		local text = inline_virt_text(bufnr)
		T.assert_true(text ~= nil, "virt_text should be present")
		T.assert_contains(text, "Test Author",
			"virt_text should include the author")
		T.assert_contains(text, "Initial commit",
			"virt_text should include the commit summary")
		T.assert_contains(text, " • ",
			"virt_text should use the ' • ' separator before the summary")

		inline_blame.disable(bufnr)
		T.assert_true(inline_virt_text(bufnr) == nil,
			"disable should clear the inline-blame mark")

		vim.api.nvim_buf_delete(bufnr, { force = true })
	end,
})

print("E2E inline blame tests passed")
