--- tests/e2e/config_validation_spec.lua
---
--- Verifies theme-driven highlight refresh and the config validation gates:
--- unknown option keys and colliding keybindings.

local config = require("gitflow.config")
local highlights = require("gitflow.highlights")

local DARK_ACCENT = tonumber("56B6C2", 16)
local LIGHT_ACCENT = tonumber("0E7490", 16)

---@param group string
---@return integer|nil
local function group_fg(group)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group })
	if not ok or type(hl) ~= "table" then
		return nil
	end
	return hl.fg
end

---@return integer  autocmds registered in the gitflow highlight augroup
local function theme_autocmd_count()
	local autocmds = vim.api.nvim_get_autocmds({ group = "GitflowHighlights" })
	return #autocmds
end

---Run `fn` with the background restored afterwards.
---@param background "dark"|"light"
---@param fn fun()
local function with_background(background, fn)
	local previous = vim.o.background
	vim.o.background = background
	local ok, err = pcall(fn)
	vim.o.background = previous
	if not ok then
		error(err, 0)
	end
end

---@param opts table
---@return string  the error message raised by config.setup
local function setup_error(opts)
	local ok, err = T.pcall_message(function()
		config.setup(opts)
	end)
	T.assert_false(ok, "config.setup should have rejected the config")
	return err or ""
end

T.run_suite("config_validation_spec", {
	["background change re-applies the matching palette"] = function()
		with_background("dark", function()
			highlights.setup({})
			T.assert_equals(
				group_fg("GitflowBorder"),
				DARK_ACCENT,
				"dark background should use the dark accent"
			)

			-- OptionSet fires here; without the autocmd the accent stays dark.
			vim.o.background = "light"
			T.assert_equals(
				group_fg("GitflowBorder"),
				LIGHT_ACCENT,
				"background=light should recompute to the light accent"
			)
		end)
	end,

	["ColorScheme re-applies cleared highlight groups"] = function()
		highlights.setup({})
		vim.api.nvim_set_hl(0, "GitflowBorder", {})
		T.assert_equals(
			group_fg("GitflowBorder"),
			nil,
			"GitflowBorder should be cleared before the event"
		)

		vim.api.nvim_exec_autocmds("ColorScheme", {})
		T.assert_true(
			group_fg("GitflowBorder") ~= nil,
			"ColorScheme should re-apply gitflow highlight groups"
		)
	end,

	["user overrides survive a ColorScheme change"] = function()
		highlights.setup({ GitflowBorder = { fg = "#FF00FF" } })
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		T.assert_equals(
			group_fg("GitflowBorder"),
			tonumber("FF00FF", 16),
			"overrides should be re-applied, not reset to the palette"
		)
		highlights.setup({})
	end,

	["repeated setup does not stack duplicate autocmds"] = function()
		highlights.setup({})
		local baseline = theme_autocmd_count()
		T.assert_true(baseline > 0, "theme autocmds should be registered")

		for _ = 1, 3 do
			highlights.setup({})
		end
		T.assert_equals(
			theme_autocmd_count(),
			baseline,
			"re-running setup must not leak autocmds"
		)
	end,

	["refresh is a no-op before setup"] = function()
		package.loaded["gitflow.highlights"] = nil
		local fresh = require("gitflow.highlights")
		vim.api.nvim_set_hl(0, "GitflowBorder", {})

		fresh.refresh()
		T.assert_equals(
			group_fg("GitflowBorder"),
			nil,
			"refresh must not define highlights when setup never ran"
		)

		-- Restore the shared instance for any later assertions.
		package.loaded["gitflow.highlights"] = nil
		require("gitflow.highlights").setup({})
	end,

	["unknown top-level option is rejected"] = function()
		local err = setup_error({ inline_blaem = { enable = false } })
		T.assert_contains(err, "unknown option", "error should name the failure")
		T.assert_contains(err, "inline_blaem", "error should name the bad key")
		T.assert_contains(err, "inline_blame", "error should suggest the real key")
	end,

	["unknown nested option names its full path"] = function()
		local err = setup_error({ inline_blame = { enalbe = false } })
		T.assert_contains(
			err,
			"inline_blame.enalbe",
			"error should name the dotted path of the bad key"
		)
		T.assert_contains(err, "did you mean 'enable'", "error should suggest 'enable'")
	end,

	["unrelated unknown key gets no misleading suggestion"] = function()
		local err = setup_error({ totally_unrelated_option = true })
		T.assert_contains(
			err,
			"totally_unrelated_option",
			"error should name the bad key"
		)
		T.assert_false(
			err:find("did you mean", 1, true) ~= nil,
			"a distant key should not get a suggestion"
		)
	end,

	["free-form and list-valued options stay accepted"] = function()
		local cfg = config.setup({
			-- Arbitrary highlight group names must not be treated as unknown.
			highlights = { MyCustomGroup = { fg = "#123456" } },
			-- A border list must not have its indices treated as unknown keys.
			ui = { float = { border = { "+", "-", "+", "|", "+", "-", "+", "|" } } },
			quick_actions = { quick_push = { "commit", "push" } },
		})
		T.assert_equals(
			cfg.highlights.MyCustomGroup.fg,
			"#123456",
			"custom highlight groups should pass validation"
		)
		T.assert_equals(
			cfg.inline_blame.delay,
			200,
			"unrelated defaults should survive the merge"
		)
	end,

	["duplicate keybindings are rejected"] = function()
		local err = setup_error({ keybindings = { commit = "gs" } })
		T.assert_contains(err, "duplicate keybindings", "error should name the failure")
		T.assert_contains(err, "gs", "error should name the colliding mapping")
		T.assert_contains(err, "commit", "error should name the colliding action")
		T.assert_contains(err, "status", "error should name the shadowed action")
	end,

	["default keybindings have no collisions"] = function()
		local cfg = config.setup({})
		T.assert_equals(
			cfg.sync.pull_strategy,
			"rebase",
			"documented default pull strategy is rebase"
		)

		local seen = {}
		for action, mapping in pairs(cfg.keybindings) do
			T.assert_equals(
				seen[mapping],
				nil,
				("default keybinding '%s' collides with '%s'"):format(
					action,
					tostring(seen[mapping])
				)
			)
			seen[mapping] = action
		end
	end,
})
