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
---@field cache table[]|nil  raw labels from the last successful fetch
---@field cache_key string|nil  scope the cache was filled under
---@field page integer  1-based page into `cache`
---@field line_entries table<integer, table>

local M = {}

-- `gh label list` defaults to 30 and has no cursor pagination; fetch a
-- generous bound in one call and page through it client-side (#283).
local FETCH_LIMIT = 500
local PAGE_SIZE = 30

---@type GitflowLabelPanelState
M.state = {
	cfg = nil,
	cache = nil,
	cache_key = nil,
	page = 1,
	line_entries = {},
}

---Scope the cache is only valid under: `gh` resolves the repo from the cwd.
---@return string
local function cache_key()
	return vim.fn.getcwd()
end

---The cache, but only when it was filled under the current scope. Unkeyed it
---painted another repo's labels as `d`-deletable rows, so a mismatch drops it.
---@return table[]|nil
local function scoped_cache()
	if not M.state.cache then
		return nil
	end
	if M.state.cache_key ~= cache_key() then
		M.state.cache, M.state.cache_key = nil, nil
		return nil
	end
	return M.state.cache
end

local P = panel.new({
	name = "labels",
	title = "Gitflow Labels",
	filetype = "markdown",
	loading = "Loading labels…",
	state = M.state,
	keymaps = {
		{ key = "c", desc = "create", essential = true, run = function()
			M.create_interactive()
		end },
		{ key = "d", desc = "delete", destructive = true, run = function()
			M.delete_under_cursor()
		end },
		-- Not n/p: n is vim's search-next in a buffer users search with `/`.
		-- Tiered below the core verbs so a narrow bar elides pages, not delete.
		{ key = "<C-n>", desc = "next page", run = function()
			M.next_page()
		end },
		{ key = "<C-p>", desc = "prev page", run = function()
			M.prev_page()
		end },
		{ key = "r", desc = "refresh", run = function()
			M.refresh()
		end },
		{ key = "q", desc = "close", essential = true, run = function()
			M.close()
		end },
	},
})

---Slice `list` to page `page` (clamped) at PAGE_SIZE.
---@param list table[]
---@param page integer
---@return table[] slice, integer page, integer total_pages
local function paginate(list, page)
	local total = #list
	local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
	page = math.min(math.max(1, page), total_pages)
	local start_index = (page - 1) * PAGE_SIZE + 1
	local end_index = math.min(total, page * PAGE_SIZE)
	local slice = {}
	for index = start_index, end_index do
		slice[#slice + 1] = list[index]
	end
	return slice, page, total_pages
end

---@param labels table[]
local function render_list(labels)
	local page_items, page, total_pages = paginate(labels, M.state.page)
	M.state.page = page

	local tag_icon = icons.get("ui", "tag")
	local B = P:begin_render()

	-- Summary bar: tag icon + label count (+ page, once there's more than one).
	local summary = {
		{ components.spacing.gutter, nil },
		{ tag_icon ~= "" and (tag_icon .. "  ") or "", "GitflowSectionIcon" },
		{ ("%d label%s"):format(#labels, #labels == 1 and "" or "s"), "GitflowSectionTitle" },
	}
	if #labels >= FETCH_LIMIT then
		-- `gh label list` has no cursor pagination: say the count is a cap,
		-- never report a truncated fetch as the repo's total.
		summary[#summary + 1] = { components.separators.field .. "capped at ", "GitflowMetaKey" }
		summary[#summary + 1] = { tostring(FETCH_LIMIT), "GitflowMeta" }
	end
	if total_pages > 1 then
		summary[#summary + 1] = { components.separators.field .. "page ", "GitflowMetaKey" }
		summary[#summary + 1] = { ("%d/%d"):format(page, total_pages), "GitflowMeta" }
	end
	B:push(summary)
	B:blank()

	components.section(B, tag_icon, "Repository Labels")

	local line_entries = {}
	if #labels == 0 then
		components.empty(B, "(no labels)")
	else
		for _, label in ipairs(page_items) do
			local name = components.maybe_text(label.name)
			local color = components.maybe_text(label.color)
			local description = components.maybe_text(label.description)

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
	else
		-- A failed paint must not leave the previous rows resolvable.
		P:clear_entry_maps()
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
	M.state.page = 1
	if not P:ensure_window(cfg) then
		return
	end
	-- Instant paint from what we already have (if any), then reconcile below.
	local cached = scoped_cache()
	if cached then
		render_list(cached)
	end
	M.refresh()
end

function M.refresh()
	if not M.state.cfg then
		return
	end

	local request_id = P:next_request()
	-- The scope this fetch is issued under: a cwd change while it is in flight
	-- must not stamp its rows as belonging to the new repo.
	local requested_key = cache_key()
	if not scoped_cache() then
		P:render_loading("Loading labels…")
	end
	gh_labels.list({ limit = FETCH_LIMIT }, {}, function(err, labels)
		if not P:is_active(request_id) then
			return
		end
		if err then
			utils.notify(err, vim.log.levels.ERROR)
			-- Drop the cache and paint the failure even when rows are on
			-- screen: stale rows left actionable resolve `d` against a fetch
			-- that failed.
			M.state.cache, M.state.cache_key = nil, nil
			P:render_error("Failed to load labels", {
				detail = err,
				hint = "r retries",
			})
			return
		end
		M.state.cache = labels or {}
		M.state.cache_key = requested_key
		M.state.page = 1
		render_list(M.state.cache)
	end)
end

---Advance to the next page of the cached list.
function M.next_page()
	local cached = scoped_cache()
	if not cached then
		return
	end
	local _, _, total_pages = paginate(cached, M.state.page)
	if M.state.page >= total_pages then
		utils.notify("No more labels", vim.log.levels.WARN)
		return
	end
	M.state.page = M.state.page + 1
	render_list(cached)
end

---Return to the previous page of the cached list.
function M.prev_page()
	local cached = scoped_cache()
	if not cached or M.state.page <= 1 then
		utils.notify("Already on the first page", vim.log.levels.WARN)
		return
	end
	M.state.page = M.state.page - 1
	render_list(cached)
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

	local label_name = components.maybe_text(entry.name)
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
