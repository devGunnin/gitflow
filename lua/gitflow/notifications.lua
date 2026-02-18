---@class GitflowNotificationEntry
---@field message string
---@field level integer
---@field timestamp integer

local M = {}

---@type GitflowNotificationEntry[]
local buffer = {}

---@type integer
local max_entries = 200

local function trim_to_capacity()
	while #buffer > max_entries do
		table.remove(buffer, 1)
	end
end

---Configure the ring buffer capacity.
---@param max integer
function M.setup(max)
	max_entries = max or 200
	trim_to_capacity()
end

---Push a new notification into the ring buffer.
---@param message string
---@param level integer|nil
function M.push(message, level)
	buffer[#buffer + 1] = {
		message = message,
		level = level or vim.log.levels.INFO,
		timestamp = os.time(),
	}
	trim_to_capacity()
end

---Return all entries in chronological order (oldest first).
---@return GitflowNotificationEntry[]
function M.entries()
	local copy = {}
	for i, entry in ipairs(buffer) do
		copy[i] = {
			message = entry.message,
			level = entry.level,
			timestamp = entry.timestamp,
		}
	end
	return copy
end

---Return total entry count.
---@return integer
function M.count()
	return #buffer
end

---Clear all stored entries.
function M.clear()
	buffer = {}
end

return M
