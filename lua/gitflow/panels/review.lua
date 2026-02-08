local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local gh_prs = require("gitflow.gh.prs")

---@class GitflowPrReviewFileMarker
---@field line integer
---@field path string

---@class GitflowPrReviewHunkMarker
---@field line integer
---@field path string|nil
---@field header string

---@class GitflowPrReviewLineContext
---@field path string|nil
---@field hunk string|nil

---@class GitflowPrReviewDraftThread
---@field id integer
---@field path string|nil
---@field hunk string|nil
---@field line integer
---@field body string

---@class GitflowPrReviewPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field pr_number integer|nil
---@field file_markers GitflowPrReviewFileMarker[]
---@field hunk_markers GitflowPrReviewHunkMarker[]
---@field line_context table<integer, GitflowPrReviewLineContext>
---@field threads GitflowPrReviewDraftThread[]

local M = {}

---@type GitflowPrReviewPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	pr_number = nil,
	file_markers = {},
	hunk_markers = {},
	line_context = {},
	threads = {},
}

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("review", {
			filetype = "diff",
			lines = { "Loading review..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("filetype", "diff", { buf = bufnr })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = ui.window.open_split({
		name = "review",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})

	vim.keymap.set("n", "]f", function()
		M.next_file()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "[f", function()
		M.prev_file()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "]h", function()
		M.next_hunk()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "[h", function()
		M.prev_hunk()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "a", function()
		M.review_approve()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "x", function()
		M.review_request_changes()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "c", function()
		M.review_comment()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "i", function()
		M.inline_comment()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "R", function()
		M.reply_to_thread()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "b", function()
		M.back_to_pr()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param text string|nil
---@return string[]
local function split_lines(text)
	local value = tostring(text or "")
	if value == "" then
		return { "(no diff output)" }
	end
	return vim.split(value, "\n", { plain = true, trimempty = false })
end

---@param lines string[]
---@param start_line integer
---@return GitflowPrReviewFileMarker[], GitflowPrReviewHunkMarker[]
---@return table<integer, GitflowPrReviewLineContext>
local function collect_markers(lines, start_line)
	local files = {}
	local hunks = {}
	local line_context = {}
	local current_file = nil
	local current_hunk = nil

	for index, line in ipairs(lines) do
		local line_no = start_line + index - 1
		local old_path, new_path = line:match("^diff %-%-git a/(.+) b/(.+)$")
		if old_path and new_path then
			current_file = new_path
			current_hunk = nil
			files[#files + 1] = { line = line_no, path = new_path }
		elseif vim.startswith(line, "@@") then
			current_hunk = line
			hunks[#hunks + 1] = {
				line = line_no,
				path = current_file,
				header = line,
			}
		end

		line_context[line_no] = {
			path = current_file,
			hunk = current_hunk,
		}
	end

	return files, hunks, line_context
end

---@param number integer|string|nil
---@return string
local function format_number(number)
	return tostring(number or "?")
end

---@param title string
---@param diff_text string
---@param files GitflowPrReviewFileMarker[]
---@param hunks GitflowPrReviewHunkMarker[]
local function render_review(title, diff_text, files, hunks)
	local lines = {
		title,
		"",
		("Files: %d  Hunks: %d"):format(#files, #hunks),
		"Navigation: ]f/[f file  ]h/[h hunk",
		"Actions: a approve  x request changes  c review comment",
		"         i inline note  R reply  r refresh  b back  q quit",
		"",
	}

	local diff_lines = split_lines(diff_text)
	local diff_start_line = #lines + 1
	for _, line in ipairs(diff_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("review", lines)
	M.state.file_markers, M.state.hunk_markers, M.state.line_context =
		collect_markers(diff_lines, diff_start_line)
end

---@param message string
local function render_loading(message)
	ui.buffer.update("review", {
		"Gitflow PR Review",
		"",
		message,
	})
	M.state.file_markers = {}
	M.state.hunk_markers = {}
	M.state.line_context = {}
end

---@param markers table[]
---@param direction 1|-1
local function jump_to_marker(markers, direction)
	if not M.state.winid or not vim.api.nvim_win_is_valid(M.state.winid) then
		return
	end
	if #markers == 0 then
		utils.notify("No diff markers available", vim.log.levels.WARN)
		return
	end

	local cursor_line = vim.api.nvim_win_get_cursor(M.state.winid)[1]
	if direction > 0 then
		for _, marker in ipairs(markers) do
			if marker.line > cursor_line then
				vim.api.nvim_win_set_cursor(M.state.winid, { marker.line, 0 })
				return
			end
		end
		vim.api.nvim_win_set_cursor(M.state.winid, { markers[1].line, 0 })
		return
	end

	for i = #markers, 1, -1 do
		local marker = markers[i]
		if marker.line < cursor_line then
			vim.api.nvim_win_set_cursor(M.state.winid, { marker.line, 0 })
			return
		end
	end
	vim.api.nvim_win_set_cursor(M.state.winid, { markers[#markers].line, 0 })
end

---@return integer|nil
local function current_pr_number()
	return M.state.pr_number
end

---@param mode "approve"|"request_changes"|"comment"
---@param body string
---@param on_success_message string
local function submit_review(mode, body, on_success_message)
	local number = current_pr_number()
	if not number then
		utils.notify("No pull request selected for review", vim.log.levels.WARN)
		return
	end

	gh_prs.review(number, mode, body, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(on_success_message, vim.log.levels.INFO)
		M.refresh()
	end)
end

---@param mode "approve"|"request_changes"|"comment"
---@param prompt string
---@param on_success_message string
local function prompt_and_submit(mode, prompt, on_success_message)
	input.prompt({ prompt = prompt }, function(body)
		submit_review(mode, body or "", on_success_message)
	end)
end

---@param include_context boolean
---@return string
local function contextual_comment_prefix(include_context)
	if not include_context then
		return ""
	end
	if not M.state.winid or not vim.api.nvim_win_is_valid(M.state.winid) then
		return ""
	end

	local line = vim.api.nvim_win_get_cursor(M.state.winid)[1]
	local context = M.state.line_context[line]
	if not context then
		return ""
	end

	local details = {}
	if context.path and context.path ~= "" then
		details[#details + 1] = ("file=%s"):format(context.path)
	end
	if context.hunk and context.hunk ~= "" then
		details[#details + 1] = ("hunk=%s"):format(context.hunk)
	end
	if #details == 0 then
		return ""
	end
	return ("[%s] "):format(table.concat(details, " "))
end

function M.review_approve()
	prompt_and_submit("approve", "Approval message (optional): ", "Review submitted (approved)")
end

function M.review_request_changes()
	prompt_and_submit(
		"request_changes",
		"Request changes message: ",
		"Review submitted (changes requested)"
	)
end

function M.review_comment()
	prompt_and_submit("comment", "Review comment (optional): ", "Review submitted (comment)")
end

function M.inline_comment()
	input.prompt({ prompt = "Inline comment: " }, function(comment)
		local body = vim.trim(comment or "")
		if body == "" then
			utils.notify("Comment cannot be empty", vim.log.levels.WARN)
			return
		end

		local prefix = contextual_comment_prefix(true)
		local number = #M.state.threads + 1
		local cursor_line = M.state.winid and vim.api.nvim_win_get_cursor(M.state.winid)[1] or 1
		local context = M.state.line_context[cursor_line] or {}
		M.state.threads[#M.state.threads + 1] = {
			id = number,
			path = context.path,
			hunk = context.hunk,
			line = cursor_line,
			body = body,
		}
		submit_review("comment", prefix .. body, ("Inline note submitted (#%d)"):format(number))
	end)
end

function M.reply_to_thread()
	local thread = M.state.threads[#M.state.threads]
	if not thread then
		utils.notify("No local inline thread found to reply to", vim.log.levels.WARN)
		return
	end

	input.prompt({ prompt = ("Reply to note #%d: "):format(thread.id) }, function(reply)
		local body = vim.trim(reply or "")
		if body == "" then
			utils.notify("Reply cannot be empty", vim.log.levels.WARN)
			return
		end

		local prefix = contextual_comment_prefix(false)
		local formatted = ("Reply to inline note #%d: %s%s"):format(thread.id, prefix, body)
		submit_review("comment", formatted, ("Reply submitted for note #%d"):format(thread.id))
	end)
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

function M.refresh()
	if not M.state.cfg or not M.state.pr_number then
		return
	end

	local number = M.state.pr_number
	render_loading(("Loading review for PR #%s..."):format(format_number(number)))
	gh_prs.view(number, {}, function(view_err, pr)
		if view_err then
			render_loading("Failed to load pull request metadata")
			utils.notify(view_err, vim.log.levels.ERROR)
			return
		end

		gh_prs.diff(number, {}, function(diff_err, diff_text)
			if diff_err then
				render_loading("Failed to load pull request diff")
				utils.notify(diff_err, vim.log.levels.ERROR)
				return
			end

			local pr_title = vim.trim(tostring(pr and pr.title or ""))
			if pr_title == "" then
				pr_title = "(untitled)"
			end
			local title = ("PR #%s Review: %s"):format(format_number(pr and pr.number or number), pr_title)

			local preview_lines = split_lines(diff_text)
			local files, hunks = collect_markers(preview_lines, 1)
			render_review(title, diff_text or "", files, hunks)
		end)
	end)
end

---@param cfg GitflowConfig
---@param pr_number integer|string
function M.open(cfg, pr_number)
	M.state.cfg = cfg
	M.state.pr_number = tonumber(pr_number)
	ensure_window(cfg)
	M.refresh()
end

function M.back_to_pr()
	local number = current_pr_number()
	if not number then
		return
	end

	local pr_panel = require("gitflow.panels.prs")
	if M.state.cfg then
		pr_panel.open_view(number, M.state.cfg)
	else
		pr_panel.open_view(number)
	end
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("review")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("review")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.cfg = nil
	M.state.pr_number = nil
	M.state.file_markers = {}
	M.state.hunk_markers = {}
	M.state.line_context = {}
	M.state.threads = {}
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
