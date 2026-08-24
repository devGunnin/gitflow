local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local gh_actions = require("gitflow.gh.actions")
local git_branch = require("gitflow.git.branch")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")
local icons = require("gitflow.icons")

---@class GitflowActionsFilters
---@field workflow string|nil
---@field status string|nil
---@field event string|nil
---@field actor string|nil
---@field all_branches boolean

---@class GitflowActionsWatchState
---@field active boolean
---@field generation integer  the watch's own token; never the panel's request_id
---@field timer any|nil  luv_timer_t from vim.defer_fn, stopped/closed on cancel
---@field run_id integer|nil
---@field errors integer  consecutive failed polls

---@class GitflowActionsLogState
---@field run_id integer
---@field job GitflowActionJob|nil  nil means the full run log
---@field parent_view "list"|"detail"
---@field title string
---@field lines string[]|nil  nil while loading; the rendered tail when capped
---@field omitted integer  lines dropped off the head by the render cap
---@field error string|nil
---@field content_start integer|nil  1-based buffer line where log content begins

---@class GitflowActionsBusyState
---@field id integer|string
---@field message string

---@class GitflowActionsPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowActionRun|GitflowActionWorkflow>
---@field detail_line_entries table<integer, GitflowActionJob>
---@field cfg GitflowConfig|nil
---@field view "list"|"detail"|"log"|"workflows"
---@field detail_run GitflowActionRun|nil
---@field workflows GitflowActionWorkflow[]|nil
---@field filters GitflowActionsFilters
---@field limit integer
---@field busy GitflowActionsBusyState|nil
---@field watch GitflowActionsWatchState
---@field log GitflowActionsLogState|nil
---@field request_id integer
---@field post_operation_augroup integer|nil

local M = {}
local ACTIONS_FLOAT_TITLE = "  Gitflow Actions  "
local ACTIONS_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_actions_hl")

local DEFAULT_LIMIT = 20
local PAGE_STEP = 20

local SPACING = ui_render.spacing
local SEPARATORS = ui_render.separators
-- Content rows carry a status icon in the gutter, so their metadata lines up
-- one indent step plus that icon's column. No token is five columns wide.
local ROW_META_INDENT = SPACING.indent .. SPACING.edge

-- Rendered-line cap for one log. Formatting + painting is linear and
-- blocking (~0.3s for a 100k-line, 8.8MB log), so this is passed to
-- gh_actions.log/job_log as max_lines to bound the raw input *before*
-- formatting runs, not just the paint. The slice below stays as a backstop
-- for any lines a caller hands us uncapped — CI failures land at the end,
-- so keep the tail, and say in the buffer what was dropped.
local MAX_LOG_LINES = 20000

-- Consecutive failed polls that stop a watch. Without a bound a persistent
-- failure (expired token, offline, deleted run) errors once per interval
-- forever.
local WATCH_MAX_ERRORS = 3

-- Buffer-local hint pairs, one set per view. Keep the *_FOOTER strings below
-- in sync by hand — same convention as tag.lua's float footer.
local LIST_HINTS = {
	{ "<CR>", "detail" }, { "l", "log" }, { "f", "filter" }, { "b", "branch" },
	{ "L", "more" }, { "W", "workflows" }, { "R", "rerun" }, { "F", "failed" },
	{ "C", "cancel" }, { "o", "open" }, { "r", "refresh" }, { "q", "close" },
}
local DETAIL_HINTS = {
	{ "<BS>", "back" }, { "l", "log" }, { "R", "rerun" }, { "F", "failed" },
	{ "J", "job" }, { "C", "cancel" }, { "w", "watch" }, { "o", "open" },
	{ "r", "refresh" }, { "q", "close" },
}
local LOG_HINTS = {
	{ "<BS>", "back" }, { "]e", "jump error" }, { "r", "refresh" }, { "q", "close" },
}
local WORKFLOWS_HINTS = {
	{ "<CR>", "dispatch" }, { "<BS>", "back" }, { "r", "refresh" }, { "q", "close" },
}

local ACTIONS_LIST_FOOTER =
	" <CR> detail · l log · f filter · b branch · L more · W workflows"
	.. " · R rerun · F failed · C cancel · o open · r refresh · q close "
local ACTIONS_DETAIL_FOOTER =
	" <BS> back · l log · R rerun · F failed · J job · C cancel"
	.. " · w watch · o open · r refresh · q close "
local ACTIONS_LOG_FOOTER = " <BS> back · ]e jump error · r refresh · q close "
local ACTIONS_WORKFLOWS_FOOTER =
	" <CR> dispatch · <BS> back · r refresh · q close "

---@return GitflowActionsFilters
local function default_filters()
	return {
		workflow = nil,
		status = nil,
		event = nil,
		actor = nil,
		all_branches = false,
	}
end

---@type GitflowActionsPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	detail_line_entries = {},
	cfg = nil,
	view = "list",
	detail_run = nil,
	workflows = nil,
	filters = default_filters(),
	limit = DEFAULT_LIMIT,
	busy = nil,
	watch = {
		active = false, generation = 0, timer = nil, run_id = nil, errors = 0,
	},
	log = nil,
	request_id = 0,
	post_operation_augroup = nil,
}

-- Last successfully rendered run list, kept across close/reopen (unlike
-- M.state, which resets) so a reopen paints instantly before reconciling.
-- Keyed by cwd + filter signature: unkeyed, it painted another repository's
-- (or another filter's) runs until the live fetch landed.
local list_cache = { key = nil, runs = nil, branch = nil }

---Scope signature for the cached list: same cwd, same query, same page size.
---@return string
local function list_cache_key()
	local filters = M.state.filters
	return table.concat({
		vim.fn.getcwd(),
		filters.workflow or "",
		filters.status or "",
		filters.event or "",
		filters.actor or "",
		filters.all_branches and "all" or "branch",
		tostring(M.state.limit),
	}, "\0")
end

---@return string
local function current_footer()
	if M.state.view == "detail" then
		return ACTIONS_DETAIL_FOOTER
	elseif M.state.view == "log" then
		return ACTIONS_LOG_FOOTER
	elseif M.state.view == "workflows" then
		return ACTIONS_WORKFLOWS_FOOTER
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
---@param expected_view "list"|"detail"|"log"|"workflows"|nil
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

---Stop the watch timer (if any) and invalidate any tick still in flight.
---Safe to call when not watching.
local function stop_watch()
	local watch = M.state.watch
	watch.active = false
	watch.generation = (watch.generation or 0) + 1
	if watch.timer then
		pcall(function()
			watch.timer:stop()
			watch.timer:close()
		end)
		watch.timer = nil
	end
	watch.run_id = nil
	watch.errors = 0
end

local ALL_VIEWS = { list = true, detail = true, log = true, workflows = true }
local LIST_DETAIL = { list = true, detail = true }

local function noop() end

-- Buffer-local maps, declared per view. A *motion* key a view does not use
-- is left UNMAPPED there, so vim's own motion keeps working — the log view
-- is a plain text buffer where l/w/b/L must move the cursor, and a panel
-- action there would only warn that it does not apply. R/C/J/o are not
-- motions: unmapped, they reach vim's Replace/Change/Join/open-line and
-- raise E21 against the nomodifiable buffer, so every view maps them to a
-- no-op instead.
local KEYMAPS = {
	{ key = "<CR>", views = LIST_DETAIL, run = function() M.open_detail_under_cursor() end },
	{ key = "<CR>", views = { workflows = true }, run = function() M.dispatch_under_cursor() end },
	{ key = "<BS>", views = { detail = true, log = true, workflows = true }, run = function() M.back() end },
	{ key = "o", views = LIST_DETAIL, run = function() M.open_in_browser() end },
	{ key = "o", views = { log = true, workflows = true }, run = noop },
	{ key = "r", views = ALL_VIEWS, run = function() M.refresh() end },
	{ key = "q", views = ALL_VIEWS, run = function() M.close() end },
	{ key = "l", views = LIST_DETAIL, run = function() M.view_log_under_cursor() end },
	{ key = "f", views = { list = true }, run = function() M.open_filter_menu() end },
	{ key = "b", views = { list = true }, run = function() M.toggle_branch_scope() end },
	{ key = "L", views = { list = true }, run = function() M.load_more() end },
	{ key = "W", views = { list = true }, run = function() M.open_workflows() end },
	{ key = "R", views = LIST_DETAIL, run = function() M.rerun_under_cursor() end },
	{ key = "R", views = { log = true, workflows = true }, run = noop },
	{ key = "F", views = LIST_DETAIL, run = function() M.rerun_failed_under_cursor() end },
	{ key = "J", views = { detail = true }, run = function() M.rerun_job_under_cursor() end },
	{ key = "J", views = { list = true, log = true, workflows = true }, run = noop },
	{ key = "C", views = LIST_DETAIL, run = function() M.cancel_under_cursor() end },
	{ key = "C", views = { log = true, workflows = true }, run = noop },
	{ key = "w", views = { detail = true }, run = function() M.toggle_watch() end },
	-- Not `E`: the log view must not shadow a motion.
	{ key = "]e", views = { log = true }, run = function() M.jump_to_first_error() end },
}

---Re-map the panel buffer for the current view: drop every panel key, then
---set back only the ones this view uses.
local function apply_view_keymaps()
	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	for _, entry in ipairs(KEYMAPS) do
		pcall(vim.keymap.del, "n", entry.key, { buffer = bufnr })
	end
	for _, entry in ipairs(KEYMAPS) do
		if entry.views[M.state.view] then
			vim.keymap.set("n", entry.key, entry.run, {
				buffer = bufnr, silent = true, nowait = true,
			})
		end
	end
end

---The single point a view changes: state, keymaps and float footer move
---together, so no view can be shown with another view's bindings.
---@param view "list"|"detail"|"log"|"workflows"
local function set_view(view)
	M.state.view = view
	apply_view_keymaps()
	update_float_footer()
end

---Every close route (`q`, `:q`, `<C-w>c`, a layout change) lands here —
---the poller must die with the window, not outlive it invisibly.
local function on_window_closed()
	M.state.winid = nil
	stop_watch()
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("actions", {
			filetype = "gitflowactions",
			lines = components.loading_lines("Loading workflow runs…"),
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		apply_view_keymaps()
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
			on_close = on_window_closed,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "actions",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = on_window_closed,
		})
	end

	apply_view_keymaps()
end

---@param started_at string
---@param completed_at string
---@return string
local function format_duration_range(started_at, completed_at)
	if started_at ~= "" and completed_at ~= "" then
		return ("  (%s %s %s)"):format(
			started_at:sub(12, 19) or "",
			ui_render.glyphs.arrow,
			completed_at:sub(12, 19) or ""
		)
	end
	return ""
end

---@param run GitflowActionRun
---@return string
local function run_title(run)
	local name = run.display_title
	if name == nil or name == "" then
		name = run.name
	end
	return name or ""
end

---Push a duration range chunk (dim) when both endpoints are present.
---@param chunks table[]
---@param started_at string|nil
---@param completed_at string|nil
local function append_duration_chunk(chunks, started_at, completed_at)
	local range = format_duration_range(started_at or "", completed_at or "")
	if range ~= "" then
		chunks[#chunks + 1] = { range, "GitflowMeta" }
	end
end

---Push a dim "verb…" banner (from ui.components.loading) when a mutation is
---in flight, so rerun/cancel/dispatch have a visible in-progress affordance
---beyond the transient notification.
---@param B GitflowRenderBuilder
local function push_busy_banner(B)
	local busy = M.state.busy
	if not busy then
		return
	end
	components.loading(B, busy.message .. "…")
	B:blank()
end

---@param runs GitflowActionRun[]
---@param current_branch string
local function render_list(runs, current_branch)
	update_float_footer()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	components.header(B, "Gitflow Actions", render_opts)
	push_busy_banner(B)

	local filters = M.state.filters
	-- Summary bar: run count + branch scope.
	B:push({
		{ SPACING.gutter, nil },
		{ icons.get("palette", "actions") .. "  ", "GitflowSectionIcon" },
		{ ("%d run%s"):format(#runs, #runs == 1 and "" or "s"), "GitflowSectionTitle" },
		{ SEPARATORS.field .. icons.get("branch", "current") .. " ", "GitflowMetaKey" },
		{
			filters.all_branches and "all branches"
				or (current_branch ~= "" and current_branch or "(unknown)"),
			"GitflowMeta",
		},
	})

	local chips = {}
	if filters.workflow then
		chips[#chips + 1] = "workflow:" .. filters.workflow
	end
	if filters.status then
		chips[#chips + 1] = "status:" .. filters.status
	end
	if filters.event then
		chips[#chips + 1] = "event:" .. filters.event
	end
	if filters.actor then
		chips[#chips + 1] = "actor:" .. filters.actor
	end
	if #chips > 0 then
		B:push({
			{ ROW_META_INDENT, nil },
			{ icons.get("ui", "search") .. " ", "GitflowMetaKey" },
			{ table.concat(chips, SEPARATORS.hint), "GitflowChip" },
		})
	end
	B:blank()

	local line_entries = {}
	if #runs == 0 then
		components.empty(B, "no workflow runs found")
	else
		local width = ui_render.content_width(render_opts)
		for _, run in ipairs(runs) do
			local icon = gh_actions.status_icon(run)
			local status_hl = gh_actions.status_highlight(run)
			local name = run_title(run)
			local time = ui_render.relative_time(run.created_at)
			local left = " " .. icon .. "  "
			local left_w = vim.fn.strdisplaywidth(left)
			local time_w = vim.fn.strdisplaywidth(time)
			local name_max = math.max(8, width - left_w - time_w - 2)
			name = ui_render.truncate(name, name_max)
			local gap = math.max(
				2, width - left_w - vim.fn.strdisplaywidth(name) - time_w
			)
			local title_line = B:push({
				{ SPACING.edge, nil },
				{ icon .. "  ", status_hl },
				{ name, "GitflowCardTitle" },
				{ string.rep(" ", gap), nil },
				{ time, "GitflowRelTime" },
			})
			line_entries[title_line] = run

			local meta_line = B:push({
				{ ROW_META_INDENT, nil },
				{ icons.get("branch", "current") .. " ", "GitflowMeta" },
				{ run.branch ~= "" and run.branch or "\u{2014}", "GitflowChip" },
				{ SEPARATORS.field .. icons.get("ui", "dot") .. " ", "GitflowMeta" },
				{ run.event ~= "" and run.event or "\u{2014}", "GitflowMeta" },
			})
			line_entries[meta_line] = run
			B:blank()
		end
	end

	if #runs >= M.state.limit then
		B:push({
			{ ROW_META_INDENT, nil },
			{ ("showing %d · L load more"):format(M.state.limit), "GitflowMeta" },
		})
		B:blank()
	end

	components.split_hint_bar(B, render_opts, LIST_HINTS)
	B:flush("actions", M.state.bufnr, ACTIONS_HIGHLIGHT_NS)
	M.state.line_entries = line_entries
	list_cache.key = list_cache_key()
	list_cache.runs = runs
	list_cache.branch = current_branch

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	components.cursorline(M.state.winid, true)
end

---@param run GitflowActionRun
local function render_detail(run)
	update_float_footer()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local title = run_title(run)
	local B = ui_render.builder()
	components.header(B, ("Gitflow Actions — %s"):format(title), render_opts)
	B:blank()
	push_busy_banner(B)

	-- Summary bar: title + colored status (+ watch indicator when live).
	local icon = gh_actions.status_icon(run)
	local status_hl = gh_actions.status_highlight(run)
	local status_text = run.conclusion ~= "" and run.conclusion or run.status
	if status_text == "" then
		status_text = "unknown"
	end
	local status_chunks = {
		{ SPACING.gutter, nil },
		{ icons.get("palette", "actions") .. "  ", "GitflowSectionIcon" },
		{ title ~= "" and title or "(run)", "GitflowSectionTitle" },
		{ SEPARATORS.field, nil },
		{ icon .. " ", status_hl },
		{ status_text, status_hl },
	}
	local watch = M.state.watch
	if watch.active and watch.run_id == run.id then
		status_chunks[#status_chunks + 1] = { SEPARATORS.field, nil }
		status_chunks[#status_chunks + 1] =
			{ "\u{25cf} watching", "GitflowActionsPending" }
	end
	B:push(status_chunks)
	B:blank()

	components.meta_row(B, "Branch:", {
		{ components.maybe_text(run.branch), "GitflowChip" },
	})
	components.meta_row(B, "Event:", {
		{ components.maybe_text(run.event), "GitflowMeta" },
	})
	components.meta_row(B, "Started:", {
		{ components.maybe_text(run.created_at), "GitflowRelTime" },
	})
	B:blank()

	local jobs = run.jobs or {}
	components.section(
		B,
		icons.get("palette", "actions"),
		("Jobs (%d)"):format(#jobs)
	)
	local job_line_entries = {}
	if #jobs == 0 then
		components.empty(B, "no job details available")
	else
		for _, job in ipairs(jobs) do
			local job_start_line = B:count() + 1
			local job_chunks = {
				{ SPACING.edge, nil },
				{ gh_actions.status_icon(job) .. "  ", gh_actions.status_highlight(job) },
				{ job.name, "GitflowCardTitle" },
			}
			append_duration_chunk(job_chunks, job.started_at, job.completed_at)
			B:push(job_chunks)

			local has_step_snippet = false
			for _, step in ipairs(job.steps or {}) do
				local step_chunks = {
					{ SPACING.indent, nil },
					{ gh_actions.status_icon(step) .. " ", gh_actions.status_highlight(step) },
					{ ("%d. "):format(step.number), "GitflowNumber" },
					{ step.name, "GitflowMeta" },
				}
				append_duration_chunk(step_chunks, step.started_at, step.completed_at)
				B:push(step_chunks)

				local snippet = vim.trim(step.log_snippet or "")
				if snippet ~= "" then
					has_step_snippet = true
					B:push({
						{ SPACING.indent .. SPACING.gutter, nil },
						{ "log: ", "GitflowMetaKey" },
						{ snippet, "GitflowMeta" },
					})
				end
			end

			if not has_step_snippet then
				local job_snippet = vim.trim(job.log_snippet or "")
				if job_snippet ~= "" then
					B:push({
						{ SPACING.indent, nil },
						{ "log: ", "GitflowMetaKey" },
						{ job_snippet, "GitflowMeta" },
					})
				end
			end

			local job_end_line = B:count()
			for line_no = job_start_line, job_end_line do
				job_line_entries[line_no] = job
			end
			B:blank()
		end
	end

	components.split_hint_bar(B, render_opts, DETAIL_HINTS)
	B:flush("actions", M.state.bufnr, ACTIONS_HIGHLIGHT_NS)
	M.state.line_entries = {}
	M.state.detail_line_entries = job_line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	components.cursorline(M.state.winid, true)
end

local function render_log()
	update_float_footer()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local log = M.state.log or {}
	local B = ui_render.builder()
	components.header(
		B, ("Gitflow Actions — %s"):format(log.title or "log"), render_opts
	)
	B:blank()
	push_busy_banner(B)

	if log.error then
		components.error_state(B, "Failed to load log", { detail = log.error })
	elseif log.lines == nil then
		components.loading(B, "Loading log…")
	elseif #log.lines == 0 then
		components.empty(B, "no log output")
	else
		if (log.omitted or 0) > 0 then
			B:push({
				{ SPACING.gutter, nil },
				{
					("showing the last %d lines · %d earlier lines omitted")
						:format(#log.lines, log.omitted),
					"GitflowMeta",
				},
			})
			B:blank()
		end
		local content_start = B:count() + 1
		for _, line in ipairs(log.lines) do
			local line_no = B:raw(line)
			if line:find("##%[error%]", 1, false) then
				B:hl(line_no, 0, -1, "GitflowActionsFail")
			end
		end
		M.state.log.content_start = content_start
	end

	components.split_hint_bar(B, render_opts, LOG_HINTS)
	B:flush("actions", M.state.bufnr, ACTIONS_HIGHLIGHT_NS)
	M.state.line_entries = {}

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	components.cursorline(M.state.winid, true)
end

---@param workflows GitflowActionWorkflow[]
local function render_workflows(workflows)
	update_float_footer()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	components.header(B, "Gitflow Actions — Workflows", render_opts)
	B:blank()
	push_busy_banner(B)

	local line_entries = {}
	if #workflows == 0 then
		components.empty(B, "no workflows found")
	else
		for _, workflow in ipairs(workflows) do
			local state_hl = workflow.state == "active"
				and "GitflowActionsPass" or "GitflowMeta"
			local line_no = B:push({
				{ SPACING.gutter, nil },
				{ icons.get("ui", "dot") .. " ", state_hl },
				{ workflow.name, "GitflowCardTitle" },
				{ SEPARATORS.hint .. workflow.path, "GitflowMeta" },
			})
			line_entries[line_no] = workflow
		end
	end

	components.split_hint_bar(B, render_opts, WORKFLOWS_HINTS)
	B:flush("actions", M.state.bufnr, ACTIONS_HIGHLIGHT_NS)
	M.state.line_entries = line_entries
	M.state.workflows = workflows

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	components.cursorline(M.state.winid, true)
end

---Paint a full-panel error state, replacing whatever was on screen — a
---failed fetch must never leave the seeded "Loading…" behind a transient
---notification.
---@param header string
---@param message string
---@param detail string|nil
---@param hints table[]
local function render_error(header, message, detail, hints)
	update_float_footer()
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	components.header(B, header, render_opts)
	B:blank()
	components.error_state(B, message, { detail = detail })
	components.split_hint_bar(B, render_opts, hints)
	B:flush("actions", M.state.bufnr, ACTIONS_HIGHLIGHT_NS)
	M.state.line_entries = {}
	M.state.detail_line_entries = {}
end

---Re-render whatever view is currently showing from state already in hand
---(no fetch) — used to paint the busy banner the instant a mutation starts.
local function render_current_view()
	if not M.is_open() then
		return
	end
	if M.state.view == "detail" and M.state.detail_run then
		render_detail(M.state.detail_run)
	elseif M.state.view == "log" then
		render_log()
	elseif M.state.view == "workflows" then
		render_workflows(M.state.workflows or {})
	elseif list_cache.key == list_cache_key() then
		-- Only when the cache was filled under this scope; painting another
		-- filter's (or repo's) runs is worse than leaving the view as-is.
		render_list(list_cache.runs or {}, list_cache.branch or "(unknown)")
	end
end

---@return GitflowActionRun|GitflowActionWorkflow|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@return GitflowActionJob|nil
local function job_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.detail_line_entries[line]
end

---The run a run-level mutation (rerun/rerun-failed/cancel) should target:
---the cursor's entry in list view, or the open run in detail view.
---@return integer|nil
local function target_run_id()
	if M.state.view == "detail" and M.state.detail_run then
		return M.state.detail_run.id
	end
	if M.state.view == "list" then
		local run = entry_under_cursor()
		return run and run.id or nil
	end
	return nil
end

---@param run_id integer
---@param job GitflowActionJob|nil
---@param title string
---@param parent_view "list"|"detail"
local function open_log(run_id, job, title, parent_view)
	M.state.log = {
		run_id = run_id,
		job = job,
		parent_view = parent_view,
		title = title,
		lines = nil,
		omitted = 0,
		error = nil,
	}
	set_view("log")
	render_log()

	local request_id = next_request_id()
	local function deliver(err, lines)
		if not is_active_request(request_id, "log") then
			return
		end
		M.state.log.error = err
		if lines and #lines > MAX_LOG_LINES then
			M.state.log.omitted = #lines - MAX_LOG_LINES
			M.state.log.lines = vim.list_slice(
				lines, #lines - MAX_LOG_LINES + 1, #lines
			)
		else
			M.state.log.omitted = 0
			M.state.log.lines = lines
		end
		render_log()
	end

	local log_opts = { max_lines = MAX_LOG_LINES }
	if job then
		gh_actions.job_log(run_id, job.id, log_opts, deliver)
	else
		gh_actions.log(run_id, log_opts, deliver)
	end
end

local function refresh_log()
	local log = M.state.log
	if not log then
		return
	end
	open_log(log.run_id, log.job, log.title, log.parent_view)
end

local function fetch_workflows()
	local request_id = next_request_id()
	gh_actions.workflow_list(nil, function(err, workflows)
		if not is_active_request(request_id, "workflows") then
			return
		end
		if err then
			render_error(
				"Gitflow Actions — Workflows",
				"Failed to load workflows", err, WORKFLOWS_HINTS
			)
			return
		end
		render_workflows(workflows or {})
	end)
end

---Run a confirm-gated, single-flight mutation (rerun/cancel/dispatch): shows
---a confirm prompt, blocks a second attempt while one is already in flight,
---renders a busy banner, and notifies + refreshes on completion.
---@param opts { id: integer|string, confirm_message: string, in_progress_message: string, done_message: string, call: fun(cb: fun(err: string|nil)) }
local function perform_mutation(opts)
	if M.state.busy then
		utils.notify(
			("Already busy: %s — wait for it to finish"):format(M.state.busy.message),
			vim.log.levels.WARN
		)
		return
	end

	local confirmed = input.confirm(opts.confirm_message, {
		choices = { "&Yes", "&No" },
		default_choice = 2,
	})
	if not confirmed then
		return
	end

	M.state.busy = { id = opts.id, message = opts.in_progress_message }
	utils.notify(opts.in_progress_message .. "…", vim.log.levels.INFO)
	render_current_view()

	opts.call(function(err)
		M.state.busy = nil
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			if M.is_open() then
				render_current_view()
			end
			return
		end
		utils.notify(opts.done_message, vim.log.levels.INFO)
		if M.is_open() then
			M.refresh()
		end
	end)
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	M.state.view = "list"
	M.state.detail_run = nil
	M.state.workflows = nil
	M.state.filters = default_filters()
	M.state.limit = DEFAULT_LIMIT
	M.state.busy = nil
	M.state.log = nil
	M.state.detail_line_entries = {}
	stop_watch()
	next_request_id()
	ensure_window(cfg)

	-- Cached instant paint: show the last-known list immediately, then
	-- M.refresh() below reconciles it against a live fetch underneath.
	-- Only when the cache was filled under this same scope.
	if list_cache.runs and list_cache.key == list_cache_key() then
		render_list(list_cache.runs, list_cache.branch or "")
	end

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
				render_error(
					"Gitflow Actions",
					"Failed to load run detail", err, DETAIL_HINTS
				)
				return
			end
			M.state.detail_run = run
			render_detail(run)
		end)
		return
	end

	if M.state.view == "workflows" then
		fetch_workflows()
		return
	end

	if M.state.view == "log" then
		refresh_log()
		return
	end

	git_branch.current({}, function(_, branch)
		if not is_active_request(request_id, "list") then
			return
		end
		local filters = M.state.filters
		-- Not `filters.all_branches and nil or branch`: that Lua ternary
		-- trap always falls through to `branch` because `nil` is falsy.
		local list_branch = branch
		if filters.all_branches then
			list_branch = nil
		end
		gh_actions.list(
			{
				branch = list_branch,
				limit = M.state.limit,
				workflow = filters.workflow,
				status = filters.status,
				event = filters.event,
				actor = filters.actor,
			},
			nil,
			function(err, runs)
				if not is_active_request(request_id, "list") then
					return
				end
				if err then
					utils.notify(err, vim.log.levels.ERROR)
					render_error(
						"Gitflow Actions",
						"Failed to load workflow runs", err, LIST_HINTS
					)
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
	if M.state.view ~= "list" then
		return
	end

	local run = entry_under_cursor()
	if not run then
		utils.notify("No workflow run selected", vim.log.levels.WARN)
		return
	end

	M.state.detail_run = run
	set_view("detail")
	local request_id = next_request_id()
	gh_actions.view(run.id, nil, function(err, detailed_run)
		if not is_active_request(request_id, "detail") then
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			render_error(
				"Gitflow Actions",
				"Failed to load run detail", err, DETAIL_HINTS
			)
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
	elseif M.state.view == "list" then
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
	stop_watch()
	M.state.detail_run = nil
	M.state.detail_line_entries = {}
	set_view("list")
	M.refresh()
end

---General "go back one level": log -> its parent view, workflows -> list,
---detail -> list. A no-op in list view (nothing above it).
function M.back()
	if M.state.view == "log" then
		local parent = (M.state.log and M.state.log.parent_view) or "list"
		M.state.log = nil
		if parent == "detail" and M.state.detail_run then
			set_view("detail")
			render_detail(M.state.detail_run)
		else
			set_view("list")
			M.refresh()
		end
		return
	end

	if M.state.view == "workflows" then
		M.state.workflows = nil
		set_view("list")
		M.refresh()
		return
	end

	if M.state.view == "detail" then
		M.back_to_list()
	end
end

-- ── Filters and pagination (list view) ──────────────────────────────────

local FILTER_FIELDS = {
	{ key = "workflow", label = "Workflow (name or filename): " },
	{ key = "status", label = "Status (e.g. success, failure, in_progress): " },
	{ key = "event", label = "Event (e.g. push, pull_request): " },
	{ key = "actor", label = "Actor (GitHub username): " },
}

function M.open_filter_menu()
	if M.state.view ~= "list" then
		utils.notify("Filters are only available in the run list", vim.log.levels.WARN)
		return
	end

	local items = {}
	for _, field in ipairs(FILTER_FIELDS) do
		items[#items + 1] = field
	end
	items[#items + 1] = { key = "__clear__", label = "Clear all filters" }

	vim.ui.select(items, {
		prompt = "Filter runs by…",
		format_item = function(item)
			if item.key == "__clear__" then
				return item.label
			end
			local current = M.state.filters[item.key]
			local suffix = (current and current ~= "")
				and (" [current: " .. current .. "]") or ""
			return item.label .. suffix
		end,
	}, function(choice)
		if not choice then
			return
		end
		if choice.key == "__clear__" then
			M.state.filters = default_filters()
			M.state.limit = DEFAULT_LIMIT
			M.refresh()
			return
		end
		input.prompt({
			prompt = choice.label,
			default = M.state.filters[choice.key] or "",
		}, function(value)
			local trimmed = vim.trim(value or "")
			M.state.filters[choice.key] = trimmed ~= "" and trimmed or nil
			M.state.limit = DEFAULT_LIMIT
			M.refresh()
		end)
	end)
end

function M.toggle_branch_scope()
	if M.state.view ~= "list" then
		utils.notify("Branch scope only applies to the run list", vim.log.levels.WARN)
		return
	end
	M.state.filters.all_branches = not M.state.filters.all_branches
	M.state.limit = DEFAULT_LIMIT
	M.refresh()
end

function M.load_more()
	if M.state.view ~= "list" then
		utils.notify("Load more only applies to the run list", vim.log.levels.WARN)
		return
	end
	M.state.limit = M.state.limit + PAGE_STEP
	M.refresh()
end

-- ── Log viewer ───────────────────────────────────────────────────────────

function M.view_log_under_cursor()
	if M.state.view == "list" then
		local run = entry_under_cursor()
		if not run then
			utils.notify("No workflow run selected", vim.log.levels.WARN)
			return
		end
		open_log(run.id, nil, run_title(run), "list")
		return
	end

	if M.state.view == "detail" and M.state.detail_run then
		local run = M.state.detail_run
		local job = job_under_cursor()
		local title = job
			and ("%s — %s"):format(run_title(run), job.name)
			or run_title(run)
		open_log(run.id, job, title, "detail")
		return
	end

	utils.notify("Open a run first", vim.log.levels.WARN)
end

function M.jump_to_first_error()
	if M.state.view ~= "log" or not M.state.log or not M.state.log.lines then
		utils.notify("Open a log first", vim.log.levels.WARN)
		return
	end

	local index = gh_actions.find_first_error_line(M.state.log.lines)
	if not index then
		utils.notify("No error found in this log", vim.log.levels.WARN)
		return
	end

	local buffer_line = (M.state.log.content_start or 1) + index - 1
	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		pcall(vim.api.nvim_win_set_cursor, M.state.winid, { buffer_line, 0 })
		pcall(vim.api.nvim_win_call, M.state.winid, function()
			vim.cmd("normal! zz")
		end)
	end
end

-- ── Rerun / cancel ───────────────────────────────────────────────────────

function M.rerun_under_cursor()
	local run_id = target_run_id()
	if not run_id then
		utils.notify("No workflow run selected", vim.log.levels.WARN)
		return
	end
	perform_mutation({
		id = run_id,
		confirm_message = ("Rerun run #%s?"):format(tostring(run_id)),
		in_progress_message = ("Rerunning run #%s"):format(tostring(run_id)),
		done_message = ("Rerun triggered for run #%s"):format(tostring(run_id)),
		call = function(cb)
			gh_actions.rerun(run_id, nil, function(err)
				cb(err)
			end)
		end,
	})
end

function M.rerun_failed_under_cursor()
	local run_id = target_run_id()
	if not run_id then
		utils.notify("No workflow run selected", vim.log.levels.WARN)
		return
	end
	perform_mutation({
		id = run_id,
		confirm_message = ("Rerun failed jobs for run #%s?"):format(tostring(run_id)),
		in_progress_message = ("Rerunning failed jobs for run #%s"):format(tostring(run_id)),
		done_message = ("Rerun (failed jobs) triggered for run #%s"):format(tostring(run_id)),
		call = function(cb)
			gh_actions.rerun_failed(run_id, nil, function(err)
				cb(err)
			end)
		end,
	})
end

function M.rerun_job_under_cursor()
	if M.state.view ~= "detail" or not M.state.detail_run then
		utils.notify("Open a run detail view first", vim.log.levels.WARN)
		return
	end
	local job = job_under_cursor()
	if not job then
		utils.notify("Move the cursor onto a job", vim.log.levels.WARN)
		return
	end

	local run_id = M.state.detail_run.id
	perform_mutation({
		id = run_id,
		confirm_message = ("Rerun job '%s' for run #%s?"):format(job.name, tostring(run_id)),
		in_progress_message = ("Rerunning job '%s' for run #%s"):format(job.name, tostring(run_id)),
		done_message = ("Rerun triggered for job '%s'"):format(job.name),
		call = function(cb)
			gh_actions.rerun_job(run_id, job.id, nil, function(err)
				cb(err)
			end)
		end,
	})
end

function M.cancel_under_cursor()
	local run_id = target_run_id()
	if not run_id then
		utils.notify("No workflow run selected", vim.log.levels.WARN)
		return
	end
	perform_mutation({
		id = run_id,
		confirm_message = ("Cancel run #%s?"):format(tostring(run_id)),
		in_progress_message = ("Cancelling run #%s"):format(tostring(run_id)),
		done_message = ("Cancelled run #%s"):format(tostring(run_id)),
		call = function(cb)
			gh_actions.cancel(run_id, nil, function(err)
				cb(err)
			end)
		end,
	})
end

-- ── Watch (bounded polling) ──────────────────────────────────────────────

---@return integer
local function watch_interval_ms()
	local cfg = M.state.cfg
	local interval = cfg and cfg.actions and cfg.actions.watch_interval
	return (type(interval) == "number" and interval > 0) and interval or 10000
end

---One watch tick. The watch owns `watch.generation` and never touches the
---panel's `request_id`: sharing that counter meant any user fetch killed the
---watch silently, and every tick stranded an in-flight log fetch.
---@param run_id integer
---@param generation integer
local function poll_watch_once(run_id, generation)
	gh_actions.view(run_id, nil, function(err, run)
		local watch = M.state.watch
		if not watch.active or watch.generation ~= generation then
			return
		end

		if err then
			watch.errors = watch.errors + 1
			utils.notify(err, vim.log.levels.ERROR)
			if watch.errors >= WATCH_MAX_ERRORS then
				stop_watch()
				utils.notify(
					("Stopped watching run #%s after %d consecutive errors")
						:format(tostring(run_id), WATCH_MAX_ERRORS),
					vim.log.levels.WARN
				)
				render_current_view()
				return
			end
		else
			watch.errors = 0
			-- Repaint only the run actually on screen; a watch that outlives
			-- a view change keeps polling but must not paint over the
			-- current view.
			local showing = M.state.detail_run
				and M.state.detail_run.id == run_id
			if showing then
				M.state.detail_run = run
			end
			local finished = gh_actions.is_terminal_status(run.status)
			if finished then
				stop_watch()
			end
			if showing and M.state.view == "detail" and M.is_open() then
				render_detail(run)
			end
			if finished then
				return
			end
		end

		watch.timer = vim.defer_fn(function()
			if not watch.active or watch.generation ~= generation then
				return
			end
			-- Panel buffer replaced in its own window fires no WinClosed;
			-- catch that here instead of polling an invisible panel forever.
			if not M.is_open() then
				stop_watch()
				return
			end
			poll_watch_once(run_id, generation)
		end, watch_interval_ms())
	end)
end

local function start_watch()
	if M.state.view ~= "detail" or not M.state.detail_run then
		utils.notify("Open a run detail view first", vim.log.levels.WARN)
		return
	end
	if gh_actions.is_terminal_status(M.state.detail_run.status) then
		utils.notify("Run has already finished", vim.log.levels.WARN)
		return
	end

	local run_id = M.state.detail_run.id
	M.state.watch.active = true
	M.state.watch.generation = (M.state.watch.generation or 0) + 1
	M.state.watch.run_id = run_id
	M.state.watch.errors = 0
	utils.notify(("Watching run #%s…"):format(tostring(run_id)), vim.log.levels.INFO)
	poll_watch_once(run_id, M.state.watch.generation)
end

function M.toggle_watch()
	if M.state.watch.active then
		stop_watch()
		utils.notify("Stopped watching", vim.log.levels.INFO)
		render_current_view()
		return
	end
	start_watch()
end

-- ── Workflow list + dispatch ─────────────────────────────────────────────

function M.open_workflows()
	if M.state.view ~= "list" then
		utils.notify("Open the run list first", vim.log.levels.WARN)
		return
	end

	set_view("workflows")
	local B = ui_render.builder()
	components.header(
		B, "Gitflow Actions — Workflows",
		{ bufnr = M.state.bufnr, winid = M.state.winid }
	)
	components.loading(B, "Loading workflows…")
	B:flush("actions", M.state.bufnr, ACTIONS_HIGHLIGHT_NS)

	fetch_workflows()
end

function M.dispatch_under_cursor()
	if M.state.view ~= "workflows" then
		utils.notify("Open the workflow list first", vim.log.levels.WARN)
		return
	end
	local workflow = entry_under_cursor()
	if not workflow then
		utils.notify("No workflow selected", vim.log.levels.WARN)
		return
	end

	git_branch.current({}, function(_, branch)
		perform_mutation({
			id = workflow.id,
			confirm_message = ("Dispatch workflow '%s' on %s?"):format(
				workflow.name, branch or "(current branch)"
			),
			in_progress_message = ("Dispatching '%s'"):format(workflow.name),
			done_message = ("Dispatched '%s'"):format(workflow.name),
			call = function(cb)
				local target = workflow.path ~= "" and workflow.path or workflow.id
				gh_actions.workflow_run(target, branch, nil, function(err)
					cb(err)
				end)
			end,
		})
	end)
end

function M.close()
	next_request_id()
	stop_watch()
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
	M.state.detail_line_entries = {}
	M.state.view = "list"
	M.state.detail_run = nil
	M.state.workflows = nil
	M.state.filters = default_filters()
	M.state.limit = DEFAULT_LIMIT
	M.state.busy = nil
	M.state.log = nil
end

---Open means visible: the buffer survives a window close (bufhidden=hide),
---so a buffer-only check reported an invisible panel as open and every
---guard built on it kept running. The tracked winid is not enough either —
---replacing the panel buffer in its own window (`:enew`, `:e`, a clone
---split) fires no WinClosed, so key liveness to whether the buffer is
---actually displayed, not to the window id.
---@return boolean
function M.is_open()
	if M.state.bufnr == nil or not vim.api.nvim_buf_is_valid(M.state.bufnr) then
		return false
	end
	return vim.fn.bufwinid(M.state.bufnr) ~= -1
end

return M
