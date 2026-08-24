-- scripts/lib/key_surfaces.lua — how the keymap specs find every key surface.
--
-- dofile'd by scripts/test_keymap_contract.lua and
-- scripts/test_keybinding_docs.lua; not a test itself.
--
-- Globbing `lua/gitflow/panels/*.lua` and requiring it forces LOADING, not
-- REGISTERING, and it cannot see a surface declared anywhere else. Three ways
-- to ship a colliding destructive key past the contract, all of them green:
-- register lazily inside `open()`; call `vim.keymap.set` directly and register
-- nothing (the command palette did exactly this); or declare the surface
-- outside `panels/`, where the spec's hardcoded requires never looked.
--
-- So: discover by source across the whole tree, and verify REGISTRATION. A
-- module that binds keys or declares a panel must have registered a surface by
-- the time it finishes loading, or be named below with a reason.

local M = {}

--- Modules that bind keys and legitimately own no key surface. Each is a
--- transient overlay the user summons and dismisses, not a panel with a key
--- set to learn — or the machinery behind them. Anything else that binds keys
--- must register a surface; adding a name here is the loud way to opt out.
local NO_SURFACE = {
	-- The panel base itself: it binds on behalf of the surfaces it registers.
	["gitflow.ui.panel"] = true,
	-- The `?` overlay's own buffer (j/k/q while it is up).
	["gitflow.ui.help"] = true,
	-- Prompt overlays: the keys live and die with one question.
	["gitflow.ui.picker"] = true,
	["gitflow.ui.form"] = true,
	["gitflow.review.threads"] = true,
	-- The global <Plug> mappings, documented in KEYBINDINGS.md's Global table
	-- and checked by scripts/test_keybinding_docs.lua.
	["gitflow.commands"] = true,
	-- A facade over gitflow.review.*: its two surfaces are registered by
	-- review/file_list.lua and review/overlay.lua, which it pulls in.
	["gitflow.panels.review"] = true,
}

---@param root string  project root, no trailing slash
---@param path string  absolute path to a lua/gitflow module
---@return string
local function module_name(root, path)
	local relative = path:sub(#root + #"/lua/" + 1):gsub("%.lua$", "")
	return (relative:gsub("/", "."):gsub("%.init$", ""))
end

---Load every module that could register a key surface.
---@param root string  project root, no trailing slash
---@return string[] problems  empty when every binder registers
function M.load(root)
	local panel = require("gitflow.ui.panel")
	local problems = {}
	local candidates = {}

	local paths = vim.fn.glob(root .. "/lua/gitflow/**/*.lua", false, true)
	table.sort(paths)
	for _, path in ipairs(paths) do
		local modname = module_name(root, path)
		local source = table.concat(vim.fn.readfile(path), "\n")
		local declares = source:find("vim.keymap.set", 1, true) ~= nil
			or source:find("register_surface(", 1, true) ~= nil
			or source:find("panel.new(", 1, true) ~= nil
			or modname:match("^gitflow%.panels%.") ~= nil
		if declares then
			candidates[#candidates + 1] = { modname = modname, path = path }
			local ok, err = pcall(require, modname)
			if not ok then
				problems[#problems + 1] =
					("could not load %s: %s"):format(modname, tostring(err))
			end
		end
	end

	local registered = {}
	for _, surface in ipairs(panel.surfaces()) do
		registered[vim.fn.fnamemodify(surface.source or "", ":p")] = true
	end
	for _, candidate in ipairs(candidates) do
		if not NO_SURFACE[candidate.modname]
			and not registered[vim.fn.fnamemodify(candidate.path, ":p")] then
			problems[#problems + 1] = (
				"%s binds keys or declares a panel but registered no key "
				.. "surface while loading — register at module scope, or name "
				.. "it in NO_SURFACE in scripts/lib/key_surfaces.lua with why"
			):format(candidate.modname)
		end
	end

	table.sort(problems)
	return problems
end

return M
