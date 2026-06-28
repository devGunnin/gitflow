--- Shared UI components for gitflow panels.
---
--- These build on ui/render.lua's line+span builder to give every panel the
--- same visual language: icon-led section headers, aligned metadata rows,
--- colored label chips, relative timestamps, and styled key-hint bars.

local ui_render = require("gitflow.ui.render")
local highlights = require("gitflow.highlights")
local icons = require("gitflow.icons")

local M = {}

-- Re-exports so panels can pull everything from one module.
M.builder = ui_render.builder
M.relative_time = ui_render.relative_time
M.truncate = ui_render.truncate
M.pad_right = ui_render.pad_right
M.content_width = ui_render.content_width
M.separator = ui_render.separator
M.is_separator = ui_render.is_separator

---@param value any
---@return string
function M.maybe_text(value)
	local text = vim.trim(tostring(value or ""))
	if text == "" then
		return "-"
	end
	return text
end

---Push a panel header (inline title + separator for splits, separator for
---floats) into the builder, styling the title and rule.
---@param B GitflowRenderBuilder
---@param title string
---@param render_opts table|nil  { winid?, bufnr? }
function M.header(B, title, render_opts)
	for _, line in ipairs(ui_render.panel_header(title, render_opts)) do
		B:raw(
			line,
			ui_render.is_separator(line) and "GitflowSeparator" or "GitflowTitle"
		)
	end
end

---Push an icon-led section header with a thin underline.
---@param B GitflowRenderBuilder
---@param icon string
---@param title string
function M.section(B, icon, title)
	B:push({
		{ " ", nil },
		{ (icon ~= "" and icon .. "  " or ""), "GitflowSectionIcon" },
		{ title, "GitflowSectionTitle" },
	})
	B:raw(
		" " .. string.rep("-", math.max(8, vim.fn.strdisplaywidth(title) + 4)),
		"GitflowSeparator"
	)
end

---Push a single-line summary/header bar: ` <icon>  <Title>   key value …`.
---@param B GitflowRenderBuilder
---@param icon string
---@param title string
---@param extras table[]|nil  list of { key=string, value=string } dim chips
---@return integer line_no
function M.summary(B, icon, title, extras)
	local chunks = {
		{ "  ", nil },
		{ (icon ~= "" and icon .. "  " or ""), "GitflowSectionIcon" },
		{ title, "GitflowSectionTitle" },
	}
	for _, extra in ipairs(extras or {}) do
		local key = extra.key or extra[1]
		local value = extra.value or extra[2]
		if key then
			chunks[#chunks + 1] = { "     " .. key .. " ", "GitflowMetaKey" }
		end
		if value ~= nil then
			chunks[#chunks + 1] = { tostring(value), "GitflowMeta" }
		end
	end
	return B:push(chunks)
end

---Push an aligned metadata row: `  Key:        value…`.
---@param B GitflowRenderBuilder
---@param key string
---@param value_chunks table[]
---@param opts table|nil  { width = integer (default 12) }
---@return integer line_no
function M.meta_row(B, key, value_chunks, opts)
	local width = (opts and opts.width) or 12
	local chunks = {
		{ "  ", nil },
		{ ui_render.pad_right(key, width), "GitflowMetaKey" },
	}
	for _, chunk in ipairs(value_chunks) do
		chunks[#chunks + 1] = chunk
	end
	return B:push(chunks)
end

---Build colored chip chunks for a list of labels.
---@param labels table|nil  array of { name, color } tables or strings
---@param opts table|nil  { empty = string (default em-dash), sep = string }
---@return table[]
function M.label_chunks(labels, opts)
	opts = opts or {}
	local empty = opts.empty or "\u{2014}"
	local sep = opts.sep or " "
	if type(labels) ~= "table" or #labels == 0 then
		return { { empty, "GitflowMeta" } }
	end
	local chunks = {}
	for _, label in ipairs(labels) do
		local name = type(label) == "table" and label.name
			or (type(label) == "string" and label or nil)
		if name and name ~= "" then
			if #chunks > 0 then
				chunks[#chunks + 1] = { sep, "GitflowMeta" }
			end
			local color = type(label) == "table" and label.color
			local group = color and highlights.label_color_group(color)
				or "GitflowChip"
			chunks[#chunks + 1] = { name, group }
		end
	end
	if #chunks == 0 then
		return { { empty, "GitflowMeta" } }
	end
	return chunks
end

---Push an empty-state line.
---@param B GitflowRenderBuilder
---@param text string
---@return integer line_no
function M.empty(B, text)
	return B:push({ { "   ", nil }, { text, "GitflowMeta" } })
end

---Push a styled inline key-hint bar.
---@param B GitflowRenderBuilder
---@param pairs table[]  list of { key, label }
---@param opts table|nil
---@return integer line_no
function M.hint_bar(B, pairs, opts)
	return B:push(ui_render.hint_chunks(pairs, vim.tbl_extend(
		"force", { leading = " " }, opts or {}
	)))
end

---Push a final "Current branch: <branch>" footer line. Must be the LAST line
---pushed (some panels/tests read the last buffer line).
---@param B GitflowRenderBuilder
---@param branch string|nil
---@return integer line_no
function M.branch_footer(B, branch)
	return B:push({
		{ "Current branch: ", "GitflowMetaKey" },
		{ tostring(branch or ""), "GitflowBranchCurrent" },
	})
end

---Toggle cursorline on a window (best-effort).
---@param winid integer|nil
---@param on boolean
function M.cursorline(winid, on)
	if winid and vim.api.nvim_win_is_valid(winid) then
		pcall(vim.api.nvim_set_option_value, "cursorline", on, { win = winid })
	end
end

---Convenience icon getter.
---@param category string
---@param name string
---@return string
function M.icon(category, name)
	return icons.get(category, name)
end

return M
