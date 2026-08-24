--- Submitting the review: turning local drafts into what GitHub's APIs accept,
--- posting them, and only then clearing the on-disk draft cache.
---
--- Drafts are the user's unsent work, so nothing here throws one away that has
--- not been confirmed as posted: a partially-failed submit marks each file
--- comment as it lands (and persists that), and the cache is cleared only once
--- the review itself is accepted.

local input = require("gitflow.ui.input")
local gh_prs = require("gitflow.gh.prs")
local cache = require("gitflow.review.cache")
local rstate = require("gitflow.review.state")

local M = {}
local state = rstate.state

--- Split pending drafts into the reviews-batch payload (line/range comments)
--- and file-level comments. File comments are returned separately because
--- the reviews API rejects any comment without a line (→ 422); they're posted
--- via the review-comments API with subject_type=file instead (#361).
---@return table[]|nil  line/range comments for the reviews API
---@return table[]  file-level comments ({ path, body, draft })
---@return string|nil  error message if any draft can't be resolved
local function collect_api_comments()
	local api = {}
	local file_comments = {}
	local unresolved = {}
	for _, pc in ipairs(state.pending_comments) do
		-- File-level comments (#361): posted separately, never in the
		-- reviews batch payload.
		if pc.file_level then
			-- Each file comment is its own API call, so a submit that fails
			-- part-way leaves some already on the PR. Skipping those is what
			-- stops a retry from posting them a second time.
			if pc.posted then
				goto continue
			end
			if pc.path and pc.path ~= "" then
				file_comments[#file_comments + 1] = {
					path = pc.path,
					body = pc.body,
					draft = pc,
				}
			else
				unresolved[#unresolved + 1] = tostring(pc.id or "?")
			end
			goto continue
		end

		local entry = { path = pc.path, body = pc.body }
		if pc.new_line then
			entry.line = pc.new_line
			entry.side = "RIGHT"
		elseif pc.old_line then
			entry.line = pc.old_line
			entry.side = "LEFT"
		end

		if pc.start_new_line then
			entry.start_line = pc.start_new_line
			entry.start_side = "RIGHT"
		elseif pc.start_old_line then
			entry.start_line = pc.start_old_line
			entry.start_side = "LEFT"
		end

		-- A multi-line comment needs start_line strictly above line on the
		-- same side; collapse degenerate/inverted ranges to a single line.
		if entry.start_line and entry.line
			and (entry.start_side ~= entry.side
				or entry.start_line >= entry.line) then
			entry.start_line = nil
			entry.start_side = nil
		end

		-- Final safety net against a 422: the anchor must be a line that is
		-- actually present in the PR diff on the chosen side.
		local resolvable = entry.path and entry.path ~= ""
			and rstate.diff_has_line(entry.path, entry.line, entry.side)
		if resolvable and entry.start_line then
			resolvable = rstate.diff_has_line(
				entry.path, entry.start_line, entry.start_side)
		end

		if resolvable then
			api[#api + 1] = entry
		else
			unresolved[#unresolved + 1] = tostring(pc.id or "?")
		end
		::continue::
	end
	if #unresolved > 0 then
		return nil, {}, (
			"%d comment(s) don't map to a line in the PR diff (ids: %s). "
			.. "This usually means the PR branch isn't checked out — run "
			.. "`gh pr checkout <N>`, reopen the review, and re-add them."
		):format(#unresolved, table.concat(unresolved, ", "))
	end
	return api, file_comments, nil
end

---@param mode "approve"|"request_changes"|"comment"
---@param body string
---@param on_success_message string
local function submit_review_with_pending(mode, body, on_success_message)
	local number = state.pr_number
	if not number then
		rstate.notify_warn("No pull request selected for review")
		return
	end
	local function refresh()
		require("gitflow.review.load").refresh()
	end

	if #state.pending_comments == 0 then
		gh_prs.review(number, mode, body, {}, function(err)
			if err then
				rstate.notify_error(err)
				return
			end
			rstate.notify_info(on_success_message)
			refresh()
		end)
		return
	end

	local api_comments, file_comments, collect_err = collect_api_comments()
	if collect_err then
		rstate.notify_warn(collect_err)
		return
	end

	-- Step 2 (runs after any file comments are posted): submit the review,
	-- batching line/range comments through the reviews API.
	local function finish_review()
		local total = #state.pending_comments
		local trimmed_body = vim.trim(body or "")

		local function on_done(err)
			if err then
				rstate.notify_error(err)
				return
			end
			state.pending_comments = {}
			cache.clear(number, state.repo_slug)
			rstate.notify_info(
				("Review submitted (%s) with %d comment(s)"):format(mode, total))
			refresh()
		end

		-- A COMMENT review with no body and no inline comments is rejected
		-- by GitHub (422). If the only drafts were file-level (already
		-- posted), don't submit an empty review — just clear and refresh.
		if #api_comments == 0 and mode == "comment" and trimmed_body == "" then
			state.pending_comments = {}
			cache.clear(number, state.repo_slug)
			rstate.notify_info(on_success_message)
			refresh()
			return
		end

		if #api_comments == 0 then
			gh_prs.review(number, mode, body, {}, on_done)
		else
			gh_prs.submit_review(number, mode, body, api_comments, {}, on_done)
		end
	end

	-- Step 1: post file-level comments via the review-comments API (the
	-- reviews batch API can't carry them → 422).
	if #file_comments == 0 then
		finish_review()
		return
	end

	local commit_id = state.pr_head_sha
	if not commit_id or commit_id == "" then
		rstate.notify_error(
			"Cannot post file-level comment: PR head commit is unknown. "
			.. "Press r to refresh the review and try again."
		)
		return
	end

	local idx = 0
	local function post_next()
		idx = idx + 1
		if idx > #file_comments then
			finish_review()
			return
		end
		local fc = file_comments[idx]
		gh_prs.create_file_comment(
			number, commit_id, fc.path, fc.body, {},
			function(err)
				if err then
					rstate.notify_error(("File comment on %s failed: %s\n"
						.. "(%d of %d already posted; retrying will not "
						.. "repost them.)"):format(
						fc.path, err, idx - 1, #file_comments))
					return
				end
				-- Record the post before moving on, and persist it, so a
				-- crash or a retry can't duplicate it on the PR.
				fc.draft.posted = true
				rstate.persist_pending()
				post_next()
			end
		)
	end
	post_next()
end

---@param mode "approve"|"request_changes"|"comment"
---@param prompt string
---@param success string
local function prompt_and_submit(mode, prompt, success)
	input.prompt({
		multiline = true,
		title = prompt:gsub(":%s*$", ""),
		draft_key = ("review:%s:submit:%s"):format(
			tostring(state.pr_number), mode),
	}, function(body)
		submit_review_with_pending(mode, body or "", success)
	end)
end

function M.review_approve()
	prompt_and_submit(
		"approve",
		"Approval message (optional): ",
		"Review submitted (approved)"
	)
end

function M.review_request_changes()
	prompt_and_submit(
		"request_changes",
		"Request changes message: ",
		"Review submitted (changes requested)"
	)
end

function M.review_comment()
	prompt_and_submit(
		"comment",
		"Review comment (optional): ",
		"Review submitted (comment)"
	)
end

--- Single entry point for submitting a review. Opens a dropdown to pick mode
--- (comment / request_changes / approve), then prompts for an optional body,
--- then submits — batching any pending inline comments through the reviews API.
function M.submit_pending_review()
	local number = state.pr_number
	if not number then
		rstate.notify_warn("No pull request selected for review")
		return
	end

	local choices = {
		{ key = "comment", label = "Comment",
			detail = "Leave a review without approval" },
		{ key = "request_changes", label = "Request changes",
			detail = "Block merge until addressed" },
		{ key = "approve", label = "Approve",
			detail = "Approve this PR for merge" },
	}

	local pending = #state.pending_comments
	local prompt = pending > 0
		and ("Submit %d pending comment(s) as:"):format(pending)
		or "Submit review as:"

	vim.ui.select(choices, {
		prompt = prompt,
		format_item = function(item)
			return ("%-18s  %s"):format(item.label, item.detail)
		end,
	}, function(choice)
		if not choice then
			return
		end
		local mode = choice.key

		input.prompt({
			multiline = true,
			title = ("%s message"):format(choice.label),
			draft_key = ("review:%s:submit:%s"):format(tostring(number), mode),
		}, function(body_in)
			submit_review_with_pending(
				mode, vim.trim(body_in or ""),
				("Review submitted (%s)"):format(mode)
			)
		end)
	end)
end

---@param mode "approve"|"request_changes"|"comment"
---@param body string
function M.submit_review_direct(mode, body)
	submit_review_with_pending(mode, body,
		("Review submitted (%s)"):format(mode))
end

--- Reply to the most recent review on a PR from the command line. Does not
--- need review mode to be open.
---@param number integer|string
function M.respond_to_review(number)
	local pr_num = rstate.as_integer(number)
	if not pr_num then
		rstate.notify_error("Invalid PR number for respond")
		return
	end
	gh_prs.list_reviews(pr_num, {}, function(err, reviews)
		if err then
			rstate.notify_error(err)
			return
		end
		if not reviews or #reviews == 0 then
			rstate.notify_warn("No reviews found on this PR")
			return
		end
		local latest = reviews[#reviews]
		local author = ""
		if type(latest.user) == "table" and latest.user.login then
			author = latest.user.login
		end
		input.prompt({
			multiline = true,
			title = ("Reply to @%s's review"):format(author),
			draft_key = ("review:%s:response:%s"):format(tostring(pr_num), author),
		}, function(reply)
			local body = vim.trim(reply or "")
			if body == "" then
				rstate.notify_warn("Reply cannot be empty")
				return
			end
			gh_prs.comment(pr_num, body, {}, function(cerr)
				if cerr then
					rstate.notify_error(cerr)
					return
				end
				rstate.notify_info(("Response posted to PR #%d"):format(pr_num))
			end)
		end)
	end)
end

return M
