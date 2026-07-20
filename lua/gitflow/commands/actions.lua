-- Area: GitHub Actions workflow runs.
local actions_panel = require("gitflow.panels.actions")

local M = {}

M.panels = { actions_panel }

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config

	ctx.register("actions", {
		description = "View GitHub Actions workflow runs",
		category = "GitHub",
		run = function()
			actions_panel.open(cfg)
			return "Actions panel opened"
		end,
	})
end

return M
