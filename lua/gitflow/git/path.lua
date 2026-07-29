---Decoding of git's C-quoted path output.
---
---Git quotes any porcelain/diff path containing a space, a double quote, a
---backslash, or (unless core.quotepath=false) a non-ASCII byte:
---`café.txt` is reported as `"caf\303\251.txt"`. Passing that literal back to
---`git add --` fails, so every parser of git path output decodes it here.

local M = {}

local SIMPLE_ESCAPES = {
	a = "\a",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
	v = "\v",
	["\\"] = "\\",
	['"'] = '"',
}

---Index of the closing quote of a C-quoted string starting at `open`.
---@param text string
---@param open integer  index of the opening quote
---@return integer|nil
local function closing_quote(text, open)
	local i = open + 1
	while i <= #text do
		local c = text:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif c == '"' then
			return i
		else
			i = i + 1
		end
	end
	return nil
end

---@param body string  the text between the surrounding quotes
---@return string
local function decode_body(body)
	local out = {}
	local i = 1
	while i <= #body do
		local c = body:sub(i, i)
		if c ~= "\\" then
			out[#out + 1] = c
			i = i + 1
		else
			local octal = body:match("^\\([0-7][0-7][0-7])", i)
			local simple = SIMPLE_ESCAPES[body:sub(i + 1, i + 1)]
			if octal then
				out[#out + 1] = string.char(tonumber(octal, 8))
				i = i + 4
			elseif simple then
				out[#out + 1] = simple
				i = i + 2
			else
				-- Unreachable for real git output (quote_c_style emits only the
				-- escapes above); keep the bytes verbatim rather than drop them.
				out[#out + 1] = c
				i = i + 1
			end
		end
	end
	return table.concat(out)
end

---Decode a git path; a path git did not quote is returned unchanged.
---@param path string
---@return string
function M.unquote(path)
	if type(path) ~= "string" or path:sub(1, 1) ~= '"' then
		return path
	end
	local close = closing_quote(path, 1)
	if close ~= #path then
		return path
	end
	return decode_body(path:sub(2, close - 1))
end

---Read one path token: a C-quoted string, or the rest of the line.
---@param text string
---@return string token, string remainder  remainder has no leading space
local function read_token(text)
	if text:sub(1, 1) ~= '"' then
		return text, ""
	end
	local close = closing_quote(text, 1)
	if not close then
		return text, ""
	end
	return text:sub(1, close), (text:sub(close + 1):gsub("^ ", ""))
end

---Split a porcelain rename pathspec (`old -> new`) into its two raw sides.
---Either side is quoted independently; a name containing a literal ` -> ` is
---always quoted (it has spaces), so the quoted scan below cannot mis-split.
---@param pathspec string
---@return string|nil source, string|nil destination  raw, still quoted
function M.split_rename(pathspec)
	if type(pathspec) ~= "string" then
		return nil, nil
	end

	if pathspec:sub(1, 1) == '"' then
		local close = closing_quote(pathspec, 1)
		if not close then
			return nil, nil
		end
		local destination = pathspec:sub(close + 1):match("^ %-%> (.+)$")
		if not destination then
			return nil, nil
		end
		return pathspec:sub(1, close), destination
	end

	local source, destination = pathspec:match("^(.-) %-%> (.+)$")
	if not source or not destination then
		return nil, nil
	end
	return source, destination
end

---Parse a `diff --git` header into decoded old/new paths.
---Git quotes each side independently and the `a/`/`b/` prefix sits INSIDE the
---quotes: `diff --git a/plain.txt "b/\303\274nicode.txt"`.
---@param line string
---@return string|nil old_path, string|nil new_path
function M.parse_diff_header(line)
	local rest = type(line) == "string" and line:match("^diff %-%-git (.+)$") or nil
	if not rest then
		return nil, nil
	end

	local old_raw, new_raw
	if rest:sub(1, 1) == '"' then
		old_raw, new_raw = read_token(rest)
	else
		-- Unquoted source: the destination starts at ` "` if it is quoted,
		-- otherwise fall back to the ambiguous ` b/` split git itself uses.
		local split = rest:find(' "', 1, true)
		if split then
			old_raw, new_raw = rest:sub(1, split - 1), rest:sub(split + 1)
		else
			old_raw, new_raw = rest:match("^(.+) (b/.+)$")
		end
	end

	if not old_raw or not new_raw or new_raw == "" then
		return nil, nil
	end

	local old_path = M.unquote(old_raw):match("^a/(.+)$")
	local new_path = M.unquote(new_raw):match("^b/(.+)$")
	if not old_path or not new_path then
		return nil, nil
	end
	return old_path, new_path
end

return M
