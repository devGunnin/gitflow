local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_tag = require("gitflow.git.tag")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
local components = require("gitflow.ui.components")

---@class GitflowTagPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowTagEntry>
---@field cfg GitflowConfig|nil

local M = {}

---@type GitflowTagPanelState
M.state = {
	line_entries = {},
	cfg = nil,
}

local P = panel.new({
	name = "tag",
	title = "Gitflow Tags",
	filetype = "gitflowtag",
	loading = "Loading tags…",
	state = M.state,
	-- Every lightweight tag carries an empty `sha`, and annotated tags share
	-- one when they point at the same commit; the tag name is the real key.
	identity = function(entry)
		if type(entry) == "table" and type(entry.name) == "string" then
			return "name=" .. entry.name
		end
		return panel.entry_identity(entry)
	end,
	keymaps = {
		{ key = "c", desc = "create", essential = true, run = function()
			M.create_tag()
		end },
		{ key = "D", desc = "delete", destructive = true, run = function()
			M.delete_under_cursor()
		end },
		{ key = "X", desc = "remote del", destructive = true, run = function()
			M.delete_remote_under_cursor()
		end },
		{ key = "P", desc = "push", run = function()
			M.push_under_cursor()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

local function emit_post_operation()
	vim.api.nvim_exec_autocmds(
		"User", { pattern = "GitflowPostOperation" }
	)
end

---@param entries GitflowTagEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local tag_icon = icons.get("git_state", "tag")

	local B = P:begin_render()

	-- Tag count + branch context summary bar.
	B:push({
		{ components.spacing.gutter, nil },
		{ tag_icon .. "  ", "GitflowSectionIcon" },
		{
			("%d tag%s"):format(#entries, #entries == 1 and "" or "s"),
			"GitflowSectionTitle",
		},
		{ components.separators.field .. icons.get("branch", "current") .. " ",
			"GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	components.section(B, tag_icon, ("Tags (%d)"):format(#entries))

	local line_entries = {}
	if #entries == 0 then
		components.empty(B, "no tags found")
	else
		for _, entry in ipairs(entries) do
			local annotated = entry.is_annotated
			-- Annotated tags carry the GitflowTagAnnotated accent on their
			-- icon + name; lightweight tags use the neutral chip color.
			local accent = annotated and "GitflowTagAnnotated" or "GitflowChip"
			local type_marker = annotated and "[annotated]" or "[lightweight]"
			local chunks = {
				{ components.spacing.gutter, nil },
				{ tag_icon .. "  ", accent },
				{ entry.name, accent },
				{ components.spacing.gutter .. type_marker, "GitflowMeta" },
			}
			if entry.subject and entry.subject ~= "" then
				chunks[#chunks + 1] = { components.spacing.gutter .. entry.subject, "GitflowCardTitle" }
			end
			if entry.sha and entry.sha ~= "" then
				chunks[#chunks + 1] = { components.spacing.gutter .. " " .. entry.sha, "GitflowMeta" }
			end
			local line_no = B:push(chunks)
			line_entries[line_no] = entry
		end
	end

	P:push_hints(B)

	P:paint(B, line_entries)
end

---@return GitflowTagEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	if not P:ensure_window(cfg) then
		return
	end
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local request_id = P:next_request()
	git_branch.current({}, function(_, branch)
		if not P:is_active(request_id) then
			return
		end
		git_tag.list({}, function(err, entries)
			if not P:is_active(request_id) then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				P:render_error("Could not list tags", { detail = err,
					hint = "r retries" })
				return
			end
			render(entries or {}, branch or "(unknown)")
		end)
	end)
end

function M.create_tag()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	ui.input.prompt(
		{ prompt = "Tag name: " },
		function(name)
			if not name or vim.trim(name) == "" then
				return
			end
			name = vim.trim(name)

			ui.input.prompt(
				{
					multiline = true,
					title = "Tag message (empty for lightweight)",
					draft_key = ("tag:%s:message"):format(name),
				},
				function(message)
					local opts = {}
					if message and vim.trim(message) ~= "" then
						opts.message = vim.trim(message)
					end

					git_tag.create(
						name,
						opts,
						function(err)
							if err then
								utils.notify(
									err,
									vim.log.levels.ERROR
								)
								return
							end
							local label = opts.message
								and "annotated" or "lightweight"
							utils.notify(
								("Created %s tag '%s'"):format(
									label, name
								),
								vim.log.levels.INFO
							)
							M.refresh()
							emit_post_operation()
						end
					)
				end
			)
		end
	)
end

function M.delete_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No tag selected", vim.log.levels.WARN)
		return
	end

	local confirmed = ui.input.confirm(
		("Delete local tag '%s'?"):format(entry.name),
		{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	git_tag.delete(entry.name, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			("Deleted tag '%s'"):format(entry.name),
			vim.log.levels.INFO
		)
		M.refresh()
		emit_post_operation()
	end)
end

function M.delete_remote_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No tag selected", vim.log.levels.WARN)
		return
	end

	local confirmed = ui.input.confirm(
		("Delete REMOTE tag '%s' from origin?"):format(entry.name),
		{ choices = { "&Delete", "&Cancel" }, default_choice = 2 }
	)
	if not confirmed then
		return
	end

	git_tag.delete_remote(entry.name, nil, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			("Deleted remote tag '%s'"):format(entry.name),
			vim.log.levels.INFO
		)
		M.refresh()
	end)
end

function M.push_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No tag selected", vim.log.levels.WARN)
		return
	end

	git_tag.push(entry.name, nil, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			("Pushed tag '%s' to origin"):format(entry.name),
			vim.log.levels.INFO
		)
	end)
end

function M.close()
	P:close()
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
