local M = {}

---@param value string|nil
---@return string
local function normalize(value)
	return vim.trim(tostring(value or ""))
end

---@param hint table|string
---@return string|nil
local function format_hint(hint)
	if type(hint) == "string" then
		local text = normalize(hint)
		if text ~= "" then
			return text
		end
		return nil
	end

	if type(hint) ~= "table" then
		return nil
	end

	local key = normalize(hint.key or hint[1])
	local label = normalize(hint.label or hint.action or hint[2])
	if key == "" and label == "" then
		return nil
	end
	if key == "" then
		return label
	end
	if label == "" then
		return key
	end
	return ("%s %s"):format(key, label)
end

---@param hints table[]|string[]|string
---@return string
function M.format_key_hints(hints)
	if type(hints) == "string" then
		return normalize(hints)
	end

	if type(hints) ~= "table" then
		return ""
	end

	local parts = {}
	for _, hint in ipairs(hints) do
		local formatted = format_hint(hint)
		if formatted then
			parts[#parts + 1] = formatted
		end
	end

	return table.concat(parts, "  ")
end

---@class GitflowApplyPanelHighlightsOpts
---@field title_line integer|nil
---@field footer_line integer|nil
---@field header_lines integer[]|nil
---@field line_groups table<integer, string>|nil

---@param bufnr integer
---@param namespace integer
---@param opts GitflowApplyPanelHighlightsOpts|nil
function M.apply_panel_highlights(bufnr, namespace, opts)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local options = opts or {}
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

	if options.title_line and options.title_line > 0 then
		vim.api.nvim_buf_add_highlight(
			bufnr,
			namespace,
			"GitflowTitle",
			options.title_line - 1,
			0,
			-1
		)
	end

	if options.footer_line and options.footer_line > 0 then
		vim.api.nvim_buf_add_highlight(
			bufnr,
			namespace,
			"GitflowFooter",
			options.footer_line - 1,
			0,
			-1
		)
	end

	for _, line in ipairs(options.header_lines or {}) do
		if line > 0 then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				namespace,
				"GitflowHeader",
				line - 1,
				0,
				-1
			)
		end
	end

	for line, group in pairs(options.line_groups or {}) do
		if line > 0 and type(group) == "string" and group ~= "" then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				namespace,
				group,
				line - 1,
				0,
				-1
			)
		end
	end
end

return M
