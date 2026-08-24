local gh = require("gitflow.gh")

local M = {}

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = gh.output(result)
	if output == "" then
		return ("gh run %s failed"):format(action)
	end
	return ("gh run %s failed: %s"):format(action, output)
end

local RUN_LIST_FIELDS = table.concat({
	"databaseId",
	"name",
	"headBranch",
	"status",
	"conclusion",
	"event",
	"createdAt",
	"updatedAt",
	"url",
	"displayTitle",
}, ",")

local RUN_VIEW_FIELDS = table.concat({
	"databaseId",
	"name",
	"headBranch",
	"status",
	"conclusion",
	"event",
	"createdAt",
	"updatedAt",
	"url",
	"displayTitle",
	"jobs",
}, ",")

---@class GitflowActionRun
---@field id integer
---@field name string
---@field branch string
---@field status string
---@field conclusion string
---@field event string
---@field created_at string
---@field updated_at string
---@field url string
---@field display_title string
---@field jobs GitflowActionJob[]|nil
---@field log_error string|nil why the failed-job logs could not be fetched

---@class GitflowActionJob
---@field id integer
---@field name string
---@field status string
---@field conclusion string
---@field started_at string
---@field completed_at string
---@field log_snippet string|nil
---@field steps GitflowActionStep[]|nil

---@class GitflowActionStep
---@field name string
---@field status string
---@field conclusion string
---@field number integer
---@field started_at string
---@field completed_at string
---@field log_snippet string|nil

---@class GitflowActionLogSnippets
---@field by_job_step table<string, string>
---@field by_job table<string, string>
---@field by_step table<string, string>
---@field fallback string|nil

---@param raw table
---@return GitflowActionRun
local function normalize_run(raw)
	return {
		id = tonumber(raw.databaseId) or 0,
		name = raw.name or "",
		branch = raw.headBranch or "",
		status = (raw.status or ""):lower(),
		conclusion = (raw.conclusion or ""):lower(),
		event = raw.event or "",
		created_at = raw.createdAt or "",
		updated_at = raw.updatedAt or "",
		url = raw.url or "",
		display_title = raw.displayTitle or raw.name or "",
	}
end

---@param raw table
---@return GitflowActionJob
local function normalize_job(raw)
	local steps = {}
	for _, raw_step in ipairs(raw.steps or {}) do
		steps[#steps + 1] = {
			name = raw_step.name or "",
			status = (raw_step.status or ""):lower(),
			conclusion = (raw_step.conclusion or ""):lower(),
			number = tonumber(raw_step.number) or 0,
			started_at = raw_step.startedAt or "",
			completed_at = raw_step.completedAt or "",
			log_snippet = nil,
		}
	end
	return {
		id = tonumber(raw.databaseId) or tonumber(raw.id) or 0,
		name = raw.name or "",
		status = (raw.status or ""):lower(),
		conclusion = (raw.conclusion or ""):lower(),
		started_at = raw.startedAt or "",
		completed_at = raw.completedAt or "",
		log_snippet = nil,
		steps = steps,
	}
end

---@param value any
---@return string
local function normalize_key(value)
	return vim.trim(tostring(value or "")):lower()
end

---@param value any
---@return string
local function normalize_snippet(value)
	local text = vim.trim(tostring(value or ""))
	text = text:gsub("%s+", " ")
	if #text > 120 then
		text = text:sub(1, 117) .. "..."
	end
	return text
end

---@param job_name any
---@param step_name any
---@return string|nil
local function normalize_job_step_key(job_name, step_name)
	local job_key = normalize_key(job_name)
	local step_key = normalize_key(step_name)
	if job_key == "" or step_key == "" then
		return nil
	end
	return ("%s\t%s"):format(job_key, step_key)
end

---@param log_output string
---@return GitflowActionLogSnippets
local function parse_failed_log_snippets(log_output)
	---@type GitflowActionLogSnippets
	local snippets = {
		by_job_step = {},
		by_job = {},
		by_step = {},
		fallback = nil,
	}

	for _, raw_line in ipairs(vim.split(
		log_output or "",
		"\n",
		{ plain = true, trimempty = true }
	)) do
		local line = vim.trim(raw_line)
		if line == "" then
			goto continue
		end

		local job_name, step_name, message = line:match(
			"^([^\t]+)\t([^\t]+)\t(.+)$"
		)
		local candidate = normalize_snippet(message or "")
		if job_name and step_name and candidate ~= "" then
			local job_key = normalize_key(job_name)
			local step_key = normalize_key(step_name)
			local job_step_key = normalize_job_step_key(job_name, step_name)
			if job_step_key and not snippets.by_job_step[job_step_key] then
				snippets.by_job_step[job_step_key] = candidate
			end
			if job_key ~= "" and not snippets.by_job[job_key] then
				snippets.by_job[job_key] = candidate
			end
			if step_key ~= "" and not snippets.by_step[step_key] then
				snippets.by_step[step_key] = candidate
			end
			if not snippets.fallback then
				snippets.fallback = candidate
			end
			goto continue
		end

		local lowered = line:lower()
		if lowered:find("error", 1, true)
			or lowered:find("fail", 1, true)
			or lowered:find("exception", 1, true)
		then
			local fallback = normalize_snippet(line)
			if fallback ~= "" and not snippets.fallback then
				snippets.fallback = fallback
			end
		end

		::continue::
	end

	return snippets
end

---@param run GitflowActionRun
---@param log_output string
local function attach_failed_log_snippets(run, log_output)
	if type(run.jobs) ~= "table" or #run.jobs == 0 then
		return
	end

	local snippets = parse_failed_log_snippets(log_output or "")
	for _, job in ipairs(run.jobs) do
		local job_key = normalize_key(job.name)
		local job_snippet = snippets.by_job[job_key]
		for _, step in ipairs(job.steps or {}) do
			local failed = step.conclusion == "failure"
				or step.status == "failed"
			if failed then
				local step_key = normalize_key(step.name)
				local job_step_key = normalize_job_step_key(job.name, step.name)
				local snippet = (job_step_key and snippets.by_job_step[job_step_key])
					or job_snippet
					or snippets.by_step[step_key]
					or snippets.fallback
				if snippet and snippet ~= "" then
					step.log_snippet = snippet
					if not job.log_snippet or job.log_snippet == "" then
						job.log_snippet = snippet
					end
				end
			end
		end
	end
end

---@param raw table
---@return GitflowActionRun
local function normalize_run_with_jobs(raw)
	local run = normalize_run(raw)
	local jobs = {}
	for _, raw_job in ipairs(raw.jobs or {}) do
		jobs[#jobs + 1] = normalize_job(raw_job)
	end
	run.jobs = jobs
	return run
end

---@param run GitflowActionRun
---@return string
function M.status_icon(run)
	local conclusion = run.conclusion
	if conclusion == "success" then
		return "✓"
	elseif conclusion == "failure" then
		return "✗"
	elseif conclusion == "cancelled" then
		return "⊘"
	elseif conclusion == "skipped" then
		return "⊘"
	end

	local status = run.status
	if status == "in_progress" or status == "queued"
		or status == "waiting" or status == "pending" then
		return "●"
	end

	return "?"
end

---@param run GitflowActionRun
---@return string
function M.status_highlight(run)
	local conclusion = run.conclusion
	if conclusion == "success" then
		return "GitflowActionsPass"
	elseif conclusion == "failure" then
		return "GitflowActionsFail"
	elseif conclusion == "cancelled" or conclusion == "skipped" then
		return "GitflowActionsCancelled"
	end

	local status = run.status
	if status == "in_progress" or status == "queued"
		or status == "waiting" or status == "pending" then
		return "GitflowActionsPending"
	end

	return "Comment"
end

---@class GitflowActionListParams
---@field branch string|nil  nil/"" means all branches
---@field limit integer|nil
---@field workflow string|nil  workflow name or filename
---@field status string|nil  gh's --status enum (e.g. "success", "in_progress")
---@field event string|nil  triggering event (e.g. "push", "pull_request")
---@field actor string|nil  triggering GitHub username

---@param params GitflowActionListParams|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, runs: GitflowActionRun[]|nil)
function M.list(params, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil)
		return
	end

	local options = params or {}
	local args = { "run", "list", "--json", RUN_LIST_FIELDS }

	if options.branch and options.branch ~= "" then
		args[#args + 1] = "--branch"
		args[#args + 1] = tostring(options.branch)
	end
	if options.limit and tonumber(options.limit) then
		args[#args + 1] = "--limit"
		args[#args + 1] = tostring(options.limit)
	end
	if options.workflow and options.workflow ~= "" then
		args[#args + 1] = "--workflow"
		args[#args + 1] = tostring(options.workflow)
	end
	if options.status and options.status ~= "" then
		args[#args + 1] = "--status"
		args[#args + 1] = tostring(options.status)
	end
	if options.event and options.event ~= "" then
		args[#args + 1] = "--event"
		args[#args + 1] = tostring(options.event)
	end
	if options.actor and options.actor ~= "" then
		args[#args + 1] = "--user"
		args[#args + 1] = tostring(options.actor)
	end

	gh.json(args, opts, function(err, data)
		if err then
			cb(err, nil)
			return
		end
		local runs = {}
		for _, raw in ipairs(data or {}) do
			runs[#runs + 1] = normalize_run(raw)
		end
		cb(nil, runs)
	end)
end

---@param run_id integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, run: GitflowActionRun|nil)
function M.view(run_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil)
		return
	end

	local args = {
		"run", "view", tostring(run_id), "--json", RUN_VIEW_FIELDS,
	}

	gh.json(args, opts, function(err, data)
		if err then
			cb(err, nil)
			return
		end
		if not data or vim.tbl_isempty(data) then
			cb("No data returned for run " .. tostring(run_id), nil)
			return
		end
		local run = normalize_run_with_jobs(data)
		gh.run({
			"run",
			"view",
			tostring(run_id),
			"--log-failed",
		}, opts, function(result)
			if result.code ~= 0 then
				-- Snippets are enrichment, not the payload: the run itself
				-- loaded, so report it with the log failure recorded on it
				-- rather than discarding valid data or claiming success.
				run.log_error = error_from_result(
					result,
					("view %s --log-failed"):format(run_id)
				)
				cb(nil, run)
				return
			end

			local log_output = gh.output(result)
			if log_output ~= "" then
				attach_failed_log_snippets(run, log_output)
			end
			cb(nil, run)
		end)
	end)
end

---GitHub Actions runs only ever settle into "completed" — every other status
---(queued, in_progress, waiting, pending, requested, action_required) is
---still in flight. This is the single stop condition the watch poller uses.
---@param status string
---@return boolean
function M.is_terminal_status(status)
	return status == "completed"
end

---Strip ANSI SGR/cursor escapes and OSC-8 hyperlink wrappers from raw `gh`
---log text so a log buffer shows plain readable lines.
---@param text string
---@return string
function M.strip_ansi(text)
	text = text or ""
	-- OSC 8 hyperlinks: ESC ] 8 ; params ; uri BEL ... ESC ] 8 ; ; BEL
	text = text:gsub("\27%]8;[^\7]*\7", "")
	-- CSI sequences: ESC [ ... <letter> (colors, cursor movement, erase).
	text = text:gsub("\27%[[%d;]*[A-Za-z]", "")
	-- Any remaining lone escape byte.
	text = text:gsub("\27", "")
	return text
end

---@param raw_line string
---@return string|nil job, string|nil step, string message
local function split_log_line(raw_line)
	local job, step, message = raw_line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
	if job and step then
		return job, step, message
	end
	return nil, nil, raw_line
end

---Format raw tab-separated `gh run view --log[-failed]` text into readable,
---ANSI-stripped lines with a rule header whenever the job/step changes.
---@param log_output string
---@param opts { show_job: boolean }|nil
---@return string[]
local function format_log_lines(log_output, opts)
	local show_job = opts == nil or opts.show_job ~= false
	local lines = {}
	local last_job, last_step = nil, nil

	for _, raw_line in ipairs(vim.split(
		log_output or "", "\n", { plain = true, trimempty = true }
	)) do
		local job, step, message = split_log_line(raw_line)
		if job and (job ~= last_job or step ~= last_step) then
			local header = show_job
				and ("── %s / %s "):format(job, step)
				or ("── %s "):format(step)
			lines[#lines + 1] = header
				.. string.rep("─", math.max(0, 70 - #header))
			last_job, last_step = job, step
		end
		lines[#lines + 1] = M.strip_ansi(message)
	end

	return lines
end

---Line number (1-based, into `lines`) of the first line that looks like a
---GitHub Actions error annotation or an "error"/"fail"/"exception" mention.
---Mirrors the heuristic in parse_failed_log_snippets, applied to a flat log.
---@param lines string[]
---@return integer|nil
function M.find_first_error_line(lines)
	for index, line in ipairs(lines) do
		if line:find("##%[error%]") then
			return index
		end
	end
	for index, line in ipairs(lines) do
		local lowered = line:lower()
		if lowered:find("error", 1, true)
			or lowered:find("fail", 1, true)
			or lowered:find("exception", 1, true)
		then
			return index
		end
	end
	return nil
end

---Full run log (every job/step), ANSI-stripped and readable in a buffer.
---@param run_id integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, lines: string[]|nil)
function M.log(run_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil)
		return
	end

	gh.run({ "run", "view", tostring(run_id), "--log" }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, ("view %s --log"):format(run_id)), nil)
			return
		end
		cb(nil, format_log_lines(gh.output(result)))
	end)
end

---Single-job log, ANSI-stripped. Step headers only (the job is already fixed).
---@param run_id integer|string
---@param job_id integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, lines: string[]|nil)
function M.job_log(run_id, job_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil)
		return
	end

	gh.run({
		"run", "view", tostring(run_id), "--job", tostring(job_id), "--log",
	}, opts, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(
					result,
					("view %s --job %s --log"):format(run_id, job_id)
				),
				nil
			)
			return
		end
		cb(nil, format_log_lines(gh.output(result), { show_job = false }))
	end)
end

---@param run_id integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.rerun(run_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run({ "run", "rerun", tostring(run_id) }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, ("rerun %s"):format(run_id)), result)
			return
		end
		cb(nil, result)
	end)
end

---@param run_id integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.rerun_failed(run_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run(
		{ "run", "rerun", tostring(run_id), "--failed" },
		opts,
		function(result)
			if result.code ~= 0 then
				cb(
					error_from_result(result, ("rerun %s --failed"):format(run_id)),
					result
				)
				return
			end
			cb(nil, result)
		end
	)
end

---@param run_id integer|string
---@param job_id integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.rerun_job(run_id, job_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run(
		{ "run", "rerun", tostring(run_id), "--job", tostring(job_id) },
		opts,
		function(result)
			if result.code ~= 0 then
				cb(
					error_from_result(
						result,
						("rerun %s --job %s"):format(run_id, job_id)
					),
					result
				)
				return
			end
			cb(nil, result)
		end
	)
end

---@param run_id integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.cancel(run_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run({ "run", "cancel", tostring(run_id) }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, ("cancel %s"):format(run_id)), result)
			return
		end
		cb(nil, result)
	end)
end

---@class GitflowActionWorkflow
---@field id integer
---@field name string
---@field path string
---@field state string

---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, workflows: GitflowActionWorkflow[]|nil)
function M.workflow_list(opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil)
		return
	end

	gh.json(
		{ "workflow", "list", "--json", "id,name,path,state" },
		opts,
		function(err, data)
			if err then
				cb(err, nil)
				return
			end
			local workflows = {}
			for _, raw in ipairs(data or {}) do
				workflows[#workflows + 1] = {
					id = tonumber(raw.id) or 0,
					name = raw.name or "",
					path = raw.path or "",
					state = raw.state or "",
				}
			end
			cb(nil, workflows)
		end
	)
end

---Dispatch a `workflow_dispatch` event. No interactive inputs are collected —
---only workflow-level `on.workflow_dispatch` triggers with no required inputs
---are supported this way (a scoped decision, see the PR description).
---@param workflow string  workflow id, filename, or name
---@param ref string|nil  branch/tag to dispatch on; nil uses the default
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.workflow_run(workflow, ref, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local args = { "workflow", "run", tostring(workflow) }
	if ref and ref ~= "" then
		args[#args + 1] = "--ref"
		args[#args + 1] = tostring(ref)
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(result, ("workflow run %s"):format(workflow)),
				result
			)
			return
		end
		cb(nil, result)
	end)
end

return M
