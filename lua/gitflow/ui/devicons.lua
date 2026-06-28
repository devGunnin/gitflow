--- Lightweight filetype icon provider (no external dependency).
---
--- Maps file extensions / names to a Nerd Font glyph and a brand color so the
--- status / diff surfaces show recognisable, colorful per-filetype icons. When
--- icons are disabled (config), a neutral ASCII bullet is returned.

local icons_cfg = require("gitflow.icons")

local M = {}

-- glyph + brand color. Glyphs are common Nerd Font v3 codepoints.
local BY_EXT = {
	lua = { "\u{e620}", "#51a0cf" },
	py = { "\u{e606}", "#ffd43b" },
	js = { "\u{e781}", "#f1e05a" },
	jsx = { "\u{e781}", "#f1e05a" },
	ts = { "\u{e628}", "#3178c6" },
	tsx = { "\u{e628}", "#3178c6" },
	json = { "\u{e60b}", "#cbcb41" },
	md = { "\u{f48a}", "#9aa7b0" },
	markdown = { "\u{f48a}", "#9aa7b0" },
	sh = { "\u{f489}", "#89e051" },
	bash = { "\u{f489}", "#89e051" },
	zsh = { "\u{f489}", "#89e051" },
	html = { "\u{f13b}", "#e34c26" },
	css = { "\u{f13c}", "#563d7c" },
	scss = { "\u{f13c}", "#cf649a" },
	go = { "\u{e627}", "#00add8" },
	rs = { "\u{e7a8}", "#dea584" },
	c = { "\u{e61e}", "#599eff" },
	h = { "\u{e61e}", "#a074c4" },
	cpp = { "\u{e61d}", "#f34b7d" },
	hpp = { "\u{e61d}", "#a074c4" },
	cc = { "\u{e61d}", "#f34b7d" },
	java = { "\u{e738}", "#cc3e44" },
	rb = { "\u{e791}", "#701516" },
	php = { "\u{e73d}", "#a074c4" },
	vim = { "\u{e62b}", "#019833" },
	txt = { "\u{f15c}", "#9aa7b0" },
	yml = { "\u{f481}", "#6d8086" },
	yaml = { "\u{f481}", "#6d8086" },
	toml = { "\u{e6b2}", "#9c4221" },
	ini = { "\u{f013}", "#6d8086" },
	conf = { "\u{f013}", "#6d8086" },
	lock = { "\u{f023}", "#bbbbbb" },
	png = { "\u{f1c5}", "#a074c4" },
	jpg = { "\u{f1c5}", "#a074c4" },
	jpeg = { "\u{f1c5}", "#a074c4" },
	gif = { "\u{f1c5}", "#a074c4" },
	svg = { "\u{f1c5}", "#ffb13b" },
	pdf = { "\u{f1c1}", "#b30b00" },
	zip = { "\u{f1c6}", "#cbcb41" },
	tar = { "\u{f1c6}", "#cbcb41" },
	gz = { "\u{f1c6}", "#cbcb41" },
	patch = { "\u{f440}", "#41535b" },
	diff = { "\u{f440}", "#41535b" },
}

local BY_NAME = {
	[".gitignore"] = { "\u{f1d3}", "#f14e32" },
	[".gitattributes"] = { "\u{f1d3}", "#f14e32" },
	[".gitmodules"] = { "\u{f1d3}", "#f14e32" },
	["readme.md"] = { "\u{f48a}", "#519aba" },
	["license"] = { "\u{f0fc}", "#cbcb41" },
	["makefile"] = { "\u{e673}", "#6d8086" },
	["dockerfile"] = { "\u{f308}", "#519aba" },
	["package.json"] = { "\u{e60b}", "#e8274b" },
}

local DEFAULT = { "\u{f15b}", "#9aa7b0" }

local registered = {}

---Ensure a highlight group exists for a hex color and return its name.
---@param hex string
---@return string
local function color_group(hex)
	local key = hex:gsub("#", ""):lower()
	local group = "GitflowDevicon_" .. key
	if not registered[group] then
		pcall(vim.api.nvim_set_hl, 0, group, { fg = "#" .. key })
		registered[group] = true
	end
	return group
end

---Resolve a file path to an icon glyph + highlight group.
---@param path string
---@return string glyph, string hl_group
function M.get(path)
	local name = (path or ""):gsub(".*/", ""):lower()
	local entry = BY_NAME[name]
	if not entry then
		local ext = name:match("%.([%w_]+)$")
		entry = ext and BY_EXT[ext] or nil
	end
	entry = entry or DEFAULT
	-- Fall back to a plain bullet when Nerd Font icons are disabled.
	if not M.enabled() then
		return "\u{2022}", "GitflowMeta"
	end
	return entry[1], color_group(entry[2])
end

---@return boolean
function M.enabled()
	-- Mirror the gitflow icons toggle: when ascii fallback is active, the
	-- git_state icon for "added" comes back as a plain "+".
	return icons_cfg.get("git_state", "added") ~= "+"
end

return M
