local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local ui_render = require("gitflow.ui.render")
local notifications = require("gitflow.notifications")

---@class GitflowNotificationsPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filter_level integer|nil
---@field line_context table<integer, GitflowNotificationContext>

local M = {}
local NOTIF_FLOAT_TITLE = "Gitflow Notifications"
local NOTIF_FLOAT_FOOTER =
	"<CR> open  r refresh  c clear  1 error  2 warn  3 info  0 all  q close"
local NOTIF_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_notifications_hl")

---@type GitflowNotificationsPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	filter_level = nil,
	line_context = {},
}

---@type table<integer, string>
local level_label = {
	[vim.log.levels.ERROR] = "ERROR",
	[vim.log.levels.WARN] = "WARN",
	[vim.log.levels.INFO] = "INFO",
	[vim.log.levels.DEBUG] = "DEBUG",
	[vim.log.levels.TRACE] = "TRACE",
}

---@type table<integer, string>
local level_hl = {
	[vim.log.levels.ERROR] = "GitflowNotificationError",
	[vim.log.levels.WARN] = "GitflowNotificationWarn",
	[vim.log.levels.INFO] = "GitflowNotificationInfo",
}

---@param ts integer
---@return string
local function format_time(ts)
	return os.date("%H:%M:%S", ts)
end

---@param message any
---@return string[]
local function split_message_lines(message)
	local text = tostring(message or "")
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	return vim.split(text, "\n", { plain = true, trimempty = false })
end

---@param context GitflowNotificationContext|nil
---@return boolean
local function has_linked_context(context)
	return type(context) == "table"
		and type(context.command_args) == "table"
		and #context.command_args > 0
end

---@param context GitflowNotificationContext
---@return string
local function context_label(context)
	local label = context.label
	if type(label) == "string" and label ~= "" then
		return label
	end
	return table.concat(context.command_args, " ")
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("notifications", {
			filetype = "gitflownotifications",
			lines = { "Loading notifications..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value(
		"modifiable", false, { buf = bufnr }
	)

	if M.state.winid
		and vim.api.nvim_win_is_valid(M.state.winid)
	then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "notifications",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = NOTIF_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and NOTIF_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "notifications",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "c", function()
		notifications.clear()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "1", function()
		M.state.filter_level = vim.log.levels.ERROR
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "2", function()
		M.state.filter_level = vim.log.levels.WARN
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "3", function()
		M.state.filter_level = vim.log.levels.INFO
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "0", function()
		M.state.filter_level = nil
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "<CR>", function()
		M.open_context_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowNotificationEntry[]
local function render(entries)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Notifications", render_opts
	)
	local entry_highlights = {}
	local line_context = {}

	local filter = M.state.filter_level
	if filter then
		local label = level_label[filter] or "?"
		lines[#lines + 1] = ui_render.entry(
			("Filter: %s"):format(label)
		)
		lines[#lines + 1] = ""
	end

	local filtered = {}
	for i = #entries, 1, -1 do
		local e = entries[i]
		if not filter or e.level == filter then
			filtered[#filtered + 1] = e
		end
	end

	if #filtered == 0 then
		lines[#lines + 1] = ui_render.empty(
			"no notifications"
		)
	else
		for _, entry in ipairs(filtered) do
			local severity = level_label[entry.level]
				or "INFO"
			local ts = format_time(entry.timestamp)
			local message_lines = split_message_lines(entry.message)
			local context_hint = ""
			if has_linked_context(entry.context) then
				context_hint = (" [<CR> %s]"):format(
					context_label(entry.context)
				)
			end
			lines[#lines + 1] = ui_render.entry(
				("%s [%s] %s"):format(
					ts, severity,
					(message_lines[1] or "") .. context_hint
				)
			)
			if has_linked_context(entry.context) then
				line_context[#lines] = entry.context
			end
			local hl = level_hl[entry.level]
			if hl then
				entry_highlights[#lines] = hl
			end
			for idx = 2, #message_lines do
				lines[#lines + 1] = ui_render.entry(
					("    %s"):format(message_lines[idx])
				)
				if hl then
					entry_highlights[#lines] = hl
				end
			end
		end
	end

	local count_text = ("%d entries"):format(#filtered)
	local footer_lines = ui_render.panel_footer(
		nil, count_text, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("notifications", lines)

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, NOTIF_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)
	M.state.line_context = line_context
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	M.state.filter_level = nil
	M.state.line_context = {}
	ensure_window(cfg)
	M.refresh()
end

function M.open_context_under_cursor()
	local winid = M.state.winid
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		utils.notify("Notifications window is not open", vim.log.levels.WARN)
		return
	end

	local line = vim.api.nvim_win_get_cursor(winid)[1]
	local context = M.state.line_context[line]
	if not has_linked_context(context) then
		utils.notify("No linked context for this entry", vim.log.levels.WARN)
		return
	end
	if not M.state.cfg then
		utils.notify(
			"Gitflow config unavailable for context navigation",
			vim.log.levels.ERROR
		)
		return
	end

	local ok, commands = pcall(require, "gitflow.commands")
	if not ok or type(commands.dispatch) ~= "function" then
		utils.notify(
			"Gitflow commands unavailable for context navigation",
			vim.log.levels.ERROR
		)
		return
	end

	local cfg = M.state.cfg
	local args = vim.deepcopy(context.command_args)
	M.close()
	local dispatch_ok, dispatch_err = pcall(
		commands.dispatch, args, cfg
	)
	if not dispatch_ok then
		utils.notify(
			("Failed to open linked context: %s"):format(
				tostring(dispatch_err)
			),
			vim.log.levels.ERROR
		)
	end
end

function M.refresh()
	render(notifications.entries())
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("notifications")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("notifications")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.filter_level = nil
	M.state.line_context = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
