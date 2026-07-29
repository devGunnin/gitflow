-- scripts/test_compose_form.lua — drive the floating compose form in tests
--
-- Commit-message prompts moved from vim.ui.input to the floating form buffer
-- (ui.input.compose), so tests must fill and submit that form instead of
-- stubbing vim.ui.input.
--
-- Usage (add after project_root is defined):
--   local compose = dofile(project_root .. "/scripts/test_compose_form.lua")
--   compose.submit("commit message")
--   compose.is_open()

---@return integer|nil winid, integer|nil bufnr
local function find_form_window()
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local bufnr = vim.api.nvim_win_get_buf(winid)
		if vim.api.nvim_get_option_value("filetype", { buf = bufnr }) == "gitflow-form" then
			return winid, bufnr
		end
	end
	return nil, nil
end

---@param lines string[]
---@param label string
---@return integer|nil  1-indexed line number of the label
local function find_label_line(lines, label)
	for i, line in ipairs(lines) do
		if line:find(label, 1, true) then
			return i
		end
	end
	return nil
end

local M = {}

---@return boolean  whether a compose form is currently open
function M.is_open()
	return (find_form_window()) ~= nil
end

---Wait for the compose form, fill one field, and submit it.
---@param value string  text to place in the field
---@param opts? { field?: string, timeout_ms?: integer }
function M.submit(value, opts)
	assert(type(value) == "string", "compose value must be a string")
	local options = opts or {}
	local field = options.field or "Message"
	local timeout_ms = options.timeout_ms or 5000

	local winid, bufnr
	local opened = vim.wait(timeout_ms, function()
		winid, bufnr = find_form_window()
		return winid ~= nil
	end, 20)
	assert(opened, ("compose form did not open within %dms"):format(timeout_ms))

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local label_line = find_label_line(lines, field)
	assert(label_line, ("compose form has no '%s' field"):format(field))

	-- value area starts on the line after the label; set_lines is 0-indexed
	vim.api.nvim_buf_set_lines(bufnr, label_line, label_line + 1, false, { value })

	vim.api.nvim_set_current_win(winid)
	vim.api.nvim_win_set_cursor(winid, { label_line + 1, 0 })
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
end

return M
