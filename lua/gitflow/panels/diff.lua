--- The raw unified-diff panel: `git diff` rendered in place, with file and
--- hunk markers to jump between.
---
--- On `ui/panel.lua`, so the buffer, the window, the keys, the hint chrome and
--- the loading/error states are the base's — including the case the panel used
--- to leak: a terminal too small for the float left the buffer behind with no
--- window to close it from.

local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
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
local DIFF_LINENR_NS = vim.api.nvim_create_namespace("gitflow_diff_linenr")

---@type GitflowDiffPanelState
M.state = {
	request = nil,
	file_markers = {},
	hunk_markers = {},
	line_context = {},
}

local P = panel.new({
	name = "diff",
	title = "Gitflow Diff",
	filetype = "gitflow-diff",
	loading = "Loading diff…",
	state = M.state,
	-- All three index buffer lines. A state render collapses the buffer, so a
	-- surviving marker would send ]f to a line that is no longer there.
	entry_maps = { "file_markers", "hunk_markers", "line_context" },
	keymaps = {
		{ key = "]f/[f", keys = { "]f", "[f" }, desc = "files",
			essential = true, run = function(key)
				if key == "]f" then
					M.next_file()
				else
					M.prev_file()
				end
			end },
		{ key = "]c/[c", keys = { "]c", "[c" }, desc = "hunks",
			run = function(key)
				if key == "]c" then
					M.next_hunk()
				else
					M.prev_hunk()
				end
			end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

---@param text string
---@return string[]
local function to_lines(text)
	if text == "" then
		return { "no diff output" }
	end
	return vim.split(text, "\n", { plain = true })
end

---@param request table
---@return string
local function request_to_title(request)
	if request.commit then
		return ("Gitflow Diff (%s)"):format(request.commit:sub(1, 8))
	end
	if request.staged then
		if request.path then
			return ("Gitflow Diff --staged (%s)"):format(request.path)
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
	if not P:has_window() then
		return
	end
	if #markers == 0 then
		utils.notify("No diff markers available", vim.log.levels.WARN)
		return
	end

	local winid = M.state.winid
	local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
	local function go(line)
		vim.api.nvim_win_set_cursor(winid, { line, 0 })
	end

	if direction > 0 then
		for _, marker in ipairs(markers) do
			if marker.line > cursor_line then
				return go(marker.line)
			end
		end
		return go(markers[1].line)
	end

	for i = #markers, 1, -1 do
		if markers[i].line < cursor_line then
			return go(markers[i].line)
		end
	end
	go(markers[#markers].line)
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

---Classify one raw diff line into its highlight group.
---@param line string
---@return string|nil
local function diff_line_group(line)
	if vim.startswith(line, "diff --git")
		or vim.startswith(line, "index ")
		or vim.startswith(line, "--- ")
		or vim.startswith(line, "+++ ")
		or vim.startswith(line, "new file mode")
		or vim.startswith(line, "deleted file mode")
		or vim.startswith(line, "rename from")
		or vim.startswith(line, "rename to")
		or vim.startswith(line, "similarity index")
		or vim.startswith(line, "old mode")
		or vim.startswith(line, "new mode") then
		return "GitflowDiffFileHeader"
	end
	if vim.startswith(line, "@@") then
		return "GitflowDiffHunkHeader"
	end
	if vim.startswith(line, "+") and not vim.startswith(line, "+++") then
		return "GitflowAdded"
	end
	if vim.startswith(line, "-") and not vim.startswith(line, "---") then
		return "GitflowRemoved"
	end
	if vim.startswith(line, " ") then
		return "GitflowDiffContext"
	end
	return nil
end

---Old/new line numbers as right-aligned virtual text. Its own namespace: the
---builder diffs the panel namespace against a snapshot, so nothing else may
---write there.
---@param bufnr integer
local function paint_line_numbers(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, DIFF_LINENR_NS, 0, -1)
	for line_no, ctx in pairs(M.state.line_context) do
		if ctx.old_line or ctx.new_line then
			local label = ("%4s %4s"):format(
				ctx.old_line and tostring(ctx.old_line) or " ",
				ctx.new_line and tostring(ctx.new_line) or " "
			)
			pcall(
				vim.api.nvim_buf_set_extmark,
				bufnr, DIFF_LINENR_NS, line_no - 1, 0,
				{
					virt_text = { { label, "GitflowDiffLineNr" } },
					virt_text_pos = "right_align",
				}
			)
		end
	end
end

---@param title string
---@param text string
---@param current_branch string
local function render(title, text, current_branch)
	local diff_lines = to_lines(text)
	local B = P:begin_render(title)

	local preview_files, preview_hunks = git_diff.collect_markers(diff_lines, 1)
	local extras = {
		{ key = ("%d hunk%s"):format(
			#preview_hunks, #preview_hunks == 1 and "" or "s") },
	}
	if current_branch and current_branch ~= "" then
		extras[#extras + 1] =
			{ key = icons.get("branch", "current"), value = current_branch }
	end
	components.summary(B, icons.get("git_state", "modified"),
		("%d file%s"):format(#preview_files, #preview_files == 1 and "" or "s"),
		extras)
	B:blank()

	local diff_start_idx = B:count() + 1
	for _, line in ipairs(diff_lines) do
		B:raw(line, diff_line_group(line))
	end

	-- Collect markers relative to buffer positions
	M.state.file_markers, M.state.hunk_markers, M.state.line_context =
		git_diff.collect_markers(diff_lines, diff_start_idx)

	P:push_hints(B)

	local bufnr = P:bufnr()
	if not P:paint(B) then
		return
	end
	paint_line_numbers(bufnr)
end

---@param cfg GitflowConfig
---@param request table
function M.open(cfg, request)
	M.state.cfg = cfg
	M.state.request = vim.deepcopy(request)
	if not P:ensure_window(cfg) then
		return
	end
	-- The base sets the filetype; the diff syntax and the treesitter opt-out
	-- (#251) are this panel's own.
	local bufnr = P:bufnr()
	vim.api.nvim_set_option_value("syntax", "diff", { buf = bufnr })
	pcall(vim.treesitter.stop, bufnr)

	local token = P:next_request()
	git_branch.current({}, function(_, branch)
		if not P:is_active(token) then
			return
		end
		git_diff.get(request, function(err, output)
			if not P:is_active(token) then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				P:render_error("Could not load the diff", { detail = err })
				return
			end
			render(request_to_title(request), output or "", branch or "(unknown)")
		end)
	end)
end

--- Re-run the request the panel is currently showing.
function M.refresh()
	if M.state.request and M.state.cfg then
		M.open(M.state.cfg, M.state.request)
	end
end

function M.close()
	P:close()
	M.state.request = nil
	M.state.cfg = nil
	M.state.file_markers = {}
	M.state.hunk_markers = {}
	M.state.line_context = {}
end

return M
