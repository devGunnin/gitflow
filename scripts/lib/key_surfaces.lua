-- scripts/lib/key_surfaces.lua — how the keymap specs find every key surface,
-- and how they check that a surface binds what its registry says.
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
--
-- Discovery is still a source scan, and a source scan is a filter, not a
-- proof: it decides which modules are ASKED to register. `compare` is the part
-- that proves — it opens a surface and diffs the keys really on the buffer
-- against the keys its registry declares, so an aliased or metatable-dispatched
-- binder shows up as an undeclared key however it spelled `vim.keymap`.
-- What that leaves open is written down in .dm-knowledge/gf-keymaps.md.

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
	["gitflow.ui.input"] = true,
	-- Two verbs on the review threads popup (`R` reply, `q` close) that live
	-- and die with the popup. They are NOT in the collision check; see
	-- .dm-knowledge/gf-keymaps.md.
	["gitflow.review.threads"] = true,
	-- Declares review mode's key ENTRIES; review/file_list.lua and
	-- review/overlay.lua are what register the two surfaces built from them.
	["gitflow.review.keymaps"] = true,
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
		-- Any spelling of a binder has to name `keymap` somewhere — plain
		-- `vim.keymap.set`, an alias, a metatable that indexes it, or the
		-- `nvim_buf_set_keymap` API. Matching the substring costs a few extra
		-- candidates (which only have to register) and costs an evader the
		-- ability to bind at all without saying the word.
		local declares = source:find("keymap", 1, true) ~= nil
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

-- ── runtime verification ───────────────────────────────────────────────

---Canonical form of a keymap lhs. `<C-n>` and `<C-N>` are one mapping, and
---Neovim reports its own spelling, so both sides go through the same filter
---before they are compared.
---@param lhs string
---@return string
function M.canonical(lhs)
	return vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
end

---What a buffer really has bound, canonical.
---@param bufnr integer
---@param mode string
---@return table<string, boolean>
local function bound_on_buffer(bufnr, mode)
	local out = {}
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
		out[M.canonical(map.lhs)] = true
	end
	return out
end

---What a registry says the buffer should have bound, canonical.
---@param entries GitflowPanelKeymap[]
---@param mode string
---@param view string|nil  restrict to the entries a per-view surface binds now
---@return table<string, boolean>
local function declared_by_registry(entries, mode, view)
	local panel = require("gitflow.ui.panel")
	local out = {}
	for _, entry in ipairs(entries) do
		local entry_mode = entry.mode or "n"
		local modes = type(entry_mode) == "table" and entry_mode or { entry_mode }
		local in_view = view == nil or entry.views == nil
			or vim.tbl_contains(entry.views, view)
		if in_view and vim.tbl_contains(modes, mode) then
			for _, binding in ipairs(panel.bindings(entry)) do
				out[M.canonical(binding.key)] = true
			end
		end
	end
	return out
end

---Run `fn` with `vim.keymap.set` recording, and report any (buffer, mode, key)
---bound more than once.
---
---`compare` sees only the key SET on the buffer, so it cannot tell that a
---second bind replaced the first: the verb comes off the surface while its
---hint keeps advertising it, on a key the registry legitimately declares.
---Recording the calls is what sees that, whatever spelling reached the binder.
---@param fn fun()
---@return string[] problems
function M.watch_rebinds(fn)
	local real = vim.keymap.set
	local seen, problems = {}, {}
	vim.keymap.set = function(mode, lhs, rhs, opts)
		local buffer = type(opts) == "table" and opts.buffer or nil
		if buffer then
			local modes = type(mode) == "table" and mode or { mode }
			for _, one in ipairs(modes) do
				local id = ("%s\0%s\0%s"):format(tostring(buffer), one, M.canonical(lhs))
				if seen[id] then
					problems[#problems + 1] = (
						"%q was bound twice in mode %s on one buffer — the second "
						.. "bind takes the first verb off the surface"
					):format(M.canonical(lhs), one)
				end
				seen[id] = true
			end
		end
		return real(mode, lhs, rhs, opts)
	end
	local ok, err = pcall(fn)
	vim.keymap.set = real
	if not ok then
		error(err, 0)
	end
	table.sort(problems)
	return problems
end

---Diff what an open surface bound against what its registry declares.
---
---This is the part of the contract that does not take the source's word for
---it: a key on the buffer that no entry declares is unadvertised, unremappable
---and outside the destructive/benign collision rule, whichever binder put it
---there; a declared key that is not on the buffer is a hint that lies.
---@param name string  surface name, for the message
---@param bufnr integer  the surface's live buffer
---@param entries GitflowPanelKeymap[]  its resolved registry
---@param opts { mode?: string, view?: string }|nil
---@return string[] problems
function M.compare(name, bufnr, entries, opts)
	opts = opts or {}
	local mode = opts.mode or "n"
	local bound = bound_on_buffer(bufnr, mode)
	local declared = declared_by_registry(entries, mode, opts.view)

	local problems = {}
	for key in pairs(bound) do
		if not declared[key] then
			problems[#problems + 1] =
				("%s binds %q, which its registry does not declare"):format(name, key)
		end
	end
	for key in pairs(declared) do
		if not bound[key] then
			problems[#problems + 1] =
				("%s advertises %q but never bound it"):format(name, key)
		end
	end
	table.sort(problems)
	return problems
end

return M
