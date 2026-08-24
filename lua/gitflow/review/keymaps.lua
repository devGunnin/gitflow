--- Every key review mode binds, declared once.
---
--- Review mode has two key surfaces — the file-list pane and each file opened
--- in the diff pane — and one legend, in the file list, that advertises both.
--- Before this module they were three hand-maintained lists (bind, unbind,
--- advertise) that could and did drift; here a key is declared once with the
--- surfaces it binds on and the legend group it belongs to, and the registries
--- and the legend are all derived from that.
---
--- Actions are looked up with a require inside the closure: those modules bind
--- these entries, so a load-time require would close the cycle.

local M = {}

---@param name string
---@return table
local function mod(name)
	return require("gitflow.review." .. name)
end

--- `surface` is which key registry the entry joins: "list" (the file-list
--- pane), "diff" (every file opened for review) or "both". `group` is the
--- legend block it is advertised under; entries with no `desc` are bound but
--- never advertised.
---@type table[]
local ENTRIES = {
	-- ── navigate ───────────────────────────────────────────────────────
	{ surface = "list", group = "navigate", essential = true,
		key = "<CR>/o", keys = { "<CR>", "o", "<2-LeftMouse>", "<Tab>" },
		desc = "open",
		run = function() mod("file_list").open_under_cursor() end },
	{ surface = "list", group = "navigate", key = "<Tab>", desc = "fold",
		bind = false,
		run = function() mod("file_list").open_under_cursor() end },
	{ surface = "list", key = "za",
		run = function() mod("file_list").toggle_dir_under_cursor() end },
	{ surface = "list", group = "navigate", key = "zR/zM",
		keys = { "zR", "zM" }, desc = "unfold/fold all",
		run = function(key)
			if key == "zR" then
				mod("file_list").expand_all_dirs()
			else
				mod("file_list").collapse_all_dirs()
			end
		end },
	{ surface = "both", group = "navigate", key = "]f/[f",
		keys = { "]f", "[f" }, desc = "file",
		run = function(key)
			if key == "]f" then
				mod("overlay").next_file()
			else
				mod("overlay").prev_file()
			end
		end },
	{ surface = "diff", group = "navigate", key = "]c/[c",
		keys = { "]c", "[c" }, desc = "hunk",
		run = function(key)
			if key == "]c" then
				mod("overlay").next_hunk()
			else
				mod("overlay").prev_hunk()
			end
		end },
	{ surface = "both", group = "navigate", key = "]C/[C",
		keys = { "]C", "[C" }, desc = "comment",
		run = function(key)
			if key == "]C" then
				mod("threads").next_comment()
			else
				mod("threads").prev_comment()
			end
		end },
	{ surface = "both", group = "navigate", key = "<leader>c",
		desc = "all comments",
		run = function() mod("threads").comments_overview() end },

	-- ── review ─────────────────────────────────────────────────────────
	-- `c` comments on the whole file from a file row, and on the cursor's
	-- line (or the selection) from the diff pane: one verb, two surfaces.
	{ surface = "list", group = "review", key = "c", desc = "comment",
		essential = true,
		run = function() mod("comments").file_comment_under_cursor() end },
	{ surface = "diff", group = "review", key = "c", desc = "comment",
		essential = true,
		run = function() mod("comments").inline_comment() end },
	{ surface = "diff", key = "c", mode = "v",
		run = function() mod("comments").inline_comment_visual() end },
	{ surface = "diff", group = "review", key = "s", desc = "suggest",
		run = function() mod("comments").inline_suggestion() end },
	{ surface = "diff", key = "s", mode = "v",
		run = function() mod("comments").inline_suggestion_visual() end },
	{ surface = "diff", group = "review", key = "R", desc = "reply",
		run = function() mod("threads").reply_to_thread() end },
	{ surface = "both", group = "review", key = "S", desc = "submit",
		essential = true,
		run = function() mod("submit").submit_pending_review() end },
	{ surface = "list", group = "review", key = "C", desc = "scope",
		run = function() mod("load").scope_to_commits() end },
	{ surface = "diff", group = "review", key = "<leader>e", desc = "edit",
		run = function() mod("comments").edit_comment_at_cursor() end },
	{ surface = "diff", group = "review", key = "<leader>x", desc = "delete",
		destructive = true,
		run = function() mod("comments").delete_comment_at_cursor() end },
	{ surface = "diff", group = "review", key = "<CR>/<leader>t",
		keys = { "<CR>", "<leader>t" }, desc = "thread",
		run = function(key)
			if key == "<CR>" then
				mod("threads").view_thread_at_cursor()
			else
				mod("threads").toggle_thread()
			end
		end },
	{ surface = "both", group = "review", key = "<leader>d",
		desc = "toggle diff view",
		run = function() mod("overlay").toggle_diff_view() end },
	{ surface = "diff", key = "<leader>i",
		run = function() mod("overlay").toggle_inline_comments() end },

	-- ── drafts ─────────────────────────────────────────────────────────
	-- The file list's Drafts rows reuse keys the tree rows already bind, so
	-- these advertise without binding a second handler.
	{ surface = "list", group = "drafts", key = "<CR>", desc = "jump",
		bind = false,
		run = function() mod("file_list").open_under_cursor() end },
	{ surface = "list", group = "drafts", key = "x", desc = "delete",
		destructive = true,
		run = function() mod("comments").delete_draft_under_cursor() end },
	{ surface = "list", group = "drafts", key = "e", desc = "edit/file",
		run = function() mod("comments").edit_draft_under_cursor() end },
	{ surface = "list", group = "drafts", key = "X", desc = "off-diff",
		destructive = true,
		run = function() mod("comments").delete_off_diff_drafts() end },

	-- ── session ────────────────────────────────────────────────────────
	{ surface = "list", group = "session", key = "r", desc = "refresh",
		run = function() mod("load").refresh() end },
	{ surface = "list", group = "session", key = "q", desc = "close",
		essential = true,
		run = function()
			require("gitflow.panels.review").close_with_guard()
		end },
}

---The legend blocks, in the order the file list draws them.
M.GROUPS = {
	{ id = "navigate", label = "NAVIGATE" },
	{ id = "review", label = "REVIEW" },
	{ id = "drafts", label = "DRAFTS" },
}

---The `session` group is drawn on its own trailing row.
M.SESSION_GROUP = "session"

---Entries for one key surface, shaped for `panel.new{ keymaps = … }`.
---@param surface "list"|"diff"
---@return GitflowPanelKeymap[]
function M.for_surface(surface)
	local out = {}
	for _, entry in ipairs(ENTRIES) do
		if entry.surface == surface or entry.surface == "both" then
			out[#out + 1] = {
				key = entry.key,
				keys = entry.keys,
				desc = entry.desc,
				mode = entry.mode,
				run = entry.run,
				bind = entry.bind,
				-- The legend groups by `group`; the base's `views` is the
				-- field it filters hints on, so they are the same thing.
				views = entry.group and { entry.group } or nil,
				essential = entry.essential,
				destructive = entry.destructive,
			}
		end
	end
	return out
end

---Advertised `{ key, desc }` pairs for one legend group, across both
---surfaces, deduplicated: `c` is declared twice (it does something different
---on each surface) but is one line in the legend.
---@param group string
---@return table[]
function M.hints_for_group(group)
	local out, seen = {}, {}
	for _, entry in ipairs(ENTRIES) do
		local id = entry.key .. "\0" .. tostring(entry.desc)
		if entry.group == group and entry.desc and not seen[id] then
			seen[id] = true
			out[#out + 1] = { entry.key, entry.desc }
		end
	end
	return out
end

return M
