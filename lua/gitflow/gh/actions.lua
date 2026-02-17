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
---@field name string
---@field status string
---@field conclusion string
---@field started_at string
---@field completed_at string
---@field steps GitflowActionStep[]|nil

---@class GitflowActionStep
---@field name string
---@field status string
---@field conclusion string
---@field number integer

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
		}
	end
	return {
		name = raw.name or "",
		status = (raw.status or ""):lower(),
		conclusion = (raw.conclusion or ""):lower(),
		started_at = raw.startedAt or "",
		completed_at = raw.completedAt or "",
		steps = steps,
	}
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
		cb(nil, normalize_run_with_jobs(data))
	end)
end

return M
