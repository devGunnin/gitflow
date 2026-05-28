local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_tag = require("gitflow.git.tag")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")

---@class GitflowTagPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowTagEntry>
---@field cfg GitflowConfig|nil

local M = {}
local TAG_FLOAT_TITLE = "Gitflow Tags"
local TAG_FLOAT_FOOTER =
	"c create  D delete  X remote del  P push  r refresh  q close"
local TAG_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_tag_hl")

---@type GitflowTagPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
}

local function emit_post_operation()
	vim.api.nvim_exec_autocmds(
		"User", { pattern = "GitflowPostOperation" }
	)
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("tag", {
			filetype = "gitflowtag",
			lines = { "Loading tags..." },
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
			name = "tag",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = TAG_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and TAG_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "tag",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "c", function()
		M.create_tag()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "D", function()
		M.delete_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "X", function()
		M.delete_remote_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "P", function()
		M.push_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowTagEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Tags", render_opts
	)
	local line_entries = {}
	local entry_highlights = {}

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty("no tags found")
	else
		for _, entry in ipairs(entries) do
			local tag_icon = icons.get("git_state", "commit")
			local type_indicator = entry.is_annotated
				and "[annotated]" or "[lightweight]"
			local subject_part = entry.subject
				and ("  " .. entry.subject) or ""
			lines[#lines + 1] = ui_render.entry(
				("%s %s %s%s"):format(
					tag_icon,
					entry.name,
					type_indicator,
					subject_part
				)
			)
			line_entries[#lines] = entry

			if entry.is_annotated then
				entry_highlights[#lines] =
					"GitflowTagAnnotated"
			end
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("tag", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, TAG_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)
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
	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	git_branch.current({}, function(_, branch)
		git_tag.list({}, function(err, entries)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
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
				{ prompt = "Message (empty for lightweight): " },
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
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("tag")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("tag")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
