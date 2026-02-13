local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local gh_labels = require("gitflow.gh.labels")

---@class GitflowLabelPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field line_entries table<integer, table>

local M = {}
local LABELS_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_labels_hl")
local LABELS_FLOAT_TITLE = "Gitflow Labels"
local LABELS_KEY_HINTS = {
	{ key = "c", label = "create" },
	{ key = "d", label = "delete" },
	{ key = "r", label = "refresh" },
	{ key = "q", label = "close" },
}
local LABELS_FLOAT_FOOTER = ui.render.format_key_hints(LABELS_KEY_HINTS)

---@type GitflowLabelPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	line_entries = {},
}

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
			footer = cfg.ui.float.footer and LABELS_FLOAT_FOOTER or nil,
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

	vim.keymap.set("n", "c", function()
		M.create_interactive()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "d", function()
		M.delete_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
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
	local lines = {
		"Gitflow Labels",
		"",
		message,
	}
	local show_window_footer = M.state.cfg
		and M.state.cfg.ui.default_layout == "float"
		and M.state.cfg.ui.float.footer
	local inline_footer = show_window_footer and "" or ui.render.format_key_hints(LABELS_KEY_HINTS)
	if inline_footer ~= "" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = inline_footer
	end

	ui.buffer.update("labels", lines)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui.render.apply_panel_highlights(bufnr, LABELS_HIGHLIGHT_NS, {
		title_line = 1,
		footer_line = inline_footer ~= "" and #lines or nil,
	})
end

---@param labels table[]
local function render_list(labels)
	local lines = {
		"Gitflow Labels",
		"",
		("Labels (%d)"):format(#labels),
	}
	local line_entries = {}

	if #labels == 0 then
		lines[#lines + 1] = "  (none)"
	else
		for _, label in ipairs(labels) do
			local name = maybe_text(label.name)
			local color = maybe_text(label.color)
			local description = maybe_text(label.description)
			lines[#lines + 1] = ("  %s (#%s)"):format(name, color)
			lines[#lines + 1] = ("      %s"):format(description)
			line_entries[#lines - 1] = label
			line_entries[#lines] = label
		end
	end

	local show_window_footer = M.state.cfg
		and M.state.cfg.ui.default_layout == "float"
		and M.state.cfg.ui.float.footer
	local inline_footer = show_window_footer and "" or ui.render.format_key_hints(LABELS_KEY_HINTS)
	if inline_footer ~= "" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = inline_footer
	end

	ui.buffer.update("labels", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui.render.apply_panel_highlights(bufnr, LABELS_HIGHLIGHT_NS, {
		title_line = 1,
		header_lines = { 3 },
		footer_line = inline_footer ~= "" and #lines or nil,
	})
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

	input.prompt({ prompt = "Label name: " }, function(name)
		local label_name = vim.trim(name or "")
		if label_name == "" then
			utils.notify("Label name cannot be empty", vim.log.levels.WARN)
			return
		end

		input.prompt({ prompt = "Label color (hex): " }, function(color)
			input.prompt({ prompt = "Label description: " }, function(description)
				gh_labels.create(label_name, color or "", description, {}, function(err)
					if err then
						utils.notify(err, vim.log.levels.ERROR)
						return
					end
					utils.notify(("Created label '%s'"):format(label_name), vim.log.levels.INFO)
					M.refresh()
				end)
			end)
		end)
	end)
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
