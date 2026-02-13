local M = {}

---@type boolean
M.enabled = false

---@type table<string, table<string, table>>
M.registry = {
	palette = {
		git = { nerd = "\u{e725}", ascii = "[G]" },
		github = { nerd = "\u{f408}", ascii = "[H]" },
		ui = { nerd = "\u{eb31}", ascii = "[U]" },
		separator = { nerd = "\u{2500}", ascii = "-" },
		arrow = { nerd = "\u{f061}", ascii = ">" },
	},
	git_state = {
		staged = { nerd = "\u{f00c}", ascii = "+" },
		unstaged = { nerd = "\u{f111}", ascii = "~" },
		untracked = { nerd = "\u{f059}", ascii = "?" },
		conflict = { nerd = "\u{f06a}", ascii = "!" },
	},
	github = {
		issue = { nerd = "\u{f41b}", ascii = "#" },
		pr = { nerd = "\u{f407}", ascii = "PR" },
	},
	branch = {
		branch = { nerd = "\u{e725}", ascii = "*" },
		remote = { nerd = "\u{f0c1}", ascii = "~" },
	},
}

---@param cfg table
function M.setup(cfg)
	M.enabled = cfg.enable == true
end

---@param category string
---@param name string
---@return string
function M.get(category, name)
	local cat = M.registry[category]
	if not cat then
		return ""
	end
	local entry = cat[name]
	if not entry then
		return ""
	end
	if M.enabled then
		return entry.nerd
	end
	return entry.ascii
end

return M
