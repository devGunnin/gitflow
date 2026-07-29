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

---@alias GitflowGhFailureKind
---| '"missing"'    gh is not on PATH
---| '"auth"'       not logged in, or the token was rejected
---| '"network"'    gh could not reach the GitHub host
---| '"permission"' authenticated, but the token lacks rights (HTTP 403)
---| '"not_found"'  absent, or invisible to this account (HTTP 404)
---| '"unknown"'    no signal we can classify — report raw output only

--- Classify a failed `gh` invocation from its combined output.
--- Every pattern here was observed from a real gh (2.95.0); none are guessed.
--- Network is tested first: a connection failure otherwise reads as auth.
---@param output string
---@return GitflowGhFailureKind
function M.classify_failure(output)
	local text = (output or ""):lower()

	if
		text:find("error connecting to", 1, true)
		or text:find("check your internet connection", 1, true)
	then
		return "network"
	end
	if
		text:find("not logged into any github hosts", 1, true)
		or text:find("failed to log in to", 1, true)
		or text:find("bad credentials", 1, true)
		or text:find("(http 401)", 1, true)
	then
		return "auth"
	end
	if text:find("(http 403)", 1, true) then
		return "permission"
	end
	if text:find("(http 404)", 1, true) then
		return "not_found"
	end

	return "unknown"
end

---@type table<GitflowGhFailureKind, string>
local FAILURE_HINTS = {
	missing = "Install the GitHub CLI (https://cli.github.com) and make sure `gh` is on your PATH.",
	auth = "Run `gh auth login` to authenticate, then retry.",
	network = "Could not reach GitHub — check your connection or https://www.githubstatus.com.",
	permission = "Your token lacks the required permission. `gh auth status` lists its scopes; `gh auth refresh -s <scope>` adds one.",
	-- GitHub answers 404 for private resources too, so "absent" and
	-- "invisible to you" are indistinguishable and stay deliberately merged.
	not_found = "Not found — it may not exist, or your account may not have access to it. Check the name and your permissions.",
}

--- Actionable recovery step for a failure kind, or nil when we cannot tell.
---@param kind GitflowGhFailureKind
---@return string|nil
function M.failure_hint(kind)
	return FAILURE_HINTS[kind]
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

	git.run(build_command(args), opts, function(result)
		-- An auth-shaped failure means the cached verdict went stale (token
		-- expired, `gh auth logout` elsewhere) — re-check on next use.
		if
			result.code ~= 0
			and M.classify_failure(M.output(result)) == "auth"
		then
			M.state.checked = false
		end
		on_exit(result)
	end)
end

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = M.output(result)
	if output == "" then
		return ("gh %s failed"):format(action)
	end

	-- Hint is appended, never substituted: the raw gh output always survives.
	local message = ("gh %s failed: %s"):format(action, output)
	local hint = M.failure_hint(M.classify_failure(output))
	if hint == nil then
		return message
	end
	return message .. "\n" .. hint
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
			-- Defensive fallback: `gh api --paginate --jq <filter>` emits
			-- concatenated JSON values (one per page) rather than a single
			-- merged value.  If the first parse fails, try splitting the
			-- payload at array/object boundaries and merging the pieces.
			local merged = M._try_merge_concatenated_json(text)
			if merged ~= nil then
				cb(nil, merged, result)
				return
			end
			cb(("Failed to parse gh JSON output for '%s': %s"):format(table.concat(args, " "), decoded), nil, result)
			return
		end

		cb(nil, decoded, result)
	end)
end

--- Attempt to recover a single JSON value from text that is actually
--- multiple concatenated JSON values (e.g. `[…][…][…]` produced by
--- `gh api --paginate --jq .`).  Returns the merged value on success,
--- or nil if the recovery isn't safe.
---@param text string
---@return any|nil
function M._try_merge_concatenated_json(text)
	-- Cheap heuristic: only attempt if it looks like multiple top-level
	-- arrays back-to-back (`][`) — that's the gh --paginate pattern.
	if not text:find("%]%s*%[", 1) then
		return nil
	end

	local merged = {}
	local pos = 1
	local len = #text
	while pos <= len do
		local first = text:sub(pos, pos)
		if first == "" then
			break
		end
		if first ~= "[" and first ~= "{" then
			-- Skip whitespace between values.
			pos = pos + 1
		else
			-- Walk forward, matching brackets while respecting strings,
			-- to find the end of this top-level JSON value.
			local depth = 0
			local in_string = false
			local escape = false
			local end_pos = nil
			for i = pos, len do
				local ch = text:sub(i, i)
				if in_string then
					if escape then
						escape = false
					elseif ch == "\\" then
						escape = true
					elseif ch == '"' then
						in_string = false
					end
				else
					if ch == '"' then
						in_string = true
					elseif ch == "[" or ch == "{" then
						depth = depth + 1
					elseif ch == "]" or ch == "}" then
						depth = depth - 1
						if depth == 0 then
							end_pos = i
							break
						end
					end
				end
			end
			if not end_pos then
				return nil
			end
			local chunk = text:sub(pos, end_pos)
			local ok, value = pcall(vim.json.decode, chunk)
			if not ok then
				return nil
			end
			if type(value) == "table" and value[1] ~= nil then
				for _, item in ipairs(value) do
					merged[#merged + 1] = item
				end
			else
				merged[#merged + 1] = value
			end
			pos = end_pos + 1
		end
	end

	if #merged == 0 then
		return nil
	end
	return merged
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

--- Compose "what happened / the raw output / what to do", skipping empty parts.
---@param summary string
---@param output string
---@param kind GitflowGhFailureKind
---@return string
local function prerequisite_message(summary, output, kind)
	local parts = { summary }
	if output ~= "" then
		parts[#parts + 1] = output
	end
	local hint = M.failure_hint(kind)
	if hint ~= nil then
		parts[#parts + 1] = hint
	end
	return table.concat(parts, "\n")
end

---@param available boolean
---@param message string
---@param opts GitflowGhPrerequisiteCheckOpts
---@return false, string
local function fail_prerequisites(available, message, opts)
	M.state = {
		checked = true,
		available = available,
		authenticated = false,
		message = message,
	}
	notify_prerequisite_error(message, opts)
	return false, message
end

--- Probe gh once, synchronously. `gh auth status` calls the GitHub API, so
--- this must stay off the startup path — see M.ensure_prerequisites.
---@param opts GitflowGhPrerequisiteCheckOpts|nil
---@return boolean, string|nil
function M.check_prerequisites(opts)
	local options = opts or {}

	if vim.fn.executable("gh") ~= 1 then
		return fail_prerequisites(
			false,
			prerequisite_message(
				"GitHub CLI (gh) was not found on your PATH.",
				"",
				"missing"
			),
			options
		)
	end

	local version_result = run_sync({ "--version" })
	if version_result.code ~= 0 then
		local output = M.output(version_result)
		return fail_prerequisites(
			false,
			prerequisite_message(
				"`gh --version` failed, so the GitHub CLI is not usable.",
				output,
				M.classify_failure(output)
			),
			options
		)
	end

	local auth_result = run_sync({ "auth", "status" })
	if auth_result.code ~= 0 then
		local output = M.output(auth_result)
		local kind = M.classify_failure(output)
		local summary = "GitHub CLI is not authenticated."
		if kind == "network" then
			summary = "Could not reach GitHub to check your GitHub CLI login."
		elseif kind == "unknown" then
			-- `gh auth status` only fails for login reasons; an unrecognised
			-- message is still an auth problem, and the output is shown as-is.
			kind = "auth"
		end
		return fail_prerequisites(
			true,
			prerequisite_message(summary, output, kind),
			options
		)
	end

	M.state = {
		checked = true,
		available = true,
		authenticated = true,
		message = nil,
	}

	return true, nil
end

--- Gate for every GitHub-dependent command. The first call pays the probe;
--- later calls reuse the cached verdict until an auth-shaped failure in M.run
--- clears it. Nothing checks gh at startup, so this is where an
--- unauthenticated user finds out.
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
