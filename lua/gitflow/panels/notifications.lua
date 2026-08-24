local utils = require("gitflow.utils")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")
local panel = require("gitflow.ui.panel")
local icons = require("gitflow.icons")
local notifications = require("gitflow.notifications")

---@class GitflowNotificationsPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field filter_level integer|nil
---@field line_context table<integer, GitflowNotificationContext>

local M = {}

---@type GitflowNotificationsPanelState
M.state = {
	cfg = nil,
	filter_level = nil,
	line_context = {},
}

---Set the severity filter and repaint.
---@param level integer|nil
local function filter_to(level)
	M.state.filter_level = level
	M.refresh()
end

local P = panel.new({
	name = "notifications",
	title = "Gitflow Notifications",
	filetype = "gitflownotifications",
	loading = "Loading notifications…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "open", run = function()
			M.open_context_under_cursor()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "c", desc = "clear", run = function()
			notifications.clear()
			M.refresh()
		end },
		{ key = "1", desc = "error", run = function()
			filter_to(vim.log.levels.ERROR)
		end },
		{ key = "2", desc = "warn", run = function()
			filter_to(vim.log.levels.WARN)
		end },
		{ key = "3", desc = "info", run = function()
			filter_to(vim.log.levels.INFO)
		end },
		{ key = "0", desc = "all", run = function()
			filter_to(nil)
		end },
		{ key = "q", desc = "close", run = function()
			M.close()
		end },
	},
})

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

---@param level integer
---@return string
local function level_icon(level)
	if level == vim.log.levels.ERROR then
		return icons.get("git_state", "conflict")
	elseif level == vim.log.levels.WARN then
		return icons.get("git_state", "modified")
	end
	return icons.get("ui", "dot")
end

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

---@param entries GitflowNotificationEntry[]
local function render(entries)
	local B = P:begin_render()

	local filter = M.state.filter_level

	-- Newest-first, honouring the active severity filter.
	local filtered = {}
	for i = #entries, 1, -1 do
		local e = entries[i]
		if not filter or e.level == filter then
			filtered[#filtered + 1] = e
		end
	end

	-- Summary bar: icon + count + filter context. When a filter is active the
	-- bar carries the literal "Filter: <LEVEL>" marker.
	local filter_extra
	if filter then
		filter_extra = { key = "Filter:", value = level_label[filter] or "?" }
	else
		filter_extra = { key = "Showing", value = "all levels" }
	end
	components.summary(
		B,
		icons.get("palette", "notifications"),
		("%d notification%s"):format(#filtered, #filtered == 1 and "" or "s"),
		{ filter_extra }
	)
	B:blank()

	local line_context = {}

	components.section(
		B,
		icons.get("ui", "clock"),
		("Recent (%d)"):format(#filtered)
	)

	if #filtered == 0 then
		components.empty(B, "no notifications")
	else
		for _, entry in ipairs(filtered) do
			local severity = level_label[entry.level] or "INFO"
			local hl = level_hl[entry.level] or "GitflowMeta"
			local ts = format_time(entry.timestamp)
			local message_lines = split_message_lines(entry.message)

			local chunks = {
				{ components.spacing.edge, nil },
				{ level_icon(entry.level) .. "  ", hl },
				{ ts .. "  ", "GitflowRelTime" },
				{ ("[%s]"):format(severity), hl },
				{ components.spacing.gutter, nil },
				{ message_lines[1] or "", "GitflowCardTitle" },
			}
			if has_linked_context(entry.context) then
				chunks[#chunks + 1] = { components.spacing.indent, nil }
				chunks[#chunks + 1] = {
					icons.get("ui", "chevron") .. " ", "GitflowHintKey",
				}
				chunks[#chunks + 1] = {
					context_label(entry.context), "GitflowMeta",
				}
			end
			local line_no = B:push(chunks)
			if has_linked_context(entry.context) then
				line_context[line_no] = entry.context
			end

			-- Continuation lines are indented with four spaces.
			for idx = 2, #message_lines do
				B:push({
					{ components.spacing.indent, nil },
					{ message_lines[idx], hl },
				})
			end
		end
	end

	P:push_hints(B)

	-- In-buffer footer: entry count only — never a branch label.
	B:blank()
	B:raw(ui_render.separator(P:render_opts()), "GitflowSeparator")
	B:push({
		{ components.spacing.gutter, nil },
		{ ("%d entries"):format(#filtered), "GitflowFooter" },
	})

	if P:paint(B) then
		M.state.line_context = line_context
	end
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	M.state.filter_level = nil
	M.state.line_context = {}
	if not P:ensure_window(cfg) then
		return
	end
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
	P:close()
	M.state.filter_level = nil
	M.state.line_context = {}
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
