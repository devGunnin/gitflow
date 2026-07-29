-- Area: reading history in place — blame (panel and inline) and reflog.
local inline_blame = require("gitflow.inline_blame")
local blame_panel = require("gitflow.panels.blame")
local reflog_panel = require("gitflow.panels.reflog")
local diffview_panel = require("gitflow.panels.diffview")

local M = {}

M.panels = { blame_panel, reflog_panel }

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config

	ctx.register("blame", {
		description = "Toggle git blame panel for current file",
		run = function()
			if blame_panel.is_open() then
				blame_panel.close()
				return "Blame panel closed"
			end
			blame_panel.open(cfg, {
				on_open_commit = function(sha)
					diffview_panel.open_commit(cfg, sha)
				end,
			})
			return "Blame panel opened"
		end,
	})

	ctx.register("reflog", {
		description = "Open git reflog panel",
		run = function()
			reflog_panel.open(cfg)
			return "Reflog panel opened"
		end,
	})

	ctx.register("blame-inline", {
		description = "Toggle inline git blame on the current line",
		run = function()
			if not cfg.inline_blame or cfg.inline_blame.enable == false then
				return "Inline blame is disabled (inline_blame.enable = false)"
			end
			local bufnr = vim.api.nvim_get_current_buf()
			local enabled = inline_blame.toggle(bufnr)
			return enabled and "Inline blame enabled" or "Inline blame disabled"
		end,
	})
end

return M
