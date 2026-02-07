---@class GitflowPromptOpts
---@field prompt string
---@field default? string
---@field completion? string
---@field on_cancel? fun()

---@class GitflowConfirmOpts
---@field choices? string[]
---@field default_choice? integer
---@field on_choice? fun(confirmed: boolean, index: integer)

local M = {}

---@param opts GitflowPromptOpts
---@param on_confirm fun(value: string)
function M.prompt(opts, on_confirm)
	vim.ui.input({
		prompt = opts.prompt,
		default = opts.default,
		completion = opts.completion,
	}, function(input)
		if input == nil then
			if opts.on_cancel then
				opts.on_cancel()
			end
			return
		end
		on_confirm(input)
	end)
end

---@param message string
---@param opts GitflowConfirmOpts|nil
---@return boolean, integer
function M.confirm(message, opts)
	local options = opts or {}
	local choices = options.choices or { "&Yes", "&No" }
	local default_choice = options.default_choice or 2
	local index = vim.fn.confirm(message, table.concat(choices, "\n"), default_choice)
	local confirmed = index == 1
	if options.on_choice then
		options.on_choice(confirmed, index)
	end
	return confirmed, index
end

return M
