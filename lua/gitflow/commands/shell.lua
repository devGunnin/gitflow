-- Area: the Gitflow shell itself — usage, the main panel, the command palette
-- and the notification center.
local ui = require("gitflow.ui")
local shared = require("gitflow.commands.shared")
local status_panel = require("gitflow.panels.status")
local branch_panel = require("gitflow.panels.branch")
local palette_panel = require("gitflow.panels.palette")
local notifications_panel = require("gitflow.panels.notifications")

local MAIN_FLOAT_FOOTER = ":Gitflow status  :Gitflow branch  :Gitflow prs  :Gitflow issues"

local M = {}

M.panels = { palette_panel, notifications_panel }

---@param cfg GitflowConfig
---@param state GitflowCommandState
local function open_panel(cfg, state)
	local bufnr = ui.buffer.create("main", {
		filetype = "gitflow",
		lines = {
			"Gitflow",
			"",
			"Plugin skeleton initialized.",
			"Run :Gitflow status to open Stage 2 status panel.",
		},
	})
	state.panel_buffer = bufnr

	if cfg.ui.default_layout == "float" then
		state.panel_window = ui.window.open_float({
			name = "main",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = cfg.ui.float.title,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and MAIN_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				state.panel_window = nil
			end,
		})
		return
	end

	state.panel_window = ui.window.open_split({
		name = "main",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			state.panel_window = nil
		end,
	})
end

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config
	local commands = ctx.commands

	ctx.register("help", {
		description = "Show Gitflow usage",
		category = "UI",
		run = function()
			local usage = commands.usage()
			shared.show_info(usage)
			return usage
		end,
	})

	ctx.register("open", {
		description = "Open the Gitflow main panel",
		category = "UI",
		run = function()
			open_panel(cfg, commands.state)
			return "Gitflow panel opened"
		end,
	})

	ctx.register("refresh", {
		description = "Refresh main/status panel content",
		category = "UI",
		run = function()
			local bufnr = commands.state.panel_buffer or ui.buffer.get("main")
			if bufnr then
				ui.buffer.update(bufnr, {
					"Gitflow",
					"",
					("Last refresh: %s"):format(os.date("%Y-%m-%d %H:%M:%S")),
				})
			end

			if status_panel.is_open() then
				status_panel.refresh()
			end
			if branch_panel.is_open() then
				branch_panel.refresh()
			end
			return "Gitflow panel refreshed"
		end,
	})

	ctx.register("close", {
		description = "Close open Gitflow panels",
		category = "UI",
		run = function()
			local state = commands.state
			if state.panel_window then
				ui.window.close(state.panel_window)
			else
				ui.window.close("main")
			end
			if state.panel_buffer then
				ui.buffer.teardown(state.panel_buffer)
			else
				ui.buffer.teardown("main")
			end
			state.panel_window = nil
			state.panel_buffer = nil

			commands.close_area_panels()
			return "Gitflow panels closed"
		end,
	})

	ctx.register("palette", {
		description = "Open command palette",
		category = "UI",
		run = function()
			palette_panel.open(cfg, commands.palette_entries(cfg), function(entry)
				commands.dispatch({ entry.name }, cfg)
			end)
			return "Command palette opened"
		end,
	})

	ctx.register("notifications", {
		description = "Open notification center",
		category = "UI",
		run = function()
			notifications_panel.open(cfg)
			return "Notifications panel opened"
		end,
	})
end

return M
