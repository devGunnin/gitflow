local components = require("gitflow.ui.components")
local panel = require("gitflow.ui.panel")
local utils = require("gitflow.utils")
local input = require("gitflow.ui.input")
local form = require("gitflow.ui.form")
local gh_labels = require("gitflow.gh.labels")
local highlights = require("gitflow.highlights")
local icons = require("gitflow.icons")

---@class GitflowLabelPanelState
---@field bufnr integer|nil
---@field winid integer|nil
---@field cfg GitflowConfig|nil
---@field line_entries table<integer, table>

local M = {}

---@type GitflowLabelPanelState
M.state = {
	cfg = nil,
	line_entries = {},
}

local P = panel.new({
	name = "labels",
	title = "Gitflow Labels",
	filetype = "markdown",
	loading = "Loading labels…",
	state = M.state,
	keymaps = {
		{ key = "c", desc = "create", run = function()
			M.create_interactive()
		end },
		{ key = "d", desc = "delete", run = function()
			M.delete_under_cursor()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", run = function()
			M.close()
		end },
	},
})

---@param value string|nil
---@return string
local function maybe_text(value)
	local text = vim.trim(tostring(value or ""))
	if text == "" then
		return "-"
	end
	return text
end

---@param labels table[]
local function render_list(labels)
	local tag_icon = icons.get("ui", "tag")
	local B = P:begin_render()

	-- Summary bar: tag icon + label count.
	B:push({
		{ components.spacing.gutter, nil },
		{ tag_icon ~= "" and (tag_icon .. "  ") or "", "GitflowSectionIcon" },
		{ ("%d label%s"):format(#labels, #labels == 1 and "" or "s"), "GitflowSectionTitle" },
	})
	B:blank()

	components.section(B, tag_icon, "Repository Labels")

	local line_entries = {}
	if #labels == 0 then
		components.empty(B, "(no labels)")
	else
		for _, label in ipairs(labels) do
			local name = maybe_text(label.name)
			local color = maybe_text(label.color)
			local description = maybe_text(label.description)

			-- Name line: text MUST contain "<name> (#<color>)" exactly so the
			-- colored highlight can target the name and tests can locate it.
			local name_line = B:push({
				{ components.spacing.edge, nil },
				{ tag_icon ~= "" and (tag_icon .. "  ") or "", "GitflowSectionIcon" },
				{ name, "GitflowCardTitle" },
				{ (" (#%s)"):format(color), "GitflowMeta" },
			})
			local desc_line = B:push({
				{ components.spacing.indent .. components.spacing.gutter, nil },
				{ description, "GitflowMeta" },
			})

			line_entries[name_line] = label
			line_entries[desc_line] = label

			-- Color the label NAME substring with its own dynamic group.
			if label.color and label.name and label.name ~= "" then
				local group = highlights.label_color_group(label.color)
				local line_text = B.lines[name_line] or ""
				local name_start = line_text:find(label.name, 1, true)
				if name_start then
					B:hl(
						name_line,
						name_start - 1,
						name_start - 1 + #label.name,
						group
					)
				end
			end
		end
	end

	P:push_hints(B)

	if P:paint(B) then
		M.state.line_entries = line_entries
	end
end

---@return table|nil
local function entry_under_cursor()
	if not M.state.bufnr or vim.api.nvim_get_current_buf() ~= M.state.bufnr then
		return nil
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	return M.state.line_entries[line]
end

---@param cfg GitflowConfig
function M.open(cfg)
	M.state.cfg = cfg
	if not P:ensure_window(cfg) then
		return
	end
	M.refresh()
end

function M.refresh()
	if not M.state.cfg then
		return
	end

	local request_id = P:next_request()
	P:render_loading("Loading labels…")
	M.state.line_entries = {}
	gh_labels.list({}, function(err, labels)
		if not P:is_active(request_id) then
			return
		end
		if err then
			M.state.line_entries = {}
			P:render_error("Failed to load labels", {
				detail = err,
				hint = "Press r to retry \u{b7} q to close",
			})
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		render_list(labels or {})
	end)
end

function M.create_interactive()
	if not M.state.cfg then
		return
	end

	form.open({
		title = "Create Label",
		draft_key = "label:create",
		fields = {
			{ name = "Name", key = "name", required = true },
			{ name = "Color (hex)", key = "color", required = true,
				placeholder = "e.g. ff0000" },
			{ name = "Description", key = "description", multiline = true },
		},
		on_submit = function(values)
			gh_labels.create(
				values.name, values.color or "", values.description, {},
				function(err)
					if err then
						utils.notify(err, vim.log.levels.ERROR)
						return
					end
					utils.notify(
						("Created label '%s'"):format(values.name),
						vim.log.levels.INFO
					)
					M.refresh()
				end
			)
		end,
	})
end

function M.delete_under_cursor()
	local entry = entry_under_cursor()
	if not entry then
		utils.notify("No label selected", vim.log.levels.WARN)
		return
	end

	local label_name = maybe_text(entry.name)
	local confirmed = input.confirm(("Delete label '%s'?"):format(label_name), {
		choices = { "&Delete", "&Cancel" },
		default_choice = 2,
	})
	if not confirmed then
		return
	end

	gh_labels.delete(label_name, {}, function(err)
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			return
		end
		utils.notify(("Deleted label '%s'"):format(label_name), vim.log.levels.INFO)
		M.refresh()
	end)
end

function M.close()
	P:close()
	M.state.line_entries = {}
end

---@return boolean
function M.is_open()
	return P:is_open()
end

return M
