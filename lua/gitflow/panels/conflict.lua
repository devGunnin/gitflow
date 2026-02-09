local ui = require("gitflow.ui")
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_conflict = require("gitflow.git.conflict")

---@class GitflowConflictFileEntry
---@field path string
---@field markers GitflowConflictMarker[]
---@field marker_error string|nil

---@class GitflowConflictLineEntry
---@field kind "file"|"marker"
---@field path string
---@field marker_index integer|nil

---@class GitflowConflictPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field files GitflowConflictFileEntry[]
---@field line_entries table<integer, GitflowConflictLineEntry>
---@field marker_lines integer[]

local M = {}

---@type GitflowConflictPanelState
M.state = {
	bufnr = nil,
	winid = nil,
	cfg = nil,
	files = {},
	line_entries = {},
	marker_lines = {},
}

---@param result GitflowGitResult|nil
---@param fallback string
---@return string
local function result_message(result, fallback)
	if not result then
		return fallback
	end
	local output = git.output(result)
	if output == "" then
		return fallback
	end
	return output
end

---@param count integer
---@return string
local function marker_label(count)
	if count == 1 then
		return "1 marker"
	end
	return ("%d markers"):format(count)
end

---@param cfg GitflowConfig
local function ensure_window(cfg)
	local bufnr = M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) and M.state.bufnr or nil
	if not bufnr then
		bufnr = ui.buffer.create("conflict", {
			filetype = "gitflowconflict",
			lines = { "Loading conflicts..." },
		})
		M.state.bufnr = bufnr
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
		vim.api.nvim_win_set_buf(M.state.winid, bufnr)
		return
	end

	M.state.winid = ui.window.open_split({
		name = "conflict",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.winid = nil
		end,
	})

	vim.keymap.set("n", "<CR>", function()
		M.open_under_cursor()
	end, { buffer = bufnr, silent = true })

	vim.keymap.set("n", "]c", function()
		M.next_marker()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "[c", function()
		M.prev_marker()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "o", function()
		M.accept_ours_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "t", function()
		M.accept_theirs_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "s", function()
		M.stage_under_cursor()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "A", function()
		M.stage_all()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "r", function()
		M.refresh()
	end, { buffer = bufnr, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = bufnr, silent = true, nowait = true })
end

---@param files GitflowConflictFileEntry[]
local function render(files)
	local lines = {
		"Gitflow Conflict Resolution",
		"",
		("Conflicted files: %d"):format(#files),
	}
	local line_entries = {}
	local marker_lines = {}

	if #files == 0 then
		lines[#lines + 1] = "  (none)"
	else
		for _, item in ipairs(files) do
			lines[#lines + 1] = ("  %s (%s)"):format(item.path, marker_label(#item.markers))
			line_entries[#lines] = {
				kind = "file",
				path = item.path,
				marker_index = nil,
			}

			if item.marker_error then
				lines[#lines + 1] = ("    ! %s"):format(item.marker_error)
			elseif #item.markers == 0 then
				lines[#lines + 1] = "    ! no conflict markers found in working tree file"
			else
				for index, marker in ipairs(item.markers) do
					local end_line = marker.end_line or marker.start_line
					lines[#lines + 1] = ("    [%d] lines %d-%d"):format(
						index,
						marker.start_line,
						end_line
					)
					line_entries[#lines] = {
						kind = "marker",
						path = item.path,
						marker_index = index,
					}
					marker_lines[#marker_lines + 1] = #lines
				end
			end
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "<CR>: open file  ]c/[c: next/prev marker"
	lines[#lines + 1] = "o: accept ours  t: accept theirs"
	lines[#lines + 1] = "s: stage file  A: stage all  r: refresh  q: quit"

	ui.buffer.update("conflict", lines)
	M.state.files = files
	M.state.line_entries = line_entries
	M.state.marker_lines = marker_lines
end

---@return GitflowConflictLineEntry|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param path string
---@return GitflowConflictFileEntry|nil
local function file_entry(path)
	for _, item in ipairs(M.state.files) do
		if item.path == path then
			return item
		end
	end
	return nil
end

---@return string|nil, GitflowConflictMarker|nil
local function selection_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		return nil, nil
	end

	local selected_path = entry.path
	local item = file_entry(selected_path)
	if not item then
		return selected_path, nil
	end

	if entry.kind == "marker" and entry.marker_index then
		return selected_path, item.markers[entry.marker_index]
	end

	return selected_path, item.markers[1]
end

---@param direction 1|-1
local function jump_marker(direction)
	if not M.state.winid or not vim.api.nvim_win_is_valid(M.state.winid) then
		return
	end
	if #M.state.marker_lines == 0 then
		utils.notify("No conflict markers available", vim.log.levels.WARN)
		return
	end

	local cursor_line = vim.api.nvim_win_get_cursor(M.state.winid)[1]
	if direction > 0 then
		for _, line in ipairs(M.state.marker_lines) do
			if line > cursor_line then
				vim.api.nvim_win_set_cursor(M.state.winid, { line, 0 })
				return
			end
		end
		vim.api.nvim_win_set_cursor(M.state.winid, { M.state.marker_lines[1], 0 })
		return
	end

	for index = #M.state.marker_lines, 1, -1 do
		local line = M.state.marker_lines[index]
		if line < cursor_line then
			vim.api.nvim_win_set_cursor(M.state.winid, { line, 0 })
			return
		end
	end
	vim.api.nvim_win_set_cursor(M.state.winid, { M.state.marker_lines[#M.state.marker_lines], 0 })
end

---@param side "ours"|"theirs"
local function accept_side(side)
	local path = select(1, selection_under_cursor())
	if not path then
		utils.notify("No conflicted file selected", vim.log.levels.WARN)
		return
	end

	git_conflict.checkout(path, side, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(
			result_message(result, ("Applied %s version for %s"):format(side, path)),
			vim.log.levels.INFO
		)
		M.refresh()
	end)
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	ensure_window(cfg)
	M.refresh()
end

function M.refresh()
	git_conflict.list({}, function(err, paths)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end

		local files = {}
		for _, path in ipairs(paths or {}) do
			local marker_err, markers = git_conflict.read_markers(path)
			files[#files + 1] = {
				path = path,
				markers = markers or {},
				marker_error = marker_err,
			}
		end
		render(files)
	end)
end

function M.next_marker()
	jump_marker(1)
end

function M.prev_marker()
	jump_marker(-1)
end

function M.open_under_cursor()
	local path, marker = selection_under_cursor()
	if not path then
		utils.notify("No conflicted file selected", vim.log.levels.WARN)
		return
	end

	vim.cmd(("belowright split %s"):format(vim.fn.fnameescape(path)))
	if marker and marker.start_line then
		local winid = vim.api.nvim_get_current_win()
		local line_count = vim.api.nvim_buf_line_count(0)
		local line = math.max(1, math.min(marker.start_line, line_count))
		vim.api.nvim_win_set_cursor(winid, { line, 0 })
	end
end

function M.accept_ours_under_cursor()
	accept_side("ours")
end

function M.accept_theirs_under_cursor()
	accept_side("theirs")
end

function M.stage_under_cursor()
	local path = select(1, selection_under_cursor())
	if not path then
		utils.notify("No conflicted file selected", vim.log.levels.WARN)
		return
	end

	git_conflict.stage(path, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(result_message(result, ("Staged %s"):format(path)), vim.log.levels.INFO)
		M.refresh()
	end)
end

function M.stage_all()
	local paths = {}
	for _, item in ipairs(M.state.files) do
		paths[#paths + 1] = item.path
	end
	if #paths == 0 then
		utils.notify("No conflicted files to stage", vim.log.levels.INFO)
		return
	end

	git_conflict.stage_paths(paths, {}, function(err, result)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(result_message(result, "Staged conflicted files"), vim.log.levels.INFO)
		M.refresh()
	end)
end

function M.close()
	if M.state.winid then
		ui.window.close(M.state.winid)
	else
		ui.window.close("conflict")
	end

	if M.state.bufnr then
		ui.buffer.teardown(M.state.bufnr)
	else
		ui.buffer.teardown("conflict")
	end

	M.state.bufnr = nil
	M.state.winid = nil
	M.state.cfg = nil
	M.state.files = {}
	M.state.line_entries = {}
	M.state.marker_lines = {}
end

---@return boolean
function M.is_open()
	return M.state.winid ~= nil
		and vim.api.nvim_win_is_valid(M.state.winid)
		and M.state.bufnr ~= nil
		and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

return M
