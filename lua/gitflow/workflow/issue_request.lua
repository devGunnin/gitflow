local M = {}

local ISSUE_ONLY_PATTERNS = {
	"create issues",
	"open issues",
	"file issues",
	"issue breakdown",
	"issue plan",
	"issue list",
	"issues only",
	"issue only",
}

local CODE_CHANGE_PATTERNS = {
	"fix ",
	"implement ",
	"add ",
	"change ",
	"update ",
	"refactor ",
	"patch ",
	"write test",
	"create pr",
	"open pr",
	"pull request",
}

local EXPLICIT_NO_PR_PATTERNS = {
	"no pr",
	"without pr",
	"do not create a pr",
	"don't create a pr",
	"do not open a pr",
	"don't open a pr",
	"do not solve with a pr",
	"don't solve with a pr",
}

---@param value unknown
---@return string
local function normalize_text(value)
	if type(value) ~= "string" then
		return ""
	end

	local normalized = value:lower():gsub("\r\n", "\n"):gsub("%s+", " ")
	return vim.trim(normalized)
end

---@param text string
---@param patterns string[]
---@return boolean
local function includes_any(text, patterns)
	for _, pattern in ipairs(patterns) do
		if text:find(pattern, 1, true) ~= nil then
			return true
		end
	end
	return false
end

---@param request table
---@return string
local function request_text(request)
	local segments = {}
	for _, key in ipairs({ "title", "body", "prompt", "instruction", "request", "description" }) do
		if type(request[key]) == "string" and request[key] ~= "" then
			segments[#segments + 1] = request[key]
		end
	end
	return normalize_text(table.concat(segments, "\n"))
end

---@class GitflowIssueRequestDecision
---@field should_create_pr boolean
---@field reason string

---@param request table
---@return GitflowIssueRequestDecision
function M.classify(request)
	if type(request) ~= "table" then
		error("issue_request.classify: request must be a table", 2)
	end

	local task_type = normalize_text(request.task_type or request.kind or request.mode)
	if task_type == "issue_agent" or task_type == "issue_only" then
		return {
			should_create_pr = false,
			reason = "issue_only_task_type",
		}
	end

	local text = request_text(request)
	if text == "" then
		return {
			should_create_pr = true,
			reason = "default_create_pr",
		}
	end

	if includes_any(text, EXPLICIT_NO_PR_PATTERNS) then
		return {
			should_create_pr = false,
			reason = "explicit_no_pr",
		}
	end

	local issue_only = includes_any(text, ISSUE_ONLY_PATTERNS)
	local code_change = includes_any(text, CODE_CHANGE_PATTERNS)
	if issue_only and not code_change then
		return {
			should_create_pr = false,
			reason = "issue_only_intent",
		}
	end

	return {
		should_create_pr = true,
		reason = "default_create_pr",
	}
end

---@param request table
---@return boolean
function M.should_create_pr(request)
	return M.classify(request).should_create_pr
end

return M
