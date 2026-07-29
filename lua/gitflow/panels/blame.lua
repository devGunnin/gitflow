local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_blame = require("gitflow.git.blame")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")

---@class GitflowBlamePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowBlameEntry>
---@field cfg GitflowConfig|nil
---@field filepath string|nil
---@field on_open_commit fun(sha: string)|nil
---@field request_id integer

local M = {}
local BLAME_FLOAT_TITLE = "  Gitflow Blame  "
local BLAME_FLOAT_FOOTER = " <CR> open commit · r refresh · q close "
local BLAME_HINTS = {
	{ "<CR>", "open commit" },
	{ "r", "refresh" },
	{ "q", "close" },
}
local BLAME_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_blame_hl")

---@type GitflowBlamePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
	filepath = nil,
	on_open_commit = nil,
	request_id = 0,
}

---@return integer
local function next_request_id()
	M.state.request_id = (M.state.request_id or 0) + 1
	return M.state.request_id
end

---A refresh is superseded as soon as another refresh, open, or close starts;
---its callbacks must not render, or a stale result clobbers the live panel.
---@param request_id integer
---@return boolean
local function is_active_request(request_id)
	if M.state.request_id ~= request_id then
		return false
	end
	local bufnr = M.state.bufnr
	return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("blame", {
			filetype = "gitflowblame",
			lines = components.loading_lines("Loading blame…"),
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
			name = "blame",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = BLAME_FLOAT_TITLE,
			title_pos = cfg.ui.float.title_pos,
			footer = cfg.ui.float.footer and BLAME_FLOAT_FOOTER or nil,
			footer_pos = cfg.ui.float.footer_pos,
			on_close = function()
				M.state.winid = nil
			end,
		})
	else
		M.state.winid = ui.window.open_split({
			name = "blame",
			bufnr = bufnr,
			orientation = cfg.ui.split.orientation,
			size = cfg.ui.split.size,
			on_close = function()
				M.state.winid = nil
			end,
		})
	end

	vim.keymap.set("n", "<CR>", function()
		M.open_commit_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---Paint the buffer with a single styled state block (loading / error) sharing
---the same header chrome as the rendered blame so transitions don't flicker.
---@param paint fun(B: GitflowRenderBuilder)
local function render_state(paint)
	local render_opts = { bufnr = M.state.bufnr, winid = M.state.winid }
	local B = ui_render.builder()
	components.header(B, "Gitflow Blame", render_opts)
	B:blank()
	paint(B)
	ui.buffer.update("blame", B.lines)
	M.state.line_entries = {}
	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, BLAME_HIGHLIGHT_NS)
end

local function render_loading()
	render_state(function(B)
		local short_path = vim.fn.fnamemodify(M.state.filepath or "", ":~:.")
		components.loading(B, "Computing blame…", {
			detail = short_path ~= "" and short_path or nil,
		})
	end)
end

---@param message string
local function render_error(message)
	render_state(function(B)
		components.error_state(B, "Could not compute blame", {
			detail = message,
			hint = "Press r to retry · q to close",
		})
	end)
end

---@param str string|nil
---@param width integer
---@return string  padding spaces to reach the given display width
local function pad_spaces(str, width)
	local pad = width - vim.fn.strdisplaywidth(tostring(str or ""))
	if pad > 0 then
		return string.rep(" ", pad)
	end
	return ""
end

---@param entries GitflowBlameEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}

	local filepath = M.state.filepath or "(unknown file)"
	local short_path = vim.fn.fnamemodify(filepath, ":~:.")

	local B = ui_render.builder()
	components.header(B, "Gitflow Blame", render_opts)

	-- Summary bar: file + branch + line count.
	B:push({
		{ "  ", nil },
		{ icons.get("palette", "blame") .. "  ", "GitflowSectionIcon" },
		{ short_path, "GitflowSectionTitle" },
		{ "     " .. icons.get("branch", "current") .. " ", "GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
		{
			("     %d line%s"):format(#entries, #entries == 1 and "" or "s"),
			"GitflowMeta",
		},
	})
	B:blank()

	local line_entries = {}

	components.section(
		B, icons.get("git_state", "commit"), ("Blame (%d)"):format(#entries)
	)

	if #entries == 0 then
		components.empty(B, "No blame data for this file", {
			hint = "The file may be untracked or have no committed history.",
		})
	else
		-- Compute max widths for aligned columns.
		local max_sha, max_author, max_date = 0, 0, 0
		for _, entry in ipairs(entries) do
			max_sha = math.max(max_sha, vim.fn.strdisplaywidth(entry.short_sha))
			max_author = math.max(max_author, vim.fn.strdisplaywidth(entry.author))
			max_date = math.max(max_date, vim.fn.strdisplaywidth(entry.date))
		end
		-- Cap author width.
		max_author = math.min(max_author, 20)

		local commit_icon = icons.get("git_state", "commit")
		for _, entry in ipairs(entries) do
			local author_display = components.truncate(entry.author, max_author)

			-- Columns: <icon> <short_sha> <author> <date> <content>, with each
			-- field highlighted distinctly and padding kept un-highlighted so
			-- the colored spans land exactly on their text.
			local line_no = B:push({
				{ " ", nil },
				{ commit_icon ~= "" and (commit_icon .. " ") or "", "GitflowLogHash" },
				{ entry.short_sha, "GitflowBlameHash" },
				{ pad_spaces(entry.short_sha, max_sha) .. "  ", nil },
				{ author_display, "GitflowBlameAuthor" },
				{ pad_spaces(author_display, max_author) .. "  ", nil },
				{ entry.date, "GitflowBlameDate" },
				{ pad_spaces(entry.date, max_date) .. "  ", nil },
				{ entry.content, "GitflowCardTitle" },
			})
			line_entries[line_no] = entry
		end
	end

	components.split_hint_bar(B, render_opts, BLAME_HINTS)

	ui.buffer.update("blame", B.lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	B:apply(bufnr, BLAME_HIGHLIGHT_NS)
	components.cursorline(M.state.winid, true)
end

---@return GitflowBlameEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr
		or vim.api.nvim_get_current_buf() ~= M.state.bufnr
	then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@return string|nil
local function resolve_open_filepath()
	local current_buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(current_buf)
	if name and name ~= "" and not name:match("^gitflow://") then
		return name
	end
	return M.state.filepath
end

---@param cfg GitflowConfig
---@param opts table|nil
function M.open(cfg, opts)
	local options = opts or {}
	M.state.cfg = cfg
	M.state.on_open_commit = options.on_open_commit

	-- Always target the current non-panel buffer when opening blame.
	local filepath = resolve_open_filepath()
	if filepath and filepath ~= "" then
		M.state.filepath = filepath
	end

	ensure_window(cfg)
	render_loading()
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local request_id = next_request_id()

	local filepath = M.state.filepath
	if not filepath or filepath == "" then
		utils.notify(
			"No file to blame (open a file first)",
			vim.log.levels.WARN
		)
		render_error("No file to blame — open a file first.")
		return
	end

	git_branch.current({}, function(_, branch)
		if not is_active_request(request_id) then
			return
		end
		git_blame.run({ filepath = filepath }, function(err, entries)
			if not is_active_request(request_id) then
				return
			end
			if err then
				utils.notify(err, vim.log.levels.ERROR)
				render_error(err)
				return
			end
			render(entries or {}, branch or "(unknown)")
		end)
	end)
end

function M.open_commit_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No blame entry selected", vim.log.levels.WARN)
		return
	end

	-- Skip uncommitted entries (all-zero SHA)
	if entry.sha:match("^0+$") then
		utils.notify(
			"Uncommitted change — no commit to show",
			vim.log.levels.WARN
		)
		return
	end

	if M.state.on_open_commit then
		M.state.on_open_commit(entry.sha)
		return
	end

	utils.notify(
		"Commit open handler is not configured",
		vim.log.levels.WARN
	)
end

function M.close()
	next_request_id()

	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("blame")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("blame")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.line_entries = {}
	M.state.filepath = nil
end

function M.is_open()
	return M.state.winid ~= nil
		and vim.api.nvim_win_is_valid(M.state.winid)
end

return M
