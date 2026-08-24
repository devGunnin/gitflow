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

---Perceived luminance of an 0-255 RGB triple, 0..1.
---@return number
local function luminance(r, g, b)
	return (0.299 * r + 0.587 * g + 0.114 * b) / 255
end

---Brand colors are chosen for a dark terminal, so on a light background the
---bright ones wash out against it. Scale luminance toward a readable band,
---keeping the hue — the alternative is a fixed table that ignores the theme.
---@param key string  6-digit hex, no leading '#'
---@return string  6-digit hex, no leading '#'
local function adapt_to_background(key)
	local r = tonumber(key:sub(1, 2), 16)
	local g = tonumber(key:sub(3, 4), 16)
	local b = tonumber(key:sub(5, 6), 16)
	if not (r and g and b) then
		return key
	end

	local lum = luminance(r, g, b)
	local scale
	if vim.o.background == "light" then
		scale = lum > 0.55 and (0.45 / lum) or nil
	else
		-- Capped: an almost-black brand color scaled freely loses its hue.
		scale = lum < 0.30 and math.min(3.0, 0.40 / math.max(lum, 0.05)) or nil
	end
	if not scale then
		return key
	end

	local function clamp(v)
		return math.max(0, math.min(255, math.floor(v * scale + 0.5)))
	end
	return ("%02x%02x%02x"):format(clamp(r), clamp(g), clamp(b))
end

---Ensure a highlight group exists for a hex color and return its name.
---The background is part of the group name, so a background flip resolves to a
---fresh group instead of reusing one computed for the old theme.
---@param hex string
---@return string
local function color_group(hex)
	local key = hex:gsub("#", ""):lower()
	local background = vim.o.background == "light" and "light" or "dark"
	local group = ("GitflowDevicon_%s_%s"):format(background, key)
	if not registered[group] then
		pcall(vim.api.nvim_set_hl, 0, group, { fg = "#" .. adapt_to_background(key) })
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
