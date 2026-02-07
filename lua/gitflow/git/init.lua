---@class GitflowGitRunOpts
---@field cwd? string
---@field env? table<string, string>
---@field stdin? string|string[]

---@class GitflowGitResult
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string
---@field cmd string[]

local M = {}

---@param value string|string[]|nil
---@return string|nil
local function normalize_stdin(value)
	if value == nil then
		return nil
	end
	if type(value) == "table" then
		return table.concat(value, "\n")
	end
	return value
end

---@param input string[]
---@return string[]
local function normalize_command(input)
	local cmd = {}
	for _, part in ipairs(input) do
		cmd[#cmd + 1] = tostring(part)
	end
	return cmd
end

---@param chunks string[]
---@return string
local function concat_chunks(chunks)
	if #chunks == 0 then
		return ""
	end
	return table.concat(chunks, "\n")
end

---@param output string[]
---@param data string[]|nil
local function append_output(output, data)
	if not data or #data == 0 then
		return
	end

	if #data == 1 and data[1] == "" then
		return
	end

	output[#output + 1] = table.concat(data, "\n")
end

---@param cmd string[]
---@param opts GitflowGitRunOpts
---@param on_exit fun(result: GitflowGitResult)
local function run_with_system(cmd, opts, on_exit)
	local system_opts = {
		text = true,
		cwd = opts.cwd,
		env = opts.env,
		stdin = normalize_stdin(opts.stdin),
	}

	vim.system(cmd, system_opts, function(result)
		vim.schedule(function()
			on_exit({
				code = result.code or 1,
				signal = result.signal or 0,
				stdout = result.stdout or "",
				stderr = result.stderr or "",
				cmd = cmd,
			})
		end)
	end)
end

---@param cmd string[]
---@param opts GitflowGitRunOpts
---@param on_exit fun(result: GitflowGitResult)
local function run_with_jobstart(cmd, opts, on_exit)
	local stdout_chunks = {}
	local stderr_chunks = {}

	local job_opts = {
		stdout_buffered = true,
		stderr_buffered = true,
		cwd = opts.cwd,
		env = opts.env,
		on_stdout = function(_, data)
			append_output(stdout_chunks, data)
		end,
		on_stderr = function(_, data)
			append_output(stderr_chunks, data)
		end,
		on_exit = function(_, code, signal)
			vim.schedule(function()
				on_exit({
					code = code or 1,
					signal = signal or 0,
					stdout = concat_chunks(stdout_chunks),
					stderr = concat_chunks(stderr_chunks),
					cmd = cmd,
				})
			end)
		end,
	}

	local job_id = vim.fn.jobstart(cmd, job_opts)
	if job_id <= 0 then
		vim.schedule(function()
			on_exit({
				code = 1,
				signal = 0,
				stdout = "",
				stderr = ("Failed to start command: %s"):format(table.concat(cmd, " ")),
				cmd = cmd,
			})
		end)
		return
	end

	local stdin = normalize_stdin(opts.stdin)
	if stdin and stdin ~= "" then
		vim.fn.chansend(job_id, stdin)
		vim.fn.chanclose(job_id, "stdin")
	end
end

---@param cmd string[]
---@param opts GitflowGitRunOpts|nil
---@param on_exit fun(result: GitflowGitResult)
function M.run(cmd, opts, on_exit)
	if type(cmd) ~= "table" or #cmd == 0 then
		error("gitflow git error: run(cmd, opts, on_exit) requires a non-empty command array", 2)
	end
	if type(on_exit) ~= "function" then
		error("gitflow git error: run(cmd, opts, on_exit) requires a callback", 2)
	end

	local normalized_cmd = normalize_command(cmd)
	local run_opts = opts or {}

	if vim.system then
		run_with_system(normalized_cmd, run_opts, on_exit)
		return
	end

	run_with_jobstart(normalized_cmd, run_opts, on_exit)
end

---@param args string[]
---@param opts GitflowGitRunOpts|nil
---@param on_exit fun(result: GitflowGitResult)
function M.git(args, opts, on_exit)
	if type(args) ~= "table" then
		error("gitflow git error: git(args, opts, on_exit) requires args table", 2)
	end

	local cmd = { "git" }
	for _, arg in ipairs(args) do
		cmd[#cmd + 1] = arg
	end
	M.run(cmd, opts, on_exit)
end

---@param result GitflowGitResult
---@return string
function M.output(result)
	local stdout = vim.trim(result.stdout or "")
	local stderr = vim.trim(result.stderr or "")

	if stdout ~= "" and stderr ~= "" then
		return stdout .. "\n" .. stderr
	end
	if stdout ~= "" then
		return stdout
	end
	if stderr ~= "" then
		return stderr
	end
	return ""
end

return M
