--- Fuzzy substring matcher shared by list_picker, label_picker and the
--- command palette. Was three byte-identical copies (list_picker.lua,
--- label_picker.lua, palette.lua:92); this is the single implementation.

local M = {}

---@param text string|nil
---@return string
function M.normalize(text)
	return vim.trim(tostring(text or "")):lower()
end

---Greedy left-to-right subsequence score: every query char must appear in
---`haystack` in order; consecutive matches (a "streak") score higher than
---matches separated by skipped characters, and closer skips score higher
---than distant ones.
---@param haystack string
---@param needle string
---@return integer|nil  nil when `needle` is not a subsequence of `haystack`
function M.fuzzy_score(haystack, needle)
	if needle == "" then
		return 0
	end

	local search = M.normalize(haystack)
	local query = M.normalize(needle)
	local offset = 1
	local score = 0
	local streak = 0

	for index = 1, #query do
		local char = query:sub(index, index)
		local found = search:find(char, offset, true)
		if not found then
			return nil
		end

		if found == offset then
			streak = streak + 1
			score = score + 10 + streak
		else
			streak = 0
			score = score + math.max(1, 6 - (found - offset))
		end
		offset = found + 1
	end

	return score
end

---Greedy subsequence match positions (0-based byte indices into `text`),
---for highlighting the matched characters in a rendered row.
---@param text string
---@param query string
---@return integer[]
function M.match_positions(text, query)
	local positions = {}
	local q = M.normalize(query)
	if q == "" then
		return positions
	end
	local lower = text:lower()
	local offset = 1
	for i = 1, #q do
		local found = lower:find(q:sub(i, i), offset, true)
		if not found then
			return {}
		end
		positions[#positions + 1] = found - 1
		offset = found + 1
	end
	return positions
end

return M
