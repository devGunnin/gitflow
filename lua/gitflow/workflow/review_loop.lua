local M = {}

local REOPENABLE_PHASES = {
	merge_ready = true,
	verified = true,
}

---@param phase string
---@return boolean
function M.should_restart_on_user_comment(phase)
	return REOPENABLE_PHASES[phase] == true
end

---@param comment table|string|nil
---@return string|nil
local function extract_comment_body(comment)
	local raw = comment
	if type(comment) == "table" then
		raw = comment.body
	end

	if type(raw) ~= "string" then
		return nil
	end

	local trimmed = vim.trim(raw:gsub("\r\n", "\n"))
	if trimmed == "" then
		return nil
	end
	return trimmed
end

---@param state table
---@param comment table|string|nil
---@return boolean restarted
---@return table next_state
function M.apply_user_comment(state, comment)
	if type(state) ~= "table" then
		error("review_loop.apply_user_comment: state must be a table", 2)
	end

	local phase = state.phase
	if type(phase) ~= "string" or phase == "" then
		error("review_loop.apply_user_comment: state.phase must be a non-empty string", 2)
	end

	local next_state = vim.deepcopy(state)
	local body = extract_comment_body(comment)
	if not body then
		return false, next_state
	end

	if not M.should_restart_on_user_comment(phase) then
		return false, next_state
	end

	next_state.phase = "fix_required"
	next_state.cycle = (tonumber(next_state.cycle) or 0) + 1
	next_state.latest_feedback = body

	local history = next_state.feedback_history
	if type(history) ~= "table" then
		history = {}
	end
	history[#history + 1] = {
		source = "user_comment",
		body = body,
		created_at = type(comment) == "table" and comment.created_at or nil,
	}
	next_state.feedback_history = history

	next_state.merge_ready_at = nil
	next_state.verified_at = nil
	return true, next_state
end

return M
