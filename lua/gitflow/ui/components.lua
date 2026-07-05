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
M.is_floating = ui_render.is_floating

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

---Push an empty-state line, optionally with a leading icon and a dim action
---hint underneath. Called with just (B, text) it stays a single muted line so
---existing callers and last-line invariants are unchanged.
---@param B GitflowRenderBuilder
---@param text string
---@param opts table|nil  { icon = string, hint = string }
---@return integer line_no
function M.empty(B, text, opts)
	opts = opts or {}
	if opts.icon == nil and opts.hint == nil then
		return B:push({ { "   ", nil }, { text, "GitflowMeta" } })
	end
	local icon = opts.icon
	if icon == nil then
		icon = icons.get("ui", "empty")
	end
	local line_no = B:push({
		{ "   ", nil },
		{ (icon ~= "" and icon .. "  " or ""), "GitflowEmptyIcon" },
		{ text, "GitflowEmptyText" },
	})
	if opts.hint and opts.hint ~= "" then
		B:push({ { "   ", nil }, { opts.hint, "GitflowEmptyHint" } })
	end
	return line_no
end

---Push a styled loading state: a leading glyph plus a label, with an optional
---dim detail line. Replaces bare "Loading…" text so every surface shows the
---same cohesive in-progress affordance.
---@param B GitflowRenderBuilder
---@param label string
---@param opts table|nil  { icon = string, detail = string, leading = string }
---@return integer line_no
function M.loading(B, label, opts)
	opts = opts or {}
	local icon = opts.icon
	if icon == nil then
		icon = icons.get("ui", "loading")
	end
	local lead = opts.leading or "  "
	local line_no = B:push({
		{ lead, nil },
		{ (icon ~= "" and icon .. "  " or ""), "GitflowLoadingIcon" },
		{ label, "GitflowLoadingText" },
	})
	if opts.detail and opts.detail ~= "" then
		B:push({ { lead, nil }, { opts.detail, "GitflowEmptyHint" } })
	end
	return line_no
end

---Build a plain (un-highlighted) loading placeholder for buffer creation, used
---as the brief first paint before a panel renders its highlighted content.
---@param label string|nil
---@return string[]
function M.loading_lines(label)
	return { "", "  " .. icons.get("ui", "loading") .. "  " .. (label or "Loading…") }
end

---Push a real in-buffer error state: an error glyph + message, with an optional
---dim detail line and a retry hint. Surfaces failures inside the panel instead
---of relying only on a transient notification.
---@param B GitflowRenderBuilder
---@param message string
---@param opts table|nil  { detail = string, hint = string }
---@return integer line_no
function M.error_state(B, message, opts)
	opts = opts or {}
	local line_no = B:push({
		{ "  ", nil },
		{ icons.get("ui", "error") .. "  ", "GitflowStateErrorIcon" },
		{ message, "GitflowStateError" },
	})
	if opts.detail and opts.detail ~= "" then
		for _, detail_line in ipairs(vim.split(opts.detail, "\n", { plain = true })) do
			if vim.trim(detail_line) ~= "" then
				B:push({ { "     ", nil }, { detail_line, "GitflowStateErrorDetail" } })
			end
		end
	end
	if opts.hint and opts.hint ~= "" then
		B:blank()
		B:push({ { "  ", nil }, { opts.hint, "GitflowEmptyHint" } })
	end
	return line_no
end

---Push a grouped key-hint block: a dim group label followed by its hint pairs
---on the next line. Keeps dense surfaces (e.g. the PR review panel) scannable
---instead of a flat wall of hints.
---@param B GitflowRenderBuilder
---@param label string
---@param pairs table[]  list of { key, label }
---@return integer line_no
function M.hint_group(B, label, pairs)
	B:push({
		{ "  ", nil },
		{ label, "GitflowHintGroupLabel" },
	})
	return B:push(ui_render.hint_chunks(pairs, { leading = "    " }))
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

---Push an in-buffer key-hint bar, but only when the panel is an inline split.
---Floats already advertise the same keys in their window footer, so showing a
---second bar inside the buffer would be redundant; splits otherwise have no
---hint chrome at all. This keeps discoverability symmetric across layouts.
---@param B GitflowRenderBuilder
---@param render_opts table|nil  { winid?, bufnr? }
---@param pairs table[]  list of { key, label }
---@param opts table|nil  { blank_before = boolean }
---@return integer|nil line_no  nil when rendered as a float (nothing pushed)
function M.split_hint_bar(B, render_opts, pairs, opts)
	if M.is_floating(render_opts) then
		return nil
	end
	opts = opts or {}
	if opts.blank_before ~= false then
		B:blank()
	end
	return M.hint_bar(B, pairs)
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
