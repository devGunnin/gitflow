local ui = require("gitflow.ui")
local ui_render = require("gitflow.ui.render")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local form = require("gitflow.ui.form")
local gh_labels = require("gitflow.gh.labels")
local highlights = require("gitflow.highlights")
local config = require("gitflow.config")

local LABELS_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_labels_hl")
local LABELS_FLOAT_TITLE = "Gitflow Labels"
local LABELS_KEY_HINTS = {
	{ action = "create", default = "c", label = "create" },
	{ action = "delete", default = "d", label = "delete" },
	{ action = "refresh", default = "r", label = "refresh" },
	{ action = "close", default = "q", label = "close" },
}

---@class GitflowLabelPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field line_entries table<integer, table>

local M = {}

---@type GitflowLabelPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	line_entries = {},
}

---@param cfg GitflowConfig|nil
---@return string
local function labels_key_hints(cfg)
	return ui_render.resolve_panel_key_hints(
		cfg or config.current, "labels", LABELS_KEY_HINTS
	)
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("labels", {
			filetype = "markdown",
			lines = { "Loading labels..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "labels",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = LABELS_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and labels_key_hints(cfg) or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "labels",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	local pk = function(action, default)
		return config.resolve_panel_key(
			cfg, "labels", action, default
		)
	end

	vim.keymap.set("n", pk("create", "c"), function()
		M.create_interactive()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("delete", "d"), function()
		M.delete_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("refresh", "r"), function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", pk("close", "q"), function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param value string|nil
---@return string
local function maybe_text(value)
	local text = vim.trim(tostring(value or ""))
	if text == "" then
		return "-"
	end
	return text
end

local function render_loading(message)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Labels", render_opts)
	lines[#lines + 1] = ui_render.entry(message)
	ui.buffer.update("labels", lines)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		ui_render.apply_panel_highlights(bufnr, LABELS_HIGHLIGHT_NS, lines, {})
	end
end

---@param labels table[]
local function render_list(labels)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Labels", render_opts)
	local section_title, section_separator = ui_render.section("Labels", #labels, render_opts)
	lines[#lines + 1] = section_title
	lines[#lines + 1] = section_separator
	local line_entries = {}

	if #labels == 0 then
		lines[#lines + 1] = ui_render.empty()
	else
		for _, label in ipairs(labels) do
			local name = maybe_text(label.name)
			local color = maybe_text(label.color)
			local description = maybe_text(label.description)
			lines[#lines + 1] = ui_render.entry(("%s (#%s)"):format(name, color))
			lines[#lines + 1] = ui_render.entry(("    %s"):format(description))
			line_entries[#lines - 1] = label
			line_entries[#lines] = label
		end
	end

	local key_hints = labels_key_hints(M.state.cfg or config.current)
	local footer_lines = ui_render.panel_footer(nil, key_hints, render_opts)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("labels", lines)

	local bufnr = M.state.bufnr
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		local entry_highlights = {}
		-- Mark section header
		for line_no, line in ipairs(lines) do
			if vim.startswith(line, "Labels (") or line == "Labels" then
				entry_highlights[line_no] = "GitflowHeader"
			end
		end

		ui_render.apply_panel_highlights(bufnr, LABELS_HIGHLIGHT_NS, lines, {
			footer_line = key_hints ~= "" and #lines or nil,
			entry_highlights = entry_highlights,
		})

		-- Apply colored label highlights
		for line_no, label in pairs(line_entries) do
			if label.color and label.name then
				local group = highlights.label_color_group(label.color)
				local line_text = lines[line_no] or ""
				local name_start = line_text:find(label.name, 1, true)
				if name_start then
					vim.api.nvim_buf_add_highlight(
						bufnr, LABELS_HIGHLIGHT_NS, group,
						line_no - 1, name_start - 1,
						name_start - 1 + #label.name
					)
				end
			end
		end
	end

	M.state.line_entries = line_entries
end

---@return table|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	if not M.state.cfg then
		return
	end

	render_loading("Loading labels...")
	gh_labels.list({}, function(err, labels)
		if err then
			render_loading("Failed to load labels")
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_list(labels or {})
	end)
end

function M.create_interactive()
	if not M.state.cfg then
		return
	end

	form.open({
		title = "Create Label",
		fields = {
			{ name = "Name", key = "name", required = true },
			{ name = "Color (hex)", key = "color", required = true,
				placeholder = "e.g. ff0000" },
			{ name = "Description", key = "description" },
		},
		on_submit = function(values)
			gh_labels.create(
				values.name, values.color or "", values.description, {},
				function(err)
					if err then
						utils.notify(err, vim.log.levels.ERROR)
						return
					end
					utils.notify(
						("Created label '%s'"):format(values.name),
						vim.log.levels.INFO
					)
					M.refresh()
				end
			)
		end,
	})
end

function M.delete_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No label selected", vim.log.levels.WARN)
		return
	end

	local label_name = maybe_text(entry.name)
	local confirmed = input.confirm(("Delete label '%s'?"):format(label_name), {
		choices = { "&Delete", "&Cancel" },
		default_choice = 2,
	})
	if not confirmed then
		return
	end

	gh_labels.delete(label_name, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Deleted label '%s'"):format(label_name), vim.log.levels.INFO)
		M.refresh()
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("labels")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("labels")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
