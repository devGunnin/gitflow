local buffer = require("gitflow.ui.buffer")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("GitflowRender")
local DEFAULT_SEPARATOR_LENGTH = 48

---@class GitflowRenderHighlight
---@field line integer
---@field group string
---@field from integer
---@field to integer

---@class GitflowRenderSpec
---@field lines string[]
---@field highlights GitflowRenderHighlight[]

---@class GitflowKeyHint
---@field key string
---@field label string

---@return GitflowRenderSpec
function M.new()
	return {
		lines = {},
		highlights = {},
	}
end

---@param spec GitflowRenderSpec
---@param text string
---@return integer
function M.line(spec, text)
	spec.lines[#spec.lines + 1] = text
	return #spec.lines
end

---@param spec GitflowRenderSpec
---@param line integer
---@param group string
---@param from integer|nil
---@param to integer|nil
function M.highlight(spec, line, group, from, to)
	spec.highlights[#spec.highlights + 1] = {
		line = line - 1,
		group = group,
		from = from or 0,
		to = to or -1,
	}
end

---@param text string
---@param min_length integer|nil
---@return string
function M.separator(text, min_length)
	local size = min_length or DEFAULT_SEPARATOR_LENGTH
	local content = text or ""
	local length = math.max(size, #content)
	return string.rep("─", length)
end

---@param spec GitflowRenderSpec
---@param title string
function M.title(spec, title)
	local line = M.line(spec, (" %s "):format(title))
	M.highlight(spec, line, "GitflowTitle")

	local separator = M.line(spec, M.separator(title, math.max(24, #title + 2)))
	M.highlight(spec, separator, "GitflowSeparator")

	M.line(spec, "")
end

---@param spec GitflowRenderSpec
---@param header string
function M.section(spec, header)
	local line = M.line(spec, header)
	M.highlight(spec, line, "GitflowSection")

	local separator = M.line(spec, ("  %s"):format(M.separator(header, math.max(16, #header + 2))))
	M.highlight(spec, separator, "GitflowSeparator", 2, -1)
end

---@param spec GitflowRenderSpec
---@param text string
---@param group string|nil
---@return integer
function M.entry(spec, text, group)
	local line = M.line(spec, ("  %s"):format(text))
	if group then
		M.highlight(spec, line, group, 2, -1)
	end
	return line
end

---@param spec GitflowRenderSpec
---@param message string
---@return integer
function M.empty(spec, message)
	local line = M.line(spec, ("  (%s)"):format(message))
	M.highlight(spec, line, "GitflowMuted", 2, -1)
	return line
end

---@param spec GitflowRenderSpec
function M.blank(spec)
	M.line(spec, "")
end

---@param hints GitflowKeyHint[]
---@return string
function M.format_key_hints(hints)
	local parts = {}
	for _, hint in ipairs(hints) do
		parts[#parts + 1] = ("[%s] %s"):format(hint.key, hint.label)
	end
	return table.concat(parts, "  ")
end

---@param spec GitflowRenderSpec
---@param hints GitflowKeyHint[]
function M.footer(spec, hints)
	M.blank(spec)

	local separator = M.line(spec, M.separator("", DEFAULT_SEPARATOR_LENGTH))
	M.highlight(spec, separator, "GitflowSeparator")

	local text = M.format_key_hints(hints)
	local line = M.line(spec, text)
	M.highlight(spec, line, "GitflowFooter")

	local cursor = 0
	for _, hint in ipairs(hints) do
		local chunk = ("[%s] %s"):format(hint.key, hint.label)
		local key_start = cursor + 1
		local key_end = key_start + #hint.key
		M.highlight(spec, line, "GitflowKeyHint", key_start, key_end)
		cursor = cursor + #chunk + 2
	end
end

---@param bufnr integer
---@param spec GitflowRenderSpec
function M.apply(bufnr, spec)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
	for _, hl in ipairs(spec.highlights) do
		vim.api.nvim_buf_add_highlight(
			bufnr,
			NAMESPACE,
			hl.group,
			hl.line,
			hl.from,
			hl.to
		)
	end
end

---@param target string|integer
---@param spec GitflowRenderSpec
function M.commit(target, spec)
	buffer.update(target, spec.lines)

	local bufnr = target
	if type(target) ~= "number" then
		bufnr = buffer.get(target)
	end
	if type(bufnr) == "number" then
		M.apply(bufnr, spec)
	end
end

return M
