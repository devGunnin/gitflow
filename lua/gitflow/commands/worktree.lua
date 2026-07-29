-- Area: git worktrees.
local git_worktree = require("gitflow.git.worktree")
local shared = require("gitflow.commands.shared")
local worktree_panel = require("gitflow.panels.worktree")

local M = {}

M.panels = { worktree_panel }

local WORKTREE_ACTIONS = { "list", "add", "remove", "move", "lock", "unlock", "prune" }

---@return string[]
local function list_worktree_paths()
	local paths = {}
	for _, line in ipairs(shared.system_lines({ "worktree", "list", "--porcelain" })) do
		local p = line:match("^worktree (.+)$")
		if p then
			paths[#paths + 1] = p
		end
	end
	return paths
end

---@param ctx GitflowAreaContext
function M.register(ctx)
	local cfg = ctx.config

	ctx.register("worktree", {
		description = "Worktree operations: list|add|remove|move|lock|unlock|prune",
		run = function(cmd)
			local action = cmd.args[2] or "list"
			if action == "list" then
				worktree_panel.open(cfg)
				return "Worktree panel opened"
			end

			if action == "add" then
				local path = shared.trimmed_or_nil(cmd.args[3])
				if not path then
					return "Usage: :Gitflow worktree add <path> [ref] [-b <branch>]"
				end
				local opts = {}
				local i = 4
				while i <= #cmd.args do
					local token = cmd.args[i]
					if token == "-b" or token == "--branch" then
						local branch = shared.trimmed_or_nil(cmd.args[i + 1])
						if not branch or vim.startswith(branch, "-") then
							return ("%s requires a branch name"):format(token)
						end
						opts.new_branch = branch
						i = i + 2
					elseif token == "--force" then
						opts.force = true
						i = i + 1
					elseif token == "--detach" then
						opts.detach = true
						i = i + 1
					elseif not vim.startswith(token, "-") then
						opts.ref = token
						i = i + 1
					else
						return ("Unknown worktree add option: %s"):format(token)
					end
				end
				git_worktree.add(path, opts, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Created worktree at %s"):format(path))
					if worktree_panel.is_open() then
						worktree_panel.refresh()
					end
					shared.emit_post_operation()
				end)
				return ("Creating worktree at %s..."):format(path)
			end

			if action == "remove" then
				local path = shared.trimmed_or_nil(cmd.args[3])
				if not path then
					return "Usage: :Gitflow worktree remove <path> [--force]"
				end
				local force = shared.has_flag(cmd.args, "--force")
				git_worktree.remove(path, { force = force }, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Removed worktree %s"):format(path))
					if worktree_panel.is_open() then
						worktree_panel.refresh()
					end
					shared.emit_post_operation()
				end)
				return ("Removing worktree %s..."):format(path)
			end

			if action == "move" then
				local path = shared.trimmed_or_nil(cmd.args[3])
				local dest = shared.trimmed_or_nil(cmd.args[4])
				if not path or not dest then
					return "Usage: :Gitflow worktree move <path> <new-path>"
				end
				git_worktree.move(path, dest, {
					force = shared.has_flag(cmd.args, "--force"),
				}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Moved worktree to %s"):format(dest))
					if worktree_panel.is_open() then
						worktree_panel.refresh()
					end
					shared.emit_post_operation()
				end)
				return ("Moving worktree %s..."):format(path)
			end

			if action == "lock" then
				local path = shared.trimmed_or_nil(cmd.args[3])
				if not path then
					return "Usage: :Gitflow worktree lock <path> [reason]"
				end
				local reason = table.concat(cmd.args, " ", 4)
				git_worktree.lock(path, { reason = reason }, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Locked worktree %s"):format(path))
					if worktree_panel.is_open() then
						worktree_panel.refresh()
					end
				end)
				return ("Locking worktree %s..."):format(path)
			end

			if action == "unlock" then
				local path = shared.trimmed_or_nil(cmd.args[3])
				if not path then
					return "Usage: :Gitflow worktree unlock <path>"
				end
				git_worktree.unlock(path, {}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info(("Unlocked worktree %s"):format(path))
					if worktree_panel.is_open() then
						worktree_panel.refresh()
					end
				end)
				return ("Unlocking worktree %s..."):format(path)
			end

			if action == "prune" then
				git_worktree.prune({}, function(err)
					if err then
						shared.show_error(err)
						return
					end
					shared.show_info("Pruned stale worktree entries")
					if worktree_panel.is_open() then
						worktree_panel.refresh()
					end
					shared.emit_post_operation()
				end)
				return "Pruning worktrees..."
			end

			return ("Unknown worktree action: %s"):format(action)
		end,
		complete = function(arglead, cmdline, args)
			if shared.completing_action(cmdline, args) then
				return shared.filter_candidates(arglead, WORKTREE_ACTIONS)
			end
			-- For path-taking actions, complete existing worktree paths.
			local sub = args[3]
			if sub == "remove" or sub == "move" or sub == "lock" or sub == "unlock" then
				return shared.filter_candidates(arglead, list_worktree_paths())
			end
			if sub == "add" then
				return shared.filter_candidates(arglead, shared.list_branch_candidates())
			end
			return {}
		end,
	})
end

return M
