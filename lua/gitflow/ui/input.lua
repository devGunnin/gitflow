---@class GitflowPromptOpts
---@field prompt string
---@field default? string
---@field completion? string|fun(arglead: string, cmdline: string, cursorpos: integer): string[]
---@field on_cancel? fun()

---@class GitflowConfirmOpts
---@field choices? string[]
---@field default_choice? integer
---@field on_choice? fun(confirmed: boolean, index: integer)

local M = {}
local next_completion_id = 0
local next_cancel_id = 0

---@param completion string|fun(arglead: string, cmdline: string, cursorpos: integer): string[]|nil
---@return string|nil, fun()
local function resolve_completion(completion)
	if type(completion) ~= "function" then
		return completion, function() end
	end

	next_completion_id = next_completion_id + 1
	local completion_name = ("__gitflow_input_completion_%d"):format(next_completion_id)

	_G[completion_name] = function(arglead, cmdline, cursorpos)
		local ok, candidates = pcall(completion, arglead or "", cmdline or "", cursorpos or 0)
		if not ok or type(candidates) ~= "table" then
			return {}
		end

		local normalized = {}
		for _, candidate in ipairs(candidates) do
			local text = vim.trim(tostring(candidate))
			if text ~= "" then
				normalized[#normalized + 1] = text
			end
		end
		return normalized
	end

	local cleanup = function()
		_G[completion_name] = nil
	end

	return "customlist,v:lua." .. completion_name, cleanup
end

---@param opts GitflowPromptOpts
---@param completion string
---@return string|nil
local function prompt_with_builtin_completion(opts, completion)
	next_cancel_id = next_cancel_id + 1
	local cancel_token = ("__gitflow_prompt_cancel_%d__"):format(next_cancel_id)

	vim.fn.inputsave()
	local ok, value = pcall(vim.fn.input, {
		prompt = opts.prompt,
		default = opts.default or "",
		completion = completion,
		cancelreturn = cancel_token,
	})
	vim.fn.inputrestore()

	if not ok then
		if opts.on_cancel then
			opts.on_cancel()
		end
		return nil
	end

	local text = tostring(value or "")
	if text == cancel_token then
		if opts.on_cancel then
			opts.on_cancel()
		end
		return nil
	end
	return text
end

---@param opts GitflowPromptOpts
---@param on_confirm fun(value: string)
function M.prompt(opts, on_confirm)
	local completion, cleanup_completion = resolve_completion(opts.completion)
	if completion then
		local value = prompt_with_builtin_completion(opts, completion)
		cleanup_completion()
		if value == nil then
			return
		end
		on_confirm(value)
		return
	end

	vim.ui.input({
		prompt = opts.prompt,
		default = opts.default,
		completion = completion,
	}, function(input)
		cleanup_completion()
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
