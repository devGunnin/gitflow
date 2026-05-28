local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git_blame = require("gitflow.git.blame")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local ui_render = require("gitflow.ui.render")

---@class GitflowBlamePanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field line_entries table<integer, GitflowBlameEntry>
---@field cfg GitflowConfig|nil
---@field filepath string|nil
---@field on_open_commit fun(sha: string)|nil

local M = {}
local BLAME_FLOAT_TITLE = "Gitflow Blame"
local BLAME_FLOAT_FOOTER = "<CR> open commit  r refresh  q close"
local BLAME_HIGHLIGHT_NS = vim.api.nvim_create_namespace("gitflow_blame_hl")

---@type GitflowBlamePanelState
M.state = {
	bufnr = nil,
	winid = nil,
	line_entries = {},
	cfg = nil,
	filepath = nil,
	on_open_commit = nil,
}

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
		and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("blame", {
			filetype = "gitflowblame",
			lines = { "Loading blame..." },
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

---@param entries GitflowBlameEntry[]
---@param current_branch string
local function render(entries, current_branch)
	local render_opts = {
		bufnr = M.state.bufnr,
		winid = M.state.winid,
	}

	local filepath = M.state.filepath or "(unknown file)"
	local short_path = vim.fn.fnamemodify(filepath, ":~:.")
	local title = ("Gitflow Blame: %s"):format(short_path)
	local lines = ui_render.panel_header(title, render_opts)
	local line_entries = {}

	if #entries == 0 then
		lines[#lines + 1] = ui_render.empty("no blame data")
	else
		-- Compute max widths for aligned columns
		local max_sha = 0
		local max_author = 0
		local max_date = 0
		for _, entry in ipairs(entries) do
			if #entry.short_sha > max_sha then
				max_sha = #entry.short_sha
			end
			if #entry.author > max_author then
				max_author = #entry.author
			end
			if #entry.date > max_date then
				max_date = #entry.date
			end
		end
		-- Cap author width at 20 chars
		if max_author > 20 then
			max_author = 20
		end

		for _, entry in ipairs(entries) do
			local author_display = entry.author
			if #author_display > max_author then
				author_display = author_display:sub(1, max_author - 1) .. "…"
			end

			local blame_icon = icons.get("git_state", "commit")
			local line_text = ("%s %-" .. max_sha .. "s  %-"
				.. max_author .. "s  %-"
				.. max_date .. "s  %s"):format(
				blame_icon,
				entry.short_sha,
				author_display,
				entry.date,
				entry.content
			)
			lines[#lines + 1] = ui_render.entry(line_text)
			line_entries[#lines] = entry
		end
	end

	local footer_lines = ui_render.panel_footer(
		current_branch, nil, render_opts
	)
	for _, line in ipairs(footer_lines) do
		lines[#lines + 1] = line
	end

	ui.buffer.update("blame", lines)
	M.state.line_entries = line_entries

	local bufnr = M.state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	ui_render.apply_panel_highlights(bufnr, BLAME_HIGHLIGHT_NS, lines, {
		footer_line = #lines,
	})

	-- Apply blame-specific highlights to each entry line
	for line_no, entry in pairs(line_entries) do
		local line_text = lines[line_no] or ""

		-- Highlight SHA
		local sha_start = line_text:find(entry.short_sha, 1, true)
		if sha_start then
			vim.api.nvim_buf_add_highlight(
				bufnr, BLAME_HIGHLIGHT_NS, "GitflowBlameHash",
				line_no - 1, sha_start - 1,
				sha_start - 1 + #entry.short_sha
			)
		end

		-- Highlight author
		if entry.author ~= "" then
			local author_display = entry.author
			if #author_display > 20 then
				author_display = author_display:sub(1, 19) .. "…"
			end
			local author_start = line_text:find(
				author_display, (sha_start or 0) + #entry.short_sha, true
			)
			if author_start then
				vim.api.nvim_buf_add_highlight(
					bufnr, BLAME_HIGHLIGHT_NS, "GitflowBlameAuthor",
					line_no - 1, author_start - 1,
					author_start - 1 + #author_display
				)
			end
		end

		-- Highlight date
		if entry.date ~= "" then
			local date_start = line_text:find(entry.date, 1, true)
			if date_start then
				vim.api.nvim_buf_add_highlight(
					bufnr, BLAME_HIGHLIGHT_NS, "GitflowBlameDate",
					line_no - 1, date_start - 1,
					date_start - 1 + #entry.date
				)
			end
		end
	end
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
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local filepath = M.state.filepath
	if not filepath or filepath == "" then
		utils.notify(
			"No file to blame (open a file first)",
			vim.log.levels.WARN
		)
		return
	end

	git_branch.current({}, function(_, branch)
		git_blame.run({ filepath = filepath }, function(err, entries)
			if err then
				utils.notify(err, vim.log.levels.ERROR)
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
