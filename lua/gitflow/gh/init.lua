local git = require("gitflow.git")
local utils = require("gitflow.utils")

---@class GitflowGhPrerequisiteState
---@field checked boolean
---@field available boolean
---@field authenticated boolean
---@field message string|nil

---@class GitflowGhPrerequisiteCheckOpts
---@field notify? boolean

local M = {}

---@type GitflowGhPrerequisiteState
M.state = {
	checked = false,
	available = false,
	authenticated = false,
	message = nil,
}

---@param args string[]
---@return string[]
local function build_command(args)
	local cmd = { "gh" }
	for _, arg in ipairs(args or {}) do
		cmd[#cmd + 1] = tostring(arg)
	end
	return cmd
end

---@param result GitflowGitResult
---@return string
function M.output(result)
	return git.output(result)
end

---@param args string[]
---@param opts GitflowGitRunOpts|nil
---@param on_exit fun(result: GitflowGitResult)
function M.run(args, opts, on_exit)
	if type(args) ~= "table" then
		error("gitflow gh error: run(args, opts, on_exit) requires args table", 2)
	end
	if type(on_exit) ~= "function" then
		error("gitflow gh error: run(args, opts, on_exit) requires callback", 2)
	end

	git.run(build_command(args), opts, on_exit)
end

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = M.output(result)
	if output == "" then
		return ("gh %s failed"):format(action)
	end
	return ("gh %s failed: %s"):format(action, output)
end

---@param args string[]
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, data: any, result: GitflowGitResult)
function M.json(args, opts, cb)
	M.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, table.concat(args, " ")), nil, result)
			return
		end

		local text = vim.trim(result.stdout or "")
		if text == "" then
			cb(nil, {}, result)
			return
		end

		local ok, decoded = pcall(vim.json.decode, text)
		if not ok then
			cb(("Failed to parse gh JSON output for '%s': %s"):format(table.concat(args, " "), decoded), nil, result)
			return
		end

		cb(nil, decoded, result)
	end)
end

---@param args string[]
---@return GitflowGitResult
local function run_sync(args)
	local cmd = build_command(args)
	if vim.system then
		local result = vim.system(cmd, { text = true }):wait()
		return {
			code = result.code or 1,
			signal = result.signal or 0,
			stdout = result.stdout or "",
			stderr = result.stderr or "",
			cmd = cmd,
		}
	end

	local output = vim.fn.system(cmd)
	return {
		code = vim.v.shell_error,
		signal = 0,
		stdout = output or "",
		stderr = "",
		cmd = cmd,
	}
end

---@param message string
---@param opts GitflowGhPrerequisiteCheckOpts|nil
local function notify_prerequisite_error(message, opts)
	local options = opts or {}
	if options.notify == false then
		return
	end
	utils.notify(message, vim.log.levels.ERROR)
end

---@param opts GitflowGhPrerequisiteCheckOpts|nil
---@return boolean, string|nil
function M.check_prerequisites(opts)
	local options = opts or {}

	if vim.fn.executable("gh") ~= 1 then
		local message = "GitHub CLI (gh) is not installed or not in PATH. Install gh to use GitHub commands."
		M.state = {
			checked = true,
			available = false,
			authenticated = false,
			message = message,
		}
		notify_prerequisite_error(message, options)
		return false, message
	end

	local version_result = run_sync({ "--version" })
	if version_result.code ~= 0 then
		local message = error_from_result(version_result, "--version")
		M.state = {
			checked = true,
			available = false,
			authenticated = false,
			message = message,
		}
		notify_prerequisite_error(message, options)
		return false, message
	end

	local auth_result = run_sync({ "auth", "status" })
	if auth_result.code ~= 0 then
		local message = "GitHub CLI is not authenticated. Run `gh auth login` and try again."
		M.state = {
			checked = true,
			available = true,
			authenticated = false,
			message = message,
		}
		notify_prerequisite_error(message, options)
		return false, message
	end

	M.state = {
		checked = true,
		available = true,
		authenticated = true,
		message = nil,
	}

	return true, nil
end

---@return boolean, string|nil
function M.ensure_prerequisites()
	if not M.state.checked then
		return M.check_prerequisites({ notify = true })
	end

	if not M.state.available or not M.state.authenticated then
		local message = M.state.message
			or "GitHub CLI prerequisites are not satisfied. Run `gh auth login` and retry."
		utils.notify(message, vim.log.levels.ERROR)
		return false, message
	end

	return true, nil
end

return M
