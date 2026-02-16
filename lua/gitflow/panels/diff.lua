local ui = require("gitflow.ui")
local ui_render = require("gitflow.ui.render")
local utils = require("gitflow.utils")
local git_diff = require("gitflow.git.diff")
local git_branch = require("gitflow.git.branch")

---@class GitflowDiffPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field request table|nil
---@field file_markers GitflowDiffFileMarker[]
---@field hunk_markers GitflowDiffHunkMarker[]
---@field line_context table<integer, GitflowDiffLineContext>

local M = {}
local DIFF_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_diff_hl")
local DIFF_LINENR_NS = vim.api.nvim_create_namespace("gitflow_diff_linenr")
local DIFF_FLOAT_TITLE = "Gitflow Diff"
local DIFF_FLOAT_FOOTER =
	"]f/[f files  ]c/[c hunks  r refresh  q close"

---@type GitflowDiffPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	request = nil,
	file_markers = {},
	hunk_markers = {},
	line_context = {},
}

---@param text string
---@return string[]
local function to_lines(text)
	if text == "" then
		return { "(no diff output)" }
	end
	return vim.split(text, "\n", { plain = true })
end

---@param request table
---@return string
local function request_to_title(request)
	if request.commit then
		return ("Gitflow Diff (%s)"):format(
			request.commit:sub(1, 8)
		)
	end
	if request.staged then
		if request.path then
			return ("Gitflow Diff --staged (%s)"):format(
				request.path
			)
		end
		return "Gitflow Diff --staged"
	end
	if request.path then
		return ("Gitflow Diff (%s)"):format(request.path)
	end
	return "Gitflow Diff"
end

---Jump to the next/prev marker in a list, wrapping around.
---@param markers table[]
---@param direction 1|-1
local function jump_to_marker(markers, direction)
	if not M.state.winid
		or not vim.api.nvim_win_is_valid(M.state.winid) then
		return
	end
	if #markers == 0 then
		utils.notify(
			"No diff markers available", vim.log.levels.WARN
		)
		return
	end

	local cursor_line =
		vim.api.nvim_win_get_cursor(M.state.winid)[1]
	if direction > 0 then
		for _, marker in ipairs(markers) do
			if marker.line > cursor_line then
				vim.api.nvim_win_set_cursor(
					M.state.winid, { marker.line, 0 }
				)
				return
			end
		end
		vim.api.nvim_win_set_cursor(
			M.state.winid, { markers[1].line, 0 }
		)
		return
	end

	for i = #markers, 1, -1 do
		local marker = markers[i]
		if marker.line < cursor_line then
			vim.api.nvim_win_set_cursor(
				M.state.winid, { marker.line, 0 }
			)
			return
		end
	end
	vim.api.nvim_win_set_cursor(
		M.state.winid, { markers[#markers].line, 0 }
	)
end

function M.next_file()
	jump_to_marker(M.state.file_markers, 1)
end

function M.prev_file()
	jump_to_marker(M.state.file_markers, -1)
end

function M.next_hunk()
	jump_to_marker(M.state.hunk_markers, 1)
end

function M.prev_hunk()
	jump_to_marker(M.state.hunk_markers, -1)
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("diff", {
			filetype = "gitflow-diff",
			lines = { "Loading diff..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value(
		"filetype", "gitflow-diff", { buf = bufnr }
	)
	vim.api.nvim_set_option_value(
		"syntax", "diff", { buf = bufnr }
	)
	vim.api.nvim_set_option_value(
		"modifiable", false, { buf = bufnr }
	)

	if M.state.winid
		and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "diff",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = DIFF_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and DIFF_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "diff",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		if M.state.request then
			M.open(cfg, M.state.request)
		end
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "]f", function()
		M.next_file()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "[f", function()
		M.prev_file()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "]c", function()
		M.next_hunk()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "[c", function()
		M.prev_hunk()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param _title string
---@param text string
---@param current_branch string
local function render(title, text, current_branch)
	local diff_lines = to_lines(text)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(title, render_opts)
	local header_line_count = #lines

	-- Build file summary section
	local preview_files, preview_hunks =
		git_diff.collect_markers(diff_lines, 1)
	if #preview_files > 0 then
		lines[#lines + 1] = ("Files: %d  Hunks: %d"):format(
			#preview_files, #preview_hunks
		)
	end

	local diff_start_idx = #lines + 1
	for _, line in ipairs(diff_lines) do
		lines[#lines + 1] = line
	end
	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end
	ui.buffer.update("diff", lines)

	-- Collect markers relative to buffer positions
	M.state.file_markers, M.state.hunk_markers,
		M.state.line_context =
		git_diff.collect_markers(diff_lines, diff_start_idx)

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local entry_highlights = {}

	-- File summary header highlight
	if #preview_files > 0 then
		entry_highlights[header_line_count + 1] =
			"GitflowHeader"
	end

	for idx, line in ipairs(diff_lines) do
		local buf_line = idx + diff_start_idx - 1
		local group = nil
		if vim.startswith(line, "diff --git")
			or vim.startswith(line, "index ")
			or vim.startswith(line, "--- ")
			or vim.startswith(line, "+++ ") then
			group = "GitflowDiffFileHeader"
		elseif vim.startswith(line, "new file mode")
			or vim.startswith(line, "deleted file mode")
			or vim.startswith(line, "rename from")
			or vim.startswith(line, "rename to")
			or vim.startswith(line, "similarity index")
			or vim.startswith(line, "old mode")
			or vim.startswith(line, "new mode") then
			group = "GitflowDiffFileHeader"
		elseif vim.startswith(line, "@@") then
			group = "GitflowDiffHunkHeader"
		elseif vim.startswith(line, "+")
			and not vim.startswith(line, "+++") then
			group = "GitflowAdded"
		elseif vim.startswith(line, "-")
			and not vim.startswith(line, "---") then
			group = "GitflowRemoved"
		elseif vim.startswith(line, " ") then
			group = "GitflowDiffContext"
		end
		if group then
			entry_highlights[buf_line] = group
		end
	end

	ui_render.apply_panel_highlights(
		bufnr, DIFF_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)

	-- Line numbers via right-aligned virtual text
	vim.api.nvim_buf_clear_namespace(
		bufnr, DIFF_LINENR_NS, 0, -1
	)
	for line_no, ctx in pairs(M.state.line_context) do
		if ctx.old_line or ctx.new_line then
			local old_str = ctx.old_line
				and tostring(ctx.old_line) or " "
			local new_str = ctx.new_line
				and tostring(ctx.new_line) or " "
			local label = ("%4s %4s"):format(
				old_str, new_str
			)
			pcall(
				vim.api.nvim_buf_set_extmark,
				bufnr, DIFF_LINENR_NS, line_no - 1, 0,
				{
					virt_text = {
						{ label, "GitflowDiffLineNr" },
					},
					virt_text_pos = "right_align",
				}
			)
		end
	end
end

---@param cfg GitflowConfig
---@param request table
function M.open(cfg, request)
	M.state.request = vim.deepcopy(request)
	ensure_window(cfg)

	git_branch.current({}, function(_, branch)
		git_diff.get(request, function(err, output)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end

			render(
				request_to_title(request),
				output or "",
				branch or "(unknown)"
			)
		end)
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("diff")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("diff")
	end

	M.state.winid = nil
	M.state.bufnr = nil
	M.state.request = nil
	M.state.file_markers = {}
	M.state.hunk_markers = {}
	M.state.line_context = {}
end

return M
