local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_reflog = require("gitflow.git.reflog")
local git_branch = require("gitflow.git.branch")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")
local icons = require("gitflow.icons")

---@class GitflowReflogPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowReflogEntry>
---@field cfg GitflowConfig|nil

local M = {}
local REFLOG_FLOAT_TITLE = "Gitflow Reflog"
local REFLOG_HIGHLIGHT_NS =
	vim.api.nvim_create_namespace("gitflow_reflog_hl")
local REFLOG_FLOAT_FOOTER =
	" <CR> checkout · 1-9 quick checkout · R reset · r refresh · q close "

---@type GitflowReflogPanelState
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
		bufnr = ui.buffer.create("reflog", {
			filetype = "gitflowreflog",
			lines = { "Loading reflog..." },
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
			name = "reflog",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = REFLOG_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer
				and REFLOG_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "reflog",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.checkout_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			M.select_by_position(i)
		end, { buffer = bufnr, silent = true, nowait = true })
	end

	vim.keymap.set("n", "R", function()
		M.reset_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---Choose a per-row accent icon based on the reflog action.
---@param action string
---@return string
local function action_icon(action)
	if action == "checkout" then
		return icons.get("branch", "current")
	elseif action == "reset" then
		return icons.get("git_state", "modified")
	elseif action == "merge" or action == "rebase" then
		return icons.get("ui", "merge")
	end
	return icons.get("git_state", "commit")
end

---@param entries GitflowReflogEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}
	local B = ui_render.builder()
	components.header(B, "Gitflow Reflog", render_opts)

	-- Summary bar: entry count + current branch context.
	B:push({
		{ "  ", nil },
		{ icons.get("git_state", "commit") .. "  ", "GitflowSectionIcon" },
		{
			("%d entr%s"):format(#entries, #entries == 1 and "y" or "ies"),
			"GitflowSectionTitle",
		},
		{ "     " .. icons.get("branch", "current") .. " ", "GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
	})
	B:blank()

	local line_entries = {}

	components.section(
		B,
		icons.get("git_state", "commit"),
		("History (%d)"):format(#entries)
	)

	if #entries == 0 then
		components.empty(B, "no reflog entries")
	else
		for idx, entry in ipairs(entries) do
			-- Quick-access marker for the first 9 entries; keep the literal
			-- "[N] <sha>" token contiguous so 1-9 selection stays discoverable.
			local marker = idx <= 9 and ("[%d] "):format(idx) or "    "
			local sha = entry.short_sha or ""
			local selector = entry.selector or ""

			-- Split "<action>: <rest>" so the action word can be accented
			-- while keeping the literal "commit:"/"checkout:"/"reset:" text.
			local action = entry.action or ""
			local desc = entry.description or ""
			local action_text, rest_text
			if action ~= "" and vim.startswith(desc, action .. ":") then
				action_text = action .. ":"
				rest_text = desc:sub(#action_text + 1)
			end

			local icon = action_icon(action)
			local chunks = {
				{ " ", nil },
				{ icon ~= "" and (icon .. "  ") or "", "GitflowSectionIcon" },
				{ marker, "GitflowNumber" },
				{ sha, "GitflowReflogHash" },
				{ "  ", nil },
				{ selector, "GitflowMetaKey" },
				{ "  ", nil },
			}
			if action_text then
				chunks[#chunks + 1] = { action_text, "GitflowReflogAction" }
				chunks[#chunks + 1] = { rest_text, "GitflowCardTitle" }
			else
				chunks[#chunks + 1] = { desc, "GitflowCardTitle" }
			end

			local line_no = B:push(chunks)
			line_entries[line_no] = entry
		end
	end

	ui.buffer.update("reflog", B.lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, REFLOG_HIGHLIGHT_NS)
	components.cursorline(M.state.winid, true)
end

---@return GitflowReflogEntry|nil
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
---@return GitflowReflogEntry|nil
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

---@param entry GitflowReflogEntry
local function execute_checkout(entry)
	local confirmed = vim.fn.confirm(
		("Checkout %s? This will detach HEAD."):format(
			entry.short_sha
		),
		"&Yes\n&No", 2
	) == 1
	if not confirmed then
		return
	end

	git_reflog.checkout(
		entry.sha, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Checked out %s (detached HEAD)"):format(
					entry.short_sha
				),
				vim.log.levels.INFO
			)
			M.refresh()
			emit_post_operation()
		end
	)
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
		git_reflog.list({}, function(err, entries)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			render(entries or {}, branch or "(unknown)")
		end)
	end)
end

function M.checkout_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No reflog entry selected", vim.log.levels.WARN
		)
		return
	end
	execute_checkout(entry)
end

---@param position integer
function M.select_by_position(position)
	local entry = entry_by_position(position)
	if not entry then
		utils.notify(
			("No reflog entry at position %d"):format(position),
			vim.log.levels.WARN
		)
		return
	end
	execute_checkout(entry)
end

function M.reset_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify(
			"No reflog entry selected", vim.log.levels.WARN
		)
		return
	end

	local choice = vim.fn.confirm(
		("Reset to %s?"):format(entry.short_sha),
		"&Soft\n&Mixed\n&Hard\n&Cancel", 4
	)
	if choice == 0 or choice == 4 then
		return
	end

	local modes = { "soft", "mixed", "hard" }
	local mode = modes[choice]

	git_reflog.reset(
		entry.sha, mode, {}, function(err)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				return
			end
			utils.notify(
				("Reset --%s to %s"):format(
					mode, entry.short_sha
				),
				vim.log.levels.INFO
			)
			M.refresh()
			emit_post_operation()
		end
	)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("reflog")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("reflog")
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
