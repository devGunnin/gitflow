--- The `?` overlay: one scrollable help buffer, generated from a keymap
--- registry rather than written by hand.
---
--- Every gitflow key surface declares its keys once (`ui/panel.lua`'s keymap
--- registry, or an equivalent list registered with it). This module turns such
--- a list into a buffer the user can scroll and search — the discoverability
--- surface the float footer and the split hint bar can only approximate,
--- because both of them elide to fit.
---
--- Nothing here is hand-maintained: if a key is not in a registry it does not
--- appear, and if it is, it does.

local buffer = require("gitflow.ui.buffer")
local window = require("gitflow.ui.window")
local ui_render = require("gitflow.ui.render")
local components = require("gitflow.ui.components")

---@class GitflowHelpRow
---@field key string
---@field desc string
---@field destructive boolean|nil

---@class GitflowHelpSection
---@field label string|nil  nil for the leading, unlabelled block
---@field rows GitflowHelpRow[]

local M = {}

local BUFFER_NAME = "help"

---@type { bufnr: integer|nil, winid: integer|nil }
M.state = { bufnr = nil, winid = nil }

---Group a keymap registry into help sections.
---
---An entry's `views` is the set of contexts it belongs to — the panel base
---filters hints on it, review mode reuses it as the legend group — so it is
---also the natural heading here. Entries that apply everywhere lead,
---unlabelled; the rest follow under each view, in first-seen order, so the
---overlay reads in the order the panel declared its keys.
---@param keymaps GitflowPanelKeymap[]
---@return GitflowHelpSection[]
function M.sections_from_keymaps(keymaps)
	local global_rows = {}
	local by_label, order = {}, {}

	for _, entry in ipairs(keymaps or {}) do
		if entry.desc then
			local row = {
				key = entry.key,
				desc = entry.desc,
				destructive = entry.destructive,
			}
			if not entry.views or #entry.views == 0 then
				global_rows[#global_rows + 1] = row
			else
				for _, label in ipairs(entry.views) do
					if not by_label[label] then
						by_label[label] = {}
						order[#order + 1] = label
					end
					local rows = by_label[label]
					rows[#rows + 1] = row
				end
			end
		end
	end

	local sections = {}
	if #global_rows > 0 then
		sections[#sections + 1] = { label = nil, rows = global_rows }
	end
	for _, label in ipairs(order) do
		sections[#sections + 1] = { label = label, rows = by_label[label] }
	end
	return sections
end

---Widest key label across every section, so the description column lines up.
---@param sections GitflowHelpSection[]
---@return integer
local function key_column_width(sections)
	local width = 0
	for _, section in ipairs(sections) do
		for _, row in ipairs(section.rows) do
			width = math.max(width, vim.fn.strdisplaywidth(row.key))
		end
	end
	return width
end

---@param B GitflowRenderBuilder
---@param sections GitflowHelpSection[]
local function push_sections(B, sections)
	local key_width = key_column_width(sections)
	for index, section in ipairs(sections) do
		if index > 1 then
			B:blank()
		end
		if section.label then
			B:push({
				{ ui_render.spacing.gutter, nil },
				{ section.label:upper(), "GitflowHintGroupLabel" },
			})
		end
		for _, row in ipairs(section.rows) do
			B:push({
				{ ui_render.spacing.indent, nil },
				{ ui_render.pad_right(row.key, key_width), "GitflowHintKey" },
				{ "  ", nil },
				{
					row.desc,
					row.destructive and "GitflowRemoved" or "GitflowHintText",
				},
			})
		end
	end
end

---The overlay's own keys, advertised in its footer so the way out is visible
---even though the buffer scrolls past the bottom of the window.
local OWN_HINTS = { { "j/k", "scroll" }, { "q", "close" } }

---@return string
local function footer_text()
	local parts = {}
	for _, hint in ipairs(OWN_HINTS) do
		parts[#parts + 1] = hint[1] .. " " .. hint[2]
	end
	return " " .. table.concat(parts, " " .. ui_render.glyphs.bullet .. " ") .. " "
end

function M.is_open()
	return M.state.bufnr ~= nil and vim.api.nvim_buf_is_valid(M.state.bufnr)
end

function M.close()
	if M.state.winid then
		window.close(M.state.winid)
	else
		window.close(BUFFER_NAME)
	end
	if M.state.bufnr then
		buffer.teardown(M.state.bufnr)
	else
		buffer.teardown(BUFFER_NAME)
	end
	M.state.bufnr = nil
	M.state.winid = nil
end

---Open the overlay. Always a float when the terminal can hold one: it is a
---transient reference over whatever the user was looking at, and replacing
---their panel with it would lose the very context they asked about.
---@param cfg GitflowConfig
---@param opts { title: string, sections: GitflowHelpSection[], note?: string }
---@return boolean opened
function M.open(cfg, opts)
	if M.is_open() then
		M.close()
	end

	local B = ui_render.builder()
	B:blank()
	push_sections(B, opts.sections or {})
	if opts.note then
		B:blank()
		B:push({ { ui_render.spacing.gutter, nil }, { opts.note, "GitflowMeta" } })
	end
	B:blank()

	local bufnr = buffer.create(BUFFER_NAME, {
		filetype = "gitflowhelp",
		lines = B.lines,
	})
	M.state.bufnr = bufnr

	local winid = window.open_float({
		name = BUFFER_NAME,
		bufnr = bufnr,
		width = cfg.ui.float.width,
		height = cfg.ui.float.height,
		border = cfg.ui.float.border,
		title = ("  %s  "):format(opts.title),
		title_pos = cfg.ui.float.title_pos,
		footer = cfg.ui.float.footer and footer_text() or nil,
		footer_pos = cfg.ui.float.footer_pos,
		on_close = function()
			M.state.winid = nil
		end,
	})
	if not winid then
		-- open_float already said why; leave no orphaned buffer behind.
		M.close()
		return false
	end
	M.state.winid = winid

	B:flush(bufnr, bufnr, vim.api.nvim_create_namespace("gitflow_help_hl"))
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	components.cursorline(winid, false)

	for _, key in ipairs({ "q", "<Esc>", "?" }) do
		vim.keymap.set("n", key, function()
			M.close()
		end, { buffer = bufnr, silent = true, nowait = true })
	end

	return true
end

return M
