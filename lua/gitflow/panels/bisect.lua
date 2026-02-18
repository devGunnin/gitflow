local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_bisect = require("gitflow.git.bisect")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")

---@class GitflowBisectPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowBisectEntry>
---@field cfg GitflowConfig|nil
---@field bisect_active boolean
---@field bad_sha string|nil
---@field good_sha string|nil
---@field first_bad_sha string|nil
---@field test_script string|nil
---@field phase "select_bad"|"select_good"|"bisecting"|"found"

local M = {}
local BISECT_FLOAT_TITLE = "Gitflow Bisect"
local BISECT_FLOAT_FOOTER_SELECT =
	"<CR> select  1-9 jump  r refresh  q close"
local BISECT_FLOAT_FOOTER_ACTIVE =
	"g good  b bad  t test  R reset  r refresh  q close"
local BISECT_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_bisect_hl")

---@type GitflowBisectPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
	bisect_active = false,
	bad_sha = nil,
	good_sha = nil,
	first_bad_sha = nil,
	test_script = nil,
	phase = "select_bad",
}

local function emit_post_operation()
	vim.api.nvim_exec_autocmds(
		"User", { pattern = "GitflowPostOperation" }
	)
end

---@return string
local function current_footer()
	if M.state.phase == "bisecting"
		or M.state.phase == "found"
	then
		return BISECT_FLOAT_FOOTER_ACTIVE
	end
	return BISECT_FLOAT_FOOTER_SELECT
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("bisect", {
			filetype = "gitflowbisect",
			lines = { "Loading commits..." },
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
			name = "bisect",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = BISECT_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and current_footer() or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "bisect",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.select_under_cursor()
	end, { buffer = bufnr, silent = true })

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			M.select_by_position(i)
		end, { buffer = bufnr, silent = true, nowait = true })
	end

	vim.keymap.set("n", "b", function()
		M.mark_bad()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "g", function()
		M.mark_good()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "t", function()
		M.select_test_file()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "R", function()
		M.reset_bisect()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param entries GitflowBisectEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local lines = ui_render.panel_header(
		"Gitflow Bisect", render_opts
	)
	local line_entries = {}
	local entry_highlights = {}

	-- Status line based on phase
	if M.state.phase == "select_bad" then
		lines[#lines + 1] = ui_render.entry(
			"Select the BAD commit (known broken)"
		)
	elseif M.state.phase == "select_good" then
		lines[#lines + 1] = ui_render.entry(
			("Bad: %s  |  Select the GOOD commit"):format(
				M.state.bad_sha
					and M.state.bad_sha:sub(1, 7) or "?"
			)
		)
	elseif M.state.phase == "bisecting" then
		local status = "Bisecting..."
		if M.state.test_script then
			status = ("Bisecting (test: %s)"):format(
				vim.fn.fnamemodify(
					M.state.test_script, ":t"
				)
			)
		end
		lines[#lines + 1] = ui_render.entry(status)
		lines[#lines + 1] = ui_render.entry(
			"Use g=good, b=bad to mark current commit"
		)
	elseif M.state.phase == "found" then
		lines[#lines + 1] = ui_render.entry(
			"FIRST BAD COMMIT FOUND:"
		)
	end

	lines[#lines + 1] = ui_render.separator(render_opts)

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty(
			"no commits found"
		)
	else
		for idx, entry in ipairs(entries) do
			local commit_icon = icons.get(
				"git_state", "commit"
			)
			local position_marker = ""
			if idx <= 9 then
				position_marker = ("[%d] "):format(idx)
			end

			local prefix = ""
			if M.state.first_bad_sha
				and (
					entry.sha == M.state.first_bad_sha
					or entry.sha:sub(
						1, #M.state.first_bad_sha
					) == M.state.first_bad_sha
					or M.state.first_bad_sha:sub(
						1, #entry.sha
					) == entry.sha
				)
			then
				prefix = "[FIRST BAD] "
			elseif M.state.bad_sha
				and (
					entry.sha == M.state.bad_sha
					or entry.sha:sub(
						1, #M.state.bad_sha
					) == M.state.bad_sha
					or M.state.bad_sha:sub(
						1, #entry.sha
					) == entry.sha
				)
			then
				prefix = "[BAD] "
			elseif M.state.good_sha
				and (
					entry.sha == M.state.good_sha
					or entry.sha:sub(
						1, #M.state.good_sha
					) == M.state.good_sha
					or M.state.good_sha:sub(
						1, #entry.sha
					) == entry.sha
				)
			then
				prefix = "[GOOD] "
			end

			lines[#lines + 1] = ui_render.entry(
				("%s%s%s %s %s"):format(
					position_marker,
					prefix,
					commit_icon,
					entry.short_sha,
					entry.summary
				)
			)
			line_entries[#lines] = entry

			if M.state.first_bad_sha
				and (
					entry.sha == M.state.first_bad_sha
					or entry.sha:sub(
						1, #M.state.first_bad_sha
					) == M.state.first_bad_sha
					or M.state.first_bad_sha:sub(
						1, #entry.sha
					) == entry.sha
				)
			then
				entry_highlights[#lines] =
					"GitflowBisectBad"
			elseif M.state.bad_sha
				and (
					entry.sha == M.state.bad_sha
					or entry.sha:sub(
						1, #M.state.bad_sha
					) == M.state.bad_sha
					or M.state.bad_sha:sub(
						1, #entry.sha
					) == entry.sha
				)
			then
				entry_highlights[#lines] =
					"GitflowBisectBad"
			elseif M.state.good_sha
				and (
					entry.sha == M.state.good_sha
					or entry.sha:sub(
						1, #M.state.good_sha
					) == M.state.good_sha
					or M.state.good_sha:sub(
						1, #entry.sha
					) == entry.sha
				)
			then
				entry_highlights[#lines] =
					"GitflowBisectGood"
			end
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("bisect", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(
		bufnr, BISECT_HIGHLIGHT_NS, lines, {
			footer_line = #lines,
			entry_highlights = entry_highlights,
		}
	)
end

---@return GitflowBisectEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param position integer
---@return GitflowBisectEntry|nil
local function entry_by_position(position)
	local sorted_lines = {}
	for line_no, _ in pairs(M.state.line_entries) do
		sorted_lines[#sorted_lines + 1] = line_no
	end
	table.sort(sorted_lines)

	if position < 1 or position > #sorted_lines then
		return nil
	end
	return M.state.line_entries[sorted_lines[position]]
end

---Handle commit selection based on current phase.
---@param entry GitflowBisectEntry
local function handle_selection(entry)
	if M.state.phase == "select_bad" then
		M.state.bad_sha = entry.sha
		M.state.phase = "select_good"
		utils.notify(
			("Bad commit: %s %s"):format(
				entry.short_sha, entry.summary
			),
			vim.log.levels.INFO
		)
		M.refresh()
	elseif M.state.phase == "select_good" then
		M.state.good_sha = entry.sha
		utils.notify(
			("Good commit: %s %s"):format(
				entry.short_sha, entry.summary
			),
			vim.log.levels.INFO
		)
		M.start_bisect()
	end
end

---Start the bisect session after both commits are selected.
function M.start_bisect()
	if not M.state.bad_sha or not M.state.good_sha then
		utils.notify(
			"Select bad and good commits first",
			vim.log.levels.WARN
		)
		return
	end

	git_bisect.start(
		M.state.bad_sha,
		M.state.good_sha,
		function(err, output)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				M.state.phase = "select_bad"
				M.state.bad_sha = nil
				M.state.good_sha = nil
				M.refresh()
				return
			end

			local first_bad = git_bisect.parse_first_bad(
				output or ""
			)
			if first_bad then
				M.state.first_bad_sha = first_bad
				M.state.phase = "found"
				utils.notify(
					("First bad commit: %s"):format(
						first_bad:sub(1, 7)
					),
					vim.log.levels.WARN
				)
			else
				M.state.phase = "bisecting"
				M.state.bisect_active = true
				utils.notify(
					output or "Bisect started",
					vim.log.levels.INFO
				)
			end

			if M.state.test_script then
				M.run_test()
				return
			end
			M.refresh()
			emit_post_operation()
		end
	)
end

---Mark the current bisect HEAD as good.
function M.mark_good()
	if M.state.phase ~= "bisecting" then
		utils.notify(
			"No active bisect session",
			vim.log.levels.WARN
		)
		return
	end

	git_bisect.good(function(err, output)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		local first_bad = git_bisect.parse_first_bad(
			output or ""
		)
		if first_bad then
			M.state.first_bad_sha = first_bad
			M.state.phase = "found"
			utils.notify(
				("First bad commit found: %s"):format(
					first_bad:sub(1, 7)
				),
				vim.log.levels.WARN
			)
		else
			utils.notify(
				output or "Marked good",
				vim.log.levels.INFO
			)
		end

		M.refresh()
		emit_post_operation()
	end)
end

---Mark the current bisect HEAD as bad.
function M.mark_bad()
	if M.state.phase ~= "bisecting" then
		utils.notify(
			"No active bisect session",
			vim.log.levels.WARN
		)
		return
	end

	git_bisect.bad(function(err, output)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		local first_bad = git_bisect.parse_first_bad(
			output or ""
		)
		if first_bad then
			M.state.first_bad_sha = first_bad
			M.state.phase = "found"
			utils.notify(
				("First bad commit found: %s"):format(
					first_bad:sub(1, 7)
				),
				vim.log.levels.WARN
			)
		else
			utils.notify(
				output or "Marked bad",
				vim.log.levels.INFO
			)
		end

		M.refresh()
		emit_post_operation()
	end)
end

---Prompt user to select a test file for bisect run.
function M.select_test_file()
	ui.input.prompt({
		prompt = "Test script path (empty to clear): ",
		completion = "file",
	}, function(value)
		local trimmed = vim.trim(value)
		if trimmed == "" then
			M.state.test_script = nil
			utils.notify(
				"Test script cleared",
				vim.log.levels.INFO
			)
		else
			M.state.test_script = trimmed
			utils.notify(
				("Test script: %s"):format(trimmed),
				vim.log.levels.INFO
			)
		end
		M.refresh()
	end)
end

---Run bisect with the selected test script.
function M.run_test()
	if not M.state.test_script then
		utils.notify(
			"No test script selected",
			vim.log.levels.WARN
		)
		return
	end

	utils.notify(
		("Running bisect with %s..."):format(
			vim.fn.fnamemodify(M.state.test_script, ":t")
		),
		vim.log.levels.INFO
	)

	git_bisect.run(
		M.state.test_script,
		function(err, output)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				M.refresh()
				return
			end

			local first_bad = git_bisect.parse_first_bad(
				output or ""
			)
			if first_bad then
				M.state.first_bad_sha = first_bad
				M.state.phase = "found"
				utils.notify(
					("First bad commit found: %s"):format(
						first_bad:sub(1, 7)
					),
					vim.log.levels.WARN
				)
			else
				utils.notify(
					output or "Bisect run completed",
					vim.log.levels.INFO
				)
			end

			M.refresh()
			emit_post_operation()
		end
	)
end

---Reset (end) the active bisect session.
function M.reset_bisect()
	if M.state.phase ~= "bisecting"
		and M.state.phase ~= "found"
	then
		utils.notify(
			"No active bisect session to reset",
			vim.log.levels.WARN
		)
		return
	end

	git_bisect.reset_bisect(function(err, output)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		utils.notify(
			output or "Bisect session ended",
			vim.log.levels.INFO
		)
		M.state.bisect_active = false
		M.state.bad_sha = nil
		M.state.good_sha = nil
		M.state.first_bad_sha = nil
		M.state.phase = "select_bad"
		M.refresh()
		emit_post_operation()
	end)
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
		git_bisect.list_commits({
			count = cfg.git.log.count,
		}, function(log_err, entries)
			if log_err then
				utils.notify(log_err, vim.log.levels.ERROR)
				return
			end

			render(entries or {}, branch or "(unknown)")
		end)
	end)
end

function M.select_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No commit selected", vim.log.levels.WARN
		)
		return
	end
	handle_selection(entry)
end

---@param position integer
function M.select_by_position(position)
	local entry = entry_by_position(position)
	if not entry then
		utils.notify(
			("No commit at position %d"):format(position),
			vim.log.levels.WARN
		)
		return
	end
	handle_selection(entry)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("bisect")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("bisect")
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
