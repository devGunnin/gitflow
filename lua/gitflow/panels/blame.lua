local utils = require("gitflow.utils")
local git_blame = require("gitflow.git.blame")
local git_branch = require("gitflow.git.branch")
local icons = require("gitflow.icons")
local panel = require("gitflow.ui.panel")
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

---@type GitflowBlamePanelState
M.state = {
	line_entries = {},
	cfg = nil,
	filepath = nil,
	on_open_commit = nil,
}

local P = panel.new({
	name = "blame",
	title = "Gitflow Blame",
	filetype = "gitflowblame",
	loading = "Loading blame…",
	state = M.state,
	keymaps = {
		{ key = "<CR>", desc = "open commit", essential = true, run = function()
			M.open_commit_under_cursor()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

local function render_loading()
	local short_path = vim.fn.fnamemodify(M.state.filepath or "", ":~:.")
	P:render_loading("Computing blame…", {
		detail = short_path ~= "" and short_path or nil,
	})
end

---@param message string
local function render_error(message)
	P:render_error("Could not compute blame", {
		detail = message,
		hint = "Press r to retry \u{b7} q to close",
	})
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
	local filepath = M.state.filepath or "(unknown file)"
	local short_path = vim.fn.fnamemodify(filepath, ":~:.")

	local B = P:begin_render()

	-- Summary bar: file + branch + line count.
	B:push({
		{ components.spacing.gutter, nil },
		{ icons.get("palette", "blame") .. "  ", "GitflowSectionIcon" },
		{ short_path, "GitflowSectionTitle" },
		{ components.separators.field .. icons.get("branch", "current") .. " ",
			"GitflowMetaKey" },
		{ current_branch ~= "" and current_branch or "(unknown)", "GitflowMeta" },
		{
			(components.separators.field .. "%d line%s"):format(
				#entries, #entries == 1 and "" or "s"
			),
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
				{ components.spacing.edge, nil },
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

	P:push_hints(B)

	if P:paint(B) then
		M.state.line_entries = line_entries
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

	if not P:ensure_window(cfg) then
		return
	end
	render_loading()
	M.refresh()
end

function M.refresh()
	local cfg = M.state.cfg
	if not cfg then
		return
	end

	local request_id = P:next_request()

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
		if not P:is_active(request_id) then
			return
		end
		git_blame.run({ filepath = filepath }, function(err, entries)
			if not P:is_active(request_id) then
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
	P:close()
	M.state.line_entries = {}
	M.state.filepath = nil
end

--- Window-scoped on purpose: `:Gitflow blame` toggles the visible panel, so a
--- buffer left behind by `:q` must still count as closed.
---@return boolean
function M.is_open()
	return P:has_window()
end

return M
