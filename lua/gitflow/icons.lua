local M = {}

---@type GitflowConfig|nil
local cfg = nil

-- Nerd Font codepoints are encoded via Lua escape sequences to avoid
-- rendering issues in editors without Nerd Font support.
local NF = {
	-- git state
	added = "\u{f457}",            -- nf-oct-diff_added
	modified = "\u{f459}",         -- nf-oct-diff_modified
	deleted = "\u{f458}",          -- nf-oct-diff_removed
	conflict = "\u{f467}",         -- nf-oct-alert
	staged = "\u{f42e}",           -- nf-oct-check
	unstaged = "\u{f444}",         -- nf-oct-circle_slash
	untracked = "\u{f128}",        -- nf-fa-question
	commit = "\u{f417}",           -- nf-oct-git_commit
	-- github
	pr_open = "\u{f407}",          -- nf-oct-git_pull_request
	pr_merged = "\u{f43f}",        -- nf-oct-git_merge
	pr_closed = "\u{f445}",        -- nf-oct-circle_x (closed)
	pr_draft = "\u{f444}",         -- nf-oct-circle_slash (draft)
	issue_open = "\u{f41b}",       -- nf-oct-issue_opened
	issue_closed = "\u{f41d}",     -- nf-oct-issue_closed
	review_approved = "\u{f42e}",  -- nf-oct-check
	review_changes = "\u{f467}",   -- nf-oct-alert
	review_commented = "\u{f4b4}", -- nf-oct-comment
	review_pending = "\u{f444}",   -- nf-oct-circle_slash
	-- branch
	branch_current = "\u{f418}",   -- nf-oct-git_branch
	branch_remote = "\u{f427}",    -- nf-oct-globe
	branch_local = "\u{f418}",     -- nf-oct-git_branch
	-- file status
	file_add = "\u{f457}",         -- nf-oct-diff_added
	file_delete = "\u{f458}",      -- nf-oct-diff_removed
	file_rename = "\u{f45a}",      -- nf-oct-diff_renamed
	file_modify = "\u{f459}",      -- nf-oct-diff_modified
	-- palette categories
	palette_git = "\u{f418}",      -- nf-oct-git_branch
	palette_github = "\u{f408}",   -- nf-oct-mark_github
	palette_ui = "\u{f013}",       -- nf-fa-gear
}

---@type table<string, table<string, {nerd: string, ascii: string}>>
local registry = {
	git_state = {
		added = { nerd = NF.added, ascii = "+" },
		modified = { nerd = NF.modified, ascii = "~" },
		deleted = { nerd = NF.deleted, ascii = "-" },
		conflict = { nerd = NF.conflict, ascii = "!" },
		staged = { nerd = NF.staged, ascii = "S" },
		unstaged = { nerd = NF.unstaged, ascii = "U" },
		untracked = { nerd = NF.untracked, ascii = "?" },
		commit = { nerd = NF.commit, ascii = "*" },
	},
	github = {
		pr_open = { nerd = NF.pr_open, ascii = "[open]" },
		pr_merged = { nerd = NF.pr_merged, ascii = "[merged]" },
		pr_closed = { nerd = NF.pr_closed, ascii = "[closed]" },
		pr_draft = { nerd = NF.pr_draft, ascii = "[draft]" },
		issue_open = { nerd = NF.issue_open, ascii = "[open]" },
		issue_closed = { nerd = NF.issue_closed, ascii = "[closed]" },
		review_approved = {
			nerd = NF.review_approved, ascii = "[ok]",
		},
		review_changes_requested = {
			nerd = NF.review_changes, ascii = "[changes]",
		},
		review_commented = {
			nerd = NF.review_commented, ascii = "[comment]",
		},
		review_pending = {
			nerd = NF.review_pending, ascii = "[pending]",
		},
	},
	branch = {
		current = { nerd = NF.branch_current, ascii = "*" },
		remote = { nerd = NF.branch_remote, ascii = "@" },
		local_branch = { nerd = NF.branch_local, ascii = " " },
	},
	file_status = {
		A = { nerd = NF.file_add, ascii = "[+]" },
		D = { nerd = NF.file_delete, ascii = "[-]" },
		R = { nerd = NF.file_rename, ascii = "[R]" },
		M = { nerd = NF.file_modify, ascii = "[~]" },
	},
	palette = {
		git = { nerd = NF.palette_git, ascii = "#" },
		github = { nerd = NF.palette_github, ascii = "@" },
		ui = { nerd = NF.palette_ui, ascii = "*" },
	},
}

---@param config_ref GitflowConfig
function M.setup(config_ref)
	cfg = config_ref
end

---@param category string
---@param name string
---@return string
function M.get(category, name)
	local cat = registry[category]
	if not cat then
		return ""
	end
	local entry = cat[name]
	if not entry then
		return ""
	end
	if cfg and cfg.icons and cfg.icons.enable then
		return entry.nerd
	end
	return entry.ascii
end

return M
