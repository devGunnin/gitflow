local gh = require("gitflow.gh")
local git = require("gitflow.git")
local utils = require("gitflow.utils")

local M = {}

--- Heuristic: does this failed `gh pr create` look like the local branch
--- simply hasn't been pushed to a remote yet? If so we can push and retry
--- instead of surfacing a confusing error.
---@param result GitflowGitResult
---@return boolean
local function pr_create_needs_push(result)
	local text = (
		tostring(result.stderr or "") .. " " .. tostring(result.stdout or "")
	):lower()
	return text:find("must first push", 1, true) ~= nil
		or text:find("push the current branch", 1, true) ~= nil
		or text:find("no git remote", 1, true) ~= nil
		or text:find("no commits between", 1, true) ~= nil
		or text:find("head branch", 1, true) ~= nil
			and text:find("not found", 1, true) ~= nil
end

local PR_LIST_FIELDS = table.concat({
	"number",
	"title",
	"state",
	"isDraft",
	"labels",
	"author",
	"assignees",
	"headRefName",
	"baseRefName",
	"updatedAt",
	"mergedAt",
}, ",")

local PR_VIEW_FIELDS = table.concat({
	"number",
	"title",
	"body",
	"state",
	"isDraft",
	"labels",
	"author",
	"assignees",
	"headRefName",
	"headRefOid",
	"baseRefName",
	"reviews",
	"reviewRequests",
	"comments",
	"files",
	"statusCheckRollup",
	"mergedAt",
	"createdAt",
	"updatedAt",
}, ",")

---@param value string|string[]|nil
---@return string|nil
local function to_csv(value)
	if value == nil then
		return nil
	end
	if type(value) == "string" then
		local trimmed = vim.trim(value)
		if trimmed == "" then
			return nil
		end
		return trimmed
	end

	local parts = {}
	for _, item in ipairs(value) do
		local trimmed = vim.trim(tostring(item))
		if trimmed ~= "" then
			parts[#parts + 1] = trimmed
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ",")
end

---@param number integer|string
---@return string
local function normalize_number(number)
	if number == nil then
		error("gitflow gh pr error: number is required", 3)
	end
	local value = tostring(number)
	if vim.trim(value) == "" then
		error("gitflow gh pr error: number is required", 3)
	end
	return value
end

---@param result GitflowGitResult
---@param action string
---@return string
local function error_from_result(result, action)
	local output = gh.output(result)
	if output == "" then
		return ("gh pr %s failed"):format(action)
	end
	return ("gh pr %s failed: %s"):format(action, output)
end

---@param result GitflowGitResult
---@return boolean
local function is_project_cards_deprecation_error(result)
	local output = vim.trim(gh.output(result)):lower()
	if output == "" then
		return false
	end
	if output:find("repository.pullrequest.projectcards", 1, true) ~= nil then
		return true
	end
	return output:find("projects (classic) is being deprecated", 1, true) ~= nil
end

---@param result GitflowGitResult
---@param action string
---@return string
local function fallback_error_from_result(result, action)
	local output = gh.output(result)
	if output == "" then
		return ("gh pr edit fallback failed (%s)"):format(action)
	end
	return ("gh pr edit fallback failed (%s): %s"):format(action, output)
end

---@param value string|nil
---@return string[]
local function csv_to_list(value)
	local items = {}
	for _, token in ipairs(vim.split(value or "", ",", { trimempty = true })) do
		local trimmed = vim.trim(token)
		if trimmed ~= "" then
			items[#items + 1] = trimmed
		end
	end
	return items
end

---@param value string
---@return string
local function url_encode(value)
	return (tostring(value):gsub("[^%w%-._~]", function(char)
		return ("%%%02X"):format(string.byte(char))
	end))
end

---@param number integer|string
---@param add_labels string[]
---@param remove_labels string[]
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
local function edit_labels_via_api(number, add_labels, remove_labels, opts, cb)
	local normalized_number = normalize_number(number)
	local endpoint = ("repos/{owner}/{repo}/issues/%s/labels"):format(normalized_number)

	local function success_result(result)
		cb(nil, result or {
			code = 0,
			signal = 0,
			stdout = "PR labels updated via gh api fallback",
			stderr = "",
			cmd = { "gh", "api", "--method", "POST", endpoint },
		})
	end

	local function remove_at(index, last_result)
		if index > #remove_labels then
			success_result(last_result)
			return
		end
		local remove_endpoint = ("%s/%s"):format(endpoint, url_encode(remove_labels[index]))
		gh.run({ "api", "--method", "DELETE", remove_endpoint }, opts, function(result)
			if result.code ~= 0 then
				cb(fallback_error_from_result(result, "remove-label"), result)
				return
			end
			remove_at(index + 1, result)
		end)
	end

	local function run_remove_phase(last_result)
		if #remove_labels == 0 then
			success_result(last_result)
			return
		end
		remove_at(1, last_result)
	end

	if #add_labels == 0 then
		run_remove_phase(nil)
		return
	end

	local add_args = { "api", "--method", "POST", endpoint }
	for _, label in ipairs(add_labels) do
		add_args[#add_args + 1] = "-f"
		add_args[#add_args + 1] = ("labels[]=%s"):format(label)
	end

	gh.run(add_args, opts, function(result)
		if result.code ~= 0 then
			cb(fallback_error_from_result(result, "add-label"), result)
			return
		end
		run_remove_phase(result)
	end)
end

---@param mode string|nil
---@return string|nil
local function normalize_review_mode(mode)
	if mode == nil then
		return "comment"
	end

	local normalized = vim.trim(tostring(mode)):lower()
	if normalized == "" then
		return "comment"
	end

	if normalized == "approve" then
		return "approve"
	end
	if normalized == "request_changes" or normalized == "request-changes" then
		return "request_changes"
	end
	if normalized == "comment" then
		return "comment"
	end
	return nil
end

---@param params table|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, prs: table[]|nil, result: GitflowGitResult)
function M.list(params, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local options = params or {}
	local args = { "pr", "list", "--json", PR_LIST_FIELDS }

	if options.state and options.state ~= "" then
		args[#args + 1] = "--state"
		args[#args + 1] = tostring(options.state)
	end
	if options.base and options.base ~= "" then
		args[#args + 1] = "--base"
		args[#args + 1] = tostring(options.base)
	end
	if options.head and options.head ~= "" then
		args[#args + 1] = "--head"
		args[#args + 1] = tostring(options.head)
	end
	if options.search and options.search ~= "" then
		args[#args + 1] = "--search"
		args[#args + 1] = tostring(options.search)
	end
	if options.limit and tonumber(options.limit) then
		args[#args + 1] = "--limit"
		args[#args + 1] = tostring(options.limit)
	end

	gh.json(args, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data or {}, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, pr: table|nil, result: GitflowGitResult)
function M.view(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.json({
		"pr",
		"view",
		normalize_number(number),
		"--json",
		PR_VIEW_FIELDS,
	}, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, diff_text: string|nil, result: GitflowGitResult)
function M.diff(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run({ "pr", "diff", normalize_number(number) }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "diff"), nil, result)
			return
		end
		cb(nil, result.stdout or "", result)
	end)
end

---@param input table
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, response: table|nil, result: GitflowGitResult)
function M.create(input, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local data = input or {}
	local title = vim.trim(tostring(data.title or ""))
	if title == "" then
		error("gitflow gh pr error: create(input, opts, cb) requires input.title", 2)
	end

	local args = {
		"pr",
		"create",
		"--title",
		title,
		"--body",
		tostring(data.body or ""),
	}

	if data.base and vim.trim(tostring(data.base)) ~= "" then
		args[#args + 1] = "--base"
		args[#args + 1] = tostring(data.base)
	end

	if data.head and vim.trim(tostring(data.head)) ~= "" then
		args[#args + 1] = "--head"
		args[#args + 1] = tostring(data.head)
	end

	if data.draft then
		args[#args + 1] = "--draft"
	end

	local reviewer_csv = to_csv(data.reviewers)
	if reviewer_csv then
		args[#args + 1] = "--reviewer"
		args[#args + 1] = reviewer_csv
	end

	local label_csv = to_csv(data.labels)
	if label_csv then
		args[#args + 1] = "--label"
		args[#args + 1] = label_csv
	end

	local function succeed(result)
		cb(nil, {
			url = vim.trim(result.stdout or ""),
			output = gh.output(result),
		}, result)
	end

	gh.run(args, opts, function(result)
		if result.code == 0 then
			succeed(result)
			return
		end

		-- Smooth over the most common failure: the branch isn't on the remote
		-- yet. Push it (set upstream) and retry once before giving up.
		if pr_create_needs_push(result) then
			utils.notify(
				"Branch not pushed — pushing to origin and retrying…",
				vim.log.levels.INFO
			)
			git.git({ "push", "-u", "origin", "HEAD" }, opts or {}, function(push_result)
				if (push_result.code or 1) ~= 0 then
					local push_output = git.output(push_result)
					local push_error = push_output ~= ""
						and ("git push failed: %s"):format(push_output)
						or "git push failed"
					-- Surface the real push failure; keep the original
					-- create error too, as context for why we pushed.
					cb(
						("%s (%s)"):format(
							push_error, error_from_result(result, "create")
						),
						nil,
						push_result
					)
					return
				end
				gh.run(args, opts, function(retry)
					if retry.code ~= 0 then
						cb(error_from_result(retry, "create"), nil, retry)
						return
					end
					succeed(retry)
				end)
			end)
			return
		end

		cb(error_from_result(result, "create"), nil, result)
	end)
end

---@param number integer|string
---@param body string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.comment(number, body, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local message_body = vim.trim(tostring(body or ""))
	if message_body == "" then
		error("gitflow gh pr error: comment(number, body, opts, cb) requires body", 2)
	end

	gh.run({ "pr", "comment", normalize_number(number), "--body", message_body }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "comment"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param strategy "merge"|"squash"|"rebase"|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.merge(number, strategy, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local merge_strategy = strategy or "merge"
	local args = { "pr", "merge", normalize_number(number) }
	if merge_strategy == "squash" then
		args[#args + 1] = "--squash"
	elseif merge_strategy == "rebase" then
		args[#args + 1] = "--rebase"
	else
		args[#args + 1] = "--merge"
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "merge"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.checkout(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run({ "pr", "checkout", normalize_number(number) }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "checkout"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.close(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	gh.run({ "pr", "close", normalize_number(number) }, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "close"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param input table
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.edit(number, input, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local options = input or {}
	local args = { "pr", "edit", normalize_number(number) }
	local changed = false

	local add_labels = to_csv(options.add_labels)
	if add_labels then
		args[#args + 1] = "--add-label"
		args[#args + 1] = add_labels
		changed = true
	end

	local remove_labels = to_csv(options.remove_labels)
	if remove_labels then
		args[#args + 1] = "--remove-label"
		args[#args + 1] = remove_labels
		changed = true
	end

	local add_assignees = to_csv(options.add_assignees)
	if add_assignees then
		args[#args + 1] = "--add-assignee"
		args[#args + 1] = add_assignees
		changed = true
	end

	local remove_assignees = to_csv(options.remove_assignees)
	if remove_assignees then
		args[#args + 1] = "--remove-assignee"
		args[#args + 1] = remove_assignees
		changed = true
	end

	local reviewers = to_csv(options.reviewers)
	if reviewers then
		args[#args + 1] = "--add-reviewer"
		args[#args + 1] = reviewers
		changed = true
	end

	local add_label_list = csv_to_list(add_labels)
	local remove_label_list = csv_to_list(remove_labels)

	if not changed then
		cb(nil, {
			code = 0,
			signal = 0,
			stdout = "No PR edits requested",
			stderr = "",
			cmd = { "gh", "pr", "edit", normalize_number(number) },
		})
		return
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			local has_label_edits = #add_label_list > 0 or #remove_label_list > 0
			if has_label_edits and not reviewers and is_project_cards_deprecation_error(result) then
				edit_labels_via_api(number, add_label_list, remove_label_list, opts, cb)
				return
			end
			cb(error_from_result(result, "edit"), result)
			return
		end
		cb(nil, result)
	end)
end

--- List files changed in a PR via the GitHub API (paginated).  Each
--- entry has filename / status / additions / deletions / patch.  The
--- `patch` field is omitted by GitHub for files whose diff exceeds the
--- service's per-file size cap (typical limit ≈ 3 MB / ~3000 lines).
---
--- This is preferred over `gh pr diff` because it streams pages and
--- never tries to fit a multi-megabyte diff in a single response.
---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, files: table[]|nil, result: GitflowGitResult)
function M.list_files(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, {
			code = 1, signal = 0, stdout = "",
			stderr = message or "", cmd = { "gh" },
		})
		return
	end

	local endpoint = ("repos/{owner}/{repo}/pulls/%s/files"):format(
		normalize_number(number)
	)
	-- IMPORTANT: do NOT pass `--jq` with `--paginate` for array endpoints.
	-- gh applies the jq filter per-page, which produces concatenated
	-- `[…][…]` output instead of a single merged array.  Without `--jq`,
	-- gh combines all pages into one valid JSON array on its own.
	gh.json({
		"api", endpoint, "--paginate",
	}, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data or {}, result)
	end)
end

--- List the commits that make up a PR (oldest → newest) via the GitHub
--- API.  Each entry has `sha` and `commit.message`.  Used by review mode to
--- scope the diff to a single commit or a range of commits (#363).
---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, commits: table[]|nil, result: GitflowGitResult)
function M.list_commits(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, {
			code = 1, signal = 0, stdout = "",
			stderr = message or "", cmd = { "gh" },
		})
		return
	end

	local endpoint = ("repos/{owner}/{repo}/pulls/%s/commits"):format(
		normalize_number(number)
	)
	-- See note in list_files: `--jq` + `--paginate` corrupts JSON for
	-- multi-page array responses.
	gh.json({
		"api", endpoint, "--paginate",
	}, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data or {}, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, comments: table[]|nil, result: GitflowGitResult)
function M.review_comments(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, {
			code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" },
		})
		return
	end

	local endpoint = ("repos/{owner}/{repo}/pulls/%s/comments"):format(
		normalize_number(number)
	)
	-- See note in list_files: `--jq` + `--paginate` corrupts JSON for
	-- multi-page array responses.
	gh.json({
		"api", endpoint, "--paginate",
	}, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data or {}, result)
	end)
end

---@param number integer|string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, reviews: table[]|nil, result: GitflowGitResult)
function M.list_reviews(number, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, nil, {
			code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" },
		})
		return
	end

	local endpoint = ("repos/{owner}/{repo}/pulls/%s/reviews"):format(
		normalize_number(number)
	)
	-- See note in list_files: `--jq` + `--paginate` corrupts JSON for
	-- multi-page array responses.
	gh.json({
		"api", endpoint, "--paginate",
	}, opts, function(err, data, result)
		if err then
			cb(err, nil, result)
			return
		end
		cb(nil, data or {}, result)
	end)
end

--- Delete a single review comment by its GitHub comment ID.
---@param number integer|string  PR number (for symmetry / future scoping)
---@param comment_id integer
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.delete_review_comment(number, comment_id, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, {
			code = 1, signal = 0, stdout = "",
			stderr = message or "", cmd = { "gh" },
		})
		return
	end

	local id = tonumber(comment_id)
	if not id then
		error(
			"gitflow gh pr error: delete_review_comment requires comment_id",
			2
		)
	end
	id = math.floor(id)

	-- The comment is scoped at the repo level on GitHub's API, not by PR,
	-- but we accept the PR number for symmetry with the other helpers.
	local _ = normalize_number(number)
	local endpoint = ("repos/{owner}/{repo}/pulls/comments/%d"):format(id)
	gh.run({
		"api", endpoint, "--method", "DELETE",
	}, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "delete_review_comment"), result)
			return
		end
		cb(nil, result)
	end)
end

--- Post a file-level review comment (#361).  The reviews batch API can't
--- carry comments without a line, so file comments use the review-comments
--- endpoint with subject_type=file + a commit_id (the PR head SHA).
---@param number integer|string
---@param commit_id string
---@param path string
---@param body string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.create_file_comment(number, commit_id, path, body, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, {
			code = 1, signal = 0, stdout = "",
			stderr = message or "", cmd = { "gh" },
		})
		return
	end

	local normalized_body = vim.trim(tostring(body or ""))
	if normalized_body == "" then
		error("gitflow gh pr error: create_file_comment requires body", 2)
	end
	if not commit_id or vim.trim(tostring(commit_id)) == "" then
		error("gitflow gh pr error: create_file_comment requires commit_id", 2)
	end

	local endpoint = ("repos/{owner}/{repo}/pulls/%s/comments"):format(
		normalize_number(number)
	)
	gh.run({
		"api", endpoint, "--method", "POST",
		-- Raw (-f) fields are always strings: never coerce a body or path.
		"-f", ("path=%s"):format(path),
		"-f", ("body=%s"):format(normalized_body),
		"-f", ("commit_id=%s"):format(commit_id),
		"-f", "subject_type=file",
	}, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "create_file_comment"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param review_id integer
---@param body string
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.reply_to_review_comment(number, review_id, body, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local normalized_body = vim.trim(tostring(body or ""))
	if normalized_body == "" then
		error(
			"gitflow gh pr error: reply_to_review_comment requires body", 2
		)
	end

	local endpoint = ("repos/{owner}/{repo}/pulls/%s/comments/%d/replies"):format(
		normalize_number(number), review_id
	)
	gh.run({
		-- Raw (-f) fields are always strings: never coerce a body or path.
		-- A typed --field treats a leading "@" as a FILENAME to read, and
		-- review replies routinely start with "@username".
		"api", endpoint, "--method", "POST", "-f", ("body=%s"):format(normalized_body),
	}, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "reply_to_review_comment"), result)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param mode "approve"|"request_changes"|"comment"|string|nil
---@param body string|nil
---@param comments table[]|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.submit_review(number, mode, body, comments, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, {
			code = 1, signal = 0, stdout = "",
			stderr = message or "", cmd = { "gh" },
		})
		return
	end

	local review_mode = normalize_review_mode(mode)
	if not review_mode then
		error(
			"gitflow gh pr error: review mode must be"
				.. " approve|request_changes|comment", 2
		)
	end

	local event = "COMMENT"
	if review_mode == "approve" then
		event = "APPROVE"
	elseif review_mode == "request_changes" then
		event = "REQUEST_CHANGES"
	end

	local endpoint =
		("repos/{owner}/{repo}/pulls/%s/reviews"):format(
			normalize_number(number)
		)

	local normalized_body = vim.trim(tostring(body or ""))
	local payload = { event = event }
	if normalized_body ~= "" then
		payload.body = normalized_body
	end
	if comments and #comments > 0 then
		payload.comments = comments
	end

	-- Submit as JSON body so comments is an array, not a string field.
	local args = {
		"api", endpoint, "--method", "POST",
		"--input", "-",
	}
	local run_opts = vim.tbl_extend("force", opts or {}, {
		stdin = vim.json.encode(payload),
	})

	gh.run(args, run_opts, function(result)
		if result.code ~= 0 then
			cb(
				error_from_result(result, "submit_review"),
				result
			)
			return
		end
		cb(nil, result)
	end)
end

---@param number integer|string
---@param mode "approve"|"request_changes"|"comment"|string|nil
---@param body string|nil
---@param opts GitflowGitRunOpts|nil
---@param cb fun(err: string|nil, result: GitflowGitResult)
function M.review(number, mode, body, opts, cb)
	local ok, message = gh.ensure_prerequisites()
	if not ok then
		cb(message, { code = 1, signal = 0, stdout = "", stderr = message or "", cmd = { "gh" } })
		return
	end

	local review_mode = normalize_review_mode(mode)
	if not review_mode then
		error("gitflow gh pr error: review mode must be approve|request_changes|comment", 2)
	end

	local args = { "pr", "review", normalize_number(number) }
	if review_mode == "approve" then
		args[#args + 1] = "--approve"
	elseif review_mode == "request_changes" then
		args[#args + 1] = "--request-changes"
	else
		args[#args + 1] = "--comment"
	end

	local normalized_body = vim.trim(tostring(body or ""))
	if normalized_body ~= "" then
		args[#args + 1] = "--body"
		args[#args + 1] = normalized_body
	end

	gh.run(args, opts, function(result)
		if result.code ~= 0 then
			cb(error_from_result(result, "review"), result)
			return
		end
		cb(nil, result)
	end)
end

return M
