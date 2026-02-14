--- Interactive form buffer for issue/PR/label creation.
--- Opens a scratch buffer with labeled fields that the user edits directly.
--- Navigation: <Tab>/<S-Tab> cycle fields, <CR> submit, <Esc>/q cancel.

local ui_buffer = require("gitflow.ui.buffer")
local ui_window = require("gitflow.ui.window")
local ui_render = require("gitflow.ui.render")
local utils = require("gitflow.utils")

local M = {}

local FORM_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_form_hl")

---@class GitflowFormField
---@field name string        display label (e.g. "Title")
---@field key string         result key (e.g. "title")
---@field default? string    pre-filled value
---@field required? boolean  submission guard
---@field multiline? boolean allow multiple lines of input
---@field placeholder? string hint text shown when empty

---@class GitflowFormOpts
---@field title string                float window title
---@field fields GitflowFormField[]   ordered field definitions
---@field on_submit fun(values: table<string, string>)  callback with field values
---@field on_cancel? fun()            optional cancel callback
---@field width? number               float width (fraction or absolute)
---@field height? number              float height (fraction or absolute)

---@class GitflowFormState
---@field bufnr integer|nil
---@field winid integer|nil
---@field fields GitflowFormField[]
---@field field_lines table<integer, {start: integer, stop: integer}>
---@field on_submit fun(values: table<string, string>)
---@field on_cancel? fun()
---@field active_field integer

-- Separator between label row and editable value row
local FIELD_SEPARATOR = "─"

---Render the form buffer content and record field line ranges.
---@param state GitflowFormState
---@param values table<string, string>|nil  pre-filled values
---@return string[]
local function render_form(state, values)
	values = values or {}
	local lines = {}
	local field_lines = {}

	lines[#lines + 1] = ""  -- top padding

	for idx, field in ipairs(state.fields) do
		local label = field.name
		if field.required then
			label = label .. " *"
		end
		lines[#lines + 1] = label .. ":"
		local label_line = #lines

		local value = values[field.key] or field.default or ""
		if field.multiline then
			local value_lines = vim.split(value, "\n", { plain = true })
			if #value_lines == 0 then
				value_lines = { "" }
			end
			local start_line = #lines + 1
			for _, vl in ipairs(value_lines) do
				lines[#lines + 1] = vl
			end
			field_lines[idx] = { start = start_line, stop = #lines }
		else
			lines[#lines + 1] = value
			field_lines[idx] = { start = #lines, stop = #lines }
		end

		-- spacing between fields
		if idx < #state.fields then
			lines[#lines + 1] = ""
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = string.rep(FIELD_SEPARATOR, 40)
	lines[#lines + 1] = "<Tab> next  <S-Tab> prev  <CR> submit  q/Esc cancel"

	state.field_lines = field_lines
	return lines
end

---Apply highlight groups to form labels, active field, and footer.
---@param state GitflowFormState
---@param lines string[]
local function apply_form_highlights(state, lines)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, FORM_HIGHLIGHT_NS, 0, -1)

	-- Label lines (line before each field value range)
	for idx, range in pairs(state.field_lines) do
		local label_line = range.start - 2  -- 0-indexed
		if label_line >= 0 then
			vim.api.nvim_buf_add_highlight(
				bufnr, FORM_HIGHLIGHT_NS, "GitflowFormLabel", label_line, 0, -1
			)
		end

		-- Active field accent
		if idx == state.active_field then
			for line = range.start, range.stop do
				vim.api.nvim_buf_add_highlight(
					bufnr, FORM_HIGHLIGHT_NS, "GitflowFormActiveField",
					line - 1, 0, -1
				)
			end
		end
	end

	-- Footer hints
	local footer_idx = #lines - 1  -- 0-indexed last line
	if footer_idx >= 0 then
		vim.api.nvim_buf_add_highlight(
			bufnr, FORM_HIGHLIGHT_NS, "GitflowFooter", footer_idx, 0, -1
		)
	end

	-- Separator
	local sep_idx = #lines - 2
	if sep_idx >= 0 then
		vim.api.nvim_buf_add_highlight(
			bufnr, FORM_HIGHLIGHT_NS, "GitflowSeparator", sep_idx, 0, -1
		)
	end
end

---Collect current field values from the buffer text.
---@param state GitflowFormState
---@return table<string, string>
local function collect_values(state)
	local bufnr = state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local result = {}
	for idx, field in ipairs(state.fields) do
		local range = state.field_lines[idx]
		if range then
			local field_lines = {}
			for line_no = range.start, math.min(range.stop, #all_lines) do
				field_lines[#field_lines + 1] = all_lines[line_no] or ""
			end
			result[field.key] = table.concat(field_lines, "\n")
		else
			result[field.key] = ""
		end
	end
	return result
end

---Jump cursor to the value area of the given field index.
---@param state GitflowFormState
---@param field_idx integer
local function jump_to_field(state, field_idx)
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local range = state.field_lines[field_idx]
	if not range then
		return
	end

	state.active_field = field_idx
	vim.api.nvim_win_set_cursor(state.winid, { range.start, 0 })

	-- Re-apply highlights to show active field
	local all_lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	apply_form_highlights(state, all_lines)
end

---Close and clean up form state.
---@param state GitflowFormState
local function close_form(state)
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		pcall(vim.api.nvim_win_close, state.winid, true)
	end
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
	end
	state.winid = nil
	state.bufnr = nil
end

---Open an interactive form float.
---@param opts GitflowFormOpts
---@return GitflowFormState
function M.open(opts)
	local state = {
		bufnr = nil,
		winid = nil,
		fields = opts.fields,
		field_lines = {},
		on_submit = opts.on_submit,
		on_cancel = opts.on_cancel,
		active_field = 1,
	}

	-- Create buffer
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "gitflow-form", { buf = bufnr })
	state.bufnr = bufnr

	-- Render initial content
	local lines = render_form(state, nil)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- Open float
	local width = opts.width or 0.5
	local height = opts.height or 0.5
	state.winid = ui_window.open_float({
		bufnr = bufnr,
		width = width,
		height = height,
		border = "rounded",
		title = "  " .. opts.title .. "  ",
		title_pos = "center",
		enter = true,
	})

	-- Apply highlights
	apply_form_highlights(state, lines)

	-- Place cursor on first field
	jump_to_field(state, 1)

	-- Keymaps ---

	-- <Tab>: next field
	vim.keymap.set("n", "<Tab>", function()
		local next_idx = state.active_field + 1
		if next_idx > #state.fields then
			next_idx = 1
		end
		jump_to_field(state, next_idx)
	end, { buffer = bufnr, silent = true })

	-- <S-Tab>: previous field
	vim.keymap.set("n", "<S-Tab>", function()
		local prev_idx = state.active_field - 1
		if prev_idx < 1 then
			prev_idx = #state.fields
		end
		jump_to_field(state, prev_idx)
	end, { buffer = bufnr, silent = true })

	-- <CR>: submit
	vim.keymap.set("n", "<CR>", function()
		local values = collect_values(state)

		-- Validate required fields
		for _, field in ipairs(state.fields) do
			if field.required then
				local val = vim.trim(values[field.key] or "")
				if val == "" then
					utils.notify(
						("%s is required"):format(field.name),
						vim.log.levels.WARN
					)
					return
				end
			end
		end

		close_form(state)
		state.on_submit(values)
	end, { buffer = bufnr, silent = true })

	-- q / <Esc>: cancel
	local function cancel()
		close_form(state)
		if state.on_cancel then
			state.on_cancel()
		end
	end

	vim.keymap.set("n", "q", cancel, { buffer = bufnr, silent = true })
	vim.keymap.set("n", "<Esc>", cancel, { buffer = bufnr, silent = true })

	-- Prevent BufWriteCmd from erroring on :w in acwrite buffer
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = bufnr,
		callback = function()
			vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
		end,
	})

	return state
end

return M
