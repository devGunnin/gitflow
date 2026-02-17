local gh = require("gitflow.gh")

local M = {}

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

---@param log_output string
---@return GitflowActionLogSnippets
local function parse_failed_log_snippets(log_output)
	---@type GitflowActionLogSnippets
	local snippets = {
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
				local snippet = snippets.by_step[step_key]
					or job_snippet
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

---@param params table|nil
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
			if result.code == 0 then
				local log_output = gh.output(result)
				if log_output ~= "" then
					attach_failed_log_snippets(run, log_output)
				end
			end
			cb(nil, run)
		end)
	end)
end

return M
