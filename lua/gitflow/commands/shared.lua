-- Helpers shared by more than one :Gitflow subcommand area.
-- Anything used by a single area stays local to that area's module.
local utils = require("gitflow.utils")
local git = require("gitflow.git")
local git_conflict = require("gitflow.git.conflict")
local status_panel = require("gitflow.panels.status")
local conflict_panel = require("gitflow.panels.conflict")

local M = {}

---@param message string
function M.show_info(message)
	utils.notify(message, vim.log.levels.INFO)
end

---@param message string
function M.show_error(message)
	utils.notify(message, vim.log.levels.ERROR)
end

---@param result GitflowGitResult
---@param fallback string
---@return string
function M.result_message(result, fallback)
	local output = git.output(result)
	if output == "" then
		return fallback
	end
	return output
end

function M.refresh_status_panel_if_open()
	if status_panel.is_open() then
		status_panel.refresh()
	end
end

function M.emit_post_operation()
	vim.api.nvim_exec_autocmds("User", { pattern = "GitflowPostOperation" })
end

-- ── argv helpers ────────────────────────────────────────────────────────

---@param args string[]
---@param flag string
---@return boolean
function M.has_flag(args, flag)
	for i = 2, #args do
		if args[i] == flag then
			return true
		end
	end
	return false
end

---@param args string[]
---@return string|nil
function M.first_positional(args)
	for i = 2, #args do
		local arg = args[i]
		if not vim.startswith(arg, "--") then
			return arg
		end
	end
	return nil
end

---@param args string[]
---@param start_index integer
---@return string|nil
function M.first_positional_from(args, start_index)
	for i = start_index, #args do
		local arg = args[i]
		if not vim.startswith(arg, "--") then
			return arg
		end
	end
	return nil
end

---@param value string|nil
---@return string|nil
function M.trimmed_or_nil(value)
	if value == nil then
		return nil
	end
	local trimmed = vim.trim(value)
	if trimmed == "" then
		return nil
	end
	return trimmed
end

-- ── conflict reporting ──────────────────────────────────────────────────

---@param paths string[]
---@return string
local function format_conflicted_paths(paths)
	if #paths == 0 then
		return "(none)"
	end
	return table.concat(paths, "\n")
end

---@param cfg GitflowConfig
---@param output string
---@param heading string
---@param hint string|nil
function M.handle_conflict_failure(cfg, output, heading, hint)
	local parsed = git_conflict.parse_conflicted_paths_from_output(output)

	---@param paths string[]
	local function notify_and_open(paths)
		local hint_text = ""
		if hint and hint ~= "" then
			hint_text = ("\n\n%s"):format(hint)
		end

		M.show_error(
			("%s\nConflicted files:\n%s%s\n\n%s"):format(heading, format_conflicted_paths(paths), hint_text, output)
		)
		M.refresh_status_panel_if_open()
		conflict_panel.open(cfg)
	end

	if #parsed > 0 then
		notify_and_open(parsed)
		return
	end

	git_conflict.list({}, function(err, conflicted)
		if err or #conflicted == 0 then
			M.show_error(output)
			return
		end
		notify_and_open(conflicted)
	end)
end

-- ── completion helpers ──────────────────────────────────────────────────

---@param arglead string
---@param candidates string[]
---@return string[]
function M.filter_candidates(arglead, candidates)
	local filtered = {}
	for _, value in ipairs(candidates) do
		if arglead == "" or vim.startswith(value, arglead) then
			filtered[#filtered + 1] = value
		end
	end
	return filtered
end

---@param args string[]
---@return string[]
function M.system_lines(args)
	local cmd = { "git" }
	for _, arg in ipairs(args) do
		cmd[#cmd + 1] = arg
	end

	local lines = {}
	if vim.system then
		local result = vim.system(cmd, { text = true }):wait()
		if (result.code or 1) ~= 0 then
			return lines
		end
		lines = vim.split(result.stdout or "", "\n", { trimempty = true })
	else
		lines = vim.fn.systemlist(cmd)
		if vim.v.shell_error ~= 0 then
			return {}
		end
	end

	return lines
end

---@return string[]
function M.list_branch_candidates()
	local names = {}
	for _, line in
		ipairs(M.system_lines({
			"for-each-ref",
			"--format=%(refname:short)",
			"refs/heads",
			"refs/remotes",
		}))
	do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and not trimmed:match("/HEAD$") then
			names[#names + 1] = trimmed
		end
	end
	table.sort(names)
	return names
end

---True while the cursor is still on the `<action>` word of `:Gitflow <cmd> <action>`.
---@param cmdline string
---@param args string[]
---@return boolean
function M.completing_action(cmdline, args)
	return #args == 2 or (#args == 3 and not cmdline:match("%s$"))
end

return M
