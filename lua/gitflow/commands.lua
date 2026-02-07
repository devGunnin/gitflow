local config = require("gitflow.config")
local ui = require("gitflow.ui")
local utils = require("gitflow.utils")

---@class GitflowSubcommand
---@field description string
---@field run fun(ctx: table): string|nil

---@class GitflowCommandState
---@field panel_buffer integer|nil
---@field panel_window integer|nil

local M = {}

---@type table<string, GitflowSubcommand>
M.subcommands = {}

---@type GitflowCommandState
M.state = {
	panel_buffer = nil,
	panel_window = nil,
}

---@return string
function M.usage()
	local lines = { "Gitflow usage: :Gitflow <subcommand>", "", "Subcommands:" }
	for _, name in ipairs(utils.sorted_keys(M.subcommands)) do
		lines[#lines + 1] = ("  %-10s %s"):format(name, M.subcommands[name].description)
	end
	return table.concat(lines, "\n")
end

---@param message string
local function show_info(message)
	utils.notify(message, vim.log.levels.INFO)
end

---@param cfg GitflowConfig
local function open_panel(cfg)
	local bufnr = ui.buffer.create("main", {
		filetype = "gitflow",
		lines = {
			"Gitflow",
			"",
			"Plugin skeleton initialized.",
			"Run :Gitflow refresh to update this panel.",
		},
	})
	M.state.panel_buffer = bufnr

	if cfg.ui.default_layout == "float" then
		M.state.panel_window = ui.window.open_float({
			name = "main",
			bufnr = bufnr,
			width = cfg.ui.float.width,
			height = cfg.ui.float.height,
			border = cfg.ui.float.border,
			title = cfg.ui.float.title,
			on_close = function()
				M.state.panel_window = nil
			end,
		})
		return
	end

	M.state.panel_window = ui.window.open_split({
		name = "main",
		bufnr = bufnr,
		orientation = cfg.ui.split.orientation,
		size = cfg.ui.split.size,
		on_close = function()
			M.state.panel_window = nil
		end,
	})
end

---@param cfg GitflowConfig
local function register_builtin_subcommands(cfg)
	M.subcommands.help = {
		description = "Show Gitflow usage",
		run = function()
			local usage = M.usage()
			show_info(usage)
			return usage
		end,
	}

	M.subcommands.open = {
		description = "Open the Gitflow panel",
		run = function()
			open_panel(cfg)
			return "Gitflow panel opened"
		end,
	}

	M.subcommands.refresh = {
		description = "Refresh panel content",
		run = function()
			local bufnr = M.state.panel_buffer or ui.buffer.get("main")
			if not bufnr then
				return "No Gitflow panel is open"
			end

			ui.buffer.update(bufnr, {
				"Gitflow",
				"",
				("Last refresh: %s"):format(os.date("%Y-%m-%d %H:%M:%S")),
			})
			return "Gitflow panel refreshed"
		end,
	}

	M.subcommands.close = {
		description = "Close the Gitflow panel",
		run = function()
			if M.state.panel_window then
				ui.window.close(M.state.panel_window)
			else
				ui.window.close("main")
			end
			if M.state.panel_buffer then
				ui.buffer.teardown(M.state.panel_buffer)
			else
				ui.buffer.teardown("main")
			end
			M.state.panel_window = nil
			M.state.panel_buffer = nil
			return "Gitflow panel closed"
		end,
	}
end

---@param commandline string
---@return string[]
local function split_args(commandline)
	if commandline == "" then
		return {}
	end
	return vim.split(commandline, "%s+", { trimempty = true })
end

---@param args string[]
---@param cfg GitflowConfig
---@return string
function M.dispatch(args, cfg)
	if #args == 0 then
		local usage = M.usage()
		show_info(usage)
		return usage
	end

	local subcommand_name = args[1]
	local subcommand = M.subcommands[subcommand_name]
	if not subcommand then
		local message = ("Unknown Gitflow subcommand: %s"):format(subcommand_name)
		utils.notify(message, vim.log.levels.ERROR)
		return message
	end

	local result = subcommand.run({
		args = args,
		config = cfg,
	})

	if result and result ~= "" and subcommand_name ~= "help" then
		show_info(result)
	end

	return result or ""
end

---@param name string
---@param subcommand GitflowSubcommand
function M.register_subcommand(name, subcommand)
	if not utils.is_non_empty_string(name) then
		error("gitflow command error: subcommand name must be a non-empty string", 2)
	end
	if type(subcommand) ~= "table" or type(subcommand.run) ~= "function" then
		error("gitflow command error: subcommand must define a run(ctx) function", 2)
	end
	if not utils.is_non_empty_string(subcommand.description) then
		error("gitflow command error: subcommand must define a description", 2)
	end
	M.subcommands[name] = subcommand
end

---@param arglead string
---@return string[]
function M.complete(arglead)
	local matches = {}
	for _, name in ipairs(utils.sorted_keys(M.subcommands)) do
		if arglead == "" or vim.startswith(name, arglead) then
			matches[#matches + 1] = name
		end
	end
	return matches
end

---@param cfg GitflowConfig|nil
function M.setup(cfg)
	local current = cfg or config.get()
	register_builtin_subcommands(current)

	pcall(vim.api.nvim_del_user_command, "Gitflow")
	vim.api.nvim_create_user_command("Gitflow", function(params)
		local args = split_args(params.args or "")
		M.dispatch(args, current)
	end, {
		nargs = "*",
		complete = function(arglead)
			return M.complete(arglead)
		end,
		desc = "Gitflow command dispatcher",
	})

	vim.keymap.set("n", "<Plug>(GitflowHelp)", "<Cmd>Gitflow help<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowOpen)", "<Cmd>Gitflow open<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowRefresh)", "<Cmd>Gitflow refresh<CR>", { silent = true })
	vim.keymap.set("n", "<Plug>(GitflowClose)", "<Cmd>Gitflow close<CR>", { silent = true })

	local key_to_plug = {
		help = "<Plug>(GitflowHelp)",
		open = "<Plug>(GitflowOpen)",
		refresh = "<Plug>(GitflowRefresh)",
		close = "<Plug>(GitflowClose)",
	}
	for action, mapping in pairs(current.keybindings) do
		local plug = key_to_plug[action]
		if plug then
			vim.keymap.set("n", mapping, plug, { remap = true, silent = true })
		end
	end
end

return M
