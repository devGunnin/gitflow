local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local gh_actions = require("gitflow.gh.actions")
local git_branch = require("gitflow.git.branch")
local ui_render = require("gitflow.ui.render")

---@class GitflowActionsPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowActionRun>
---@field cfg GitflowConfig|nil
---@field view "list"|"detail"
---@field detail_run GitflowActionRun|nil
---@field request_id integer
---@field post_operation_augroup integer|nil

local M = {}
local ACTIONS_FLOAT_TITLE = "Gitflow Actions"
local ACTIONS_LIST_FOOTER = "<CR> detail  o open in browser  r refresh  q close"
local ACTIONS_DETAIL_FOOTER = "<BS> back  o open in browser  r refresh  q close"
local ACTIONS_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_actions_hl")

---@type GitflowActionsPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
	view = "list",
	detail_run = nil,
	request_id = 0,
	post_operation_augroup = nil,
}

---@return string
local function current_footer()
	if M.state.view == "detail" then
		return ACTIONS_DETAIL_FOOTER
	end
	return ACTIONS_LIST_FOOTER
end

local function update_float_footer()
	local winid = M.state.winid
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end

	local ok, win_cfg = pcall(vim.api.nvim_win_get_config, winid)
	if not ok or not win_cfg or not win_cfg.relative or win_cfg.relative == "" then
		return
	end

	local cfg = M.state.cfg
	local footer_enabled = cfg
		and cfg.ui
		and cfg.ui.float
		and cfg.ui.float.footer
	if not footer_enabled or vim.fn.has("nvim-0.10") ~= 1 then
		return
	end

	pcall(vim.api.nvim_win_set_config, winid, {
		footer = current_footer(),
	})
end

---@return integer
local function next_request_id()
	M.state.request_id = (M.state.request_id or 0) + 1
	return M.state.request_id
end

---@param request_id integer
---@param expected_view "list"|"detail"|nil
---@return boolean
local function is_active_request(request_id, expected_view)
	if M.state.request_id ~= request_id then
		return false
	end
	if expected_view and M.state.view ~= expected_view then
		return false
	end
	return M.is_open()
end

local function clear_post_operation_autocmd()
	if M.state.post_operation_augroup then
		pcall(
			vim.api.nvim_del_augroup_by_id,
			M.state.post_operation_augroup
		)
		M.state.post_operation_augroup = nil
	end
end

local function setup_post_operation_autocmd()
	clear_post_operation_autocmd()

	local augroup = vim.api.nvim_create_augroup(
		"GitflowActionsPostOperation",
		{ clear = true }
	)
	M.state.post_operation_augroup = augroup
	vim.api.nvim_create_autocmd("User", {
		group = augroup,
		pattern = "GitflowPostOperation",
		callback = function()
			if not M.is_open() then
				return
			end
			M.refresh()
		end,
	})
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("actions", {
			filetype = "gitflowactions",
			lines = { "Loading workflow runs..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	if cfg.ui.default_layout == "float" then
		M.state.winid = ui.window.open_float({
			name = "actions",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = ACTIONS_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and current_footer() or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "actions",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.open_detail_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "o", function()
		M.open_in_browser()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "<BS>", function()
		M.back_to_list()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param started_at string
---@param completed_at string
---@return string
local function format_duration_range(started_at, completed_at)
	if started_at ~= "" and completed_at ~= "" then
		return ("  (%s → %s)"):format(
			started_at:sub(12, 19) or "",
			completed_at:sub(12, 19) or ""
		)
	end
	return ""
end

---@param run GitflowActionRun
---@return string
local function format_run_line(run)
	local icon = gh_actions.status_icon(run)
	local name = run.display_title
	if name == "" then
		name = run.name
	end
	return ("%s %s  %s  %s"):format(icon, name, run.branch, run.event)
end

---@param job GitflowActionJob
---@return string
local function format_job_line(job)
	local icon = "?"
	local conclusion = job.conclusion
	if conclusion == "success" then
		icon = "✓"
	elseif conclusion == "failure" then
		icon = "✗"
	elseif conclusion == "cancelled" or conclusion == "skipped" then
		icon = "⊘"
	elseif job.status == "in_progress" or job.status == "queued"
		or job.status == "waiting" then
		icon = "●"
	end

	local duration = format_duration_range(job.started_at, job.completed_at)
	return ("  %s %s%s"):format(icon, job.name, duration)
end

---@param step GitflowActionStep
---@return string
local function format_step_line(step)
	local icon = "?"
	local conclusion = step.conclusion
	if conclusion == "success" then
		icon = "✓"
	elseif conclusion == "failure" then
		icon = "✗"
	elseif conclusion == "cancelled" or conclusion == "skipped" then
		icon = "⊘"
	elseif step.status == "in_progress" or step.status == "queued"
		or step.status == "waiting" then
		icon = "●"
	end
	local duration = format_duration_range(
		step.started_at or "",
		step.completed_at or ""
	)
	return ("    %s %d. %s%s"):format(icon, step.number, step.name, duration)
end

---@param step GitflowActionStep
---@return string|nil
local function format_step_snippet_line(step)
	local snippet = vim.trim(step.log_snippet or "")
	if snippet == "" then
		return nil
	end
	return ("      log: %s"):format(snippet)
end

---@param runs GitflowActionRun[]
---@param current_branch string
local function render_list(runs, current_branch)
	update_float_footer()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header("Gitflow Actions", render_opts)
	local line_entries = {}

	if #runs == 0 then
		lines[#lines + 1] = ui_render.empty("no workflow runs found")
	else
		for _, run in ipairs(runs) do
			lines[#lines + 1] = ui_render.entry(format_run_line(run))
			line_entries[#lines] = run
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("actions", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(bufnr, ACTIONS_HIGHLIGHT_NS, lines, {
		footer_line = #lines,
	})

	for line_no, run in pairs(line_entries) do
		local hl_group = gh_actions.status_highlight(run)
		local line_text = lines[line_no] or ""
		local icon = gh_actions.status_icon(run)
		local icon_start = line_text:find(icon, 1, true)
		if icon_start then
			vim.api.nvim_buf_add_highlight(
				bufnr, ACTIONS_HIGHLIGHT_NS, hl_group,
				line_no - 1, icon_start - 1,
				icon_start - 1 + #icon
			)
		end
	end
end

---@param run GitflowActionRun
local function render_detail(run)
	update_float_footer()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local title = ("Gitflow Actions — %s"):format(run.display_title)
	local lines = ui_render.panel_header(title, render_opts)

	local icon = gh_actions.status_icon(run)
	lines[#lines + 1] = ui_render.entry(
		("%s %s"):format(icon, run.conclusion ~= "" and run.conclusion or run.status)
	)
	lines[#lines + 1] = ui_render.entry(("  Branch: %s"):format(run.branch))
	lines[#lines + 1] = ui_render.entry(("  Event:  %s"):format(run.event))
	lines[#lines + 1] = ui_render.entry(
		("  Started: %s"):format(run.created_at)
	)
	lines[#lines + 1] = ""

	local jobs = run.jobs or {}
	if #jobs == 0 then
		lines[#lines + 1] = ui_render.empty("no job details available")
	else
		for _, job in ipairs(jobs) do
			lines[#lines + 1] = format_job_line(job)
			local has_step_snippet = false
			for _, step in ipairs(job.steps or {}) do
				lines[#lines + 1] = format_step_line(step)
				local snippet_line = format_step_snippet_line(step)
				if snippet_line then
					has_step_snippet = true
					lines[#lines + 1] = snippet_line
				end
			end
			if not has_step_snippet then
				local job_snippet = vim.trim(job.log_snippet or "")
				if job_snippet ~= "" then
					lines[#lines + 1] = ("    log: %s"):format(job_snippet)
				end
			end
			lines[#lines + 1] = ""
		end
	end

	local footer_lines = ui_render.panel_footer(
		run.branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("actions", lines)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(bufnr, ACTIONS_HIGHLIGHT_NS, lines, {
		footer_line = #lines,
	})
end

---@return GitflowActionRun|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	M.state.view = "list"
	M.state.detail_run = nil
	next_request_id()
	ensure_window(cfg)
	update_float_footer()
	setup_post_operation_autocmd()
	M.refresh()
end

function M.refresh()
	local request_id = next_request_id()

	if M.state.view == "detail" and M.state.detail_run then
		local run_id = M.state.detail_run.id
		gh_actions.view(run_id, nil, function(err, run)
			if not is_active_request(request_id, "detail") then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			M.state.detail_run = run
			render_detail(run)
		end)
		return
	end

	git_branch.current({}, function(_, branch)
		if not is_active_request(request_id, "list") then
			return
		end
		gh_actions.list(
			{ branch = branch, limit = 20 },
			nil,
			function(err, runs)
				if not is_active_request(request_id, "list") then
					return
				end
				if err then
					utils.notify(err, vim.log.levels.ERROR)
					return
				end
				render_list(runs or {}, branch or "(unknown)")
			end
		)
	end)
end

function M.open_detail_under_cursor()
	if M.state.view == "detail" then
		M.open_in_browser()
		return
	end

	local run = entry_under_cursor()
	if not run then
		utils.notify("No workflow run selected", vim.log.levels.WARN)
		return
	end

	M.state.view = "detail"
	M.state.detail_run = run
	update_float_footer()
	local request_id = next_request_id()
	gh_actions.view(run.id, nil, function(err, detailed_run)
		if not is_active_request(request_id, "detail") then
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		M.state.detail_run = detailed_run
		render_detail(detailed_run)
	end)
end

function M.open_in_browser()
	local url = nil
	if M.state.view == "detail" and M.state.detail_run then
		url = M.state.detail_run.url
	else
		local run = entry_under_cursor()
		if run then
			url = run.url
		end
	end

	if not url or url == "" then
		utils.notify("No URL available for this run", vim.log.levels.WARN)
		return
	end

	vim.ui.open(url)
end

function M.back_to_list()
	if M.state.view ~= "detail" then
		return
	end
	M.state.view = "list"
	M.state.detail_run = nil
	update_float_footer()
	M.refresh()
end

function M.close()
	next_request_id()
	clear_post_operation_autocmd()

	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("actions")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("actions")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.view = "list"
	M.state.detail_run = nil
end

---@return boolean
function M.is_open()
	return M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
